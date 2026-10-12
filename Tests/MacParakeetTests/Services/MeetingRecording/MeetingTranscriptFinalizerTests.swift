import XCTest
@testable import MacParakeetCore

final class MeetingTranscriptFinalizerTests: XCTestCase {
    func testUncoveredWordBetweenOneSpeakerTakesThatSpeaker() {
        let finalized = finalizeSystem(
            words: [("so", 0, 100), ("um", 150, 250), ("right", 300, 400)],
            segments: [
                SpeakerSegment(speakerId: "system:S1", startMs: 0, endMs: 120),
                SpeakerSegment(speakerId: "system:S1", startMs: 280, endMs: 420),
            ]
        )

        XCTAssertEqual(finalized.words.map(\.speakerId), ["system:S1", "system:S1", "system:S1"])
        XCTAssertEqual(finalized.speakers, [SpeakerInfo(id: "system:S1", label: "Others 1")])
    }

    func testUncoveredWordBetweenTwoSpeakersIsListedAsUnattributed() {
        let finalized = finalizeSystem(
            words: [("so", 0, 100), ("um", 150, 250), ("right", 300, 400)],
            segments: [
                SpeakerSegment(speakerId: "system:S1", startMs: 0, endMs: 120),
                SpeakerSegment(speakerId: "system:S2", startMs: 280, endMs: 420),
            ]
        )

        XCTAssertEqual(finalized.words.map(\.speakerId), ["system:S1", "system", "system:S2"])
        XCTAssertEqual(
            finalized.speakers,
            [
                SpeakerInfo(id: "system:S1", label: "Others 1"),
                SpeakerInfo(id: "system:S2", label: "Others 2"),
                SpeakerInfo(id: "system", label: "Unattributed"),
            ])
        XCTAssertEqual(finalized.speakers.people.map(\.id), ["system:S1", "system:S2"])
    }

    func testUndiarizedSystemTrackKeepsOthersLabel() {
        let finalized = MeetingTranscriptFinalizer.finalize(sourceTranscripts: [
            systemTranscript(words: [("hello", 0, 100)])
        ])

        XCTAssertEqual(finalized.speakers, [SpeakerInfo(id: "system", label: "Others")])
        XCTAssertEqual(finalized.speakers.people.count, 1)
    }

    func testDiarizedTrackWithNoCoveredWordCountsNobody() {
        let finalized = finalizeSystem(
            words: [("hello", 0, 100)],
            segments: [SpeakerSegment(speakerId: "system:S1", startMs: 500, endMs: 900)]
        )

        XCTAssertEqual(finalized.speakers, [SpeakerInfo(id: "system", label: "Unattributed")])
        XCTAssertEqual(finalized.speakers.people, [])
    }

    func testPeopleDropsLegacyOthersEntryOfDiarizedMeeting() {
        let speakers = [
            SpeakerInfo(id: "microphone", label: "Me"),
            SpeakerInfo(id: "system", label: "Others"),
            SpeakerInfo(id: "system:S1", label: "Others 1"),
        ]

        XCTAssertEqual(speakers.people.map(\.id), ["microphone", "system:S1"])
    }

    private func finalizeSystem(
        words: [(String, Int, Int)],
        segments: [SpeakerSegment]
    ) -> MeetingTranscriptFinalizer.FinalizedTranscript {
        let ids = segments.map(\.speakerId).reduce(into: [String]()) { ids, id in
            if !ids.contains(id) { ids.append(id) }
        }
        return MeetingTranscriptFinalizer.finalize(
            sourceTranscripts: [systemTranscript(words: words)],
            systemDiarization: .init(
                speakers: ids.enumerated().map { SpeakerInfo(id: $1, label: "Others \($0 + 1)") },
                segments: segments
            )
        )
    }

    private func systemTranscript(words: [(String, Int, Int)]) -> MeetingTranscriptFinalizer.SourceTranscript {
        .init(
            source: .system,
            result: STTResult(
                text: words.map(\.0).joined(separator: " "),
                words: words.map { TimestampedWord(word: $0.0, startMs: $0.1, endMs: $0.2, confidence: 0.9) }
            ),
            startOffsetMs: 0
        )
    }
}
