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
  private let queue = DispatchQueue(label: "chronicle.rpc.server")
  private let stateLock = NSLock()
  private var listenFD: Int32 = -1
  private var running = false

  public init(paths: RuntimePaths) {
    self.paths = paths
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
      response = route(request)
    } catch {
      response = RPCProtocol.handleDecodeFailure(data)
    }
    writeAll(response.encodedString() + "\n", fd: clientFD)
  }

  private func route(_ request: RPCRequest) -> RPCResponse {
    if request.method == "status.get" {
      let requestedSource: CaptureSource
      if case .string(let raw)? = request.params?["source"], let source = CaptureSource(rawValue: raw) {
        requestedSource = source
      } else {
        requestedSource = paths.source
      }
      return .success(
        id: request.id,
        result: [
          "source": .string(requestedSource.rawValue),
          "lifecycle": .string(DaemonLifecycle.stopped.rawValue),
          "socket": .string(paths.socketURL.path),
        ]
      )
    }
    return RPCProtocol.dispatch(request, supportedMethods: OpenRPCSchema.registeredMethodNames)
  }
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
