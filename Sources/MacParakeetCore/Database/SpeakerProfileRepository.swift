import Foundation
import GRDB

public protocol SpeakerProfileRepositoryProtocol: Sendable {
    /// Every enrolled voice, ordered by name.
    func profiles() throws -> [SpeakerProfile]
    func profile(id: UUID) throws -> SpeakerProfile?
    /// Case-insensitive lookup, the one enrollment uses to decide between
    /// adding a sample and creating a profile.
    func profile(named name: String) throws -> SpeakerProfile?
    /// Inserts or updates. Names are unique, so saving a second profile under
    /// an existing name throws rather than creating a duplicate.
    func save(_ profile: SpeakerProfile) throws
    /// A profile's samples, oldest first.
    func exemplars(profileId: UUID) throws -> [SpeakerProfileExemplar]
    /// Every sample grouped by profile — one read for a whole matching pass.
    func exemplarsByProfile() throws -> [UUID: [SpeakerProfileExemplar]]
    /// Adds a sample. Throws when the profile already holds one from the same
    /// recording, which the schema forbids.
    func insert(_ exemplar: SpeakerProfileExemplar) throws
    /// Removes one sample, leaving its profile in place. `false` when it was
    /// already gone.
    func deleteExemplar(id: UUID) throws -> Bool
    /// Decisions recorded for one transcript at one fingerprint. Rows from an
    /// earlier fingerprint are deliberately invisible here.
    func links(transcriptionId: UUID, fingerprint: String) throws -> [SpeakerProfileLink]
    /// Inserts or updates a decision, preserving its original creation time.
    func save(_ link: SpeakerProfileLink) throws
    /// Removes a profile with its samples and decisions, in one transaction.
    /// Transcripts and labels already applied are untouched.
    func deleteProfile(id: UUID) throws -> Bool
    /// Forgets every voice. Same guarantees as `deleteProfile`, applied at once.
    func deleteAllProfiles() throws
}

/// Stores enrolled voices. Persistence only: thresholds, gates and matching
/// policy live in the matcher, and nothing here decides whether two voices are
/// the same person.
public final class SpeakerProfileRepository: SpeakerProfileRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: Profiles

    public func profiles() throws -> [SpeakerProfile] {
        try dbQueue.read { db in
            try SpeakerProfile
                .order(Column("displayName").collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
        }
    }

    public func profile(id: UUID) throws -> SpeakerProfile? {
        try dbQueue.read { db in
            try SpeakerProfile.fetchOne(db, key: id)
        }
    }

    /// Case-insensitive lookup: "sarah" and "Sarah" are the same person as far
    /// as enrollment is concerned.
    ///
    /// Uses a localized collation rather than SQLite's `NOCASE`, which folds
    /// only the 26 ASCII letters — under it "josé" and "JOSÉ" would be two
    /// different people, and the second enrollment would silently create a
    /// rival profile instead of adding a sample. The unique index keeps
    /// `NOCASE` as a backstop, so this lookup is deliberately the wider of the
    /// two.
    public func profile(named name: String) throws -> SpeakerProfile? {
        try dbQueue.read { db in
            try SpeakerProfile
                .filter(Column("displayName").collating(.localizedCaseInsensitiveCompare) == name)
                .fetchOne(db)
        }
    }

    public func save(_ profile: SpeakerProfile) throws {
        try dbQueue.write { db in
            try profile.save(db)
        }
    }

    // MARK: Exemplars

    public func exemplars(profileId: UUID) throws -> [SpeakerProfileExemplar] {
        try dbQueue.read { db in
            try SpeakerProfileExemplar
                .filter(Column("profileId") == profileId)
                .order(Column("createdAt"))
                .fetchAll(db)
        }
    }

    /// Every exemplar, grouped by profile — one read for a whole matching pass
    /// rather than one per profile.
    public func exemplarsByProfile() throws -> [UUID: [SpeakerProfileExemplar]] {
        let all = try dbQueue.read { db in
            try SpeakerProfileExemplar.order(Column("createdAt")).fetchAll(db)
        }
        return Dictionary(grouping: all, by: \.profileId)
    }

    public func insert(_ exemplar: SpeakerProfileExemplar) throws {
        try dbQueue.write { db in
            try exemplar.insert(db)
        }
    }

    public func deleteExemplar(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try SpeakerProfileExemplar.deleteOne(db, key: id)
        }
    }

    // MARK: Links

    public func links(transcriptionId: UUID, fingerprint: String) throws -> [SpeakerProfileLink] {
        try dbQueue.read { db in
            try SpeakerProfileLink
                .filter(Column("transcriptionId") == transcriptionId)
                .filter(Column("transcriptFingerprint") == fingerprint)
                .fetchAll(db)
        }
    }

    /// Upserts a decision, keeping the original `createdAt`.
    ///
    /// A link is saved again whenever its status moves — suggested, then
    /// confirmed or dismissed — and each caller builds a fresh value. Without
    /// this, the moment the suggestion was first made would be overwritten by
    /// the moment the user answered, and the journal would lose the interval
    /// between them.
    public func save(_ link: SpeakerProfileLink) throws {
        try dbQueue.write { db in
            var link = link
            let existing = try SpeakerProfileLink
                .filter(Column("transcriptionId") == link.transcriptionId)
                .filter(Column("speakerId") == link.speakerId)
                .filter(Column("transcriptFingerprint") == link.transcriptFingerprint)
                .fetchOne(db)
            if let existing {
                link.createdAt = existing.createdAt
            }
            try link.save(db)
        }
    }

    // MARK: Deletion

    /// Removes a profile and everything it owns in one transaction.
    ///
    /// Exemplars and links go with it through their cascades; transcripts and
    /// any label already applied are untouched, because deleting a voiceprint
    /// must not rewrite the user's history.
    public func deleteProfile(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try SpeakerProfile.deleteOne(db, key: id)
        }
    }

    public func deleteAllProfiles() throws {
        try dbQueue.write { db in
            _ = try SpeakerProfile.deleteAll(db)
        }
    }
}
