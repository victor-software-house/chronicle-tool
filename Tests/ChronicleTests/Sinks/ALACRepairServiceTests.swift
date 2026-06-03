import AudioToolbox
@preconcurrency import AVFoundation
import Testing

@testable import ChronicleCore

@Suite("ALACRepairService")
struct ALACRepairServiceTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alac-repair-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeValidCAF(to url: URL, frames: Int = 16384) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let sink = try ExtAudioFileALACSink(url: url, sourceFormat: format)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        buf.frameLength = 4096
        // Fill with silence (zeros already)
        let iterations = frames / 4096
        for _ in 0 ..< iterations {
            try sink.appendOrThrow(buf)
        }
        // Synchronous finish needed for test — sink.finish() is async
        let sem = DispatchSemaphore(value: 0)
        Task {
            await sink.finish()
            sem.signal()
        }
        sem.wait()
    }

    /// Strip the pakt chunk from a CAF file by rewriting without it.
    private func stripPaktChunk(from url: URL) throws -> Data {
        var data = try Data(contentsOf: url)

        // Parse CAF chunks and remove pakt
        var pos = 8 // after file header
        while pos + 12 <= data.count {
            let chunkType = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: pos, as: UInt32.self).bigEndian
            }
            let chunkSize: Int64 = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: pos + 4, as: Int64.self).bigEndian
            }

            if chunkType == 0x70616b74 { // 'pakt'
                let totalChunkSize = 12 + Int(chunkSize)
                data.removeSubrange(pos ..< pos + totalChunkSize)
                return data
            }

            if chunkSize < 0 { break }
            pos += 12 + Int(chunkSize)
        }
        return data // no pakt found (shouldn't happen with valid CAFs)
    }

    @Test("repairs broken CAF by re-encoding and produces decodable output")
    func repairBrokenCAF() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write valid CAF
        let validURL = dir.appendingPathComponent("valid.caf")
        try writeValidCAF(to: validURL, frames: 16384)

        // Verify valid file works with afinfo
        let validInfo = try Process.run(
            URL(fileURLWithPath: "/usr/bin/afinfo"), arguments: [validURL.path]
        )
        validInfo.waitUntilExit()
        #expect(validInfo.terminationStatus == 0, "valid CAF should pass afinfo")

        // Strip pakt → broken
        let brokenData = try stripPaktChunk(from: validURL)
        let brokenURL = dir.appendingPathComponent("broken.caf")
        try brokenData.write(to: brokenURL)

        // Verify broken file fails afinfo (0 duration)
        let brokenProc = Process()
        brokenProc.executableURL = URL(fileURLWithPath: "/usr/bin/afinfo")
        brokenProc.arguments = [brokenURL.path]
        let pipe = Pipe()
        brokenProc.standardOutput = pipe
        brokenProc.standardError = FileHandle.nullDevice
        try brokenProc.run()
        brokenProc.waitUntilExit()
        let brokenOutput = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Broken CAF typically shows 0 duration or fails entirely
        let brokenDuration = brokenOutput.contains("estimated duration: 0")
            || brokenProc.terminationStatus != 0
            || !brokenOutput.contains("estimated duration")
        #expect(brokenDuration, "pakt-stripped CAF should show 0 duration or fail")

        // Repair
        let repairedURL = dir.appendingPathComponent("repaired.caf")
        let result = try await ALACRepairService.repair(
            inputURL: brokenURL,
            outputURL: repairedURL
        )

        #expect(result.totalFrames > 0, "should decode frames")
        #expect(result.duration > 0, "should have duration")

        // Verify repaired file works with afinfo
        let repairedInfo = try Process.run(
            URL(fileURLWithPath: "/usr/bin/afinfo"), arguments: [repairedURL.path]
        )
        repairedInfo.waitUntilExit()
        #expect(repairedInfo.terminationStatus == 0, "repaired CAF should pass afinfo")
    }

    @Test("throws alreadyValid for CAF that has pakt chunk")
    func skipAlreadyValid() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let validURL = dir.appendingPathComponent("valid.caf")
        try writeValidCAF(to: validURL)

        let outURL = dir.appendingPathComponent("out.caf")
        await #expect(throws: ALACRepairService.RepairError.self) {
            try await ALACRepairService.repair(inputURL: validURL, outputURL: outURL)
        }
    }

    @Test("throws for non-CAF file")
    func rejectNonCAF() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fakeURL = dir.appendingPathComponent("fake.caf")
        try Data("not a caf file".utf8).write(to: fakeURL)

        let outURL = dir.appendingPathComponent("out.caf")
        await #expect(throws: ALACRepairService.RepairError.self) {
            try await ALACRepairService.repair(inputURL: fakeURL, outputURL: outURL)
        }
    }
}
