/// UI-level capture source — distinct from ChronicleCore.CaptureSource.
enum CaptureSource: String, CaseIterable, Hashable, Sendable {
    case mic
    case sysaudio
}

/// Current state of an active or inactive capture session.
enum CaptureState: Equatable {
    case idle
    case recording(sources: Set<CaptureSource>)
    case stopping
    case error(message: String)
}
