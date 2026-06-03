import Foundation

/// A single line of transcribed speech, suitable for display in a SwiftUI list.
struct TranscriptLine: Identifiable, Equatable {
    let id: UUID
    let text: String
    let speakerId: String?
    let timestamp: Date
}
