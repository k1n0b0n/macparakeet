import Foundation
import GRDB

public protocol SpeakerProfileRepositoryProtocol: Sendable {
    func profiles() throws -> [SpeakerProfile]
    func profile(id: UUID) throws -> SpeakerProfile?
    /// Case-insensitive; what enrollment uses to choose between adding a sample
    /// and creating a profile.
    func profile(named name: String) throws -> SpeakerProfile?
    func save(_ profile: SpeakerProfile) throws
    func exemplars(profileId: UUID) throws -> [SpeakerProfileExemplar]
    /// One read for a whole matching pass.
    func exemplarsByProfile() throws -> [UUID: [SpeakerProfileExemplar]]
    func insert(_ exemplar: SpeakerProfileExemplar) throws
    func deleteExemplar(id: UUID) throws -> Bool
    /// Rows from an earlier fingerprint are deliberately invisible here.
    func links(transcriptionId: UUID, fingerprint: String) throws -> [SpeakerProfileLink]
    func save(_ link: SpeakerProfileLink) throws
    /// Removes a profile with its samples and decisions in one transaction.
    /// Transcripts and labels already applied are untouched.
    func deleteProfile(id: UUID) throws -> Bool
    func deleteAllProfiles() throws
}

/// Stores enrolled voices. Persistence only — thresholds and matching policy
/// live in the matcher.
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

    /// Queries the stored normalized key, the same one the unique index uses.
    /// A collation here instead would let lookup and constraint disagree:
    /// `NOCASE` folds only ASCII, so two rows a Unicode-aware lookup considers
    /// equal could both exist and `fetchOne` would pick arbitrarily.
    public func profile(named name: String) throws -> SpeakerProfile? {
        let key = SpeakerProfile.normalizedName(for: name)
        return try dbQueue.read { db in
            try SpeakerProfile.filter(Column("normalizedName") == key).fetchOne(db)
        }
    }

    /// Recomputes the normalized key before writing: `displayName` is mutable,
    /// so a rename would otherwise leave the old key enforcing uniqueness while
    /// a lookup by the new name found nothing.
    public func save(_ profile: SpeakerProfile) throws {
        var profile = profile
        profile.normalizedName = SpeakerProfile.normalizedName(for: profile.displayName)
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

    /// One read for a whole matching pass rather than one per profile.
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

    /// Upserts a decision, keeping the original `createdAt`: status moves from
    /// suggested to confirmed or dismissed, and each caller builds a fresh
    /// value, so otherwise the offer time is overwritten by the answer time.
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

    /// Exemplars and links go with it through their cascades; transcripts and
    /// any label already applied are untouched.
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
