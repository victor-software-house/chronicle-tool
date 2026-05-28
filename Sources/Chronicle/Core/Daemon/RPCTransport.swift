import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum RPCTransportError: Error, Equatable, CustomStringConvertible, Sendable {
  case socketUnavailable(String)
  case pathTooLong(String)
  case invalidResponse(String)

  public var description: String {
    switch self {
    case .socketUnavailable(let message): "socket unavailable: \(message)"
    case .pathTooLong(let path): "unix socket path is too long: \(path)"
    case .invalidResponse(let message): "invalid response: \(message)"
    }
  }
}

public final class RPCServer: @unchecked Sendable {
  public let paths: RuntimePaths
  public let coordinator: DaemonCoordinator?
  public let eventHub: EventHub?
  public let idempotencyStore: IdempotencyStore?
  private let queue = DispatchQueue(label: "chronicle.rpc.server")
  private let stateLock = NSLock()
  private var listenFD: Int32 = -1
  private var running = false

  public init(
    paths: RuntimePaths,
    coordinator: DaemonCoordinator? = nil,
    eventHub: EventHub? = nil,
    idempotencyStore: IdempotencyStore? = nil
  ) {
    self.paths = paths
    self.coordinator = coordinator
    self.eventHub = eventHub
    self.idempotencyStore = idempotencyStore
  }

  deinit {
    stop()
  }

  public func start() throws {
    try paths.prepareDirectories()
    try? FileManager.default.removeItem(at: paths.socketURL)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw RPCTransportError.socketUnavailable(posixMessage()) }

    do {
      try bindUnixSocket(fd: fd, path: paths.socketURL.path)
    } catch {
      close(fd)
      throw error
    }

    guard listen(fd, 16) == 0 else {
      let message = posixMessage()
      close(fd)
      throw RPCTransportError.socketUnavailable(message)
    }

    stateLock.lock()
    listenFD = fd
    running = true
    stateLock.unlock()

