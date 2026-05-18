import AVFoundation
import CoreAudio
import Foundation
import Speech

#if canImport(Darwin)
import Darwin
#endif

/// `AudioSource` backed by CoreAudio's process-tap API.
///
/// This is Chronicle's production system-audio backend on Tahoe. It avoids
/// ScreenCaptureKit's Developer-ID-gated audio path for ad-hoc builds and uses
/// the Apple-blessed CoreAudio tap + private aggregate-device recipe documented
/// in ADR-0004.
public final class CoreAudioTapSource: AudioSource, @unchecked Sendable {
  public let analyzerFormat: AVAudioFormat
  public let analyzerInputs: AsyncStream<AnalyzerInput>
  public let pcmBuffers: AsyncStream<PCMBufferRef>

  public private(set) var sourceFormat: AVAudioFormat?
  public private(set) var buffersReceived: Int = 0
  public private(set) var peakSample: Int16 = 0
  public private(set) var hasValidBuffer = false

  public let verbose: Bool

  public static let noBufferWarningSeconds: Double = 5.0
  public static let recurringNoBufferWarningSeconds: Double = 30.0

  private static let aggregateUIDBase = "com.victor-software-house.chronicle.sysaudio."

  private let excludeSelf: Bool
  private let streams: AudioSourceOutputStreams
  private let ioQueue = DispatchQueue(label: "chronicle.sysaudio.coreaudio.ioproc", qos: .userInteractive)
  private let listenerQueue = DispatchQueue(label: "chronicle.sysaudio.coreaudio.listener", qos: .utility)

  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var ioProcID: AudioDeviceIOProcID?
  private var converter: BufferConverter?
  private var currentDefaultOutputID = AudioDeviceID(kAudioObjectUnknown)
  private var defaultOutputListener: AudioObjectPropertyListenerBlock?
  private var started = false
  private var stopped = false
  private var rebuilding = false
  private var sawIOCallback = false
  private var noBufferWarningGeneration = 0
  private var ioGeneration: UInt64 = 0

  public init(
    analyzerFormat: AVAudioFormat,
    excludeCurrentProcessAudio: Bool = true,
    verbose: Bool = false
  ) {
    self.analyzerFormat = analyzerFormat
    self.excludeSelf = excludeCurrentProcessAudio
    self.verbose = verbose

    let streams = AudioSourceOutputStreams()
    self.streams = streams
    self.analyzerInputs = streams.analyzerInputs
    self.pcmBuffers = streams.pcmBuffers
  }

  deinit {
    stop()
  }

  public func start() async throws {
    guard !started else { return }
    started = true
    stopped = false

    do {
      try Self.destroyStaleAggregateDevices()
      try startCoreAudio()
    } catch {
      cleanupAfterFailedStart()
      throw error
    }

    scheduleNoBufferWarning(context: "startup")
  }

  public func stop() {
    guard started, !stopped else { return }
    stopped = true
    teardownAndDrain(removeListener: true)
    streams.finish()
  }

  private func cleanupAfterFailedStart() {
    streams.finish()
    teardownCoreAudio(removeListener: true)
    started = false
    stopped = true
  }

  private func startCoreAudio() throws {
    guard tapID == kAudioObjectUnknown, aggregateID == kAudioObjectUnknown, ioProcID == nil else { return }

    // Bump generation so any stale IO callbacks from a previous tap are rejected.
    ioGeneration &+= 1
    let expectedGeneration = ioGeneration

    let excludedProcesses: [AudioObjectID] = excludeSelf ? try Self.processObjectIDs(for: [getpid()]) : []
    let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses)
    tapDesc.uuid = UUID()
    tapDesc.muteBehavior = .unmuted
    tapDesc.name = "chronicle-sysaudio-\(tapDesc.uuid.uuidString)"

    var newTapID = AudioObjectID(kAudioObjectUnknown)
    try Self.check(AudioHardwareCreateProcessTap(tapDesc, &newTapID), "AudioHardwareCreateProcessTap")
    guard newTapID != kAudioObjectUnknown else {
      throw CoreAudioTapSourceError.coreAudioCallFailed("AudioHardwareCreateProcessTap", kAudioHardwareBadObjectError)
    }
    tapID = newTapID

