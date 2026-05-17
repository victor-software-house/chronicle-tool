import Foundation
@preconcurrency import AVFoundation

public enum ScratchExportContainer: String, CaseIterable, Sendable {
  case wav
  case alac

  public static func infer(from url: URL) throws -> ScratchExportContainer {
    switch url.pathExtension.lowercased() {
    case "caf": return .alac
    case "wav": return .wav
    default: throw ScratchExportError.unsupportedOutputExtension(url.pathExtension)
    }
  }
}

public struct ScratchFormatManifest: Decodable, Sendable {
  public let sampleRate: Double
  public let channelCount: Int
  public let commonFormat: String
  public let interleaved: Bool
  public let bitsPerChannel: Int
  public let ttl: Double?
  public let rotateInterval: Double?

  public var bytesPerSample: Int? {
    switch commonFormat {
    case "float32", "int32": return 4
    case "int16": return 2
    default: return nil
    }
  }

  public var avCommonFormat: AVAudioCommonFormat? {
    switch commonFormat {
    case "float32": return .pcmFormatFloat32
    case "int16": return .pcmFormatInt16
    case "int32": return .pcmFormatInt32
    default: return nil
    }
  }
}

public struct ScratchExportSummary: Sendable {
  public let segmentCount: Int
  public let framesWritten: Int64
  public let bytesRead: Int64
  public let bytesTrimmed: Int64
  public let outputURL: URL
}

public enum ScratchExportError: Error, CustomStringConvertible, Equatable {
  case manifestMissing(URL)
  case invalidManifest(String)
  case unsupportedFormat(String)
  case unsupportedOutputExtension(String)
  case unsupportedLayout(interleaved: Bool)
  case noSegments(URL)
  case invalidSegmentName(String)
  case missingSegment(expected: String)
  case outputInsideScratch(URL)
  case outputIsDirectory(URL)
  case emptySegment(URL)
  case bufferAllocationFailed(frames: Int)
  case bufferCopyFailed(URL)

  public var description: String {
    switch self {
    case .manifestMissing(let url):
      return "Scratch manifest missing: \(url.path)"
    case .invalidManifest(let message):
      return "Invalid scratch manifest: \(message)"
    case .unsupportedFormat(let format):
      return "Unsupported scratch commonFormat: \(format)"
    case .unsupportedOutputExtension(let ext):
      return "Unsupported scratch export output extension: \(ext.isEmpty ? "<none>" : ext). Use .wav, .caf, or pass --format explicitly."
    case .unsupportedLayout(let interleaved):
      return "Unsupported scratch layout: interleaved=\(interleaved). Only canonical interleaved scratch is exportable."
    case .noSegments(let dir):
      return "No .pcm scratch segments found in \(dir.path)"
    case .invalidSegmentName(let name):
      return "Invalid scratch segment name: \(name)"
    case .missingSegment(let expected):
      return "Missing scratch segment: \(expected)"
    case .outputInsideScratch(let url):
      return "Scratch export output must not be inside the scratch directory: \(url.path)"
    case .outputIsDirectory(let url):
      return "Scratch export output path is a directory: \(url.path)"
    case .emptySegment(let url):
      return "Scratch segment has no complete frame: \(url.path)"
    case .bufferAllocationFailed(let frames):
      return "Failed to allocate scratch export buffer for \(frames) frames"
    case .bufferCopyFailed(let url):
      return "Failed to copy scratch bytes into AVAudioPCMBuffer: \(url.path)"
    }
  }
}

public enum ScratchExporter {
  public static func export(
    scratchDirectory: URL,
    outputURL: URL,
    container: ScratchExportContainer? = nil
  ) async throws -> ScratchExportSummary {
    let manifest = try readManifest(from: scratchDirectory)
    try validate(manifest)

    let segmentURLs = try listContiguousSegments(in: scratchDirectory)
    let outputContainer = try container ?? ScratchExportContainer.infer(from: outputURL)
    let format = try audioFormat(from: manifest)
    let bytesPerFrame = try bytesPerFrame(from: manifest)

    try validateOutputURL(outputURL, scratchDirectory: scratchDirectory)
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try FileManager.default.removeItem(at: outputURL)
    }
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    var framesWritten: Int64 = 0
    var bytesRead: Int64 = 0
    var bytesTrimmed: Int64 = 0

    switch outputContainer {
    case .wav:
      let file = try AVAudioFile(
        forWriting: outputURL,
        settings: format.settings,
        commonFormat: format.commonFormat,
        interleaved: format.isInterleaved
      )
      defer {
        if #available(macOS 15.0, *) {
          file.close()
        }
      }
      for url in segmentURLs {
        let result = try makeBuffer(from: url, format: format, bytesPerFrame: bytesPerFrame)
        bytesRead += Int64(result.bytesRead)
        bytesTrimmed += Int64(result.bytesTrimmed)
        try file.write(from: result.buffer)
        framesWritten += Int64(result.buffer.frameLength)
      }