    queue.async { [weak self] in
      self?.acceptLoop()
    }
  }

  public func stop() {
    stateLock.lock()
    let fd = listenFD
    listenFD = -1
    running = false
    stateLock.unlock()

    if fd >= 0 {
      shutdown(fd, SHUT_RDWR)
      close(fd)
    }
    try? FileManager.default.removeItem(at: paths.socketURL)
  }

  private func acceptLoop() {
    while isRunning {
      let clientFD = accept(listenFD, nil, nil)
      if clientFD < 0 {
        if isRunning { continue }
        return
      }
      handle(clientFD: clientFD)
    }
  }

  private var isRunning: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return running
  }

  private func handle(clientFD: Int32) {
    defer { close(clientFD) }
    let data = readAll(fd: clientFD)
    let response: RPCResponse
    do {
      let request = try RPCRequest.decode(data)
      if let cached = idempotencyStore?.lookup(request) {
        response = cached
      } else {
        let routed = route(request)
        if let store = idempotencyStore {
          do {
            _ = try store.record(request: request, response: routed, source: paths.source)
            try? store.save(to: paths.idempotencyURL)
          } catch IdempotencyStoreError.conflict(let existing) {
            let conflict = RPCResponse.failure(
              id: request.id,
              error: RPCError(
                code: .malformedRequest,
                message: "client_req_id reuse with different payload for \(request.method)",
                retriable: false,
                hint: "Use a fresh client_req_id for new payloads.",
                details: [
                  "stored_method": .string(existing.method),
                  "stored_client_req_id": .string(existing.clientRequestID.rawValue),
                ]
              )
            )
            writeAll(conflict.encodedString() + "\n", fd: clientFD)
            return
          } catch {
            // Any other persistence error: prefer correctness — return the
            // routed response without persisting (Req 9.3 evidence path
            // remains durable via DaemonEventLog).
          }
        }
        response = routed
      }
    } catch {
      response = RPCProtocol.handleDecodeFailure(data)
    }
    writeAll(response.encodedString() + "\n", fd: clientFD)
  }

  private func route(_ request: RPCRequest) -> RPCResponse {
    switch request.method {
    case "meta.schema":
      return RPCProtocol.dispatch(request, supportedMethods: OpenRPCSchema.registeredMethodNames)

    case "status.get":
      return handleStatus(request)

    case "capture.ensure":
      return handleEnsure(request)

    case "capture.stop":
      return handleStop(request)

    case "capture.reconfigure":
      return handleReconfigure(request)

    case "mark.create":
      return handleMark(request)

    case "clip.create":
      return handleClip(request)

    case "events.subscribe":
      return handleEventsSubscribe(request)

    case "lease.acquire":
      return handleLeaseAcquire(request)

    case "lease.renew":
      return handleLeaseRenew(request)

    case "lease.release":
      return handleLeaseRelease(request)

    default:
      return RPCProtocol.dispatch(request, supportedMethods: OpenRPCSchema.registeredMethodNames)
    }
  }

  private func handleStatus(_ request: RPCRequest) -> RPCResponse {
    let requestedSource: CaptureSource
    if case .string(let raw)? = request.params?["source"], let source = CaptureSource(rawValue: raw) {
      requestedSource = source
    } else {
      requestedSource = paths.source
    }

    guard let coordinator else {
      let stopped = DaemonStatus.stopped(source: requestedSource, paths: paths)
      return .success(id: request.id, result: encodeAsJSONObject(stopped))
    }

    let status = awaitAsync { await coordinator.status() }
    return .success(id: request.id, result: encodeAsJSONObject(status))
  }

  private func handleEnsure(_ request: RPCRequest) -> RPCResponse {
    guard let coordinator else { return coordinatorUnavailable(id: request.id) }
    guard let cid = extractClientRequestID(request) else {
      return .failure(
        id: request.id,
        error: RPCError(
          code: .malformedRequest,
          message: "capture.ensure requires client_req_id.",
          retriable: false,
          hint: "Include a non-empty string client_req_id."
        )
      )
    }
    let outcome = awaitAsyncThrowing { try await coordinator.ensure(clientRequestID: cid) }
    switch outcome {
    case .success(let result):
      return .success(id: request.id, result: encodeAsJSONObject(result))
    case .failure(let error):
      return .failure(
        id: request.id,
        error: RPCError(
          code: .resourceBusy,
          message: "capture.ensure failed: \(error.localizedDescription)",
          retriable: false,
          hint: "Inspect daemon logs and source-owner snapshot before retrying."
        )
      )
    }
  }

  private func handleStop(_ request: RPCRequest) -> RPCResponse {
    guard let coordinator else { return coordinatorUnavailable(id: request.id) }
    guard let cid = extractClientRequestID(request) else {
      return .failure(
        id: request.id,
        error: RPCError(
          code: .malformedRequest,
          message: "capture.stop requires client_req_id.",
          retriable: false,
          hint: "Include a non-empty string client_req_id."
        )
      )
    }
    let result = awaitAsync { await coordinator.stop(clientRequestID: cid) }
    return .success(id: request.id, result: encodeAsJSONObject(result))
  }

  private func handleReconfigure(_ request: RPCRequest) -> RPCResponse {
    guard let coordinator else { return coordinatorUnavailable(id: request.id) }
    guard let cid = extractClientRequestID(request) else {
      return .failure(
        id: request.id,
        error: RPCError(
          code: .malformedRequest,
          message: "capture.reconfigure requires client_req_id.",
          retriable: false,
          hint: "Include a non-empty string client_req_id."
        )
      )
    }
    guard let change = extractChange(request) else {
      return .failure(
        id: request.id,
        error: RPCError(
          code: .malformedRequest,
          message: "capture.reconfigure requires a decodable 'change' field.",
          retriable: false,
          hint: "Supply a LiveCaptureChange JSON payload (object or JSON-encoded string)."
        )
      )
    }
    let result = awaitAsync { await coordinator.reconfigure(change, clientRequestID: cid) }
    if let error = result.error {
      return .failure(id: request.id, error: error)
    }
    let outcomeString: String
    switch result.outcome {
    case .appliedLive: outcomeString = "applied_live"
    case .futureSegment: outcomeString = "future_segment"
    case .rejected: outcomeString = "rejected"
    }
    return .success(id: request.id, result: [
      "source": .string(result.source.rawValue),
      "outcome": .string(outcomeString),
      "status": encodeAsJSON(result.status),
    ])
  }

  private func handleMark(_ request: RPCRequest) -> RPCResponse {
    guard let coordinator else { return coordinatorUnavailable(id: request.id) }
    guard let cid = extractClientRequestID(request) else {
      return .failure(
        id: request.id,
        error: RPCError(
          code: .malformedRequest,
          message: "mark.create requires client_req_id.",
          retriable: false,
          hint: "Include a non-empty string client_req_id."
        )
      )
    }
    let label: String
    if case .string(let raw)? = request.params?["label"] {
      label = raw
    } else {
      return .failure(
        id: request.id,
        error: RPCError(
          code: .malformedRequest,
          message: "mark.create requires a string label.",
          retriable: false,
          hint: "Include a non-empty string label."
        )
      )
    }
    let result = awaitAsync { await coordinator.createMarker(label: label, clientRequestID: cid) }
    if let error = result.error {
      return .failure(id: request.id, error: error)
    }
    var dict: [String: JSONValue] = ["source": .string(result.source.rawValue)]
    if let event = result.event {
      dict["event"] = encodeAsJSON(event)
    }
    return .success(id: request.id, result: dict)
  }

  private func handleClip(_ request: RPCRequest) -> RPCResponse {
    guard let coordinator else { return coordinatorUnavailable(id: request.id) }
    guard let cid = extractClientRequestID(request) else {
      return .failure(
        id: request.id,
        error: RPCError(
          code: .malformedRequest,
          message: "clip.create requires client_req_id.",
          retriable: false,
          hint: "Include a non-empty string client_req_id."
        )
      )
    }
    guard let clipRequest = extractClipRequest(request) else {
      return .failure(
        id: request.id,
        error: RPCError(
          code: .malformedRequest,
          message: "clip.create requires numeric last_seconds and string output.",
          retriable: false,
          hint: "Supply last_seconds > 0 and an absolute output path."
        )
      )
    }
    let result = awaitAsync { await coordinator.createClip(request: clipRequest, clientRequestID: cid) }
    if let error = result.error {
      return .failure(id: request.id, error: error)
    }
    var dict: [String: JSONValue] = ["source": .string(result.source.rawValue)]
    if let outputURL = result.outputURL {
      dict["output"] = .string(outputURL.path)
    }
    if let availableRange = result.availableRange {
      dict["available_range"] = .object(["duration_seconds": .number(availableRange.durationSeconds)])
    }
    return .success(id: request.id, result: dict)
  }

  private func handleLeaseAcquire(_ request: RPCRequest) -> RPCResponse {
    guard let coordinator else { return coordinatorUnavailable(id: request.id) }
    guard let cid = extractClientRequestID(request) else {
      return malformedRequest(id: request.id, method: "lease.acquire", hint: "Include a non-empty string client_req_id.")
    }
    guard case .string(let purpose)? = request.params?["purpose"], !purpose.isEmpty else {
      return malformedRequest(id: request.id, method: "lease.acquire", hint: "Include a non-empty string purpose.")
    }
    guard case .number(let ttl)? = request.params?["ttl"], ttl > 0 else {
      return malformedRequest(id: request.id, method: "lease.acquire", hint: "Include a positive numeric ttl (seconds).")
    }
    let holder: String
    if case .string(let raw)? = request.params?["holder"], !raw.isEmpty {
      holder = raw
    } else {
      holder = cid.rawValue
    }
    let outcome = awaitAsyncThrowing { try await coordinator.acquireCoordinationLease(purpose: purpose, holder: holder, ttl: TimeInterval(ttl)) }
    switch outcome {
    case .success(let lease):
      return .success(id: request.id, result: encodeAsJSONObject(lease))
    case .failure(let error):
      return .failure(
        id: request.id,
        error: RPCError(
          code: .invalidConfig,
          message: "lease.acquire rejected: \(error.localizedDescription)",
          retriable: false,
          hint: "Supply a positive ttl and unique client_req_id."
        )
      )
    }
  }

  private func handleLeaseRenew(_ request: RPCRequest) -> RPCResponse {
    guard let coordinator else { return coordinatorUnavailable(id: request.id) }
    guard extractClientRequestID(request) != nil else {
      return malformedRequest(id: request.id, method: "lease.renew", hint: "Include a non-empty string client_req_id.")
    }
    guard case .string(let raw)? = request.params?["lease_id"], !raw.isEmpty else {
      return malformedRequest(id: request.id, method: "lease.renew", hint: "Include a non-empty string lease_id.")
    }
    guard case .number(let ttl)? = request.params?["ttl"], ttl > 0 else {
      return malformedRequest(id: request.id, method: "lease.renew", hint: "Include a positive numeric ttl (seconds).")
    }
    let leaseID = LeaseID(rawValue: raw)
    let outcome = awaitAsyncThrowing { try await coordinator.renewCoordinationLease(id: leaseID, ttl: TimeInterval(ttl)) }
    switch outcome {
    case .success(let lease):
      return .success(id: request.id, result: encodeAsJSONObject(lease))
    case .failure:
      return .failure(
        id: request.id,
        error: RPCError(
          code: .noActiveSession,
          message: "lease.renew failed: lease not found or expired.",
          retriable: false,
          hint: "Call lease.acquire again with a fresh client_req_id."
        )
      )
    }
  }

  private func handleLeaseRelease(_ request: RPCRequest) -> RPCResponse {
    guard let coordinator else { return coordinatorUnavailable(id: request.id) }
    guard extractClientRequestID(request) != nil else {
      return malformedRequest(id: request.id, method: "lease.release", hint: "Include a non-empty string client_req_id.")
    }
    guard case .string(let raw)? = request.params?["lease_id"], !raw.isEmpty else {
      return malformedRequest(id: request.id, method: "lease.release", hint: "Include a non-empty string lease_id.")
    }
    let leaseID = LeaseID(rawValue: raw)
    let outcome = awaitAsyncThrowing { try await coordinator.releaseCoordinationLease(id: leaseID) }
    switch outcome {
    case .success(let lease):
      return .success(id: request.id, result: [
        "released": .bool(true),
        "lease": encodeAsJSON(lease),
      ])
    case .failure:
      return .success(id: request.id, result: [
        "released": .bool(false),
        "lease_id": .string(raw),
      ])
    }
  }

  private func malformedRequest(id: RPCID?, method: String, hint: String) -> RPCResponse {
    .failure(
      id: id,
      error: RPCError(
        code: .malformedRequest,
        message: "\(method) request is malformed.",
        retriable: false,
        hint: hint
      )
    )
  }

  private func extractClientRequestID(_ request: RPCRequest) -> ClientRequestID? {
    if case .string(let raw)? = request.params?["client_req_id"], !raw.isEmpty {
      return ClientRequestID(rawValue: raw)
    }
    return nil
  }

  private func extractChange(_ request: RPCRequest) -> LiveCaptureChange? {
    let decoder = RPCProtocol.decoder()
    switch request.params?["change"] {
    case .string(let raw)?:
      guard let data = raw.data(using: .utf8) else { return nil }
      return try? decoder.decode(LiveCaptureChange.self, from: data)
    case .object(let dict)?:
      let encoder = RPCProtocol.encoder()
      guard let data = try? encoder.encode(dict) else { return nil }
      return try? decoder.decode(LiveCaptureChange.self, from: data)
    default:
      return nil
    }
  }

  private func extractClipRequest(_ request: RPCRequest) -> ClipRequest? {
    guard case .number(let seconds)? = request.params?["last_seconds"],
          case .string(let outputPath)? = request.params?["output"] else { return nil }
    return ClipRequest(lastSeconds: TimeInterval(seconds), outputURL: URL(fileURLWithPath: outputPath))
  }

  private func coordinatorUnavailable(id: RPCID?) -> RPCResponse {
    .failure(
      id: id,
      error: RPCError(
        code: .daemonUnavailable,
        message: "Daemon coordinator is not attached to this RPC server.",
        retriable: false,
        hint: "Start the daemon through Daemon.start so the coordinator is wired into the RPC server."
      )
    )
  }

  private func handleEventsSubscribe(_ request: RPCRequest) -> RPCResponse {
    let filter = extractEventFilter(request.params)
    let events: [DaemonEvent]
    do {
      events = try DaemonEventLog.read(url: paths.logURL)
    } catch {
      return .failure(
        id: request.id,
        error: RPCError(
          code: .rangeUnavailable,
          message: "Failed to read durable event log: \(error.localizedDescription)",
          retriable: true,
          hint: "Inspect the daemon log file for malformed records.",
          details: ["log": .string(paths.logURL.path)]
        )
      )
    }
    let filtered = events.filter { filter.matches($0) }
    let payload = filtered.map { encodeAsJSON($0) }
    return .success(id: request.id, result: [
      "source": .string(paths.source.rawValue),
      "events": .array(payload),
    ])
  }

  private func extractEventFilter(_ params: [String: JSONValue]?) -> EventFilter {
    var source: CaptureSource?
    if case .string(let raw)? = params?["source"], let parsed = CaptureSource(rawValue: raw) {
      source = parsed
    }
    var streams: Set<DaemonEventStream>?
    if case .string(let raw)? = params?["streams"] {
      let parsed = raw.split(separator: ",").compactMap { DaemonEventStream(rawValue: String($0)) }
      if !parsed.isEmpty { streams = Set(parsed) }
    }
    var typePrefix: String?
    if case .string(let raw)? = params?["type_prefix"] { typePrefix = raw }
    var sinceSequence: Int?
    if case .number(let raw)? = params?["since_sequence"] { sinceSequence = Int(raw) }
    var includeHeartbeat = true
    if case .bool(let raw)? = params?["include_heartbeat"] { includeHeartbeat = raw }
    return EventFilter(
      source: source,
      streams: streams,
      typePrefix: typePrefix,
      sinceSequence: sinceSequence,
      includeHeartbeat: includeHeartbeat
    )
  }
}

