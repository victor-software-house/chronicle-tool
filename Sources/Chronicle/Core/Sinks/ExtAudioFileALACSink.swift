import Foundation
@preconcurrency import AVFoundation
import AudioToolbox

/// Apple Lossless (ALAC) sidecar writer using AudioToolbox `ExtAudioFile`.
///
/// Drop-in replacement for `AVAudioFileALACSink`. `ExtAudioFileDispose` reliably
/// writes the `pakt` (packet table) chunk required for ALAC VBR — unlike
/// `AVAudioFile.close()` which silently omits `pakt` on macOS Tahoe, producing
/// undecodable CAFs. See ADR-0002 Tahoe amendment for the full failure analysis.
///
/// Conforms to `AudioSidecarSink` with an identical `init(url:sourceFormat:)`
/// signature, making every call site a zero-change swap.
///
/// `@unchecked Sendable`: the `ExtAudioFileRef` is not Sendable. All access is
/// single-writer (one Task drains the PCM stream), matching the documented
/// `AudioSidecarSink` threading contract.
public final class ExtAudioFileALACSink: AudioSidecarSink, @unchecked Sendable {
    private let url: URL
    private let sourceFormat: AVAudioFormat
    private let int16Format: AVAudioFormat
    private let converter: AVAudioConverter?
    private var extFile: ExtAudioFileRef?

    // Integrity probe — at most once per 60 s
    private var lastProbeTime: Date = .distantPast
    private let probeInterval: TimeInterval = 60

    public init(url: URL, sourceFormat: AVAudioFormat) throws {
        self.url = url
        self.sourceFormat = sourceFormat

        guard let int16Format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sourceFormat.sampleRate,
            channels: sourceFormat.channelCount,
            interleaved: false
        ) else {
            throw ExtAudioFileALACSinkError.formatCreationFailed
        }
        self.int16Format = int16Format

        if sourceFormat.commonFormat == .pcmFormatInt16
            && sourceFormat.sampleRate == int16Format.sampleRate
            && sourceFormat.channelCount == int16Format.channelCount
            && !sourceFormat.isInterleaved
        {
            self.converter = nil
        } else {
            guard let conv = AVAudioConverter(from: sourceFormat, to: int16Format) else {
                throw ExtAudioFileALACSinkError.converterCreationFailed
            }
            self.converter = conv
        }

        // ALAC ASBD for the CAF container.
        // mBytesPerFrame / mBytesPerPacket = 0: VBR — ExtAudioFile manages sizes.
        var alacASBD = AudioStreamBasicDescription(
            mSampleRate: sourceFormat.sampleRate,
            mFormatID: kAudioFormatAppleLossless,
            mFormatFlags: kAppleLosslessFormatFlag_16BitSourceData,
            mBytesPerPacket: 0,
            mFramesPerPacket: 4096,
            mBytesPerFrame: 0,
            mChannelsPerFrame: sourceFormat.channelCount,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var ref: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileCAFType,
            &alacASBD,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &ref
        )
        guard createStatus == noErr, let ref else {
            throw ExtAudioFileALACSinkError.createFailed(createStatus)
        }

        // Client format: non-interleaved Int16 PCM.
        // ExtAudioFile converts on write from this format to ALAC.
        var clientASBD = AudioStreamBasicDescription(
            mSampleRate: sourceFormat.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: sourceFormat.channelCount,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        let setStatus = ExtAudioFileSetProperty(
            ref,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientASBD
        )
        guard setStatus == noErr else {
            ExtAudioFileDispose(ref)
            throw ExtAudioFileALACSinkError.setClientFormatFailed(setStatus)
        }

        self.extFile = ref
    }

    public func append(_ buffer: AVAudioPCMBuffer) async {
        guard buffer.frameLength > 0, extFile != nil else { return }

        do {
            _ = try write(buffer)
            probeIntegrityIfNeeded()
        } catch {
            FileHandle.standardError.write(Data(
                "[ExtAudioFileALACSink] write failed: \(error)\n".utf8
            ))
        }
    }

