import XCTest
import GRDB
@testable import MacParakeetCore

final class SpeakerProfileRepositoryTests: XCTestCase {
    private var dbQueue: DatabaseQueue!
    private var repo: SpeakerProfileRepository!
    private var transcriptions: TranscriptionRepository!

    private let identity = SpeakerModelIdentity(
        embeddingModelId: "test-model",
        aggregationProfileId: "test-aggregation"
    )

    override func setUp() async throws {
        let manager = try DatabaseManager()
        dbQueue = manager.dbQueue
        repo = SpeakerProfileRepository(dbQueue: manager.dbQueue)
        transcriptions = TranscriptionRepository(dbQueue: manager.dbQueue)
    }

    // MARK: Schema

    func testMigrationCreatesTheThreeVoiceprintTables() throws {
        try dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("speaker_profiles"))
            XCTAssertTrue(try db.tableExists("speaker_profile_exemplars"))
            XCTAssertTrue(try db.tableExists("speaker_profile_links"))

            XCTAssertEqual(
                Set(try db.columns(in: "speaker_profiles").map(\.name)),
                [
                    "id", "displayName", "normalizedName", "embeddingModelId", "aggregationProfileId",
                    "createdAt", "updatedAt", "lastMatchedAt", "lastEvaluatedAt",
                    "lastEvaluatedDistance",
                ]
            )
            XCTAssertEqual(
                Set(try db.columns(in: "speaker_profile_exemplars").map(\.name)),
                [
                    "id", "profileId", "vector", "speechSeconds", "captureDomain",
                    "origin", "embeddingModelId", "aggregationProfileId",
                    "sourceTranscriptionId", "sourceSpeakerId", "createdAt",
                ]
            )
            XCTAssertEqual(
                Set(try db.columns(in: "speaker_profile_links").map(\.name)),
                [
                    "transcriptionId", "speakerId", "transcriptFingerprint", "profileId",
                    "status", "distance", "runnerUpDistance", "createdAt", "updatedAt",
                ]
            )
        }
    }

    // MARK: Round trip

    func testExemplarVectorRoundTripsBitExact() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let embedding = makeEmbedding(index: 7)
        try repo.insert(exemplar(profileId: profile.id, embedding: embedding))

        let stored = try XCTUnwrap(try repo.exemplars(profileId: profile.id).first)
        XCTAssertEqual(stored.vector.count, 1024)
        XCTAssertEqual(try XCTUnwrap(stored.embedding).vector, embedding.vector)
        XCTAssertEqual(stored.identity, identity)
    }

    // MARK: Constraints

    func testRejectsVectorOfTheWrongLength() throws {
        let profile = try enrolledProfile(named: "Sarah")
        XCTAssertThrowsError(
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO speaker_profile_exemplars
                        (id, profileId, vector, speechSeconds, captureDomain, origin,
                         embeddingModelId, aggregationProfileId, createdAt)
                        VALUES (?, ?, ?, ?, 'system', 'manualEnrollment', 'm', 'a', ?)
                        """,
                    arguments: [UUID(), profile.id, Data(repeating: 0, count: 1020), 20.0, Date()]
                )
            }
        )
    }

    func testRejectsNonPositiveSpeechDuration() throws {
        let profile = try enrolledProfile(named: "Sarah")
        XCTAssertThrowsError(
            try repo.insert(exemplar(profileId: profile.id, embedding: makeEmbedding(index: 1), speechSeconds: 0))
        )
    }

    func testRejectsUnknownCaptureDomainOrOrigin() throws {
        let profile = try enrolledProfile(named: "Sarah")
        for (domain, origin) in [("hologram", "manualEnrollment"), ("system", "osmosis")] {
            XCTAssertThrowsError(
                try dbQueue.write { db in
                    try db.execute(
                        sql: """
                            INSERT INTO speaker_profile_exemplars
                            (id, profileId, vector, speechSeconds, captureDomain, origin,
                             embeddingModelId, aggregationProfileId, createdAt)
                            VALUES (?, ?, ?, ?, ?, ?, 'm', 'a', ?)
                            """,
                        arguments: [
                            UUID(), profile.id, makeEmbedding(index: 1).data, 20.0,
                            domain, origin, Date(),
                        ]
                    )
                }
            )
        }
    }

    func testNamesAreUniqueCaseInsensitively() throws {
        _ = try enrolledProfile(named: "Sarah")
        XCTAssertThrowsError(try repo.save(SpeakerProfile(displayName: "sarah", identity: identity)))
    }

    func testOneExemplarPerProfilePerRecording() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let transcription = try savedTranscription()

        try repo.insert(
            exemplar(
                profileId: profile.id,
                embedding: makeEmbedding(index: 1),
                sourceTranscriptionId: transcription.id
            )
        )
        XCTAssertThrowsError(
            try repo.insert(
                exemplar(
                    profileId: profile.id,
                    embedding: makeEmbedding(index: 2),
                    sourceTranscriptionId: transcription.id
                )
            )
        )
    }

    /// SQLite treats NULLs as distinct in a UNIQUE constraint, which is what we
    /// want: exemplars whose recording was deleted must not start colliding.
    func testExemplarsWithoutARecordingDoNotCollide() throws {
        let profile = try enrolledProfile(named: "Sarah")
        try repo.insert(exemplar(profileId: profile.id, embedding: makeEmbedding(index: 1)))
        try repo.insert(exemplar(profileId: profile.id, embedding: makeEmbedding(index: 2)))
        XCTAssertEqual(try repo.exemplars(profileId: profile.id).count, 2)
    }

    func testRejectsAnExemplarFromAnotherEmbeddingModel() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let otherModel = SpeakerModelIdentity(
            embeddingModelId: "other-model",
            aggregationProfileId: identity.aggregationProfileId
        )
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[0] = 1
        let foreign = try XCTUnwrap(SpeakerEmbedding(rawVector: values, identity: otherModel))

        XCTAssertThrowsError(
            try repo.insert(
                SpeakerProfileExemplar(
                    profileId: profile.id,
                    embedding: foreign,
                    speechSeconds: 20,
                    captureDomain: .system,
                    origin: .manualEnrollment
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? SpeakerProfileStoreError,
                .incompatibleEmbeddingModel(profile: "test-model", exemplar: "other-model")
            )
        }
        XCTAssertTrue(try repo.exemplars(profileId: profile.id).isEmpty)
    }

    /// A differing aggregation profile stays comparable — the matcher tightens
    /// its threshold for it — so the store must not refuse it.
    func testAcceptsAnExemplarFromAnotherAggregationProfile() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let otherAggregation = SpeakerModelIdentity(
            embeddingModelId: identity.embeddingModelId,
            aggregationProfileId: "other-aggregation"
        )
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[1] = 1
        let embedding = try XCTUnwrap(SpeakerEmbedding(rawVector: values, identity: otherAggregation))

        XCTAssertNoThrow(
            try repo.insert(
                SpeakerProfileExemplar(
                    profileId: profile.id,
                    embedding: embedding,
                    speechSeconds: 20,
                    captureDomain: .system,
                    origin: .manualEnrollment
                )
            )
        )
        XCTAssertEqual(try repo.exemplars(profileId: profile.id).count, 1)
    }

    func testRejectsAModelChangeOnAProfileThatHasSamples() throws {
        var profile = try enrolledProfile(named: "Sarah")
        try repo.insert(exemplar(profileId: profile.id, embedding: makeEmbedding(index: 1)))

        profile = SpeakerProfile(
            id: profile.id,
            displayName: profile.displayName,
            identity: SpeakerModelIdentity(
                embeddingModelId: "next-model",
                aggregationProfileId: identity.aggregationProfileId
            )
        )
        XCTAssertThrowsError(try repo.save(profile)) { error in
            XCTAssertEqual(
                error as? SpeakerProfileStoreError, .embeddingModelChangeWithExemplars(profile.id)
            )
        }
        XCTAssertEqual(try repo.profile(id: profile.id)?.embeddingModelId, "test-model")
    }

    func testAModelChangeIsAllowedWhileAProfileHasNoSamples() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let migrated = SpeakerProfile(
            id: profile.id,
            displayName: profile.displayName,
            identity: SpeakerModelIdentity(
                embeddingModelId: "next-model",
                aggregationProfileId: identity.aggregationProfileId
            )
        )
        XCTAssertNoThrow(try repo.save(migrated))
        XCTAssertEqual(try repo.profile(id: profile.id)?.embeddingModelId, "next-model")
    }

    /// The stored key must not depend on the device locale: under a Turkish
    /// locale, localized folding maps "I" to a dotless i, and every profile
    /// whose name contains one would become unfindable after a locale change.
    func testNormalizedKeyIsIndependentOfLocale() throws {
        let profile = SpeakerProfile(displayName: "ISTANBUL", identity: identity)
        try repo.save(profile)

        XCTAssertEqual(
            SpeakerProfile.normalizedName(for: "ISTANBUL"),
            SpeakerProfile.normalizedName(for: "Istanbul")
        )
        XCTAssertEqual(try repo.profile(named: "istanbul")?.id, profile.id)
        // Localized folding would give "ıstanbul" here; the canonical mapping
        // must not.
        XCTAssertEqual(SpeakerProfile.normalizedName(for: "ISTANBUL"), "istanbul")
    }

    func testRejectsAProfileWhoseNameNormalizesToNothing() throws {
        for blank in ["", "   ", "\n\t "] {
            XCTAssertThrowsError(
                try repo.save(SpeakerProfile(displayName: blank, identity: identity))
            ) { error in
                XCTAssertEqual(error as? SpeakerProfileStoreError, .emptyDisplayName)
            }
        }
        XCTAssertTrue(try repo.profiles().isEmpty)
    }

    func testASuggestionCannotOverwriteAConfirmedDecision() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let transcription = try savedTranscription()

        var confirmed = link(transcriptionId: transcription.id, profileId: profile.id)
        confirmed.status = .confirmed
        try repo.save(confirmed)

        XCTAssertThrowsError(
            try repo.save(link(transcriptionId: transcription.id, profileId: profile.id))
        ) { error in
            XCTAssertEqual(
                error as? SpeakerProfileStoreError,
                .terminalDecisionAlreadyRecorded(status: .confirmed)
            )
        }
        XCTAssertEqual(
            try repo.links(transcriptionId: transcription.id, fingerprint: "fingerprint")
                .map(\.status),
            [.confirmed]
        )
    }

    func testASuggestionCannotOverwriteADismissedDecision() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let transcription = try savedTranscription()

        var dismissed = link(transcriptionId: transcription.id, profileId: profile.id)
        dismissed.status = .dismissed
        try repo.save(dismissed)

        XCTAssertThrowsError(
            try repo.save(link(transcriptionId: transcription.id, profileId: profile.id))
        )
    }

    func testASuggestionStillBecomesTerminal() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let transcription = try savedTranscription()
        try repo.save(link(transcriptionId: transcription.id, profileId: profile.id))

        var confirmed = link(transcriptionId: transcription.id, profileId: profile.id)
        confirmed.status = .confirmed
        XCTAssertNoThrow(try repo.save(confirmed))
        XCTAssertEqual(
            try repo.links(transcriptionId: transcription.id, fingerprint: "fingerprint")
                .map(\.status),
            [.confirmed]
        )
    }

    /// The composite foreign key is what makes the model invariant structural
    /// rather than merely enforced in Swift.
    func testTheDatabaseItselfRefusesAMismatchedExemplarModel() throws {
        let profile = try enrolledProfile(named: "Sarah")
        XCTAssertThrowsError(
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO speaker_profile_exemplars
                        (id, profileId, vector, speechSeconds, captureDomain, origin,
                         embeddingModelId, aggregationProfileId, createdAt)
                        VALUES (?, ?, ?, ?, 'system', 'manualEnrollment', 'other-model', 'a', ?)
                        """,
                    arguments: [UUID(), profile.id, makeEmbedding(index: 1).data, 20.0, Date()]
                )
            }
        )
    }

    // MARK: Deletion

    func testDeletingAProfileRemovesItsExemplarsAndLinks() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let transcription = try savedTranscription()
        try repo.insert(
            exemplar(
                profileId: profile.id,
                embedding: makeEmbedding(index: 1),
                sourceTranscriptionId: transcription.id
            )
        )
        try repo.save(link(transcriptionId: transcription.id, profileId: profile.id))

        XCTAssertTrue(try repo.deleteProfile(id: profile.id))

        try dbQueue.read { db in
            XCTAssertEqual(try SpeakerProfileExemplar.fetchCount(db), 0)
            XCTAssertEqual(try SpeakerProfileLink.fetchCount(db), 0)
        }
        // The recording itself is untouched: deleting a voiceprint never
        // rewrites the user's transcripts.
        XCTAssertNotNil(try transcriptions.fetch(id: transcription.id))
    }

    func testDeletingARecordingKeepsTheExemplarButClearsItsSource() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let transcription = try savedTranscription()
        try repo.insert(
            exemplar(
                profileId: profile.id,
                embedding: makeEmbedding(index: 1),
                sourceTranscriptionId: transcription.id
            )
        )

        XCTAssertTrue(try transcriptions.delete(id: transcription.id))

        let stored = try XCTUnwrap(try repo.exemplars(profileId: profile.id).first)
        XCTAssertNil(stored.sourceTranscriptionId)
        XCTAssertNotNil(stored.embedding)
    }

    func testDeletingARecordingRemovesItsLinks() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let transcription = try savedTranscription()
        try repo.save(link(transcriptionId: transcription.id, profileId: profile.id))

        XCTAssertTrue(try transcriptions.delete(id: transcription.id))

        try dbQueue.read { db in
            XCTAssertEqual(try SpeakerProfileLink.fetchCount(db), 0)
        }
    }

    func testDeleteAllProfilesEmptiesEveryVoiceprintTable() throws {
        let first = try enrolledProfile(named: "Sarah")
        let second = try enrolledProfile(named: "Dan")
        let transcription = try savedTranscription()
        try repo.insert(
            exemplar(
                profileId: first.id,
                embedding: makeEmbedding(index: 1),
                sourceTranscriptionId: transcription.id
            )
        )
        try repo.save(link(transcriptionId: transcription.id, profileId: second.id))

        try repo.deleteAllProfiles()

        try dbQueue.read { db in
            XCTAssertEqual(try SpeakerProfile.fetchCount(db), 0)
            XCTAssertEqual(try SpeakerProfileExemplar.fetchCount(db), 0)
            XCTAssertEqual(try SpeakerProfileLink.fetchCount(db), 0)
        }
        XCTAssertNotNil(try transcriptions.fetch(id: transcription.id))
    }

    func testDeleteExemplarRemovesOnlyThatSample() throws {
        let profile = try enrolledProfile(named: "Sarah")
        try repo.insert(exemplar(profileId: profile.id, embedding: makeEmbedding(index: 1)))
        let second = exemplar(profileId: profile.id, embedding: makeEmbedding(index: 2))
        try repo.insert(second)

        XCTAssertTrue(try repo.deleteExemplar(id: second.id))
        XCTAssertEqual(try repo.exemplars(profileId: profile.id).count, 1)
        XCTAssertNotNil(try repo.profile(id: profile.id))
    }

    // MARK: Lookups

    func testProfileLookupByNameIgnoresCase() throws {
        let profile = try enrolledProfile(named: "Sarah")
        XCTAssertEqual(try repo.profile(named: "sarah")?.id, profile.id)
        XCTAssertEqual(try repo.profile(named: "SARAH")?.id, profile.id)
        XCTAssertNil(try repo.profile(named: "Dan"))
    }

    func testExemplarsByProfileGroupsEveryProfile() throws {
        let first = try enrolledProfile(named: "Sarah")
        let second = try enrolledProfile(named: "Dan")
        try repo.insert(exemplar(profileId: first.id, embedding: makeEmbedding(index: 1)))
        try repo.insert(exemplar(profileId: first.id, embedding: makeEmbedding(index: 2)))
        try repo.insert(exemplar(profileId: second.id, embedding: makeEmbedding(index: 3)))

        let grouped = try repo.exemplarsByProfile()
        XCTAssertEqual(grouped[first.id]?.count, 2)
        XCTAssertEqual(grouped[second.id]?.count, 1)
    }

    func testLinksAreScopedToTheirFingerprint() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let transcription = try savedTranscription()
        try repo.save(
            link(transcriptionId: transcription.id, profileId: profile.id, fingerprint: "before")
        )

        XCTAssertEqual(
            try repo.links(transcriptionId: transcription.id, fingerprint: "before").count,
            1
        )
        // After re-diarization the fingerprint changes and old decisions no
        // longer apply, so a stale dismissal cannot suppress a fresh suggestion.
        XCTAssertTrue(
            try repo.links(transcriptionId: transcription.id, fingerprint: "after").isEmpty
        )
    }

    func testProfileLookupHandlesNonAsciiCase() throws {
        // SQLite's NOCASE folds only ASCII, so this is the case that would
        // silently create a second profile for the same person.
        let profile = SpeakerProfile(displayName: "José", identity: identity)
        try repo.save(profile)
        XCTAssertEqual(try repo.profile(named: "josé")?.id, profile.id)
        XCTAssertEqual(try repo.profile(named: "JOSÉ")?.id, profile.id)
    }

    /// The constraint and the lookup must agree on what one name is, otherwise
    /// two rows can exist that a lookup considers equal and picks between at
    /// random.
    func testNonAsciiCaseVariantsCannotBothBeStored() throws {
        try repo.save(SpeakerProfile(displayName: "José", identity: identity))
        XCTAssertThrowsError(try repo.save(SpeakerProfile(displayName: "JOSÉ", identity: identity)))
    }

    func testRenamingAProfileMovesItsLookupKey() throws {
        var profile = SpeakerProfile(displayName: "Sarah", identity: identity)
        try repo.save(profile)

        profile.displayName = "Sarah Chen"
        try repo.save(profile)

        XCTAssertEqual(try repo.profile(named: "sarah chen")?.id, profile.id)
        XCTAssertNil(try repo.profile(named: "Sarah"))
        // The old key must not keep enforcing uniqueness either.
        XCTAssertNoThrow(try repo.save(SpeakerProfile(displayName: "Sarah", identity: identity)))
    }

    func testLookupIgnoresSurroundingWhitespace() throws {
        let profile = SpeakerProfile(displayName: "Sarah", identity: identity)
        try repo.save(profile)
        XCTAssertEqual(try repo.profile(named: "  sarah  ")?.id, profile.id)
    }

    /// Accents are typography; dropping them would be a guess about identity.
    /// Two colleagues named Jose and José stay two people, and the enrollment
    /// guard is what catches a genuine name clash, by voice.
    func testAccentsDistinguishNames() throws {
        let plain = SpeakerProfile(displayName: "Jose", identity: identity)
        let accented = SpeakerProfile(displayName: "José", identity: identity)
        try repo.save(plain)
        try repo.save(accented)
        XCTAssertEqual(try repo.profile(named: "jose")?.id, plain.id)
        XCTAssertEqual(try repo.profile(named: "josé")?.id, accented.id)
    }

    func testUpdatingALinkKeepsItsOriginalCreationTime() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let transcription = try savedTranscription()
        let suggestedAt = Date(timeIntervalSince1970: 1_000_000)

        var suggestion = link(transcriptionId: transcription.id, profileId: profile.id)
        suggestion.createdAt = suggestedAt
        suggestion.updatedAt = suggestedAt
        try repo.save(suggestion)

        var confirmation = link(transcriptionId: transcription.id, profileId: profile.id)
        confirmation.status = .confirmed
        try repo.save(confirmation)

        let stored = try XCTUnwrap(
            try repo.links(transcriptionId: transcription.id, fingerprint: "fingerprint").first
        )
        XCTAssertEqual(stored.status, .confirmed)
        XCTAssertEqual(stored.createdAt.timeIntervalSince1970, suggestedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertGreaterThan(stored.updatedAt, suggestedAt)
    }

    func testSavingALinkTwiceUpdatesItInPlace() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let transcription = try savedTranscription()
        try repo.save(link(transcriptionId: transcription.id, profileId: profile.id))

        var updated = link(transcriptionId: transcription.id, profileId: profile.id)
        updated.status = .dismissed
        try repo.save(updated)

        let stored = try repo.links(transcriptionId: transcription.id, fingerprint: "fingerprint")
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.status, .dismissed)
    }

    // MARK: Helpers

    private func makeEmbedding(index: Int) -> SpeakerEmbedding {
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[index] = 1
        guard let embedding = SpeakerEmbedding(rawVector: values, identity: identity) else {
            preconditionFailure("fixture vector must be valid")
        }
        return embedding
    }

    private func enrolledProfile(named name: String) throws -> SpeakerProfile {
        let profile = SpeakerProfile(displayName: name, identity: identity)
        try repo.save(profile)
        return profile
    }

    private func savedTranscription() throws -> Transcription {
        let transcription = Transcription(fileName: "meeting.wav", sourceType: .meeting)
        try transcriptions.save(transcription)
        return transcription
    }

    private func exemplar(
        profileId: UUID,
        embedding: SpeakerEmbedding,
        speechSeconds: Double = 20,
        sourceTranscriptionId: UUID? = nil
    ) -> SpeakerProfileExemplar {
        SpeakerProfileExemplar(
            profileId: profileId,
            embedding: embedding,
            speechSeconds: speechSeconds,
            captureDomain: .system,
            origin: .manualEnrollment,
            sourceTranscriptionId: sourceTranscriptionId,
            sourceSpeakerId: "S1"
        )
    }

    private func link(
        transcriptionId: UUID,
        profileId: UUID,
        fingerprint: String = "fingerprint"
    ) -> SpeakerProfileLink {
        SpeakerProfileLink(
            transcriptionId: transcriptionId,
            speakerId: "system:S1",
            transcriptFingerprint: fingerprint,
            profileId: profileId,
            status: .suggested,
            distance: 0.12,
            runnerUpDistance: 0.44
        )
    }
}