private final class ResultBox<T>: @unchecked Sendable {
  var value: T?
}

@discardableResult
private func awaitAsync<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
  let semaphore = DispatchSemaphore(value: 0)
  let box = ResultBox<T>()
  Task {
    let result = await body()
    box.value = result
    semaphore.signal()
  }
  semaphore.wait()
  return box.value!
}

private func awaitAsyncThrowing<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
  let semaphore = DispatchSemaphore(value: 0)
  let box = ResultBox<Result<T, Error>>()
  Task {
    do {
      let result = try await body()
      box.value = .success(result)
    } catch {
      box.value = .failure(error)
    }
    semaphore.signal()
  }
  semaphore.wait()
  return box.value!
}

private func encodeAsJSON<T: Encodable>(_ value: T) -> JSONValue {
  do {
    let data = try RPCProtocol.encoder().encode(value)
    return try RPCProtocol.decoder().decode(JSONValue.self, from: data)
  } catch {
    return .null
  }
}

private func encodeAsJSONObject<T: Encodable>(_ value: T) -> [String: JSONValue] {
  if case .object(let dict) = encodeAsJSON(value) { return dict }
  return [:]
}

public struct ChronicleRPCClient: Sendable {
  public let socketURL: URL

  public init(socketURL: URL) {
    self.socketURL = socketURL
  }

