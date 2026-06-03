import Testing
import Foundation
import AVFoundation
import AudioToolbox
@testable import Chronicle
@testable import ChronicleCore

@Suite("ExtAudioFile ALAC sink")
struct ExtAudioFileALACSinkTests {

    // MARK: - Helpers

    private func tmpURL(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtAudioFileALACSink.\(UUID().uuidString).\(suffix)")
    }

    /// Non-interleaved Int16 PCM buffer filled with silence (all zeros).
    private func silenceBuffer(
        frames: AVAudioFrameCount,
        sampleRate: Double = 16_000
    ) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        // int16ChannelData is zero-initialised; no explicit fill needed.
        return buf
    }

    /// Run `/usr/bin/afinfo <url>` and return stdout.
    private func afinfo(_ url: URL) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/afinfo")
        proc.arguments = [url.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    /// Parse the audio packet count from `afinfo` output.
    /// Looks for lines like "audio packets: 10".
    private func parsePacketCount(from info: String) -> Int? {
        for line in info.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            if lower.contains("audio packets") {
                let parts = line.components(separatedBy: CharacterSet.decimalDigits.inverted)
                if let s = parts.first(where: { !$0.isEmpty }), let n = Int(s) {
                    return n
                }
            }
        }
        return nil
    }

    /// Parse duration in seconds from `afinfo` output.
    /// Handles both "Duration: X.XXX sec" and "estimated duration: X.XXX sec".
    private func parseDuration(from info: String) -> Double? {
        for line in info.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            if lower.contains("duration") && lower.contains("sec") {
                // Find first floating-point-like token.
                let tokens = line.components(separatedBy: CharacterSet(charactersIn: " \t:,"))
                for t in tokens {
                    if let d = Double(t), d > 0 { return d }
                }
            }
        }
        return nil
    }

    // MARK: - Tests

    @Test("single buffer write + finish produces decodable CAF with duration > 0 and packets > 0")
    func singleBufferWriteFinish() async throws {
        let url = tmpURL("single.caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let sink = try ExtAudioFileALACSink(url: url, sourceFormat: fmt)
        let buf = silenceBuffer(frames: 4096)
        await sink.append(buf)
        await sink.finish()

        #expect(FileManager.default.fileExists(atPath: url.path),
                "CAF file must exist after finish()")

        let info = try afinfo(url)
        let duration = parseDuration(from: info)
        let packets = parsePacketCount(from: info)

        #expect(duration != nil, "afinfo must report a duration; output:\n\(info)")
        #expect((duration ?? 0) > 0, "duration must be > 0; got \(duration ?? 0)")
        #expect(packets != nil, "afinfo must report packet count; output:\n\(info)")
        #expect((packets ?? 0) > 0, "packet count must be > 0; got \(packets ?? 0)")
    }

    @Test("10-buffer write produces ~2.56 s duration and 10 packets per afinfo")
    func multiBufferWrite() async throws {
        let url = tmpURL("multi.caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let sink = try ExtAudioFileALACSink(url: url, sourceFormat: fmt)
        for _ in 0..<10 {
            let buf = silenceBuffer(frames: 4096) // 10 × 4096 = 40960 frames
            await sink.append(buf)
        }
        await sink.finish()

        #expect(FileManager.default.fileExists(atPath: url.path))

        let info = try afinfo(url)
        let duration = parseDuration(from: info)
        let packets = parsePacketCount(from: info)

        // 40960 frames @ 16000 Hz = 2.56 s; allow ±0.1 s tolerance.
        let expectedDuration = 40_960.0 / 16_000.0
        #expect(duration != nil, "afinfo must report duration; output:\n\(info)")
        if let d = duration {
            #expect(abs(d - expectedDuration) <= 0.1,
                    "expected ≈\(expectedDuration) s; got \(d) s")
        }

        // ALAC always appends a trailing remainder packet, so 10 input chunks → 10 or 11 packets.
        #expect((packets ?? 0) >= 10, "expected ≥10 ALAC packets; got \(packets as Any)\nOutput:\n\(info)")
    }

    @Test("reopen with ExtAudioFile and verify frame count matches written frames")
    func reopenAndReadFrameCount() async throws {
        let url = tmpURL("reopen.caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let sink = try ExtAudioFileALACSink(url: url, sourceFormat: fmt)

        let writtenFrames: AVAudioFrameCount = 4096 * 5 // 5 packets = 20480 frames
        for _ in 0..<5 {
            let buf = silenceBuffer(frames: 4096)
            await sink.append(buf)
        }
        await sink.finish()

        // Reopen with ExtAudioFile and set a client format so frame count is computable.
        var ref: ExtAudioFileRef?
        let openStatus = ExtAudioFileOpenURL(url as CFURL, &ref)
        #expect(openStatus == noErr, "ExtAudioFileOpenURL failed: \(openStatus)")
        let extRef = try #require(ref)
        defer { ExtAudioFileDispose(extRef) }

        // Set client format to Int16 PCM so kExtAudioFileProperty_FileLengthFrames works.
        var clientASBD = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        let setStatus = ExtAudioFileSetProperty(
            extRef,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientASBD
        )
        #expect(setStatus == noErr, "ExtAudioFileSetProperty(ClientDataFormat) failed: \(setStatus)")

        var frames: Int64 = 0
        var size = UInt32(MemoryLayout<Int64>.size)
        let getStatus = ExtAudioFileGetProperty(
            extRef,
            kExtAudioFileProperty_FileLengthFrames,
            &size,
            &frames
        )
        #expect(getStatus == noErr, "ExtAudioFileGetProperty(FileLengthFrames) failed: \(getStatus)")
        #expect(frames == Int64(writtenFrames),
                "expected \(writtenFrames) frames; got \(frames)")
    }

    @Test("append after finish is a no-op — no crash, no error")
    func appendAfterFinishIsNoOp() async throws {
        let url = tmpURL("noop.caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let sink = try ExtAudioFileALACSink(url: url, sourceFormat: fmt)

        // Write one buffer and finish.
        await sink.append(silenceBuffer(frames: 4096))
        await sink.finish()

        // Appending after finish must not crash.
        await sink.append(silenceBuffer(frames: 4096))
        // Implicit success: test reaches this point without crashing.
    }
}
