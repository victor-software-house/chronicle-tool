import ChronicleCore
import ArgumentParser
import ChronicleCore
import Foundation

/// Common option group for daemon/client subcommands. Local-only by design.
struct DaemonSourceOption: ParsableArguments {
  @Option(name: .long, help: "Capture source: 'mic' or 'sysaudio'.")
  var source: String

  func resolved() throws -> CaptureSource {
    guard let captured = CaptureSource(rawValue: source) else {
      throw ValidationError("source must be 'mic' or 'sysaudio'")
    }
    return captured
  }
}

private func defaultRuntimePaths(for source: CaptureSource) -> RuntimePaths {
  RuntimePaths(source: source)
}

private func printResponse(_ response: RPCResponse) {
  print(response.encodedString())
}

struct DaemonGroup: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "daemon",
    abstract: "Chronicle source-owner daemon: run the local capture owner and talk to it.",
    subcommands: [
      DaemonRun.self,
      DaemonStart.self,
      DaemonStop.self,
      DaemonStatusCommand.self,
      DaemonTail.self,
      DaemonMark.self,
      DaemonClip.self,
      DaemonConfig.self,
    ],
    defaultSubcommand: nil
  )
}

struct DaemonRun: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run",
    abstract: "Run the Chronicle source-owner daemon for one physical source."
  )

  @OptionGroup var source: DaemonSourceOption

  mutating func run() async throws {
    let captured = try source.resolved()
    let paths = defaultRuntimePaths(for: captured)
    let configuration = LiveCaptureConfiguration.direct(
      source: captured,
      locale: "auto",
      output: nil,
      append: nil,
      live: nil,
      saveAudio: nil,
      audioFormat: "alac",
      diarize: false
    )
    let daemon = Daemon(paths: paths, configuration: configuration)
    try await daemon.start(heartbeatInterval: 1.0)
    FileHandle.standardError.write(Data("[daemon-run] source=\(captured.rawValue) socket=\(paths.socketURL.path)\n".utf8))
    await SignalHandler.waitForTermination()
    await daemon.stop()
  }
}

struct DaemonStart: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "start",
    abstract: "Send capture.ensure to the local daemon."
  )

  @OptionGroup var source: DaemonSourceOption
  @Option(name: .long, help: "Idempotency key for the start request.")
  var clientReqId: String = UUID().uuidString.lowercased()

  mutating func run() async throws {
    let captured = try source.resolved()
    let response = await StartClient.send(
      paths: defaultRuntimePaths(for: captured),
      clientRequestID: ClientRequestID(rawValue: clientReqId)
    )
    printResponse(response)
  }
}

struct DaemonStop: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "stop",
    abstract: "Send capture.stop to the local daemon."
  )

  @OptionGroup var source: DaemonSourceOption
  @Option(name: .long, help: "Idempotency key for the stop request.")
  var clientReqId: String = UUID().uuidString.lowercased()

  mutating func run() async throws {
    let captured = try source.resolved()
    let response = await StopClient.send(
      paths: defaultRuntimePaths(for: captured),
      clientRequestID: ClientRequestID(rawValue: clientReqId)
    )
    printResponse(response)
  }
}

struct DaemonStatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Query status.get from the local daemon."
  )

  @OptionGroup var source: DaemonSourceOption

  mutating func run() async throws {
    let captured = try source.resolved()
    let response = await StatusClient.fetch(paths: defaultRuntimePaths(for: captured))
    printResponse(response)
  }
}

struct DaemonTail: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tail",
    abstract: "Subscribe to local daemon events.subscribe."
  )

  @OptionGroup var source: DaemonSourceOption
  @Option(name: .long, help: "Comma-separated streams to subscribe to.")
  var streams: String?
  @Option(name: .long, help: "Filter to events whose type starts with this prefix.")
  var typePrefix: String?
  @Option(name: .long, help: "Resume from this sequence (exclusive lower bound).")
  var sinceSequence: Int?
  @Flag(name: .long, inversion: .prefixedNo, help: "Include heartbeat events.")
  var heartbeat: Bool = true

  mutating func run() async throws {
    let captured = try source.resolved()
    let streamValues = streams?.split(separator: ",").compactMap { DaemonEventStream(rawValue: String($0)) }
    let request = TailRequest(
      source: captured,
      streams: streamValues,
      typePrefix: typePrefix,
      sinceSequence: sinceSequence,
      includeHeartbeat: heartbeat
    )
    let response = await TailClient.send(paths: defaultRuntimePaths(for: captured), request: request)
    printResponse(response)
  }
}

struct DaemonMark: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mark",
    abstract: "Create a marker on the active daemon session."
  )

  @OptionGroup var source: DaemonSourceOption
  @Argument(help: "Marker label.")
  var label: String
  @Option(name: .long, help: "Idempotency key for the marker request.")
  var clientReqId: String = UUID().uuidString.lowercased()

  mutating func run() async throws {
    let captured = try source.resolved()
    let response = await MarkClient.send(
      paths: defaultRuntimePaths(for: captured),
      label: label,
      clientRequestID: ClientRequestID(rawValue: clientReqId)
    )
    printResponse(response)
  }
}

struct DaemonClip: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "clip",
    abstract: "Export a bounded recent clip from retained scratch."
  )

  @OptionGroup var source: DaemonSourceOption
  @Option(name: .long, help: "Last N seconds to export.")
  var lastSeconds: Double
  @Option(name: .long, help: "Output file path (.wav or .caf).")
  var output: String
  @Option(name: .long, help: "Idempotency key for the clip request.")
  var clientReqId: String = UUID().uuidString.lowercased()

  mutating func run() async throws {
    let captured = try source.resolved()
    let request = ClipRequest(lastSeconds: lastSeconds, outputURL: URL(fileURLWithPath: output))
    let response = await ClipClient.send(
      paths: defaultRuntimePaths(for: captured),
      request: request,
      clientRequestID: ClientRequestID(rawValue: clientReqId)
    )
    printResponse(response)
  }
}

struct DaemonConfig: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "config",
    abstract: "Hot-reconfigure the active daemon capture."
  )

  @OptionGroup var source: DaemonSourceOption
  @Option(name: .long, help: "Enable or disable diarization (true/false).")
  var diarize: Bool?
  @Option(name: .long, help: "Override audio format (e.g. alac, wav).")
  var audioFormat: String?
  @Option(name: .long, help: "Idempotency key for the reconfigure request.")
  var clientReqId: String = UUID().uuidString.lowercased()

  mutating func run() async throws {
    let captured = try source.resolved()
    let change: LiveCaptureChange
    if let diarize {
      change = .setDiarization(enabled: diarize)
    } else if let audioFormat {
      change = .setAudioFormat(audioFormat)
    } else {
      throw ValidationError("config requires --diarize or --audio-format")
    }
    let response = await ConfigClient.send(
      paths: defaultRuntimePaths(for: captured),
      change: change,
      clientRequestID: ClientRequestID(rawValue: clientReqId)
    )
    printResponse(response)
  }
}
