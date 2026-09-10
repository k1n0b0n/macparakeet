import Foundation

/// One detected speaker in one recording, as offered to the matcher.
public struct SpeakerClusterObservation: Sendable, Equatable {
    /// Positional id for this run ("S1", "system:S1").
    public let speakerId: String
    public let embedding: SpeakerEmbedding
    public let speechSeconds: Double
    public let captureDomain: SpeakerCaptureDomain

    public init(
        speakerId: String,
        embedding: SpeakerEmbedding,
        speechSeconds: Double,
        captureDomain: SpeakerCaptureDomain
    ) {
        self.speakerId = speakerId
        self.embedding = embedding
        self.speechSeconds = speechSeconds
        self.captureDomain = captureDomain
    }
}

/// An enrolled voice, reduced to what scoring needs.
public struct SpeakerProfileCandidate: Sendable, Equatable {
    public struct Reference: Sendable, Equatable {
        public let embedding: SpeakerEmbedding
        public let captureDomain: SpeakerCaptureDomain

        public init(embedding: SpeakerEmbedding, captureDomain: SpeakerCaptureDomain) {
            self.embedding = embedding
            self.captureDomain = captureDomain
        }
    }

    public let profileId: UUID
    public let displayName: String
    /// Most relevant first: only the first `maxReferencesPerProfile` are scored,
    /// so a caller passing oldest-first would hide its newest samples.
    public let references: [Reference]

    public init(profileId: UUID, displayName: String, references: [Reference]) {
        self.profileId = profileId
        self.displayName = displayName
        self.references = references
    }
}

/// Thresholds and gates, injected so calibration changes values and no logic.
public struct SpeakerMatchPolicy: Sendable, Equatable {
    /// Accept only below this cosine distance.
    public let tau: Double
    /// Required separation from the runner-up, on both sides.
    public let margin: Double
    public let minSpeechSecondsToMatch: Double
    /// A cluster above the match gate but below this may match, never enroll.
    public let minSpeechSecondsToEnroll: Double
    public let maxReferencesPerProfile: Int
    /// Tightening when the reference came from another clustering config.
    public let crossAggregationPenalty: Double
    /// Above this, a name-based enrollment is a different person, not a merge.
    public let pollutionGuardDistance: Double

    public init(
        tau: Double,
        margin: Double,
        minSpeechSecondsToMatch: Double,
        minSpeechSecondsToEnroll: Double,
        maxReferencesPerProfile: Int,
        crossAggregationPenalty: Double,
        pollutionGuardDistance: Double
    ) {
        self.tau = tau
        self.margin = margin
        self.minSpeechSecondsToMatch = minSpeechSecondsToMatch
        self.minSpeechSecondsToEnroll = minSpeechSecondsToEnroll
        // Clamped rather than trusted: `prefix` precondition-fails on a
        // negative length, and no configuration mistake should be able to bring
        // matching down.
        self.maxReferencesPerProfile = max(0, maxReferencesPerProfile)
        self.crossAggregationPenalty = crossAggregationPenalty
        self.pollutionGuardDistance = pollutionGuardDistance
    }

    /// `tau` sits at the bottom of the Phase 0b zero-false-positive plateau
    /// (0.25 to 0.45, worst true pair 0.227), not mid-plateau: that plateau came
    /// from clean audio, and a false suggestion costs more than a missed one.
    public static let v1 = SpeakerMatchPolicy(
        tau: 0.25,
        margin: 0.10,
        minSpeechSecondsToMatch: 3,
        minSpeechSecondsToEnroll: 15,
        maxReferencesPerProfile: 10,
        crossAggregationPenalty: 0.05,
        pollutionGuardDistance: 0.45
    )
}

/// A proposed name for a detected speaker. Never applied on its own.
public struct SpeakerVoiceprintSuggestion: Sendable, Equatable {
    public let speakerId: String
    public let profileId: UUID
    public let displayName: String
    public let distance: Double
    /// What the decision had to beat; `nil` when there was no second candidate.
    public let runnerUpDistance: Double?

    public init(
        speakerId: String,
        profileId: UUID,
        displayName: String,
        distance: Double,
        runnerUpDistance: Double?
    ) {
        self.speakerId = speakerId
        self.profileId = profileId
        self.displayName = displayName
        self.distance = distance
        self.runnerUpDistance = runnerUpDistance
    }
}

/// Decides which enrolled voices to propose for one recording's speakers.
///
/// Stateless and I/O-free on purpose: this is where the feature can be wrong
/// about a person, so it must be testable on fixtures alone.
///
/// `profileId` and `speakerId` must each be unique across the inputs. Scoring
/// works on positions and results carry ids, so duplicates would yield two
/// suggestions naming the same profile. Both callers satisfy this by
/// construction — profiles come from a primary key, clusters from one
/// diarization run.
public enum SpeakerVoiceprintMatcher {

