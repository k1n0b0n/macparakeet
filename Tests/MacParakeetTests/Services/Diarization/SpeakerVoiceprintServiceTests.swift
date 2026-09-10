import XCTest
import GRDB
@testable import MacParakeetCore

final class SpeakerVoiceprintServiceTests: XCTestCase {
    private var dbQueue: DatabaseQueue!
    private var profiles: SpeakerProfileRepository!
    private var journal: SpeakerMatchJournalRepository!
    private var transcriptions: TranscriptionRepository!
    private var enabled = true

    private let identity = SpeakerModelIdentity(
        embeddingModelId: "test-model",
        aggregationProfileId: "test-aggregation"
    )
    private let fingerprint = TranscriptFingerprint(rawValue: "fingerprint-1")

    override func setUp() async throws {
        let manager = try DatabaseManager()
        dbQueue = manager.dbQueue
        profiles = SpeakerProfileRepository(dbQueue: manager.dbQueue)
        journal = SpeakerMatchJournalRepository(dbQueue: manager.dbQueue)
        transcriptions = TranscriptionRepository(dbQueue: manager.dbQueue)
        enabled = true
    }

    // MARK: Gating

    func testDisabledServiceReadsNothingAndWritesNothing() async throws {
        let recording = try savedTranscription()
        _ = try await enrolledSarah(transcriptionId: recording.id)
        enabled = false

        let suggestions = try await makeService().evaluate(
            transcriptionId: recording.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 0)]
        )

        XCTAssertTrue(suggestions.isEmpty)
        XCTAssertTrue(try journal.entries(retention: SpeakerMatchJournalRepository.defaultRetention, now: Date()).isEmpty)
        XCTAssertTrue(try profiles.links(transcriptionId: recording.id, fingerprint: fingerprint.rawValue).isEmpty)
    }

    func testNoEnrolledProfilesYieldsNoSuggestionsAndNoJournal() async throws {
        let recording = try savedTranscription()

        let suggestions = try await makeService().evaluate(
            transcriptionId: recording.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 0)]
        )

        XCTAssertTrue(suggestions.isEmpty)
        XCTAssertTrue(try journal.entries(retention: SpeakerMatchJournalRepository.defaultRetention, now: Date()).isEmpty)
    }

    // MARK: Evaluation

    func testSuggestsAnEnrolledVoiceAndRecordsAPendingLink() async throws {
        let recording = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: recording.id)
        let next = try savedTranscription()

        let suggestions = try await makeService().evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )

        XCTAssertEqual(suggestions.map(\.displayName), ["Sarah"])
        let links = try profiles.links(transcriptionId: next.id, fingerprint: fingerprint.rawValue)
        XCTAssertEqual(links.map(\.status), [.suggested])
        XCTAssertEqual(links.first?.profileId, profile.id)
    }

    func testDismissedSpeakersAreNotScoredAgainForTheSameFingerprint() async throws {
        let recording = try savedTranscription()
        _ = try await enrolledSarah(transcriptionId: recording.id)
        let next = try savedTranscription()
        let service = makeService()

        let first = try await service.evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        try await service.dismiss(
            try XCTUnwrap(first.first), transcriptionId: next.id, fingerprint: fingerprint
        )

        let second = try await service.evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        XCTAssertTrue(second.isEmpty)
    }

    /// Re-diarization changes the fingerprint, and speaker ids are positional,
    /// so an old refusal must not silence a fresh, possibly correct suggestion.
    func testANewFingerprintReconsidersADismissedSpeaker() async throws {
        let recording = try savedTranscription()
        _ = try await enrolledSarah(transcriptionId: recording.id)
        let next = try savedTranscription()
        let service = makeService()

        let first = try await service.evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        try await service.dismiss(
            try XCTUnwrap(first.first), transcriptionId: next.id, fingerprint: fingerprint
        )

        let afterRerun = try await service.evaluate(
            transcriptionId: next.id,
            fingerprint: TranscriptFingerprint(rawValue: "fingerprint-2"),
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        XCTAssertEqual(afterRerun.map(\.displayName), ["Sarah"])
    }

    func testJournalRecordsRejectionsWithTheirReason() async throws {
        let recording = try savedTranscription()
        _ = try await enrolledSarah(transcriptionId: recording.id)
        let next = try savedTranscription()

        _ = try await makeService().evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [
                cluster("S1", voice: 0, degrees: 14.1),
                cluster("S2", voice: 3, degrees: 0),
                cluster("S3", voice: 0, degrees: 0, speechSeconds: 2),
            ]
        )

        let outcomes = Dictionary(
            uniqueKeysWithValues: try journal.entries(retention: SpeakerMatchJournalRepository.defaultRetention, now: Date()).map { ($0.speakerId, $0.outcome) }
        )
        XCTAssertEqual(outcomes["S1"], .suggested)
        XCTAssertEqual(outcomes["S2"], .pastThreshold)
        XCTAssertEqual(outcomes["S3"], .belowSpeechGate)
    }

    func testEvaluationStampsTheProfileEvenWhenNothingIsSuggested() async throws {
        let recording = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: recording.id)
        let next = try savedTranscription()

        _ = try await makeService().evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 3, degrees: 0)]
        )

        let stored = try XCTUnwrap(try profiles.profile(id: profile.id))
        XCTAssertNotNil(stored.lastEvaluatedAt)
        XCTAssertEqual(try XCTUnwrap(stored.lastEvaluatedDistance), 1, accuracy: 0.01)
        // Scored, but never matched.
        XCTAssertNil(stored.lastMatchedAt)
    }

    func testJournalDropsEntriesPastRetention() throws {
        let recording = try savedTranscription()
        try journal.append(
            [
                SpeakerMatchJournalEntry(
                    transcriptionId: recording.id,
                    speakerId: "S1",
                    outcome: .noComparableProfile,
                    speechSeconds: 30,
                    createdAt: Date(timeIntervalSinceNow: -100 * 24 * 60 * 60)
                )
            ],
            retention: SpeakerMatchJournalRepository.defaultRetention,
            now: Date()
        )
        XCTAssertTrue(try journal.entries(retention: SpeakerMatchJournalRepository.defaultRetention, now: Date()).isEmpty)
    }

    /// Expiry cannot ride on writes alone: a user who stops recording stops
    /// appending, and a ninety-day journal would quietly become permanent.
    func testJournalExpiresEvenWhenNothingIsWrittenAgain() throws {
        let recording = try savedTranscription()
        let longAgo = Date(timeIntervalSinceNow: -10 * 24 * 60 * 60)
        try journal.append(
            [
                SpeakerMatchJournalEntry(
                    transcriptionId: recording.id,
                    speakerId: "S1",
                    outcome: .noComparableProfile,
                    speechSeconds: 30,
                    createdAt: longAgo
                )
            ],
            retention: SpeakerMatchJournalRepository.defaultRetention,
            now: longAgo
        )
        XCTAssertEqual(
            try journal.entries(
                retention: SpeakerMatchJournalRepository.defaultRetention, now: longAgo
            ).count,
            1
        )

        // Same rows, read once the window has passed, with no write in between.
        XCTAssertTrue(
            try journal.entries(retention: 24 * 60 * 60, now: Date()).isEmpty
        )
        try dbQueue.read { db in
            XCTAssertEqual(try SpeakerMatchJournalEntry.fetchCount(db), 0)
        }
    }

    // MARK: Enrollment

    func testEnrollCreatesAProfileWithOneManualExemplar() async throws {
        let recording = try savedTranscription()
        let result = try await makeService().enroll(
            displayName: "  Sarah  ",
            observation: cluster("S1", voice: 0, degrees: 0),
            transcriptionId: recording.id,
            allowMergeIntoExistingName: false
        )

        guard case .created(let profile) = result else {
            return XCTFail("expected a new profile, got \(result)")
        }
        XCTAssertEqual(profile.displayName, "Sarah")
        let exemplars = try profiles.exemplars(profileId: profile.id)
        XCTAssertEqual(exemplars.map(\.origin), [.manualEnrollment])
        XCTAssertEqual(exemplars.first?.sourceTranscriptionId, recording.id)
    }

    func testEnrollRefusesAClusterBelowTheEnrollGate() async throws {
        let recording = try savedTranscription()
        let result = try await makeService().enroll(
            displayName: "Sarah",
            observation: cluster("S1", voice: 0, degrees: 0, speechSeconds: 12),
            transcriptionId: recording.id,
            allowMergeIntoExistingName: false
        )

        guard case .rejectedTooShort = result else {
            return XCTFail("expected a refusal, got \(result)")
        }
        XCTAssertTrue(try profiles.profiles().isEmpty)
    }

    func testEnrollingTheSameNameWithTheSameVoiceAddsASample() async throws {
        let first = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: first.id)
        let second = try savedTranscription()

        let result = try await makeService().enroll(
            displayName: "sarah",
            observation: cluster("S1", voice: 0, degrees: 14.1),
            transcriptionId: second.id,
            allowMergeIntoExistingName: false
        )

        guard case .addedExemplar = result else {
            return XCTFail("expected an added exemplar, got \(result)")
        }
        XCTAssertEqual(try profiles.exemplars(profileId: profile.id).count, 2)
        XCTAssertEqual(try profiles.profiles().count, 1)
    }

    /// The widest hole in the design: naming a speaker bypasses every
    /// threshold, so two colleagues called Sarah would silently fuse.
    func testEnrollingAKnownNameWithADifferentVoiceAsksInstead() async throws {
        let first = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: first.id)
        let second = try savedTranscription()

        let result = try await makeService().enroll(
            displayName: "Sarah",
            observation: cluster("S1", voice: 4, degrees: 0),
            transcriptionId: second.id,
            allowMergeIntoExistingName: false
        )

        guard case .needsDisambiguation(let existing, let distance) = result else {
            return XCTFail("expected disambiguation, got \(result)")
        }
        XCTAssertEqual(existing.id, profile.id)
        XCTAssertGreaterThan(distance, SpeakerMatchPolicy.v1.pollutionGuardDistance)
        XCTAssertEqual(try profiles.exemplars(profileId: profile.id).count, 1)
    }

    func testTheUserCanOverrideTheDisambiguationGuard() async throws {
        let first = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: first.id)
        let second = try savedTranscription()

        let result = try await makeService().enroll(
            displayName: "Sarah",
            observation: cluster("S1", voice: 4, degrees: 0),
            transcriptionId: second.id,
            allowMergeIntoExistingName: true
        )

        guard case .addedExemplar = result else {
            return XCTFail("expected an added exemplar, got \(result)")
        }
        XCTAssertEqual(try profiles.exemplars(profileId: profile.id).count, 2)
    }

    func testAProfileTakesAtMostOneSamplePerRecording() async throws {
        let recording = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: recording.id)

        let result = try await makeService().enroll(
            displayName: "Sarah",
            observation: cluster("S2", voice: 0, degrees: 14.1),
            transcriptionId: recording.id,
            allowMergeIntoExistingName: false
        )

        guard case .alreadySampled = result else {
            return XCTFail("expected a refusal, got \(result)")
        }
        XCTAssertEqual(try profiles.exemplars(profileId: profile.id).count, 1)
    }

    // MARK: Confirmation

    func testConfirmingRecordsTheLinkButDoesNotAmplifyAYoungProfile() async throws {
        let recording = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: recording.id)
        let next = try savedTranscription()
        let service = makeService()

        let suggestions = try await service.evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        let observation = cluster("S1", voice: 0, degrees: 14.1)
        try await service.confirm(
            try XCTUnwrap(suggestions.first),
            observation: observation,
            transcriptionId: next.id,
            fingerprint: fingerprint
        )

        let links = try profiles.links(transcriptionId: next.id, fingerprint: fingerprint.rawValue)
        XCTAssertEqual(links.map(\.status), [.confirmed])
        // One manual enrollment only: a confirmation must not let the profile
        // amplify itself on the strength of its own suggestion.
        XCTAssertEqual(try profiles.exemplars(profileId: profile.id).count, 1)
        XCTAssertNotNil(try profiles.profile(id: profile.id)?.lastMatchedAt)
    }

    func testConfirmingAddsASampleOnceTwoManualEnrollmentsAnchorTheVoice() async throws {
        let first = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: first.id)
        let second = try savedTranscription()
        let service = makeService()
        _ = try await service.enroll(
            displayName: "Sarah",
            observation: cluster("S1", voice: 0, degrees: 14.1),
            transcriptionId: second.id,
            allowMergeIntoExistingName: false
        )

        let third = try savedTranscription()
        let suggestions = try await service.evaluate(
            transcriptionId: third.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        try await service.confirm(
            try XCTUnwrap(suggestions.first),
            observation: cluster("S1", voice: 0, degrees: 14.1),
            transcriptionId: third.id,
            fingerprint: fingerprint
        )

        let exemplars = try profiles.exemplars(profileId: profile.id)
        XCTAssertEqual(exemplars.count, 3)
        XCTAssertEqual(exemplars.filter { $0.origin == .confirmedSuggestion }.count, 1)
    }

    // MARK: Helpers

    private func makeService() -> SpeakerVoiceprintService {
        SpeakerVoiceprintService(
            profiles: profiles,
            journal: journal,
            policy: .v1,
            isEnabled: { [self] in enabled }
        )
    }

    private func embedding(voice: Int, degrees: Double) -> SpeakerEmbedding {
        let radians = degrees * Double.pi / 180
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[voice] = Float(cos(radians))
        values[SpeakerEmbedding.dimension - 1 - voice] = Float(sin(radians))
        guard let embedding = SpeakerEmbedding(rawVector: values, identity: identity) else {
            preconditionFailure("fixture vector must be valid")
        }
        return embedding
    }

    private func cluster(
        _ speakerId: String,
        voice: Int,
        degrees: Double,
        speechSeconds: Double = 30
    ) -> SpeakerClusterObservation {
        SpeakerClusterObservation(
            speakerId: speakerId,
            embedding: embedding(voice: voice, degrees: degrees),
            speechSeconds: speechSeconds,
            captureDomain: .system
        )
    }

    private func savedTranscription() throws -> Transcription {
        let transcription = Transcription(fileName: "meeting.wav", sourceType: .meeting)
        try transcriptions.save(transcription)
        return transcription
    }

    @discardableResult
    private func enrolledSarah(transcriptionId: UUID) async throws -> SpeakerProfile {
        let result = try await makeService().enroll(
            displayName: "Sarah",
            observation: cluster("S1", voice: 0, degrees: 0),
            transcriptionId: transcriptionId,
            allowMergeIntoExistingName: false
        )
        guard case .created(let profile) = result else {
            preconditionFailure("fixture enrollment must create a profile")
        }
        return profile
    }
}