    @discardableResult
    public func appendOrThrow(_ buffer: AVAudioPCMBuffer) throws -> AVAudioFrameCount {
        guard buffer.frameLength > 0, extFile != nil else { return 0 }
        return try write(buffer)
    }

    public func finish() async {
        guard let ref = extFile else { return }
        extFile = nil   // nil first — prevent double-dispose on any re-entrant path
        let status = ExtAudioFileDispose(ref)
        if status != noErr {
            FileHandle.standardError.write(Data(
                ("[ExtAudioFileALACSink] dispose failed (OSStatus \(status))"
                + " — pakt may not be written for \(url.lastPathComponent)\n").utf8
            ))
        }
    }

    // MARK: - Private

    private func write(_ buffer: AVAudioPCMBuffer) throws -> AVAudioFrameCount {
        let out: AVAudioPCMBuffer
        if let converter {
            out = try convert(buffer, with: converter)
        } else {
            out = buffer
        }

        guard out.frameLength > 0 else { return 0 }
        guard let ref = extFile else { return 0 }

        var abl = out.audioBufferList.pointee
        let status = ExtAudioFileWrite(ref, out.frameLength, &abl)
        guard status == noErr else {
            throw ExtAudioFileALACSinkError.writeError(status)
        }
        return out.frameLength
    }

    private func convert(
        _ input: AVAudioPCMBuffer,
        with converter: AVAudioConverter
    ) throws -> AVAudioPCMBuffer {
        let capacity = AVAudioFrameCount(
            ceil(Double(input.frameLength) * int16Format.sampleRate / sourceFormat.sampleRate)
        )
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: int16Format, frameCapacity: capacity)
        else { throw ExtAudioFileALACSinkError.bufferAllocationFailed }

        nonisolated(unsafe) var didProvideInput = false
        var convError: NSError?
        let status = converter.convert(to: output, error: &convError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return input
        }

        if status == .error {
            throw ExtAudioFileALACSinkError.conversionFailed(
                convError?.localizedDescription ?? "unknown"
            )
        }
        guard output.frameLength > 0 else {
            throw ExtAudioFileALACSinkError.conversionProducedNoFrames
        }
        return output
    }

    private func probeIntegrityIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastProbeTime) >= probeInterval else { return }
        lastProbeTime = now
        guard let ref = extFile else { return }

        var frames: Int64 = 0
        var size = UInt32(MemoryLayout<Int64>.size)
        let status = ExtAudioFileGetProperty(
            ref,
            kExtAudioFileProperty_FileLengthFrames,
            &size,
            &frames
        )
        if status != noErr || frames == 0 {
            FileHandle.standardError.write(Data(
                ("[audio.integrity] ExtAudioFileALACSink probe:"
                + " frames=\(frames) status=\(status)"
                + " url=\(url.lastPathComponent)\n").utf8
            ))
        }
    }
}

// MARK: - Errors

public enum ExtAudioFileALACSinkError: Error, CustomStringConvertible {
    case formatCreationFailed
    case converterCreationFailed
    case bufferAllocationFailed
    case createFailed(OSStatus)
    case setClientFormatFailed(OSStatus)
    case writeError(OSStatus)
    case conversionFailed(String)
    case conversionProducedNoFrames

    public var description: String {
        switch self {
        case .formatCreationFailed:
            return "Failed to create Int16 PCM format for ExtAudioFile ALAC sink"
        case .converterCreationFailed:
            return "Failed to create AVAudioConverter for ExtAudioFile ALAC sink"
        case .bufferAllocationFailed:
            return "Failed to allocate Int16 PCM buffer for ExtAudioFile ALAC sink"
        case .createFailed(let s):
            return "ExtAudioFileCreateWithURL failed (OSStatus \(s))"
        case .setClientFormatFailed(let s):
            return "ExtAudioFileSetProperty(ClientDataFormat) failed (OSStatus \(s))"
        case .writeError(let s):
            return "ExtAudioFileWrite failed (OSStatus \(s))"
        case .conversionFailed(let msg):
            return "Failed to convert PCM buffer for ExtAudioFile ALAC sink: \(msg)"
        case .conversionProducedNoFrames:
            return "PCM conversion produced no frames for ExtAudioFile ALAC sink"
        }
    }
}