    let tapUID = try Self.readCFStringProperty(
      objectID: tapID,
      selector: kAudioTapPropertyUID,
      scope: kAudioObjectPropertyScopeGlobal,
      element: kAudioObjectPropertyElementMain
    )
    let tapFormat = try Self.readTapFormat(tapID)

    let defaultOutputID = try Self.defaultOutputDeviceID()
    let outputUID = try Self.deviceUID(defaultOutputID)
    currentDefaultOutputID = defaultOutputID

    let aggregateUID = Self.aggregateUIDPrefix + UUID().uuidString
    let aggregateDescription: [String: Any] = [
      kAudioAggregateDeviceNameKey as String: "chronicle System Audio",
      kAudioAggregateDeviceUIDKey as String: aggregateUID,
      kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
      kAudioAggregateDeviceIsPrivateKey as String: true,
      kAudioAggregateDeviceIsStackedKey as String: false,
      kAudioAggregateDeviceTapAutoStartKey as String: true,
      kAudioAggregateDeviceSubDeviceListKey as String: [
        [kAudioSubDeviceUIDKey: outputUID]
      ],
      kAudioAggregateDeviceTapListKey as String: [
        [
          kAudioSubTapUIDKey: tapUID,
          kAudioSubTapDriftCompensationKey: true
        ]
      ]
    ]

