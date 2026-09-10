import Foundation

/// What happened when the user asked to remember a voice.
public enum SpeakerProfileEnrollment: Sendable, Equatable {
    case created(SpeakerProfile)
    case addedExemplar(SpeakerProfile)
    /// The name is taken by a profile whose voice does not match. Merging would
    /// fuse two people, so the caller must ask.
    case needsDisambiguation(existing: SpeakerProfile, distance: Double)
    case rejectedTooShort(speechSeconds: Double)
    /// The profile already holds a sample from this recording.
    case alreadySampled(SpeakerProfile)
}

public protocol SpeakerVoiceprintServicing: Sendable {
    /// Names worth proposing. Applies nothing, and does no work when off.
    func evaluate(
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint,
        clusters: [SpeakerClusterObservation]
    ) async throws -> [SpeakerVoiceprintSuggestion]

    /// Creates the profile or adds a sample. Refuses short clusters, and asks
    /// rather than merges when the name is taken by a voice that differs.
    func enroll(
        displayName: String,
        observation: SpeakerClusterObservation,
        transcriptionId: UUID,
        allowMergeIntoExistingName: Bool
    ) async throws -> SpeakerProfileEnrollment

    /// Records acceptance and, once two manual enrollments anchor the profile,
    /// lets it learn. The label is written by the correction layer, not here.
    func confirm(
        _ suggestion: SpeakerVoiceprintSuggestion,
        observation: SpeakerClusterObservation,
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint
    ) async throws

    /// Not offered again for this version of the transcript.
    func dismiss(
        _ suggestion: SpeakerVoiceprintSuggestion,
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint
    ) async throws
}

/// Owns enrolled voices: scoring, enrolling, and recording what the user chose.
///
/// A `final class` like its neighbour `SpeakerCorrectionService`, not an actor:
/// GRDB already serializes through the database queue.
public final class SpeakerVoiceprintService: SpeakerVoiceprintServicing, @unchecked Sendable {
    private let profiles: SpeakerProfileRepositoryProtocol
    private let journal: SpeakerMatchJournalRepositoryProtocol
    private let policy: SpeakerMatchPolicy
    /// Read per call, so turning the preference off takes effect immediately.
    private let isEnabled: @Sendable () -> Bool
    private let now: @Sendable () -> Date

    public init(
        profiles: SpeakerProfileRepositoryProtocol,
        journal: SpeakerMatchJournalRepositoryProtocol,
        policy: SpeakerMatchPolicy = .v1,
        isEnabled: @escaping @Sendable () -> Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.profiles = profiles
        self.journal = journal
        self.policy = policy
        self.isEnabled = isEnabled
        self.now = now
    }

    // MARK: Matching

    /// Suggestions only; nothing is applied. When off, reads nothing and writes
    /// nothing, so no voiceprint work happens behind a user who never opted in.
    public func evaluate(
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint,
        clusters: [SpeakerClusterObservation]
    ) async throws -> [SpeakerVoiceprintSuggestion] {
        guard isEnabled(), !clusters.isEmpty else { return [] }

        let candidates = try candidates()
        guard !candidates.isEmpty else { return [] }

        let dismissed = try Set(
            profiles.links(transcriptionId: transcriptionId, fingerprint: fingerprint.rawValue)
                .filter { $0.status == .dismissed }
                .map(\.speakerId)
        )
        let scored = clusters.filter { !dismissed.contains($0.speakerId) }
        guard !scored.isEmpty else { return [] }

        let decisions = SpeakerVoiceprintMatcher.decisions(
            clusters: scored,
            profiles: candidates,
            policy: policy
        )

        try record(decisions, transcriptionId: transcriptionId, fingerprint: fingerprint)
        return decisions.compactMap(\.suggestion)
    }

    // MARK: Enrollment

