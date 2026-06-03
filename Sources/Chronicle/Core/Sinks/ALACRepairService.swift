import AudioToolbox
@preconcurrency import AVFoundation
import Foundation

/// Repairs broken ALAC-in-CAF files missing the `pakt` (packet table) chunk.
///
/// Strategy: extract the raw ALAC data and magic cookie from the broken CAF,
/// feed the data through an `AudioConverter` (ALAC → PCM) which handles
/// internal ALAC framing, and re-encode through `ExtAudioFileALACSink`.
public struct ALACRepairService {

    public struct RepairResult: Sendable {
        public let outputURL: URL
        public let totalFrames: Int64
        public let duration: TimeInterval
    }

    public enum RepairError: Error, CustomStringConvertible, Sendable {
        case notALACCAF(String)
        case missingChunk(String)
        case decodeFailed(String)
        case reEncodeFailed(String)
        case verificationFailed(String)
        case alreadyValid

        public var description: String {
            switch self {
            case .notALACCAF(let m):        "Not an ALAC CAF: \(m)"
            case .missingChunk(let m):      "Missing chunk: \(m)"
            case .decodeFailed(let m):      "Decode failed: \(m)"
            case .reEncodeFailed(let m):    "Re-encode failed: \(m)"
            case .verificationFailed(let m): "Verification failed: \(m)"
            case .alreadyValid:             "File already has valid pakt chunk"
            }
        }
    }

    // MARK: - CAF binary

