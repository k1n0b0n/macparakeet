import Foundation

/// What happened when the user asked to remember a voice.
public enum SpeakerProfileEnrollment: Sendable, Equatable {
    case created(SpeakerProfile)
    /// The name was blank once trimmed. It would have no lookup key, so the
    /// profile could never be found again nor collide with a second blank one.
    case rejectedEmptyName
    case addedExemplar(SpeakerProfile)
    /// The name is taken by a profile whose voice does not match. Merging would
    /// fuse two people, so the caller must ask.
    case needsDisambiguation(existing: SpeakerProfile, distance: Double)
    case rejectedTooShort(speechSeconds: Double)
    /// The profile already holds a sample from this recording.
    case alreadySampled(SpeakerProfile)
    /// The profile is at its sample cap and every sample is a manual
    /// enrollment, so there is nothing to evict without weakening the anchor
    /// that lets it learn.
    case rejectedProfileFull(SpeakerProfile)
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

        // Both terminal statuses are excluded, not just refusals: rescoring a
        // confirmed speaker would write a fresh suggestion over the answer the
        // user already gave, and the store now refuses that outright.
        let decided = try Set(
            profiles.links(transcriptionId: transcriptionId, fingerprint: fingerprint.rawValue)
                .filter { $0.status != .suggested }
                .map(\.speakerId)
        )
        let scored = clusters.filter { !decided.contains($0.speakerId) }
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
        guard !SpeakerProfile.normalizedName(for: name).isEmpty else {
            return .rejectedEmptyName
        }
        guard observation.speechSeconds >= policy.minSpeechSecondsToEnroll else {
            return .rejectedTooShort(speechSeconds: observation.speechSeconds)
        }

        if let existing = try profiles.profile(named: name) {
            return try sample(
                existing,
                observation: observation,
                transcriptionId: transcriptionId,
                allowMergeIntoExistingName: allowMergeIntoExistingName
            )
        }

        let profile = SpeakerProfile(
            displayName: name,
            identity: observation.embedding.identity,
            createdAt: now(),
            updatedAt: now()
        )
        do {
            try profiles.insert(profile)
        } catch SpeakerProfileStoreError.nameAlreadyTaken {
            // Another enrollment claimed the name between the lookup and the
            // insert. The user asked for a name, not for a row, so the second
            // one samples the winner instead of failing.
            guard let winner = try profiles.profile(named: name) else {
                throw SpeakerProfileStoreError.nameAlreadyTaken(
                    normalizedName: SpeakerProfile.normalizedName(for: name)
                )
            }
            return try sample(
                winner,
                observation: observation,
                transcriptionId: transcriptionId,
                allowMergeIntoExistingName: allowMergeIntoExistingName
            )
        }

        _ = try addExemplar(
            to: profile,
            observation: observation,
            origin: .manualEnrollment,
            transcriptionId: transcriptionId
        )
        return .created(profile)
    }

    /// Adds this voice to a profile that already exists, which is where the
    /// pollution guard applies: the name is a claim about identity that no
    /// threshold has checked.
    private func sample(
        _ profile: SpeakerProfile,
        observation: SpeakerClusterObservation,
        transcriptionId: UUID,
        allowMergeIntoExistingName: Bool
    ) throws -> SpeakerProfileEnrollment {
        var profile = profile
        // Checked before the pollution guard and regardless of the override:
        // the store refuses samples from another embedding model, and a forced
        // merge is the caller overriding a judgement about *which person* this
        // is, not about whether the two vectors can be compared at all.
        guard profile.embeddingModelId == observation.embedding.identity.embeddingModelId else {
            return .needsDisambiguation(existing: profile, distance: 1)
        }

        let references = try references(for: profile.id)
        if !allowMergeIntoExistingName, !references.isEmpty {
            let candidate = SpeakerProfileCandidate(
                profileId: profile.id,
                displayName: profile.displayName,
                references: references
            )
            // A nil distance is less evidence than a far one, not more: treat
            // it as a mismatch rather than a silent merge.
            let distance = SpeakerVoiceprintMatcher.distance(
                from: observation, to: candidate, policy: policy
            )
            if distance ?? .infinity > policy.pollutionGuardDistance {
                return .needsDisambiguation(existing: profile, distance: distance ?? 1)
            }
        }

        switch try addExemplar(
            to: profile,
            observation: observation,
            origin: .manualEnrollment,
            transcriptionId: transcriptionId
        ) {
        case .rejectedProfileFull:
            return .rejectedProfileFull(profile)
        case .rejectedAlreadySampled:
            return .alreadySampled(profile)
        case .inserted, .insertedEvicting:
            profile.updatedAt = now()
            try profiles.save(profile)
            return .addedExemplar(profile)
        }
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
        // suggestion: two manual enrollments must anchor the voice first. The
        // one-sample-per-recording rule is the store's, so no check here.
        let exemplars = try profiles.exemplars(profileId: profile.id)
        if exemplars.filter({ $0.origin == .manualEnrollment }).count >= 2 {
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

    /// Adds a sample under the cap, in the store's transaction.
    ///
    /// The cap bounds storage, not just scoring: keeping vectors the matcher
    /// will never reach would accumulate biometric data for nothing. Eviction
    /// spares manual enrollments because `confirm` counts them to decide
    /// whether a profile may learn at all — evicting them oldest-first would
    /// drop a mature profile back below that anchor for no visible reason.
    @discardableResult
    private func addExemplar(
        to profile: SpeakerProfile,
        observation: SpeakerClusterObservation,
        origin: SpeakerProfileExemplar.Origin,
        transcriptionId: UUID?
    ) throws -> SpeakerExemplarInsertion {
        try profiles.insertExemplar(
            SpeakerProfileExemplar(
                profileId: profile.id,
                embedding: observation.embedding,
                speechSeconds: observation.speechSeconds,
                captureDomain: observation.captureDomain,
                origin: origin,
                sourceTranscriptionId: transcriptionId,
                sourceSpeakerId: observation.speakerId,
                createdAt: now()
            ),
            maxPerProfile: policy.maxReferencesPerProfile,
            evicting: .confirmedSuggestion
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