    /// Suggestions for `clusters`, at most one per cluster and one per profile.
    ///
    /// A pair is accepted only when it is each other's best match, clears the
    /// threshold, and beats its runner-up by `margin` **on both sides**. The
    /// two-sided rule is not belt and braces: the diarizer over-splits, so one
    /// person routinely yields two clusters, and a cluster-side margin alone
    /// would let both of them claim the same profile and put two "Sarah"s in
    /// one transcript.
    public static func match(
        clusters: [SpeakerClusterObservation],
        profiles: [SpeakerProfileCandidate],
        policy: SpeakerMatchPolicy
    ) -> [SpeakerVoiceprintSuggestion] {
        let scorable = clusters.filter { $0.speechSeconds >= policy.minSpeechSecondsToMatch }
        guard !scorable.isEmpty, !profiles.isEmpty else { return [] }

        // matches[clusterIndex][profileIndex], nil when incomparable.
        let matches: [[ReferenceMatch?]] = scorable.map { cluster in
            profiles.map { profile in bestReference(from: cluster, to: profile, policy: policy) }
        }
        let distances: [[Double?]] = matches.map { $0.map(\.?.distance) }

        var suggestions: [SpeakerVoiceprintSuggestion] = []
        for (clusterIndex, cluster) in scorable.enumerated() {
            let row = distances[clusterIndex]
            guard let best = bestCandidate(in: row) else { continue }

            let column = distances.map { $0[best.index] }
            guard let bestForProfile = bestCandidate(in: column), bestForProfile.index == clusterIndex else {
                // Some other cluster is a better fit for this profile, so this
                // pairing is not mutual and nothing is proposed.
                continue
            }

            let profile = profiles[best.index]
            guard let winning = matches[clusterIndex][best.index],
                  best.distance <= effectiveTau(for: winning, policy: policy)
            else { continue }

            // A side with no second candidate has nothing to be separated
            // from, so its margin is vacuously satisfied. Failing it would make
            // the first enrolled voice unsuggestable.
            // Equality is checked before the configurable margin, which a
            // policy may set to zero: a tie would then pass
            // `runnerUp - best < 0` and position alone would decide.
            if let runnerUp = best.runnerUp,
               runnerUp == best.distance || runnerUp - best.distance < policy.margin
            { continue }
            if let runnerUp = bestForProfile.runnerUp,
               runnerUp == best.distance || runnerUp - best.distance < policy.margin
            { continue }

            suggestions.append(
                SpeakerVoiceprintSuggestion(
                    speakerId: cluster.speakerId,
                    profileId: profile.profileId,
                    displayName: profile.displayName,
                    distance: best.distance,
                    runnerUpDistance: [best.runnerUp, bestForProfile.runnerUp].compactMap { $0 }.min()
                )
            )
        }
        return suggestions
    }

    public struct ReferenceMatch: Sendable, Equatable {
        public let distance: Double
        /// Of the *winning* reference, carried alongside the distance so the
        /// two describe the same one: a profile holding both pre- and
        /// post-upgrade exemplars would otherwise be scored on an old reference
        /// while trusted as current.
        public let sameAggregation: Bool
    }

    /// Distance from a cluster to a profile: the closest reference, preferring
    /// one captured in the same domain when two are equally close. `nil` when
    /// no reference is comparable at all.
    public static func distance(
        from cluster: SpeakerClusterObservation,
        to profile: SpeakerProfileCandidate,
        policy: SpeakerMatchPolicy
    ) -> Double? {
        bestReference(from: cluster, to: profile, policy: policy)?.distance
    }

    /// As `distance`, keeping the winning reference's aggregation identity.
    public static func bestReference(
        from cluster: SpeakerClusterObservation,
        to profile: SpeakerProfileCandidate,
        policy: SpeakerMatchPolicy
    ) -> ReferenceMatch? {
        var best: (distance: Double, sameDomain: Bool, sameAggregation: Bool)?

        for reference in profile.references.prefix(policy.maxReferencesPerProfile) {
            guard let distance = cluster.embedding.cosineDistance(to: reference.embedding) else { continue }
            let sameDomain = reference.captureDomain == cluster.captureDomain
            let sameAggregation = reference.embedding.identity.aggregationProfileId
                == cluster.embedding.identity.aggregationProfileId

            guard let current = best else {
                best = (distance, sameDomain, sameAggregation)
                continue
            }
            if distance < current.distance {
                best = (distance, sameDomain, sameAggregation)
            } else if distance == current.distance, sameDomain, !current.sameDomain {
                best = (distance, sameDomain, sameAggregation)
            }
        }

        guard let best else { return nil }
        return ReferenceMatch(distance: best.distance, sameAggregation: best.sameAggregation)
    }

    /// A cross-aggregation reference stays comparable — Phase 0b leaves a 0.24
    /// gap between worst true pair and best impostor — but is trusted less.
    private static func effectiveTau(for match: ReferenceMatch, policy: SpeakerMatchPolicy) -> Double {
        match.sameAggregation ? policy.tau : policy.tau - policy.crossAggregationPenalty
    }

    private struct Candidate {
        let index: Int
        let distance: Double
        /// Second-best distance, or nil when there was only one candidate.
        let runnerUp: Double?
    }

    /// Smallest distance in `row`, with the next smallest. An exact tie leaves
    /// a zero margin, which the caller rejects: no tie-break by index or
    /// insertion order, since an arbitrary winner is a wrong automatic name.
    private static func bestCandidate(in row: [Double?]) -> Candidate? {
        var best: (index: Int, distance: Double)?
        var runnerUp: Double?

        for (index, value) in row.enumerated() {
            guard let value else { continue }
            if let current = best {
                if value < current.distance {
                    runnerUp = current.distance
                    best = (index, value)
                } else if runnerUp == nil || value < runnerUp! {
                    runnerUp = value
                }
            } else {
                best = (index, value)
            }
        }

        guard let best else { return nil }
        return Candidate(index: best.index, distance: best.distance, runnerUp: runnerUp)
    }
}