    var newAggregateID = AudioObjectID(kAudioObjectUnknown)
    try withExtendedLifetime(tapDesc) {
      try Self.check(
        AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID),
        "AudioHardwareCreateAggregateDevice"
      )
    }
    guard newAggregateID != kAudioObjectUnknown else {
      throw CoreAudioTapSourceError.coreAudioCallFailed("AudioHardwareCreateAggregateDevice", kAudioHardwareBadObjectError)
    }
    aggregateID = newAggregateID

    sourceFormat = tapFormat
    sawIOCallback = false
    guard let newConverter = BufferConverter(from: tapFormat, to: analyzerFormat) else {
      throw CoreAudioTapSourceError.converterUnavailable(from: tapFormat, to: analyzerFormat)
    }
    converter = newConverter

    let sourceFormat = tapFormat
    let converter = newConverter
    let streams = self.streams
    let verbose = self.verbose
    let ioBlock: AudioDeviceIOBlock = { [weak self] _, inputBufferList, _, _, _ in
      guard let self, !self.stopped, self.ioGeneration == expectedGeneration else { return }
      if !self.sawIOCallback {
        self.sawIOCallback = true
        if verbose {
          FileHandle.standardError.write(Data("[sysaudio.tap] first ioproc callback\n".utf8))
        }
      }
      guard let input = AVAudioPCMBuffer(
              pcmFormat: sourceFormat,
              bufferListNoCopy: inputBufferList,
              deallocator: nil
            ),
            let converted = converter.convert(input)
      else { return }

      self.hasValidBuffer = true
      self.buffersReceived += 1
      self.updatePeak(from: converted)
      if verbose, self.buffersReceived == 1 {
        FileHandle.standardError.write(Data("[sysaudio.tap] first converted buffer\n".utf8))
      }
      streams.yield(converted)
    }
    var newIOProcID: AudioDeviceIOProcID?
    try Self.check(
      AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateID, ioQueue, ioBlock),
      "AudioDeviceCreateIOProcIDWithBlock"
    )
    guard let newIOProcID else {
      throw CoreAudioTapSourceError.coreAudioCallFailed("AudioDeviceCreateIOProcIDWithBlock", kAudioHardwareBadObjectError)
    }
    ioProcID = newIOProcID

    try Self.check(AudioDeviceStart(aggregateID, newIOProcID), "AudioDeviceStart")
    installDefaultOutputListener()

    if verbose {
      FileHandle.standardError.write(Data(
        "[sysaudio.tap] started tap=\(tapID) aggregate=\(aggregateID) sourceFormat=\(tapFormat) defaultOutput=\(outputUID)\n".utf8
      ))
    }
  }

  private func teardownCoreAudio(removeListener: Bool, releaseConverter: Bool = true) {
    if removeListener {
      removeDefaultOutputListener()
    }
    if let ioProcID, aggregateID != kAudioObjectUnknown {
      AudioDeviceStop(aggregateID, ioProcID)
      AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
    }
    ioProcID = nil

    // Drain the ioQueue so any in-flight IO callbacks complete before we
    // destroy the aggregate device or release the converter. This prevents
    // use-after-free when a device change triggers rebuild while an IO
    // callback is mid-flight on ioQueue.
    ioQueue.sync {}

    if aggregateID != kAudioObjectUnknown {
      AudioHardwareDestroyAggregateDevice(aggregateID)
      aggregateID = AudioObjectID(kAudioObjectUnknown)
    }
    if tapID != kAudioObjectUnknown {
      AudioHardwareDestroyProcessTap(tapID)
      tapID = AudioObjectID(kAudioObjectUnknown)
    }
    if releaseConverter {
      converter = nil
      sourceFormat = nil
    }
  }

  private func teardownAndDrain(removeListener: Bool) {
    // Stop/destroy IOProc before draining: AVAudioConverter is not thread-safe,
    // so no IO callback may call `convert(_:)` after this point.
    teardownCoreAudio(removeListener: removeListener, releaseConverter: false)
    drainConverter()
    converter = nil
    sourceFormat = nil
  }

  private func drainConverter() {
    guard let converter else { return }
    streams.yieldAll(converter.drain())
  }

  private func updatePeak(from converted: AVAudioPCMBuffer) {
    guard buffersReceived % 64 == 0 else { return }
    var peak: Int16 = 0
    if let int16Data = converted.int16ChannelData {
      let count = Int(converted.frameLength)
      let ptr = int16Data[0]
      for i in 0..<count {
        let sample = ptr[i]
        let magnitude: Int16 = sample < 0 ? (sample == Int16.min ? Int16.max : -sample) : sample
        if magnitude > peak { peak = magnitude }
      }
    } else if let floatData = converted.floatChannelData {
      let count = Int(converted.frameLength)
      let ptr = floatData[0]
      for i in 0..<count {
        let scaled = min(abs(ptr[i]), 1.0) * Float(Int16.max)
        let magnitude = Int16(scaled)
        if magnitude > peak { peak = magnitude }
      }
    }
    if peak > peakSample { peakSample = peak }
    if verbose {
      FileHandle.standardError.write(Data(
        "[sysaudio.tap] buffers=\(buffersReceived) lastPeak=\(peak) sessionPeak=\(peakSample) (Int16 ±32767)\n".utf8
      ))
    }
  }

  private func installDefaultOutputListener() {
    // Rebuilds keep the existing listener installed while replacing only the
    // tap + aggregate device, so this is intentionally idempotent.
    guard defaultOutputListener == nil else { return }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      self?.handleDefaultOutputChanged()
    }
    let status = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      listenerQueue,
      listener
    )
    guard status == noErr else {
      FileHandle.standardError.write(Data(
        "[sysaudio.tap] warning: default-output listener install failed: \(status)\n".utf8
      ))
      return
    }
    defaultOutputListener = listener
  }

  private func removeDefaultOutputListener() {
    guard let listener = defaultOutputListener else { return }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      listenerQueue,
      listener
    )
    defaultOutputListener = nil
  }

  private func handleDefaultOutputChanged() {
    guard started, !stopped, !rebuilding else { return }
    guard let newDefaultID = try? Self.defaultOutputDeviceID() else { return }
    guard newDefaultID != currentDefaultOutputID else { return }
    rebuilding = true
    if verbose {
      FileHandle.standardError.write(Data(
        "[sysaudio.tap] default output changed; rebuilding tap+aggregate\n".utf8
      ))
    }
    teardownAndDrain(removeListener: false)
    hasValidBuffer = false
    do {
      try startCoreAudio()
      scheduleNoBufferWarning(context: "rebuild")
    } catch {
      FileHandle.standardError.write(Data(
        "[sysaudio.tap] rebuild failed: \(error); stopping source\n".utf8
      ))
      rebuilding = false
      stop()
      return
    }
    rebuilding = false
  }

  private func scheduleNoBufferWarning(context: String) {
    listenerQueue.async { [weak self] in
      guard let self else { return }
      self.noBufferWarningGeneration += 1
      self.scheduleNoBufferWarning(context: context, delaySeconds: Self.noBufferWarningSeconds, generation: self.noBufferWarningGeneration)
    }
  }

  private func scheduleNoBufferWarning(context: String, delaySeconds: Double, generation: Int) {
    listenerQueue.asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
      guard let self, self.started, !self.stopped, !self.hasValidBuffer, generation == self.noBufferWarningGeneration else { return }
      FileHandle.standardError.write(Data(
        Self.noValidBuffersWarning(context: context, waitedSeconds: delaySeconds).utf8
      ))
      self.scheduleNoBufferWarning(context: context, delaySeconds: Self.recurringNoBufferWarningSeconds, generation: generation)
    }
  }

  static func noValidBuffersWarning(context: String, waitedSeconds: Double) -> String {
    "[sysaudio.tap] warning: no valid buffers after \(waitedSeconds)s during \(context); still running and waiting for system audio\n"
  }

  private static func destroyStaleAggregateDevices() throws {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    try check(
      AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize),
      "AudioObjectGetPropertyDataSize(kAudioHardwarePropertyDevices)"
    )
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
    guard count > 0 else { return }
    var devices = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
    try check(
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &dataSize,
        &devices
      ),
      "AudioObjectGetPropertyData(kAudioHardwarePropertyDevices)"
    )
    for deviceID in devices {
      guard let uid = try? deviceUID(deviceID), uid.hasPrefix(aggregateUIDBase) else { continue }
      guard shouldDestroyAggregate(withUID: uid) else { continue }
      AudioHardwareDestroyAggregateDevice(deviceID)
    }
  }

  private static var aggregateUIDPrefix: String {
    "\(aggregateUIDBase)\(getpid())."
  }

  private static func shouldDestroyAggregate(withUID uid: String) -> Bool {
    let suffix = uid.dropFirst(aggregateUIDBase.count)
    guard let dot = suffix.firstIndex(of: "."), let pid = pid_t(suffix[..<dot]) else {
      return false
    }
    if pid == getpid() { return true }
    return kill(pid, 0) == -1 && errno == ESRCH
  }

  private static func defaultOutputDeviceID() throws -> AudioDeviceID {
    var outputID = AudioDeviceID(kAudioObjectUnknown)
    var dataSize = UInt32(MemoryLayout<AudioDeviceID>.stride)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    try check(
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &dataSize,
        &outputID
      ),
      "AudioObjectGetPropertyData(kAudioHardwarePropertyDefaultOutputDevice)"
    )
    guard outputID != kAudioObjectUnknown else {
      throw CoreAudioTapSourceError.noDefaultOutputDevice
    }
    return outputID
  }

  private static func processObjectIDs(for pids: [pid_t]) throws -> [AudioObjectID] {
    try pids.map { pid in
      var mutablePID = pid
      var processObject = AudioObjectID(kAudioObjectUnknown)
      var dataSize = UInt32(MemoryLayout<AudioObjectID>.stride)
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      try check(
        AudioObjectGetPropertyData(
          AudioObjectID(kAudioObjectSystemObject),
          &address,
          UInt32(MemoryLayout<pid_t>.stride),
          &mutablePID,
          &dataSize,
          &processObject
        ),
        "AudioObjectGetPropertyData(kAudioHardwarePropertyTranslatePIDToProcessObject)"
      )
      guard processObject != kAudioObjectUnknown else {
        throw CoreAudioTapSourceError.coreAudioCallFailed(
          "AudioObjectGetPropertyData(kAudioHardwarePropertyTranslatePIDToProcessObject)",
          kAudioHardwareBadObjectError
        )
      }
      return processObject
    }
  }

  private static func deviceUID(_ deviceID: AudioDeviceID) throws -> String {
    try readCFStringProperty(
      objectID: deviceID,
      selector: kAudioDevicePropertyDeviceUID,
      scope: kAudioObjectPropertyScopeGlobal,
      element: kAudioObjectPropertyElementMain
    )
  }

  private static func readTapFormat(_ tapID: AudioObjectID) throws -> AVAudioFormat {
    var asbd = AudioStreamBasicDescription()
    var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyFormat,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    try check(
      AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &asbd),
      "AudioObjectGetPropertyData(kAudioTapPropertyFormat)"
    )
    try validateTapASBD(asbd)
    return try audioFormat(fromTapASBD: asbd)
  }

  static func validateTapASBD(_ asbd: AudioStreamBasicDescription) throws {
    let validSampleRate = asbd.mSampleRate >= 8_000 && asbd.mSampleRate <= 192_000
    let validChannels = asbd.mChannelsPerFrame >= 1 && asbd.mChannelsPerFrame <= 8
    let validBytesPerFrame = asbd.mBytesPerFrame >= 1 && asbd.mBytesPerFrame <= 64
    let validFramesPerPacket = asbd.mFramesPerPacket >= 1 && asbd.mFramesPerPacket <= 8192
    let validBitsPerChannel = asbd.mBitsPerChannel >= 8 && asbd.mBitsPerChannel <= 64
    guard validSampleRate && validChannels && validBytesPerFrame && validFramesPerPacket && validBitsPerChannel else {
      throw CoreAudioTapSourceError.invalidTapFormat(asbd)
    }
  }

  static func audioFormat(fromTapASBD asbd: AudioStreamBasicDescription) throws -> AVAudioFormat {
    let flags = asbd.mFormatFlags
    let commonFormat: AVAudioCommonFormat
    if flags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 {
      commonFormat = .pcmFormatFloat32
    } else if flags & kAudioFormatFlagIsSignedInteger != 0, asbd.mBitsPerChannel == 16 {
      commonFormat = .pcmFormatInt16
    } else {
      throw CoreAudioTapSourceError.unsupportedTapFormat(asbd)
    }

    let interleaved = flags & kAudioFormatFlagIsNonInterleaved == 0
    guard let format = AVAudioFormat(
      commonFormat: commonFormat,
      sampleRate: asbd.mSampleRate,
      channels: asbd.mChannelsPerFrame,
      interleaved: interleaved
    ) else {
      throw CoreAudioTapSourceError.formatCreationFailed
    }
    return format
  }

  private static func readCFStringProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    element: AudioObjectPropertyElement
  ) throws -> String {
    var value: CFString = "" as CFString
    var dataSize = UInt32(MemoryLayout<CFString>.stride)
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    try withUnsafeMutablePointer(to: &value) { pointer in
      try check(
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, pointer),
        "AudioObjectGetPropertyData(\(selector))"
      )
    }
    return value as String
  }

  private static func check(_ status: OSStatus, _ call: String) throws {
    guard status == noErr else {
      throw CoreAudioTapSourceError.coreAudioCallFailed(call, status)
    }
  }
}

