import Foundation
import Observation
import ChronicleCore

/// Buffers the last N final transcript lines for SwiftUI consumption.
///
/// Sink methods are called from background capture tasks. All mutation runs on
/// the main actor so `@Observable` change propagation is safe for SwiftUI.
/// `finish()` is a no-op so lines are preserved across session boundaries.
@Observable
@MainActor
final class UITranscriptSink: TranscriptionSink {

    // MARK: - Configuration

    let capacity: Int

    // MARK: - Observable state

    private(set) var lines: [TranscriptLine] = []
    private var speakerIds: Set<String> = []

    var speakerCount: Int { speakerIds.count }

    // MARK: - Init

    init(capacity: Int = 50) {
        self.capacity = capacity
    }

    // MARK: - TranscriptionSink

    /// Called from background capture task; hops to main actor to mutate state.
    nonisolated func didReceiveResult(
        _ text: String,
        isFinal: Bool,
        wallclockOffsetMs: Double,
        wallclock: Date,
        audioRange: TraceAudioRange?,
        speakerId: String?
    ) async {
        guard isFinal else { return }
        let line = TranscriptLine(id: UUID(), text: text, speakerId: speakerId, timestamp: wallclock)
        await MainActor.run { self.append(line: line) }
    }

    /// No-op: preserves lines across session boundary.
    nonisolated func finish() async {}

    /// Clear lines and speaker state for a fresh session.
    func clear() {
        lines.removeAll()
        speakerIds.removeAll()
    }

    // MARK: - Private

    private func append(line: TranscriptLine) {
        lines.append(line)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
        if let sid = line.speakerId {
            speakerIds.insert(sid)
        }
    }
}
