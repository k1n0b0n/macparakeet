import Foundation
import GRDB

/// One matching decision, kept locally so thresholds can be calibrated on real
/// meetings rather than on the clean-corpus numbers the plan had to borrow.
///
/// Ground truth arrives for free: the label the user ends up typing says
/// whether the decision was right. That makes these rows identifying, so they
/// never leave the machine and they expire.
public struct SpeakerMatchJournalEntry: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var transcriptionId: UUID
    public var speakerId: String
    /// The profile involved, when there was one.
    public var profileId: UUID?
    public var outcome: SpeakerMatchOutcome
    public var topDistance: Double?
    public var runnerUpDistance: Double?
    public var speechSeconds: Double
    public var createdAt: Date

    /// - Parameters:
    ///   - profileId: the profile involved, absent when no enrolled voice was
    ///     comparable.
    ///   - topDistance: the closest distance considered, absent when nothing
    ///     was scored.
    public init(
        id: UUID = UUID(),
        transcriptionId: UUID,
        speakerId: String,
        profileId: UUID? = nil,
        outcome: SpeakerMatchOutcome,
        topDistance: Double? = nil,
        runnerUpDistance: Double? = nil,
        speechSeconds: Double,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.transcriptionId = transcriptionId
        self.speakerId = speakerId
        self.profileId = profileId
        self.outcome = outcome
        self.topDistance = topDistance
        self.runnerUpDistance = runnerUpDistance
        self.speechSeconds = speechSeconds
        self.createdAt = createdAt
    }
}

extension SpeakerMatchJournalEntry: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "speaker_match_journal"
}

public protocol SpeakerMatchJournalRepositoryProtocol: Sendable {
    /// Records one matching pass and prunes anything past the retention window.
    func append(_ entries: [SpeakerMatchJournalEntry], retention: TimeInterval, now: Date) throws
    /// Everything still within the window, oldest first. Expired rows are
    /// removed first, so reading can never surface what should have expired.
    func entries(retention: TimeInterval, now: Date) throws -> [SpeakerMatchJournalEntry]
    /// Removes everything past the window. Safe to call at any time.
    func prune(retention: TimeInterval, now: Date) throws
    /// Forgets every decision. Profiles and transcripts are untouched.
    func deleteAll() throws
}

public final class SpeakerMatchJournalRepository: SpeakerMatchJournalRepositoryProtocol {
    /// Long enough to accumulate the twenty-odd meetings calibration needs,
    /// short enough that the journal never becomes an archive of who spoke to
    /// whom.
    public static let defaultRetention: TimeInterval = 90 * 24 * 60 * 60

    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// Appends a pass and drops anything past the retention window, in one
    /// transaction.
    public func append(
        _ entries: [SpeakerMatchJournalEntry],
        retention: TimeInterval,
        now: Date
    ) throws {
        try dbQueue.write { db in
            for entry in entries {
                try entry.insert(db)
            }
            try deleteExpired(db, retention: retention, now: now)
        }
    }

    /// Prunes, then reads.
    ///
    /// Expiry cannot ride on writes alone: a user who stops recording stops
    /// appending, and rows past the window would then sit there indefinitely,
    /// turning a ninety-day journal into a permanent record of who spoke.
    public func entries(
        retention: TimeInterval = defaultRetention,
        now: Date = Date()
    ) throws -> [SpeakerMatchJournalEntry] {
        try prune(retention: retention, now: now)
        return try dbQueue.read { db in
            try SpeakerMatchJournalEntry.order(Column("createdAt")).fetchAll(db)
        }
    }

    public func prune(retention: TimeInterval = defaultRetention, now: Date = Date()) throws {
        try dbQueue.write { db in
            try deleteExpired(db, retention: retention, now: now)
        }
    }

    private func deleteExpired(_ db: Database, retention: TimeInterval, now: Date) throws {
        try db.execute(
            sql: "DELETE FROM speaker_match_journal WHERE createdAt < ?",
            arguments: [now.addingTimeInterval(-retention)]
        )
    }

    public func deleteAll() throws {
        try dbQueue.write { db in
            _ = try SpeakerMatchJournalEntry.deleteAll(db)
        }
    }
}