public enum CoreAudioTapSourceError: Error, CustomStringConvertible {
  case coreAudioCallFailed(String, OSStatus)
  case invalidTapFormat(AudioStreamBasicDescription)
  case unsupportedTapFormat(AudioStreamBasicDescription)
  case formatCreationFailed
  case converterUnavailable(from: AVAudioFormat, to: AVAudioFormat)
  case noDefaultOutputDevice

  public var description: String {
    switch self {
    case .coreAudioCallFailed(let call, let status):
      return "\(call) failed with OSStatus \(status). \(Self.audioCaptureRemediation)"
    case .invalidTapFormat(let asbd):
      return "CoreAudio tap reported an invalid audio format (sampleRate=\(asbd.mSampleRate), channels=\(asbd.mChannelsPerFrame), bytesPerFrame=\(asbd.mBytesPerFrame), framesPerPacket=\(asbd.mFramesPerPacket), bitsPerChannel=\(asbd.mBitsPerChannel)). This usually means System Audio Recording is denied for the current app identity. \(Self.audioCaptureRemediation)"
    case .unsupportedTapFormat(let asbd):
      return "CoreAudio tap reported an unsupported audio format (formatID=\(asbd.mFormatID), flags=\(asbd.mFormatFlags), bitsPerChannel=\(asbd.mBitsPerChannel))."
    case .formatCreationFailed:
      return "CoreAudio tap reported an audio format Chronicle could not materialise."
    case .converterUnavailable(let from, let to):
      return "Could not build AVAudioConverter from CoreAudio tap format \(from) to analyzer format \(to)."
    case .noDefaultOutputDevice:
      return "No default output audio device is available."
    }
  }

  public static let audioCaptureRemediation = "System Audio Recording permission is required by `chronicle sysaudio`. Build the app bundle with `scripts/make-app.sh`, launch `.build/release/chronicle.app/Contents/MacOS/chronicle sysaudio`, and approve System Settings → Privacy & Security → Screen & System Audio Recording."
}