    /// The pollution guard lives here, not in the matcher: naming a speaker is
    /// a user action that bypasses every threshold, so two colleagues called
    /// Sarah, or one misclick, would fuse two voices with no way back.
    public func enroll(
        displayName: String,
        observation: SpeakerClusterObservation,
        transcriptionId: UUID,
        allowMergeIntoExistingName: Bool
    ) async throws -> SpeakerProfileEnrollment {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard observation.speechSeconds >= policy.minSpeechSecondsToEnroll else {
            return .rejectedTooShort(speechSeconds: observation.speechSeconds)
        }

        guard var existing = try profiles.profile(named: name) else {
            let profile = SpeakerProfile(
                displayName: name,
                identity: observation.embedding.identity,
                createdAt: now(),
                updatedAt: now()
            )
            try profiles.save(profile)
            try addExemplar(
                to: profile,
                observation: observation,
                origin: .manualEnrollment,
                transcriptionId: transcriptionId
            )
            return .created(profile)
        }

        let references = try references(for: existing.id)
        if !allowMergeIntoExistingName, !references.isEmpty {
            let candidate = SpeakerProfileCandidate(
                profileId: existing.id,
                displayName: existing.displayName,
                references: references
            )
            // A nil distance means the models are incomparable, which is less
            // evidence than a far one, not more: treat it as a mismatch rather
            // than letting it fall through into a silent merge.
            let distance = SpeakerVoiceprintMatcher.distance(
                from: observation, to: candidate, policy: policy
            )
            if distance ?? .infinity > policy.pollutionGuardDistance {
                return .needsDisambiguation(existing: existing, distance: distance ?? 1)
            }
        }

        let sampled = try profiles.exemplars(profileId: existing.id)
            .contains { $0.sourceTranscriptionId == transcriptionId }
        guard !sampled else { return .alreadySampled(existing) }

        try addExemplar(
            to: existing,
            observation: observation,
            origin: .manualEnrollment,
            transcriptionId: transcriptionId
        )
        existing.updatedAt = now()
        try profiles.save(existing)
        return .addedExemplar(existing)
    }

    // MARK: Decisions

    /// The label is not written here — that goes through
    /// `SpeakerCorrectionService`, inheriting undo and provenance. The caller
    /// renames first, so a crash between the two leaves a correct name and a
    /// profile that did not learn, rather than a poisoned profile.
    public func confirm(
        _ suggestion: SpeakerVoiceprintSuggestion,
        observation: SpeakerClusterObservation,
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint
    ) async throws {
        guard var profile = try profiles.profile(id: suggestion.profileId) else { return }

        try profiles.save(
            SpeakerProfileLink(
                transcriptionId: transcriptionId,
                speakerId: suggestion.speakerId,
                transcriptFingerprint: fingerprint.rawValue,
                profileId: suggestion.profileId,
                status: .confirmed,
                distance: suggestion.distance,
                runnerUpDistance: suggestion.runnerUpDistance,
                createdAt: now(),
                updatedAt: now()
            )
        )

        // A profile born of one enrollment cannot amplify itself on its own
        // suggestion: two manual enrollments must anchor the voice first.
        let exemplars = try profiles.exemplars(profileId: profile.id)
        let manualCount = exemplars.filter { $0.origin == .manualEnrollment }.count
        let alreadySampled = exemplars.contains { $0.sourceTranscriptionId == transcriptionId }

        if manualCount >= 2, !alreadySampled {
            try addExemplar(
                to: profile,
                observation: observation,
                origin: .confirmedSuggestion,
                transcriptionId: transcriptionId
            )
        }

        profile.lastMatchedAt = now()
        profile.updatedAt = now()
        try profiles.save(profile)
    }

    public func dismiss(
        _ suggestion: SpeakerVoiceprintSuggestion,
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint
    ) async throws {
        try profiles.save(
            SpeakerProfileLink(
                transcriptionId: transcriptionId,
                speakerId: suggestion.speakerId,
                transcriptFingerprint: fingerprint.rawValue,
                profileId: suggestion.profileId,
                status: .dismissed,
                distance: suggestion.distance,
                runnerUpDistance: suggestion.runnerUpDistance,
                createdAt: now(),
                updatedAt: now()
            )
        )
    }

