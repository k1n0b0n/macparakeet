import XCTest

/// Guards the telemetry boundary for voice profiles by reading the source: the
/// feature must emit nothing beyond whether the preference is on.
///
/// A source scan rather than a behavioural test because the invariant is the
/// *absence* of calls. Nothing a runtime test observes can prove a call that
/// was never written, and the cheapest way to break this is to add one.
final class SpeakerVoiceprintTelemetryTests: XCTestCase {
    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Diarization
            .deletingLastPathComponent()  // Services
            .deletingLastPathComponent()  // MacParakeetTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources")
    }

    /// Distances, names, profile ids and sample counts are all identifying once
    /// they leave the machine — a distance joined to a label says who was in the
    /// room. The plan allows counters; none are implemented, and adding one is a
    /// decision to take deliberately rather than by reflex.
    func testTheVoiceprintSourcesEmitNoTelemetry() throws {
        let files = [
            "MacParakeetCore/Services/Diarization/SpeakerVoiceprintService.swift",
            "MacParakeetCore/Services/Diarization/SpeakerVoiceprintMatcher.swift",
            "MacParakeetCore/Services/Diarization/SpeakerEmbedding.swift",
            "MacParakeetCore/Database/SpeakerProfileRepository.swift",
            "MacParakeetCore/Database/SpeakerEmbeddingCandidateRepository.swift",
            "MacParakeetCore/Database/SpeakerMatchJournalRepository.swift",
            "MacParakeetViewModels/VoiceProfilesViewModel.swift",
        ]

        for path in files {
            let url = sourceRoot.appendingPathComponent(path)
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(
                source.contains("Telemetry.send"),
                "\(path) sends telemetry; voice profile data must not leave the machine"
            )
        }
    }

    /// The one event the feature does produce carries a bare boolean, through
    /// the same `settingChanged` path every other toggle uses.
    func testTheOnlyVoiceprintTelemetryIsThePreferenceItself() throws {
        let settings = try String(
            contentsOf: sourceRoot.appendingPathComponent(
                "MacParakeetViewModels/SettingsViewModel.swift"
            ),
            encoding: .utf8
        )
        let sends = settings.components(separatedBy: "Telemetry.send")
            .dropFirst()
            .map { String($0.prefix(220)) }
        let voiceprintSends = sends.filter {
            $0.contains("rememberSpeakers") || $0.contains("voiceprint")
        }

        XCTAssertEqual(voiceprintSends.count, 1, "expected exactly one voice-profile event")
        let event = try XCTUnwrap(voiceprintSends.first)
        XCTAssertTrue(event.contains(".settingChanged"), event)
        XCTAssertTrue(event.contains("settingValue(rememberSpeakers)"), event)
        // The consent date is a compliance record, not an analytics signal.
        XCTAssertFalse(event.contains("voiceprintConsentAcknowledgedAt"), event)
    }
}
