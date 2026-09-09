import Foundation
import GRDB

public protocol SpeakerProfileRepositoryProtocol: Sendable {
    func profiles() throws -> [SpeakerProfile]
    func profile(id: UUID) throws -> SpeakerProfile?
    func profile(named name: String) throws -> SpeakerProfile?
    func save(_ profile: SpeakerProfile) throws
    func exemplars(profileId: UUID) throws -> [SpeakerProfileExemplar]
    func exemplarsByProfile() throws -> [UUID: [SpeakerProfileExemplar]]
    func insert(_ exemplar: SpeakerProfileExemplar) throws
    func deleteExemplar(id: UUID) throws -> Bool
    func links(transcriptionId: UUID, fingerprint: String) throws -> [SpeakerProfileLink]
    func save(_ link: SpeakerProfileLink) throws
    func deleteProfile(id: UUID) throws -> Bool
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

    /// Case-insensitive, matching the unique index: "sarah" and "Sarah" are the
    /// same person as far as enrollment is concerned.
    public func profile(named name: String) throws -> SpeakerProfile? {
        try dbQueue.read { db in
            try SpeakerProfile
                .filter(Column("displayName").collating(.nocase) == name)
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

    public func save(_ link: SpeakerProfileLink) throws {
        try dbQueue.write { db in
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