  public func send(_ request: RPCRequest) async throws -> RPCResponse {
    let data = try RPCProtocol.encoder().encode(request)
    let raw = try await Self.sendRaw(String(decoding: data, as: UTF8.self) + "\n", to: socketURL)
    guard let responseData = raw.data(using: .utf8) else {
      throw RPCTransportError.invalidResponse("response was not utf8")
    }
    return try RPCProtocol.decoder().decode(RPCResponse.self, from: responseData)
  }

  public func sendOrStructuredError(_ request: RPCRequest) async -> RPCResponse {
    do {
      return try await send(request)
    } catch {
      return .failure(
        id: request.id,
        error: RPCError(
          code: .daemonUnavailable,
          message: "Daemon unavailable",
          retriable: true,
          hint: "Start the Chronicle daemon for this source, then retry the request.",
          details: ["socket": .string(socketURL.path)]
        )
      )
    }
  }

  public static func sendRaw(_ raw: String, to socketURL: URL) async throws -> String {
    try await Task.detached {
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      guard fd >= 0 else { throw RPCTransportError.socketUnavailable(posixMessage()) }
      defer { close(fd) }
      try connectUnixSocket(fd: fd, path: socketURL.path)
      writeAll(raw, fd: fd)
      shutdown(fd, SHUT_WR)
      return String(decoding: readAll(fd: fd), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }.value
  }
}

private func bindUnixSocket(fd: Int32, path: String) throws {
  var addr = try sockaddrUnix(path: path)
  let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
  let result = withUnsafePointer(to: &addr) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
      bind(fd, sockaddrPointer, length)
    }
  }
  guard result == 0 else { throw RPCTransportError.socketUnavailable(posixMessage()) }
}

