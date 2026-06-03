import Testing
import Foundation
@testable import ChronicleApp

@MainActor
struct UITranscriptSinkTests {

    // MARK: - Helpers

    private func makeSink(capacity: Int = 50) -> UITranscriptSink {
        UITranscriptSink(capacity: capacity)
    }

    private func sendFinal(
        _ sink: UITranscriptSink,
        text: String,
        speakerId: String? = nil
    ) async {
        await sink.didReceiveResult(
            text,
            isFinal: true,
            wallclockOffsetMs: 0,
            wallclock: Date(),
            audioRange: nil,
            speakerId: speakerId
        )
    }

    private func sendVolatile(
        _ sink: UITranscriptSink,
        text: String
    ) async {
        await sink.didReceiveResult(
            text,
            isFinal: false,
            wallclockOffsetMs: 0,
            wallclock: Date(),
            audioRange: nil,
            speakerId: nil
        )
    }

    // MARK: - Final-only filtering

    @Test func ignoresVolatileResults() async {
        let sink = makeSink()
        await sendVolatile(sink, text: "draft")
        await sendVolatile(sink, text: "another draft")
        #expect(sink.lines.isEmpty)
    }

    @Test func buffersFinalResults() async {
        let sink = makeSink()
        await sendFinal(sink, text: "hello")
        await sendFinal(sink, text: "world")
        #expect(sink.lines.count == 2)
        #expect(sink.lines[0].text == "hello")
        #expect(sink.lines[1].text == "world")
    }

    @Test func mixedVolatileAndFinalOnlyBuffersFinals() async {
        let sink = makeSink()
        await sendVolatile(sink, text: "partial...")
        await sendFinal(sink, text: "complete sentence")
        await sendVolatile(sink, text: "another partial...")
        #expect(sink.lines.count == 1)
        #expect(sink.lines[0].text == "complete sentence")
    }

    // MARK: - Capacity bounds

    @Test func respectsCapacityLimit() async {
        let sink = makeSink(capacity: 3)
        for i in 1...5 {
            await sendFinal(sink, text: "line \(i)")
        }
        #expect(sink.lines.count == 3)
        #expect(sink.lines[0].text == "line 3")
        #expect(sink.lines[2].text == "line 5")
    }

    @Test func exactlyAtCapacityDoesNotTrim() async {
        let sink = makeSink(capacity: 3)
        for i in 1...3 {
            await sendFinal(sink, text: "line \(i)")
        }
        #expect(sink.lines.count == 3)
    }

    @Test func capacityOneKeepsLatest() async {
        let sink = makeSink(capacity: 1)
        await sendFinal(sink, text: "first")
        await sendFinal(sink, text: "second")
        #expect(sink.lines.count == 1)
        #expect(sink.lines[0].text == "second")
    }

    // MARK: - Speaker counting

    @Test func speakerCountZeroInitially() {
        let sink = makeSink()
        #expect(sink.speakerCount == 0)
    }

    @Test func countsSingleSpeaker() async {
        let sink = makeSink()
        await sendFinal(sink, text: "hi", speakerId: "speaker-A")
        await sendFinal(sink, text: "bye", speakerId: "speaker-A")
        #expect(sink.speakerCount == 1)
    }

    @Test func countsDistinctSpeakers() async {
        let sink = makeSink()
        await sendFinal(sink, text: "hi", speakerId: "speaker-A")
        await sendFinal(sink, text: "hello", speakerId: "speaker-B")
        await sendFinal(sink, text: "hey", speakerId: "speaker-C")
        #expect(sink.speakerCount == 3)
    }

    @Test func speakerCountUnaffectedByNilSpeakerId() async {
        let sink = makeSink()
        await sendFinal(sink, text: "no speaker")          // speakerId: nil
        await sendFinal(sink, text: "tagged", speakerId: "speaker-A")
        #expect(sink.speakerCount == 1)
    }

    @Test func speakerCountPreservedAfterCapacityTrim() async {
        let sink = makeSink(capacity: 2)
        await sendFinal(sink, text: "a", speakerId: "speaker-A")
        await sendFinal(sink, text: "b", speakerId: "speaker-B")
        await sendFinal(sink, text: "c", speakerId: "speaker-C") // trims "a"
        // lines trimmed but speakerIds set is never pruned
        #expect(sink.lines.count == 2)
        #expect(sink.speakerCount == 3)
    }

    // MARK: - finish() preserves lines

    @Test func finishPreservesLines() async {
        let sink = makeSink()
        await sendFinal(sink, text: "keep me")
        await sink.finish()
        #expect(sink.lines.count == 1)
        #expect(sink.lines[0].text == "keep me")
    }

    @Test func finishPreservesSpeakerCount() async {
        let sink = makeSink()
        await sendFinal(sink, text: "hi", speakerId: "speaker-A")
        await sink.finish()
        #expect(sink.speakerCount == 1)
    }

    @Test func canAcceptResultsAfterFinish() async {
        let sink = makeSink()
        await sendFinal(sink, text: "before")
        await sink.finish()
        await sendFinal(sink, text: "after")
        #expect(sink.lines.count == 2)
    }
}