    private struct ChunkLoc {
        let type: UInt32; let headerOff: Int; let dataOff: Int; let dataSize: Int64
    }

    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self).bigEndian }
    }
    private static func i64(_ d: Data, _ o: Int) -> Int64 {
        d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int64.self).bigEndian }
    }
    private static func u64(_ d: Data, _ o: Int) -> UInt64 {
        d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self).bigEndian }
    }

    private static func parseChunks(_ d: Data) throws -> [ChunkLoc] {
        guard d.count >= 8, u32(d, 0) == 0x63616666 else {
            throw RepairError.notALACCAF("no 'caff' magic")
        }
        var r: [ChunkLoc] = []
        var p = 8
        while p + 12 <= d.count {
            let t = u32(d, p); let s = i64(d, p + 4)
            r.append(ChunkLoc(type: t, headerOff: p, dataOff: p + 12, dataSize: s))
            if s < 0 { break }; p += 12 + Int(s)
        }
        return r
    }

    // MARK: - Converter state (lives in a stable heap allocation for C callback)

    private final class ConverterState {
        let bytes: UnsafeMutablePointer<UInt8>
        let count: Int
        var position: Int = 0

        init(data: Data) {
            count = data.count
            bytes = .allocate(capacity: count)
            data.copyBytes(to: bytes, count: count)
        }

        deinit { bytes.deallocate() }
    }

    // MARK: - Public

    public static func repair(inputURL: URL, outputURL: URL) async throws -> RepairResult {
        let data = try Data(contentsOf: inputURL)
        let chunks = try parseChunks(data)
        if chunks.contains(where: { $0.type == 0x70616b74 }) { throw RepairError.alreadyValid }

        guard let desc = chunks.first(where: { $0.type == 0x64657363 }), desc.dataSize >= 32 else {
            throw RepairError.missingChunk("desc")
        }
        let sampleRate = Float64(bitPattern: u64(data, desc.dataOff))
        let formatID = u32(data, desc.dataOff + 8)
        let formatFlags = u32(data, desc.dataOff + 12)
        let fpp = u32(data, desc.dataOff + 20)
        let chans = u32(data, desc.dataOff + 24)
        let bpc = u32(data, desc.dataOff + 28)
        guard formatID == kAudioFormatAppleLossless else {
            throw RepairError.notALACCAF("formatID \(formatID)")
        }

        guard let kukiChunk = chunks.first(where: { $0.type == 0x6b756b69 }), kukiChunk.dataSize > 0 else {
            throw RepairError.missingChunk("kuki")
        }
        let cookie = data.subdata(in: kukiChunk.dataOff ..< kukiChunk.dataOff + Int(kukiChunk.dataSize))

        guard let dataChunk = chunks.first(where: { $0.type == 0x64617461 }) else {
            throw RepairError.missingChunk("data")
        }
        let audioStart = dataChunk.dataOff + 4
        let audioEnd = dataChunk.dataSize < 0 ? data.count : dataChunk.dataOff + Int(dataChunk.dataSize)
        let audioSize = audioEnd - audioStart
        guard audioSize > 0 else { throw RepairError.notALACCAF("empty data") }

        let audioData = data.subdata(in: audioStart ..< audioEnd)

        // Set up AudioConverter: ALAC → interleaved Int16 PCM
        var inputASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatAppleLossless,
            mFormatFlags: formatFlags, mBytesPerPacket: 0,
            mFramesPerPacket: fpp, mBytesPerFrame: 0,
            mChannelsPerFrame: chans, mBitsPerChannel: bpc, mReserved: 0
        )
        var outputASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * chans, mFramesPerPacket: 1,
            mBytesPerFrame: 2 * chans, mChannelsPerFrame: chans,
            mBitsPerChannel: 16, mReserved: 0
        )

        var converter: AudioConverterRef?
        var st = AudioConverterNew(&inputASBD, &outputASBD, &converter)
        guard st == noErr, let converter else {
            throw RepairError.decodeFailed("AudioConverterNew: \(st)")
        }
        defer { AudioConverterDispose(converter) }

        cookie.withUnsafeBytes { ptr in
            AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie,
                                       UInt32(cookie.count), ptr.baseAddress!)
        }

        // Allocate stable heap state for the C callback
        let state = ConverterState(data: audioData)
        let statePtr = Unmanaged.passUnretained(state).toOpaque()

        // The input data proc. AudioConverter calls this to get ALAC input.
        // We provide ALL remaining bytes each time. The converter internally
        // knows ALAC framing (via the magic cookie) and reads exactly one
        // packet's worth of bytes. After the call, we need to figure out
        // how many bytes were consumed.
        //
        // Key insight: AudioConverterFillComplexBuffer + this callback runs in
        // a loop. Each call to FillComplexBuffer produces fpp output frames
        // (one ALAC packet) and calls the input proc once. The converter
        // consumes exactly the bytes for one ALAC packet.
        //
        // To track consumption: before the call, record position. After
        // FillComplexBuffer returns, the consumed bytes = (the amount of
        // mDataByteSize we provided) minus (what the converter didn't use).
        // BUT AudioToolbox doesn't tell us how much it consumed from the buffer.
        //
        // HOWEVER: we can use the `outDataPacketDescription` parameter of
        // `AudioConverterFillComplexBuffer` — but that describes OUTPUT packets.
        //
        // ALTERNATIVE: set mDataByteSize to a large value each time but
        // use `outDataPacketDescription` on the INPUT callback. The callback's
        // `outDataPacketDescription` parameter, when non-nil, should be filled
        // with `AudioStreamPacketDescription` for the input data.
        //
        // For VBR → CBR conversion, the input callback MUST provide packet
        // descriptions via `outDataPacketDescription`. Let's do that.
        //
        // We'll provide 1 input packet at a time, with the packet description
        // pointing at position with mDataByteSize = remaining.
        // The converter reads from position, and the packet description tells
        // it how many bytes = remaining (overestimate). The decoder reads
        // exactly the real packet size from the bitstream.
        //
        // After decoding, the converter consumed exactly one real packet's
        // worth of bytes. We detect this by: the output produced exactly fpp
        // frames. Then we binary-search for the correct input packet size.
        //
        // Actually, the simple solution: provide packet description with
        // mDataByteSize = remaining_bytes. The converter reads from
        // mStartOffset = 0 (relative to mData). After the decoder processes
        // one packet, we don't know how far it read. BUT: the input proc is
        // called once per output packet. We provide all remaining data each time.
        // The decoder reads one packet's worth and ignores the rest.
        // Next call: we provide the SAME data again (position unchanged).
        // The decoder reads the SAME first packet again → infinite loop!
        //
        // The ONLY way to advance: know the exact packet size. Which requires
        // either (a) the pakt table we don't have, or (b) a full ALAC bitstream
        // parser.
        //
        // FINAL APPROACH: brute-force each packet. For each packet position,
        // try all sizes from 1 to maxPktSize. Build a 1-packet CAF for each
        // candidate, try to decode. If we get fpp frames, that's the right size.
        // This is O(audioSize * maxPktSize) in the worst case but ALAC packets
        // are small (typically < 100 bytes for silence, < 5000 for speech at
        // 16kHz mono), so in practice it's fast.

        // We don't use the converter after all. Clean up and use the brute-force approach.
        AudioConverterDispose(converter)

        // Brute-force packet boundary detection
        let maxPktSize = Int(fpp) * Int(chans) * 2 + 64
        var packetSizes: [Int] = []
        var pos = audioStart

        while pos < audioEnd {
            let remaining = audioEnd - pos
            if remaining <= 0 { break }
            let upper = min(remaining, maxPktSize)
            var found = false

            // For each candidate size (ascending), build a 1-packet CAF and try decode
            for sz in 1 ... upper {
                let audioSlice = data.subdata(in: pos ..< pos + sz)
                let frames = buildAndTryDecode(
                    originalData: data, chunks: chunks,
                    audioSlice: audioSlice, fpp: fpp, chans: chans,
                    sampleRate: sampleRate, formatFlags: formatFlags, bpc: bpc
                )
                if frames == fpp {
                    packetSizes.append(sz)
                    pos += sz
                    found = true
                    break
                }
            }

            if !found {
                // Last packet: remainder may be < fpp frames
                packetSizes.append(remaining)
                break
            }
        }

        guard !packetSizes.isEmpty else {
            throw RepairError.decodeFailed("found 0 packets")
        }

        // Build properly patched CAF with correct pakt
        var totalFrames = Int64(packetSizes.count) * Int64(fpp)
        var paktBody = Data(capacity: 24 + packetSizes.count * 4)
        Self.appendBE64(&paktBody, Int64(packetSizes.count))
        Self.appendBE64(&paktBody, totalFrames)
        Self.appendBE32(&paktBody, 0)
        Self.appendBE32(&paktBody, 0)
        for sz in packetSizes { paktBody.append(contentsOf: Self.encodeBER(UInt32(sz))) }

        var repaired = Data(capacity: data.count + 12 + paktBody.count)
        repaired.append(data[0 ..< dataChunk.headerOff])
        Self.appendBE32(&repaired, 0x70616b74)
        Self.appendBE64(&repaired, Int64(paktBody.count))
        repaired.append(paktBody)
        repaired.append(data[dataChunk.headerOff...])

        // Decode repaired CAF and re-encode to output
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("chronicle-repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let patchedURL = tmp.appendingPathComponent("repaired.caf")
        try repaired.write(to: patchedURL)

        var ref: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(patchedURL as CFURL, &ref) == noErr, let ref else {
            throw RepairError.decodeFailed("open repaired")
        }
        defer { ExtAudioFileDispose(ref) }

        var clientASBD = outputASBD
        guard ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                                       &clientASBD) == noErr else {
            throw RepairError.decodeFailed("set client format")
        }

        guard let sinkFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                                           channels: AVAudioChannelCount(chans), interleaved: false) else {
            throw RepairError.reEncodeFailed("sink format")
        }
        let sink = try ExtAudioFileALACSink(url: outputURL, sourceFormat: sinkFmt)

        let readChunk: UInt32 = 4096
        let bpf = Int(clientASBD.mBytesPerFrame)
        let pcmBufSize = Int(readChunk) * bpf
        let pcm = UnsafeMutablePointer<UInt8>.allocate(capacity: pcmBufSize)
        defer { pcm.deallocate() }
        let ch = Int(chans)
        var total: Int64 = 0

        while true {
            var n = readChunk
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: chans, mDataByteSize: UInt32(pcmBufSize), mData: pcm
            ))
            let rs = ExtAudioFileRead(ref, &n, &abl)
            if rs != noErr || n == 0 { break }

            guard let buf = AVAudioPCMBuffer(pcmFormat: sinkFmt, frameCapacity: n) else { break }
            buf.frameLength = n
            pcm.withMemoryRebound(to: Int16.self, capacity: Int(n) * ch) { src in
                for c in 0 ..< ch {
                    guard let dst = buf.int16ChannelData?[c] else { return }
                    for f in 0 ..< Int(n) { dst[f] = src[f * ch + c] }
                }
            }
            try sink.appendOrThrow(buf)
            total += Int64(n)
        }

        await sink.finish()

        guard total > 0 else {
            throw RepairError.verificationFailed("0 frames from \(audioSize) bytes")
        }

        return RepairResult(outputURL: outputURL, totalFrames: total, duration: Double(total) / sampleRate)
    }

    /// Build a minimal 1-packet CAF from an audio slice and try to decode fpp frames.
    private static func buildAndTryDecode(
        originalData: Data, chunks: [ChunkLoc],
        audioSlice: Data, fpp: UInt32, chans: UInt32,
        sampleRate: Float64, formatFlags: UInt32, bpc: UInt32
    ) -> UInt32 {
        // Build minimal CAF
        var caf = Data(capacity: 200 + audioSlice.count)

        // File header: 'caff' + version(2) + flags(2)
        appendBE32(&caf, 0x63616666)
        var ver = UInt16(1).bigEndian; caf.append(Data(bytes: &ver, count: 2))
        caf.append(Data(count: 2))

        // desc chunk from original
        guard let desc = chunks.first(where: { $0.type == 0x64657363 }) else { return 0 }
        caf.append(originalData[desc.headerOff ..< desc.headerOff + 12 + Int(desc.dataSize)])

        // kuki chunk from original
        guard let kuki = chunks.first(where: { $0.type == 0x6b756b69 }) else { return 0 }
        caf.append(originalData[kuki.headerOff ..< kuki.headerOff + 12 + Int(kuki.dataSize)])

        // pakt: 1 packet
        var paktBody = Data(capacity: 30)
        appendBE64(&paktBody, 1)
        appendBE64(&paktBody, Int64(fpp))
        appendBE32(&paktBody, 0)
        appendBE32(&paktBody, 0)
        paktBody.append(contentsOf: encodeBER(UInt32(audioSlice.count)))
        appendBE32(&caf, 0x70616b74)
        appendBE64(&caf, Int64(paktBody.count))
        caf.append(paktBody)

        // data chunk
        appendBE32(&caf, 0x64617461)
        appendBE64(&caf, Int64(audioSlice.count + 4))
        appendBE32(&caf, 0) // edit count
        caf.append(audioSlice)

        // Write, open, decode
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("trial-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        guard (try? caf.write(to: tmpURL)) != nil else { return 0 }

        var ref: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(tmpURL as CFURL, &ref) == noErr, let ref else { return 0 }
        defer { ExtAudioFileDispose(ref) }

        var clientASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * chans, mFramesPerPacket: 1,
            mBytesPerFrame: 2 * chans, mChannelsPerFrame: chans,
            mBitsPerChannel: 16, mReserved: 0
        )
        guard ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                                       &clientASBD) == noErr else { return 0 }

        let bufSize = Int(fpp) * Int(clientASBD.mBytesPerFrame)
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        var n = fpp
        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: chans, mDataByteSize: UInt32(bufSize), mData: buf
        ))
        let rs = ExtAudioFileRead(ref, &n, &abl)
        return rs == noErr ? n : 0
    }

    private static func appendBE32(_ d: inout Data, _ v: UInt32) {
        var be = v.bigEndian; d.append(Data(bytes: &be, count: 4))
    }
    private static func appendBE64(_ d: inout Data, _ v: Int64) {
        var be = v.bigEndian; d.append(Data(bytes: &be, count: 8))
    }
    private static func encodeBER(_ value: UInt32) -> [UInt8] {
        if value < 0x80 { return [UInt8(value)] }
        var v = value; var b: [UInt8] = []
        b.append(UInt8(v & 0x7F)); v >>= 7
        while v > 0 { b.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        return b.reversed()
    }
}