private func connectUnixSocket(fd: Int32, path: String) throws {
  var addr = try sockaddrUnix(path: path)
  let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
  let result = withUnsafePointer(to: &addr) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
      connect(fd, sockaddrPointer, length)
    }
  }
  guard result == 0 else { throw RPCTransportError.socketUnavailable(posixMessage()) }
}

private func sockaddrUnix(path: String) throws -> sockaddr_un {
  guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
    throw RPCTransportError.pathTooLong(path)
  }
  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
    path.withCString { cString in
      buffer.copyMemory(from: UnsafeRawBufferPointer(start: cString, count: path.utf8.count + 1))
    }
  }
  return addr
}

private func readAll(fd: Int32) -> Data {
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 4096)
  while true {
    let count = read(fd, &buffer, buffer.count)
    if count > 0 {
      data.append(buffer, count: count)
    } else {
      return data
    }
  }
}

private func writeAll(_ string: String, fd: Int32) {
  let bytes = Array(string.utf8)
  bytes.withUnsafeBytes { rawBuffer in
    var remaining = rawBuffer.count
    var pointer = rawBuffer.baseAddress
    while remaining > 0 {
      let written = write(fd, pointer, remaining)
      if written <= 0 { return }
      remaining -= written
      pointer = pointer?.advanced(by: written)
    }
  }
}

private func posixMessage() -> String {
  String(cString: strerror(errno))
}