    // MARK: Internals

    private func candidates() throws -> [SpeakerProfileCandidate] {
        let stored = try profiles.profiles()
        guard !stored.isEmpty else { return [] }

        let exemplars = try profiles.exemplarsByProfile()
        return stored.compactMap { profile in
            let references = (exemplars[profile.id] ?? [])
                .sorted { $0.createdAt > $1.createdAt }
                .compactMap(reference(from:))
            guard !references.isEmpty else { return nil }
            return SpeakerProfileCandidate(
                profileId: profile.id,
                displayName: profile.displayName,
                references: references
            )
        }
    }

    /// Newest first: the matcher scores only the first `maxReferencesPerProfile`,
    /// and the repository returns exemplars oldest first, so passing them
    /// straight through would hide every sample added after the cap was reached
    /// — the ones most likely to share the current aggregation identity.
    private func references(for profileId: UUID) throws -> [SpeakerProfileCandidate.Reference] {
        try profiles.exemplars(profileId: profileId)
            .sorted { $0.createdAt > $1.createdAt }
            .compactMap(reference(from:))
    }

    private func reference(
        from exemplar: SpeakerProfileExemplar
    ) -> SpeakerProfileCandidate.Reference? {
        guard let embedding = exemplar.embedding else { return nil }
        return SpeakerProfileCandidate.Reference(
            embedding: embedding,
            captureDomain: exemplar.captureDomain
        )
    }

    private func addExemplar(
        to profile: SpeakerProfile,
        observation: SpeakerClusterObservation,
        origin: SpeakerProfileExemplar.Origin,
        transcriptionId: UUID?
    ) throws {
        try profiles.insert(
            SpeakerProfileExemplar(
                profileId: profile.id,
                embedding: observation.embedding,
                speechSeconds: observation.speechSeconds,
                captureDomain: observation.captureDomain,
                origin: origin,
                sourceTranscriptionId: transcriptionId,
                sourceSpeakerId: observation.speakerId,
                createdAt: now()
            )
        )
    }

    /// Pending links for suggestions, and every decision to the local journal.
    private func record(
        _ decisions: [SpeakerMatchDecision],
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint
    ) throws {
        for decision in decisions {
            guard let suggestion = decision.suggestion else { continue }
            try profiles.save(
                SpeakerProfileLink(
                    transcriptionId: transcriptionId,
                    speakerId: suggestion.speakerId,
                    transcriptFingerprint: fingerprint.rawValue,
                    profileId: suggestion.profileId,
                    status: .suggested,
                    distance: suggestion.distance,
                    runnerUpDistance: suggestion.runnerUpDistance,
                    createdAt: now(),
                    updatedAt: now()
                )
            )
        }

        // Scored is not matched: this is what tells "never recognized" apart
        // from "recognized and wrong".
        var evaluated: [UUID: (date: Date, distance: Double)] = [:]
        for decision in decisions {
            guard let profileId = decision.profileId, let distance = decision.distance else { continue }
            if let current = evaluated[profileId], current.distance <= distance { continue }
            evaluated[profileId] = (now(), distance)
        }
        for (profileId, evaluation) in evaluated {
            guard var profile = try profiles.profile(id: profileId) else { continue }
            profile.lastEvaluatedAt = evaluation.date
            profile.lastEvaluatedDistance = evaluation.distance
            try profiles.save(profile)
        }

        try journal.append(
            decisions.map { decision in
                SpeakerMatchJournalEntry(
                    transcriptionId: transcriptionId,
                    speakerId: decision.speakerId,
                    transcriptFingerprint: fingerprint.rawValue,
                    profileId: decision.profileId,
                    outcome: decision.outcome,
                    topDistance: decision.distance,
                    runnerUpDistance: decision.runnerUpDistance,
                    speechSeconds: decision.speechSeconds,
                    createdAt: now()
                )
            },
            retention: SpeakerMatchJournalRepository.defaultRetention,
            now: now()
        )
    }
}
