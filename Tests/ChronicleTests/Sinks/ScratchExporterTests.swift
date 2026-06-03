import Testing
import Foundation
import AVFoundation
@testable import ChronicleCore

@Suite("ScratchExporter")
struct ScratchExporterTests {
  private func tmpDir() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("ScratchExporterTests.\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func tmpOutput(_ extensionName: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("ScratchExporterTests.\(UUID().uuidString).recovered.\(extensionName)")
  }

  private func writeManifest(
    _ dir: URL,
    commonFormat: String,
    bitsPerChannel: Int,
    sampleRate: Double = 16_000,
    channelCount: Int = 1,
    interleaved: Bool = true
  ) throws {
    let manifest: [String: Any] = [
      "sampleRate": sampleRate,
      "channelCount": channelCount,
      "commonFormat": commonFormat,
      "interleaved": interleaved,
      "bitsPerChannel": bitsPerChannel,
      "ttl": 300.0,
      "rotateInterval": 30.0
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: dir.appendingPathComponent("format.json"))
  }

  private func writeBytes<T>(_ values: [T], to url: URL) throws {
    let data = values.withUnsafeBufferPointer { buffer in
      Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<T>.stride)
    }
    try data.write(to: url)
  }

  private func readInt16Values(from url: URL, channels: AVAudioChannelCount) throws -> [Int16] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let byteCount = Int(buffer.frameLength) * Int(channels) * MemoryLayout<Int16>.size
    guard let source = buffer.audioBufferList.pointee.mBuffers.mData else { return [] }
    return Data(bytes: source, count: byteCount).withUnsafeBytes { raw in
      Array(raw.bindMemory(to: Int16.self))
    }
  }

  private func readFloatValues(from url: URL, channels: AVAudioChannelCount) throws -> [Float] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let byteCount = Int(buffer.frameLength) * Int(channels) * MemoryLayout<Float>.size
    guard let source = buffer.audioBufferList.pointee.mBuffers.mData else { return [] }
    return Data(bytes: source, count: byteCount).withUnsafeBytes { raw in
      Array(raw.bindMemory(to: Float.self))
    }
  }

  @Test("exports interleaved Int16 stereo scratch to WAV")
  func exportsInt16StereoWAV() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeManifest(dir, commonFormat: "int16", bitsPerChannel: 16, channelCount: 2)
    try writeBytes([Int16(1), -1, 2, -2], to: dir.appendingPathComponent("000000.pcm"))
    try writeBytes([Int16(3), -3], to: dir.appendingPathComponent("000001.pcm"))

    let output = tmpOutput("wav")
    defer { try? FileManager.default.removeItem(at: output) }
    let summary = try await ScratchExporter.export(scratchDirectory: dir, outputURL: output, container: .wav)

    #expect(summary.segmentCount == 2)
    #expect(summary.framesWritten == 3)
    #expect(summary.bytesTrimmed == 0)
    #expect(try readInt16Values(from: output, channels: 2) == [1, -1, 2, -2, 3, -3])
  }

  @Test("exports Float32 mono scratch to WAV")
  func exportsFloat32MonoWAV() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeManifest(dir, commonFormat: "float32", bitsPerChannel: 32)
    try writeBytes([Float(0.25), -0.5, 0.75], to: dir.appendingPathComponent("000000.pcm"))

    let output = tmpOutput("wav")
    defer { try? FileManager.default.removeItem(at: output) }
    let summary = try await ScratchExporter.export(scratchDirectory: dir, outputURL: output, container: .wav)

    #expect(summary.framesWritten == 3)
    #expect(try readFloatValues(from: output, channels: 1) == [0.25, -0.5, 0.75])
  }

  @Test("exports Int16 mono scratch to ALAC CAF")
  func exportsInt16MonoALAC() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeManifest(dir, commonFormat: "int16", bitsPerChannel: 16)
    try writeBytes([Int16(100), 200, -300], to: dir.appendingPathComponent("000000.pcm"))

    let output = tmpOutput("caf")
    defer { try? FileManager.default.removeItem(at: output) }
    let summary = try await ScratchExporter.export(scratchDirectory: dir, outputURL: output, container: .alac)
    let file = try AVAudioFile(forReading: output)

    #expect(summary.framesWritten == 3)
    #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatAppleLossless)
    #expect(try readInt16Values(from: output, channels: 1) == [100, 200, -300])
  }

  @Test("trims partial trailing frames")
  func trimsPartialTrailingFrames() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeManifest(dir, commonFormat: "int16", bitsPerChannel: 16)
    var data = Data()
    data.append(contentsOf: [0x01, 0x00, 0x02, 0x00, 0xff])
    try data.write(to: dir.appendingPathComponent("000000.pcm"))

    let output = tmpOutput("wav")
    defer { try? FileManager.default.removeItem(at: output) }
    let summary = try await ScratchExporter.export(scratchDirectory: dir, outputURL: output, container: .wav)

    #expect(summary.framesWritten == 2)
    #expect(summary.bytesTrimmed == 1)
    #expect(try readInt16Values(from: output, channels: 1) == [1, 2])
  }

  @Test("throws on missing manifest")
  func throwsOnMissingManifest() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeBytes([Int16(1)], to: dir.appendingPathComponent("000000.pcm"))

    do {
      _ = try await ScratchExporter.export(scratchDirectory: dir, outputURL: dir.appendingPathComponent("out.wav"))
      Issue.record("expected missing manifest error")
    } catch ScratchExportError.manifestMissing(let url) {
      #expect(url.lastPathComponent == "format.json")
    }
  }

  @Test("refuses output inside scratch directory")
  func refusesOutputInsideScratchDirectory() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeManifest(dir, commonFormat: "int16", bitsPerChannel: 16)
    let segmentURL = dir.appendingPathComponent("000000.pcm")
    try writeBytes([Int16(1)], to: segmentURL)

    do {
      _ = try await ScratchExporter.export(scratchDirectory: dir, outputURL: segmentURL, container: .wav)
      Issue.record("expected output-inside-scratch error")
    } catch ScratchExportError.outputInsideScratch(let url) {
      #expect(url == segmentURL)
      #expect(FileManager.default.fileExists(atPath: segmentURL.path))
    }
  }

  @Test("throws on unsupported inferred output extension")
  func throwsOnUnsupportedOutputExtension() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeManifest(dir, commonFormat: "int16", bitsPerChannel: 16)
    try writeBytes([Int16(1)], to: dir.appendingPathComponent("000000.pcm"))

    do {
      _ = try await ScratchExporter.export(scratchDirectory: dir, outputURL: dir.appendingPathComponent("out.m4a"))
      Issue.record("expected unsupported output extension error")
    } catch ScratchExportError.unsupportedOutputExtension(let ext) {
      #expect(ext == "m4a")
    }
  }

  @Test("throws on invalid manifest JSON")
  func throwsOnInvalidManifest() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("{".utf8).write(to: dir.appendingPathComponent("format.json"))
    try writeBytes([Int16(1)], to: dir.appendingPathComponent("000000.pcm"))

    do {
      _ = try await ScratchExporter.export(scratchDirectory: dir, outputURL: dir.appendingPathComponent("out.wav"))
      Issue.record("expected invalid manifest error")
    } catch ScratchExportError.invalidManifest(let message) {
      #expect(!message.isEmpty)
    }
  }

  @Test("throws on missing middle segment")
  func throwsOnMissingMiddleSegment() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeManifest(dir, commonFormat: "int16", bitsPerChannel: 16)
    try writeBytes([Int16(1)], to: dir.appendingPathComponent("000000.pcm"))
    try writeBytes([Int16(3)], to: dir.appendingPathComponent("000002.pcm"))

    do {
      _ = try await ScratchExporter.export(scratchDirectory: dir, outputURL: dir.appendingPathComponent("out.wav"))
      Issue.record("expected missing segment error")
    } catch ScratchExportError.missingSegment(let expected) {
      #expect(expected == "000001.pcm")
    }
  }

  @Test("throws on unsupported non-interleaved manifest")
  func throwsOnNonInterleavedManifest() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeManifest(dir, commonFormat: "int16", bitsPerChannel: 16, interleaved: false)
    try writeBytes([Int16(1)], to: dir.appendingPathComponent("000000.pcm"))

    do {
      _ = try await ScratchExporter.export(scratchDirectory: dir, outputURL: dir.appendingPathComponent("out.wav"))
      Issue.record("expected unsupported layout error")
    } catch ScratchExportError.unsupportedLayout(let interleaved) {
      #expect(interleaved == false)
    }
  }
}