    case .alac:
      let sink = try AVAudioFileALACSink(url: outputURL, sourceFormat: format)
      do {
        for url in segmentURLs {
          let result = try makeBuffer(from: url, format: format, bytesPerFrame: bytesPerFrame)
          bytesRead += Int64(result.bytesRead)
          bytesTrimmed += Int64(result.bytesTrimmed)
          let writtenFrames = try sink.appendOrThrow(result.buffer)
          framesWritten += Int64(writtenFrames)
        }
      } catch {
        await sink.finish()
        throw error
      }
      await sink.finish()
    }

    return ScratchExportSummary(
      segmentCount: segmentURLs.count,
      framesWritten: framesWritten,
      bytesRead: bytesRead,
      bytesTrimmed: bytesTrimmed,
      outputURL: outputURL
    )
  }

  private static func readManifest(from dir: URL) throws -> ScratchFormatManifest {
    let manifestURL = dir.appendingPathComponent("format.json")
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
      throw ScratchExportError.manifestMissing(manifestURL)
    }
    do {
      let data = try Data(contentsOf: manifestURL)
      return try JSONDecoder().decode(ScratchFormatManifest.self, from: data)
    } catch {
      throw ScratchExportError.invalidManifest(error.localizedDescription)
    }
  }

  private static func validate(_ manifest: ScratchFormatManifest) throws {
    guard manifest.sampleRate > 0, manifest.channelCount > 0 else {
      throw ScratchExportError.invalidManifest("sampleRate and channelCount must be positive")
    }
    guard manifest.interleaved else {
      throw ScratchExportError.unsupportedLayout(interleaved: manifest.interleaved)
    }
    guard manifest.bytesPerSample != nil, manifest.avCommonFormat != nil else {
      throw ScratchExportError.unsupportedFormat(manifest.commonFormat)
    }
    guard manifest.bitsPerChannel > 0 else {
      throw ScratchExportError.invalidManifest("bitsPerChannel must be positive")
    }
  }

  private static func listContiguousSegments(in dir: URL) throws -> [URL] {
    let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    let segmentURLs = entries.filter { $0.pathExtension == "pcm" }
    guard !segmentURLs.isEmpty else { throw ScratchExportError.noSegments(dir) }

    let sortedSegments = try segmentURLs.map { url -> (index: Int, url: URL) in
      guard let index = Int(url.deletingPathExtension().lastPathComponent) else {
        throw ScratchExportError.invalidSegmentName(url.lastPathComponent)
      }
      return (index, url)
    }.sorted { $0.index < $1.index }
    guard let first = sortedSegments.first?.index else { throw ScratchExportError.noSegments(dir) }
    for (offset, segment) in sortedSegments.enumerated() {
      let expectedIndex = first + offset
      guard segment.index == expectedIndex else {
        throw ScratchExportError.missingSegment(expected: String(format: "%06d.pcm", expectedIndex))
      }
    }
    return sortedSegments.map(\.url)
  }

  private static func validateOutputURL(_ outputURL: URL, scratchDirectory: URL) throws {
    let output = outputURL.resolvingSymlinksInPath().standardizedFileURL
    let scratch = scratchDirectory.resolvingSymlinksInPath().standardizedFileURL
    let scratchPath = scratch.path.hasSuffix("/") ? scratch.path : scratch.path + "/"
    guard output != scratch, !output.path.hasPrefix(scratchPath) else {
      throw ScratchExportError.outputInsideScratch(outputURL)
    }

    var isDirectory = ObjCBool(false)
    if FileManager.default.fileExists(atPath: outputURL.path, isDirectory: &isDirectory),
       isDirectory.boolValue
    {
      throw ScratchExportError.outputIsDirectory(outputURL)
    }
  }

  private static func audioFormat(from manifest: ScratchFormatManifest) throws -> AVAudioFormat {
    guard let commonFormat = manifest.avCommonFormat else {
      throw ScratchExportError.unsupportedFormat(manifest.commonFormat)
    }
    guard let format = AVAudioFormat(
      commonFormat: commonFormat,
      sampleRate: manifest.sampleRate,
      channels: AVAudioChannelCount(manifest.channelCount),
      interleaved: true
    ) else {
      throw ScratchExportError.invalidManifest("failed to create AVAudioFormat")
    }
    return format
  }

  private static func bytesPerFrame(from manifest: ScratchFormatManifest) throws -> Int {
    guard let bytesPerSample = manifest.bytesPerSample else {
      throw ScratchExportError.unsupportedFormat(manifest.commonFormat)
    }
    return bytesPerSample * manifest.channelCount
  }

  private struct BufferResult {
    let buffer: AVAudioPCMBuffer
    let bytesRead: Int
    let bytesTrimmed: Int
  }

  private static func makeBuffer(
    from url: URL,
    format: AVAudioFormat,
    bytesPerFrame: Int
  ) throws -> BufferResult {
    let data = try Data(contentsOf: url)
    let completeBytes = data.count - (data.count % bytesPerFrame)
    let trimmed = data.count - completeBytes
    guard completeBytes > 0 else { throw ScratchExportError.emptySegment(url) }

    let frames = completeBytes / bytesPerFrame
    guard let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: AVAudioFrameCount(frames)
    ) else {
      throw ScratchExportError.bufferAllocationFailed(frames: frames)
    }
    buffer.frameLength = AVAudioFrameCount(frames)

    guard let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData else {
      throw ScratchExportError.bufferCopyFailed(url)
    }
    data.withUnsafeBytes { source in
      if let sourceAddress = source.baseAddress {
        destination.copyMemory(from: sourceAddress, byteCount: completeBytes)
      }
    }
    buffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = UInt32(completeBytes)

    return BufferResult(buffer: buffer, bytesRead: data.count, bytesTrimmed: trimmed)
  }
}
