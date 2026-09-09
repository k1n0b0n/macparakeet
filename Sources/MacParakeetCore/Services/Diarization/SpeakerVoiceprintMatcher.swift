import Foundation

/// One detected speaker in one recording, as offered to the matcher.
public struct SpeakerClusterObservation: Sendable, Equatable {
    /// The diarizer's id for this run ("S1", "system:S1"). Positional.
    public let speakerId: String
    public let embedding: SpeakerEmbedding
    public let speechSeconds: Double
    public let captureDomain: SpeakerCaptureDomain

    /// - Parameter speechSeconds: total clean speech for this cluster; the
    ///   duration gates read it, and a short cluster is never scored.
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
    /// One stored sample of the voice, with the domain it was captured in.
    public struct Reference: Sendable, Equatable {
        public let embedding: SpeakerEmbedding
        public let captureDomain: SpeakerCaptureDomain

        /// - Parameter captureDomain: preferred when two references are
        ///   equally close, since the same voice sits elsewhere in the space
        ///   over a compressed stream than over a local microphone.
        public init(embedding: SpeakerEmbedding, captureDomain: SpeakerCaptureDomain) {
            self.embedding = embedding
            self.captureDomain = captureDomain
        }
    }

    public let profileId: UUID
    public let displayName: String
    public let references: [Reference]

    /// - Parameter references: scored as a set, closest wins; a profile with
    ///   none is skipped rather than treated as distant.
    public init(profileId: UUID, displayName: String, references: [Reference]) {
        self.profileId = profileId
        self.displayName = displayName
        self.references = references
    }
}

/// Thresholds and gates. Injected rather than hard-coded so calibration changes
/// one value and nothing else, and so tests state their own.
public struct SpeakerMatchPolicy: Sendable, Equatable {
    /// Accept only below this cosine distance.
    public let tau: Double
    /// Required separation from the runner-up, on both sides.
    public let margin: Double
    /// A cluster below this much speech is never scored.
    public let minSpeechSecondsToMatch: Double
    /// A cluster below this much speech may match but never enroll.
    public let minSpeechSecondsToEnroll: Double
    public let maxReferencesPerProfile: Int
    /// Tightening applied when the reference was aggregated under a different
    /// clustering configuration.
    public let crossAggregationPenalty: Double
    /// Above this, a name-based enrollment is treated as a different person
    /// rather than merged into the existing profile.
    public let pollutionGuardDistance: Double

    /// Use ``v1`` unless a test or a calibration run needs its own values.
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
        self.maxReferencesPerProfile = maxReferencesPerProfile
        self.crossAggregationPenalty = crossAggregationPenalty
        self.pollutionGuardDistance = pollutionGuardDistance
    }

    /// Shipping values.
    ///
    /// `tau` sits at the bottom of the zero-false-positive plateau measured in
    /// the Phase 0b calibration (0.25 to 0.45, worst true pair at 0.227) rather
    /// than mid-plateau: a missed suggestion is a non-event, a false one is the
    /// worst documented outcome, and the plateau was measured on clean audio
    /// that real meeting captures will not match.
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
    /// Next-best distance on either side, whichever is closer — what the
    /// decision had to beat. `nil` when there was no second candidate at all.
    public let runnerUpDistance: Double?

    /// - Parameter runnerUpDistance: what this decision had to beat, or `nil`
    ///   when there was no second candidate on either side.
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

/// Decides which enrolled voices to propose for the speakers of one recording.
///
/// Stateless and I/O-free on purpose: this is where the feature can be wrong
/// about a person, so it must be testable on fixtures alone.
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
            // from, so its margin is vacuously satisfied. Failing it instead
            // would make the very first enrolled voice unsuggestable, which is
            // precisely when the feature is supposed to earn its keep.
            if let runnerUp = best.runnerUp, runnerUp - best.distance < policy.margin { continue }
            if let runnerUp = bestForProfile.runnerUp, runnerUp - best.distance < policy.margin { continue }

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

    /// The closest reference of a profile, and whether it was aggregated the
    /// same way as the cluster.
    public struct ReferenceMatch: Sendable, Equatable {
        public let distance: Double
        /// Whether the *winning* reference shares the cluster's aggregation
        /// profile. Carried alongside the distance rather than derived later,
        /// because the two must describe the same reference: a profile holding
        /// both pre- and post-upgrade exemplars would otherwise be scored on an
        /// old reference while being trusted as if it were current.
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

    /// The threshold for one pair. A reference aggregated under a different
    /// clustering configuration is still comparable — Phase 0b leaves a 0.24
    /// gap between the worst true pair and the best impostor, and configuration
    /// drift costs hundredths — but it is trusted less.
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
    /// a zero margin, which the caller rejects — no tie-break by index or
    /// insertion order, because an arbitrary winner is exactly the wrong
    /// automatic name the design forbids.
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
