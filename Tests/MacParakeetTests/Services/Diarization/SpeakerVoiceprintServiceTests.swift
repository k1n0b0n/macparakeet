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
                    transcriptFingerprint: fingerprint.rawValue,
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
                    transcriptFingerprint: fingerprint.rawValue,
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

    /// speakerId is positional, so a decision is only joinable to the label
    /// that answered it when the transcript version is recorded with it.
    func testJournalRecordsTheTranscriptVersionOfEachDecision() async throws {
        let recording = try savedTranscription()
        _ = try await enrolledSarah(transcriptionId: recording.id)
        let next = try savedTranscription()

        _ = try await makeService().evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )

        let entries = try journal.entries(
            retention: SpeakerMatchJournalRepository.defaultRetention, now: Date()
        )
        XCTAssertEqual(entries.map(\.transcriptFingerprint), [fingerprint.rawValue])
    }

    /// An embedding from another model carries no comparable evidence, so it
    /// must not slip past the guard into a silent merge.
    func testEnrollingWithAnIncomparableModelAsksInstead() async throws {
        let first = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: first.id)
        let second = try savedTranscription()

        let otherModel = SpeakerModelIdentity(
            embeddingModelId: "other-model",
            aggregationProfileId: identity.aggregationProfileId
        )
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[0] = 1
        let observation = SpeakerClusterObservation(
            speakerId: "S1",
            embedding: try XCTUnwrap(SpeakerEmbedding(rawVector: values, identity: otherModel)),
            speechSeconds: 30,
            captureDomain: .system
        )

        let result = try await makeService().enroll(
            displayName: "Sarah",
            observation: observation,
            transcriptionId: second.id,
            allowMergeIntoExistingName: false
        )

        guard case .needsDisambiguation = result else {
            return XCTFail("expected disambiguation, got \(result)")
        }
        XCTAssertEqual(try profiles.exemplars(profileId: profile.id).count, 1)
    }

    /// Forcing a merge overrides a judgement about which person this is, not
    /// about whether two vectors can be compared: the store would refuse the
    /// sample anyway, so the service must stop first.
    func testForcingAMergeStillRefusesAnIncomparableModel() async throws {
        let first = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: first.id)
        let second = try savedTranscription()

        let otherModel = SpeakerModelIdentity(
            embeddingModelId: "other-model",
            aggregationProfileId: identity.aggregationProfileId
        )
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[0] = 1
        let observation = SpeakerClusterObservation(
            speakerId: "S1",
            embedding: try XCTUnwrap(SpeakerEmbedding(rawVector: values, identity: otherModel)),
            speechSeconds: 30,
            captureDomain: .system
        )

        let result = try await makeService().enroll(
            displayName: "Sarah",
            observation: observation,
            transcriptionId: second.id,
            allowMergeIntoExistingName: true
        )

        guard case .needsDisambiguation = result else {
            return XCTFail("expected disambiguation, got \(result)")
        }
        XCTAssertEqual(try profiles.exemplars(profileId: profile.id).count, 1)
    }

    func testEnrollRefusesABlankName() async throws {
        let recording = try savedTranscription()
        for blank in ["", "   ", "\n\t"] {
            let result = try await makeService().enroll(
                displayName: blank,
                observation: cluster("S1", voice: 0, degrees: 0),
                transcriptionId: recording.id,
                allowMergeIntoExistingName: false
            )
            XCTAssertEqual(result, .rejectedEmptyName)
        }
        XCTAssertTrue(try profiles.profiles().isEmpty)
    }

    /// A confirmation is as final as a refusal: rescoring would write a fresh
    /// suggestion over the answer the user gave.
    func testConfirmedSpeakersAreNotScoredAgain() async throws {
        let recording = try savedTranscription()
        _ = try await enrolledSarah(transcriptionId: recording.id)
        let next = try savedTranscription()
        let service = makeService()

        let first = try await service.evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        try await service.confirm(
            try XCTUnwrap(first.first),
            observation: cluster("S1", voice: 0, degrees: 14.1),
            transcriptionId: next.id,
            fingerprint: fingerprint
        )

        let second = try await service.evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(
            try profiles.links(transcriptionId: next.id, fingerprint: fingerprint.rawValue)
                .map(\.status),
            [.confirmed]
        )
    }

    /// The cap has to bound storage, not just scoring: vectors the matcher can
    /// never reach would be biometric data kept for nothing.
    func testTheOldestConfirmationIsEvictedAtTheCap() async throws {
        let service = makeService()
        let first = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: first.id)

        // A second manual enrollment unlocks learning from confirmations.
        let second = try savedTranscription()
        _ = try await service.enroll(
            displayName: "Sarah",
            observation: cluster("S1", voice: 0, degrees: 14.1),
            transcriptionId: second.id,
            allowMergeIntoExistingName: false
        )

        // Fill the rest of the cap with confirmations.
        var confirmedRecordings: [UUID] = []
        while try profiles.exemplars(profileId: profile.id).count
            < SpeakerMatchPolicy.v1.maxReferencesPerProfile
        {
            let recording = try savedTranscription()
            confirmedRecordings.append(recording.id)
            let suggestions = try await service.evaluate(
                transcriptionId: recording.id,
                fingerprint: fingerprint,
                clusters: [cluster("S1", voice: 0, degrees: 14.1)]
            )
            try await service.confirm(
                try XCTUnwrap(suggestions.first),
                observation: cluster("S1", voice: 0, degrees: 14.1),
                transcriptionId: recording.id,
                fingerprint: fingerprint
            )
        }
        XCTAssertEqual(
            try profiles.exemplars(profileId: profile.id).count,
            SpeakerMatchPolicy.v1.maxReferencesPerProfile
        )
        let oldestConfirmation = try XCTUnwrap(confirmedRecordings.first)

        // One more recording: the count holds and the oldest confirmation goes.
        let extra = try savedTranscription()
        let suggestions = try await service.evaluate(
            transcriptionId: extra.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        try await service.confirm(
            try XCTUnwrap(suggestions.first),
            observation: cluster("S1", voice: 0, degrees: 14.1),
            transcriptionId: extra.id,
            fingerprint: fingerprint
        )

        let stored = try profiles.exemplars(profileId: profile.id)
        XCTAssertEqual(stored.count, SpeakerMatchPolicy.v1.maxReferencesPerProfile)
        XCTAssertFalse(stored.contains { $0.sourceTranscriptionId == oldestConfirmation })
        XCTAssertTrue(stored.contains { $0.sourceTranscriptionId == extra.id })
        // Both manual anchors survive, so the profile keeps its right to learn.
        XCTAssertEqual(stored.filter { $0.origin == .manualEnrollment }.count, 2)
    }

    /// Ten manual enrollments are the strongest evidence there is; there is
    /// nothing to evict without weakening the anchor.
    func testAProfileFullOfManualEnrollmentsRefusesMore() async throws {
        let service = makeService()
        let first = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: first.id)

        while try profiles.exemplars(profileId: profile.id).count
            < SpeakerMatchPolicy.v1.maxReferencesPerProfile
        {
            let recording = try savedTranscription()
            _ = try await service.enroll(
                displayName: "Sarah",
                observation: cluster("S1", voice: 0, degrees: 14.1),
                transcriptionId: recording.id,
                allowMergeIntoExistingName: false
            )
        }

        let overflow = try savedTranscription()
        let result = try await service.enroll(
            displayName: "Sarah",
            observation: cluster("S1", voice: 0, degrees: 14.1),
            transcriptionId: overflow.id,
            allowMergeIntoExistingName: false
        )

        guard case .rejectedProfileFull = result else {
            return XCTFail("expected a refusal, got \(result)")
        }
        XCTAssertEqual(
            try profiles.exemplars(profileId: profile.id).count,
            SpeakerMatchPolicy.v1.maxReferencesPerProfile
        )
    }

    /// The user asked for a name, not for a row: when another enrollment claims
    /// it between the lookup and the insert, the second one samples the winner
    /// rather than failing.
    func testAnEnrollmentThatLosesTheNameRaceSamplesTheWinner() async throws {
        let first = try savedTranscription()
        let winner = try await enrolledSarah(transcriptionId: first.id)

        let racing = SpeakerVoiceprintService(
            profiles: NameHidingStore(profiles),
            journal: journal,
            policy: .v1,
            isEnabled: { true }
        )
        let second = try savedTranscription()
        let result = try await racing.enroll(
            displayName: "Sarah",
            observation: cluster("S1", voice: 0, degrees: 14.1),
            transcriptionId: second.id,
            allowMergeIntoExistingName: false
        )

        guard case .addedExemplar(let profile) = result else {
            return XCTFail("expected the loser to sample the winner, got \(result)")
        }
        XCTAssertEqual(profile.id, winner.id)
        XCTAssertEqual(try profiles.profiles().count, 1)
        XCTAssertEqual(try profiles.exemplars(profileId: winner.id).count, 2)
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

/// Hides a name from the first lookup so `enroll` takes the path where another
/// enrollment claimed it in between.
private final class NameHidingStore: SpeakerProfileRepositoryProtocol {
    private let wrapped: SpeakerProfileRepository
    private let lock = NSLock()
    private var hidden = true

    init(_ wrapped: SpeakerProfileRepository) {
        self.wrapped = wrapped
    }

    func profile(named name: String) throws -> SpeakerProfile? {
        lock.lock()
        let hide = hidden
        hidden = false
        lock.unlock()
        return hide ? nil : try wrapped.profile(named: name)
    }

    func profiles() throws -> [SpeakerProfile] { try wrapped.profiles() }
    func profile(id: UUID) throws -> SpeakerProfile? { try wrapped.profile(id: id) }
    func insert(_ profile: SpeakerProfile) throws { try wrapped.insert(profile) }
    func save(_ profile: SpeakerProfile) throws { try wrapped.save(profile) }
    func exemplars(profileId: UUID) throws -> [SpeakerProfileExemplar] {
        try wrapped.exemplars(profileId: profileId)
    }
    func exemplarsByProfile() throws -> [UUID: [SpeakerProfileExemplar]] {
        try wrapped.exemplarsByProfile()
    }
    func insert(_ exemplar: SpeakerProfileExemplar) throws { try wrapped.insert(exemplar) }
    func insertExemplar(
        _ exemplar: SpeakerProfileExemplar,
        maxPerProfile: Int,
        evicting: SpeakerProfileExemplar.Origin
    ) throws -> SpeakerExemplarInsertion {
        try wrapped.insertExemplar(exemplar, maxPerProfile: maxPerProfile, evicting: evicting)
    }
    func deleteExemplar(id: UUID) throws -> Bool { try wrapped.deleteExemplar(id: id) }
    func links(transcriptionId: UUID, fingerprint: String) throws -> [SpeakerProfileLink] {
        try wrapped.links(transcriptionId: transcriptionId, fingerprint: fingerprint)
    }
    func save(_ link: SpeakerProfileLink) throws { try wrapped.save(link) }
    func deleteProfile(id: UUID) throws -> Bool { try wrapped.deleteProfile(id: id) }
    func deleteAllProfiles() throws { try wrapped.deleteAllProfiles() }
}
