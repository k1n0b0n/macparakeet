import Foundation
import GRDB

/// A voice the user has explicitly enrolled, so the same person can be
/// recognized across recordings.
///
/// Deliberately holds no centroid column: scoring takes the minimum distance
/// over the profile's exemplars, which preserves per-domain modes, so a derived
/// aggregate would be an unused cache with its own coherency bugs.
public struct SpeakerProfile: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    /// Unique case-insensitively: renaming another speaker to this name adds an
    /// exemplar here rather than creating a rival profile.
    public var displayName: String
    public var embeddingModelId: String
    public var aggregationProfileId: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Last time this profile was actually suggested for a speaker.
    public var lastMatchedAt: Date?
    /// Last time it was scored at all, matched or not, with its best distance.
    /// The pair is what lets the admin screen answer "why does this profile
    /// never match?" with a number instead of a shrug.
    public var lastEvaluatedAt: Date?
    public var lastEvaluatedDistance: Double?

    /// - Parameters:
    ///   - displayName: unique case-insensitively; enrollment looks a profile
    ///     up by this name before deciding to create one.
    ///   - identity: the representation this profile's samples live in. Samples
    ///     from another embedding model are never compared against it.
    public init(
        id: UUID = UUID(),
        displayName: String,
        identity: SpeakerModelIdentity,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastMatchedAt: Date? = nil,
        lastEvaluatedAt: Date? = nil,
        lastEvaluatedDistance: Double? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.embeddingModelId = identity.embeddingModelId
        self.aggregationProfileId = identity.aggregationProfileId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMatchedAt = lastMatchedAt
        self.lastEvaluatedAt = lastEvaluatedAt
        self.lastEvaluatedDistance = lastEvaluatedDistance
    }

    public var identity: SpeakerModelIdentity {
        SpeakerModelIdentity(
            embeddingModelId: embeddingModelId,
            aggregationProfileId: aggregationProfileId
        )
    }
}

extension SpeakerProfile: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "speaker_profiles"
}

/// One recording's worth of voice evidence for a profile.
///
/// At most one per profile per recording, enforced by a unique constraint
/// rather than by code: offline segment embeddings within a recording all
/// derive from the same cluster centroid, so storing several would inflate the
/// sample count without adding any diversity.
public struct SpeakerProfileExemplar: Codable, Identifiable, Sendable, Equatable {
    public enum Origin: String, Codable, Sendable {
        /// The user named this speaker themselves.
        case manualEnrollment
        /// The user confirmed a suggestion, which also improves the profile.
        case confirmedSuggestion
    }

    public var id: UUID
    public var profileId: UUID
    /// The embedding, 1024 bytes of little-endian Float32. Stored as a blob
    /// rather than JSON: SQLite validates the length, and an accidental
    /// serialization yields opaque bytes instead of a readable voiceprint.
    public var vector: Data
    public var speechSeconds: Double
    public var captureDomain: SpeakerCaptureDomain
    public var origin: Origin
    public var embeddingModelId: String
    public var aggregationProfileId: String
    /// Cleared rather than cascaded when the transcript goes: the user enrolled
    /// a person, not a recording, so tidying the library must not quietly
    /// degrade a profile.
    public var sourceTranscriptionId: UUID?
    public var sourceSpeakerId: String?
    public var createdAt: Date

    /// - Parameters:
    ///   - embedding: stored as bytes; its model identity is copied alongside
    ///     so a later upgrade can tell which representation this sample is in.
    ///   - sourceTranscriptionId: the recording it came from, cleared rather
    ///     than cascaded when that recording is deleted.
    public init(
        id: UUID = UUID(),
        profileId: UUID,
        embedding: SpeakerEmbedding,
        speechSeconds: Double,
        captureDomain: SpeakerCaptureDomain,
        origin: Origin,
        sourceTranscriptionId: UUID? = nil,
        sourceSpeakerId: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.profileId = profileId
        self.vector = embedding.data
        self.speechSeconds = speechSeconds
        self.captureDomain = captureDomain
        self.origin = origin
        self.embeddingModelId = embedding.identity.embeddingModelId
        self.aggregationProfileId = embedding.identity.aggregationProfileId
        self.sourceTranscriptionId = sourceTranscriptionId
        self.sourceSpeakerId = sourceSpeakerId
        self.createdAt = createdAt
    }

    public var identity: SpeakerModelIdentity {
        SpeakerModelIdentity(
            embeddingModelId: embeddingModelId,
            aggregationProfileId: aggregationProfileId
        )
    }

    /// Decodes the stored vector. `nil` means the blob no longer satisfies the
    /// embedding invariants, in which case the exemplar cannot take part in
    /// matching.
    public var embedding: SpeakerEmbedding? {
        SpeakerEmbedding(data: vector, identity: identity)
    }
}

extension SpeakerProfileExemplar: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "speaker_profile_exemplars"
}

/// What was decided about one detected speaker in one transcript.
///
/// Carries no label: the label lives in `speaker_corrections`, which already
/// owns provenance and undo. This table exists for the three things that layer
/// cannot express — that a dismissal must not be repeated, that a profile has
/// already taken a sample from this recording, and that everything disappears
/// with its profile.
public struct SpeakerProfileLink: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case suggested
        case confirmed
        case dismissed
    }

    public var transcriptionId: UUID
    /// The diarizer's id for this run ("S1", "system:S1"). Positional, which is
    /// exactly why rows are fingerprint-scoped: after re-diarization the same
    /// id can mean a different person.
    public var speakerId: String
    public var transcriptFingerprint: String
    public var profileId: UUID
    public var status: Status
    public var distance: Double
    public var runnerUpDistance: Double?
    public var createdAt: Date
    public var updatedAt: Date

    /// - Parameters:
    ///   - speakerId: the diarizer's positional id, meaningful only together
    ///     with `transcriptFingerprint`.
    ///   - distance: what the decision was based on, kept so calibration can
    ///     read it back.
    public init(
        transcriptionId: UUID,
        speakerId: String,
        transcriptFingerprint: String,
        profileId: UUID,
        status: Status,
        distance: Double,
        runnerUpDistance: Double? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.transcriptionId = transcriptionId
        self.speakerId = speakerId
        self.transcriptFingerprint = transcriptFingerprint
        self.profileId = profileId
        self.status = status
        self.distance = distance
        self.runnerUpDistance = runnerUpDistance
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension SpeakerProfileLink: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "speaker_profile_links"
}
