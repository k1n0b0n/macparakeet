import ArgumentParser
import Foundation
import MacParakeetCore

/// `macparakeet-cli speaker-consolidation-sim <audio>` — re-run the shipping
/// meeting diarization on an audio file and report what an embedding-based
/// consolidation pass would do to the clusters it produces.
///
/// Dev/agent tool for issue #944 (one speaker split across several clusters).
/// It surfaces what the pipeline currently discards: per-cluster turn shape,
/// the full pairwise centroid distance matrix, and the grouping an
/// agglomerative pass would produce at a given threshold. Read-only — it
/// touches neither the database nor the meeting artifacts.
struct SpeakerConsolidationSimCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speaker-consolidation-sim",
        abstract: "Diarize an audio file and report cluster stats, centroid distances, and the consolidation grouping.",
        // Internal #944 diagnostic, deliberately absent from `spec --json` and
        // from `--help`, like `meeting-vad-sim`. Still invokable by name.
        shouldDisplay: false
    )

    @Argument(help: "Path to an audio file (wav/m4a/mp3/caf/aiff). For a meeting, use its system-raw.m4a.")
    var audioPath: String

    @Option(name: .long, help: "Merge threshold on cosine distance. Default: the shipping SpeakerMatchPolicy.v1 tau.")
    var tau: Double = SpeakerMatchPolicy.v1.tau

    @Option(name: .long, help: "Linkage: single | average. Default: single.")
    var linkage: String = "single"

    @Option(name: .long, help: "Report clusters under this many seconds of speech as noise. Default: 3.")
    var minSpeech: Double = 3

    @Option(name: .long, help: "Speaker count hint; omit for the unconstrained path the app uses without a calendar.")
    var speakers: Int?

    @Option(name: .long, help: "Second audio track (usually microphone-raw.m4a) whose dominant voice each group is tested against.")
    var compare: String?

    @Option(name: .long, help: "Start offset of the comparison track relative to this one, from meeting-recording-metadata.json. Default: 0.")
    var compareOffsetMs: Int = 0

    @Option(name: .long, help: "Write each group's speech spans, in milliseconds, as JSON to this path.")
    var dumpSpans: String?

    @Option(name: .long, help: "Share of a group's speech that must coincide with the comparison voice to call it bleed. Default: 0.8.")
    var bleedOverlap: Double = 0.8

    @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
    var json: Bool = false

    func run() async throws {
        try await emitJSONOrRethrow(json: json) {
            try await self.simulate()
        }
    }

    // Split out of `run` deliberately: inlined in the `emitJSONOrRethrow`
    // closure, this body defeats the type checker.
    private func simulate() async throws {
        let url = URL(fileURLWithPath: (audioPath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("No such audio file: \(url.path)")
        }
        guard let mode = Linkage(rawValue: linkage) else {
            throw ValidationError("Unknown linkage '\(linkage)'. Use single or average.")
        }

        let constraint: SpeakerDiarizationConstraint? = speakers.map { .exact($0) }
        let service = DiarizationService()
        let progress: (@Sendable (String) -> Void)?
        if json {
            progress = nil
        } else {
            progress = { message in print("  \(message)") }
            print("preparing speaker models…")
        }
        try await service.prepareModels(onProgress: progress)

        let started = Date()
        let result = try await service.diarize(audioURL: url, speakerConstraint: constraint)
        let elapsed = Date().timeIntervalSince(started)

        let clusters = Self.clusterStats(from: result)
        let groups = Self.consolidate(
            clusters: clusters,
            embeddings: result.speakerEmbeddings,
            tau: tau,
            linkage: mode
        )

        var echoRows: [SelfEchoRow] = []
        var echoReference: String?
        if let compare {
            let outcome = try await selfEcho(
                groups: groups,
                embeddings: result.speakerEmbeddings,
                segments: result.segments,
                service: service,
                path: compare
            )
            echoRows = outcome.rows
            echoReference = outcome.reference
        }

        if json {
            try printJSON(JSONReport(
                audio: url.lastPathComponent,
                diarizationSeconds: elapsed,
                tau: tau,
                linkage: mode.rawValue,
                minSpeechSeconds: minSpeech,
                clusters: clusters.map(JSONCluster.init),
                distances: Self.distanceRows(clusters: clusters, embeddings: result.speakerEmbeddings),
                groups: groups.map { JSONGroup(members: $0.members, totalSeconds: $0.totalSeconds, isNoise: $0.totalSeconds < minSpeech) },
                selfEchoReference: echoReference,
                selfEcho: echoRows
            ))
        } else {
            printHuman(
                result: result, clusters: clusters, groups: groups,
                elapsed: elapsed, selfEcho: echoRows, reference: echoReference
            )
        }
    }

    /// Distance from each consolidated group to the dominant voice of a second
    /// track. On a meeting that is the microphone, so a system group landing
    /// inside `tau` is the user's own voice bleeding into the system capture —
    /// a speaker who does not exist. Only legible after consolidation: spread
    /// across several short clusters, none of them carries enough voice to be
    /// recognised.
    private func selfEcho(
        groups: [Group],
        embeddings: [String: SpeakerEmbedding],
        segments: [SpeakerSegment],
        service: DiarizationService,
        path: String
    ) async throws -> (rows: [SelfEchoRow], reference: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("No such comparison audio: \(url.path)")
        }
        if !json { print("diarizing comparison track…") }
        let other = try await service.diarize(audioURL: url, speakerConstraint: nil)
        let otherClusters = Self.clusterStats(from: other)
        guard let dominant = otherClusters.first,
              let reference = other.speakerEmbeddings[dominant.id] else {
            return ([], "\(url.lastPathComponent): no usable centroid")
        }

        // Voice identity survives neither the far end's codec nor its echo
        // canceller: measured on a 1:1, one speaker's bleed sits 1.07 from
        // their own clean centroid, further than a different person entirely.
        // So the bleed verdict is temporal — speech that only ever happens
        // while the other track's voice is talking is that voice leaking.
        let referenceSpans = Self.mergedSpans(
            segments: other.segments.filter { $0.speakerId == dominant.id },
            offsetMs: compareOffsetMs
        )

        var spansByGroup: [String: [[Int]]] = [:]
        let rows = groups.map { group -> SelfEchoRow in
            let distance = group.members
                .compactMap { member -> Double? in
                    guard let x = embeddings[member] else { return nil }
                    return x.cosineDistance(to: reference)
                }
                .min()
            let owned = Set(group.members)
            let groupSpans = Self.mergedSpans(
                segments: segments.filter { owned.contains($0.speakerId) },
                offsetMs: 0
            )
            spansByGroup[group.members.joined(separator: "+")] = groupSpans.map { [$0.0, $0.1] }
            let overlap = Self.overlapRatio(groupSpans, against: referenceSpans)
            let verdict = overlap >= bleedOverlap ? "BLEED" : "distinct speaker"
            return SelfEchoRow(
                members: group.members,
                totalSeconds: group.totalSeconds,
                distance: distance,
                overlapRatio: overlap,
                verdict: verdict
            )
        }

        let label = String(
            format: "%@ / %@ (%.0fs of speech)",
            url.lastPathComponent, dominant.id, dominant.totalSeconds
        )
        if let dumpSpans {
            spansByGroup["__reference__"] = referenceSpans.map { [$0.0, $0.1] }
            try JSONEncoder().encode(spansByGroup).write(to: URL(fileURLWithPath: dumpSpans))
        }
        return (rows, label)
    }

    struct SelfEchoRow: Encodable {
        let members: [String]
        let totalSeconds: Double
        let distance: Double?
        let overlapRatio: Double
        let verdict: String
    }

    /// Sorted, non-overlapping spans in milliseconds.
    static func mergedSpans(segments: [SpeakerSegment], offsetMs: Int) -> [(Int, Int)] {
        let sorted = segments
            .map { ($0.startMs + offsetMs, $0.endMs + offsetMs) }
            .sorted { $0.0 < $1.0 }
        var merged: [(Int, Int)] = []
        for span in sorted {
            if let last = merged.last, span.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, span.1)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// Share of `spans` that falls inside `reference`.
    static func overlapRatio(_ spans: [(Int, Int)], against reference: [(Int, Int)]) -> Double {
        let total = spans.reduce(0) { $0 + max(0, $1.1 - $1.0) }
        guard total > 0 else { return 0 }
        var covered = 0
        var index = 0
        for span in spans {
            while index < reference.count, reference[index].1 <= span.0 { index += 1 }
            var probe = index
            while probe < reference.count, reference[probe].0 < span.1 {
                covered += max(0, min(span.1, reference[probe].1) - max(span.0, reference[probe].0))
                probe += 1
            }
        }
        return Double(covered) / Double(total)
    }

    // MARK: - Analysis

    enum Linkage: String {
        case single
        case average
    }

    struct ClusterStats {
        let id: String
        let segmentCount: Int
        let totalSeconds: Double
        let maxTurnSeconds: Double
        let hasEmbedding: Bool

        var averageTurnSeconds: Double {
            segmentCount > 0 ? totalSeconds / Double(segmentCount) : 0
        }
    }

    /// Segments here are the diarizer's own turns, not the word-grouped runs the
    /// app persists in `diarizationSegments`, so counts differ from what a query
    /// against the database reports for the same meeting.
    static func clusterStats(from result: MacParakeetDiarizationResult) -> [ClusterStats] {
        var durations: [String: [Double]] = [:]
        for segment in result.segments {
            let seconds = Double(max(0, segment.endMs - segment.startMs)) / 1000
            durations[segment.speakerId, default: []].append(seconds)
        }
        return durations.map { id, turns in
            ClusterStats(
                id: id,
                segmentCount: turns.count,
                totalSeconds: turns.reduce(0, +),
                maxTurnSeconds: turns.max() ?? 0,
                hasEmbedding: result.speakerEmbeddings[id] != nil
            )
        }
        .sorted { $0.totalSeconds > $1.totalSeconds }
    }

    struct Group {
        var members: [String]
        var totalSeconds: Double
    }

    /// Agglomerative merge over every cluster, not short-into-long: the
    /// measured failure mode is one speaker shattered into several short
    /// clusters that are near each other and far from everyone else, which a
    /// short-into-long pass cannot see.
    static func consolidate(
        clusters: [ClusterStats],
        embeddings: [String: SpeakerEmbedding],
        tau: Double,
        linkage: Linkage
    ) -> [Group] {
        var groups = clusters.map { Group(members: [$0.id], totalSeconds: $0.totalSeconds) }

        while true {
            var best: (Int, Int, Double)?
            for i in groups.indices {
                for j in groups.indices where j > i {
                    guard let distance = groupDistance(
                        groups[i], groups[j], embeddings: embeddings, linkage: linkage
                    ) else { continue }
                    if distance <= tau, distance < (best?.2 ?? .infinity) {
                        best = (i, j, distance)
                    }
                }
            }
            guard let (i, j, _) = best else { break }
            groups[i].members.append(contentsOf: groups[j].members)
            groups[i].totalSeconds += groups[j].totalSeconds
            groups.remove(at: j)
        }

        return groups.sorted { $0.totalSeconds > $1.totalSeconds }
    }

    static func groupDistance(
        _ a: Group,
        _ b: Group,
        embeddings: [String: SpeakerEmbedding],
        linkage: Linkage
    ) -> Double? {
        var distances: [Double] = []
        for left in a.members {
            for right in b.members {
                guard let x = embeddings[left], let y = embeddings[right],
                      let distance = x.cosineDistance(to: y) else { continue }
                distances.append(distance)
            }
        }
        guard !distances.isEmpty else { return nil }
        switch linkage {
        case .single:
            return distances.min()
        case .average:
            return distances.reduce(0, +) / Double(distances.count)
        }
    }

    static func distanceRows(
        clusters: [ClusterStats],
        embeddings: [String: SpeakerEmbedding]
    ) -> [JSONDistanceRow] {
        clusters.map { row in
            var cells: [String: Double] = [:]
            for column in clusters where column.id != row.id {
                guard let a = embeddings[row.id], let b = embeddings[column.id],
                      let distance = a.cosineDistance(to: b) else { continue }
                cells[column.id] = distance
            }
            return JSONDistanceRow(id: row.id, distances: cells)
        }
    }

    /// The widest merge actually used against the narrowest pair left unmerged:
    /// the empty band between them says whether `tau` sits on a real gap or on
    /// a value fitted to this one recording.
    static func separation(
        groups: [Group],
        embeddings: [String: SpeakerEmbedding],
        linkage: Linkage
    ) -> (widestMerge: Double?, closestKept: Double?) {
        var widestMerge: Double?
        for group in groups where group.members.count > 1 {
            for left in group.members {
                for right in group.members where right != left {
                    guard let x = embeddings[left], let y = embeddings[right],
                          let distance = x.cosineDistance(to: y) else { continue }
                    // Single linkage merges on the nearest pair, so the band
                    // starts at the largest nearest-neighbour hop in the chain.
                    let nearestInGroup = group.members
                        .filter { $0 != left }
                        .compactMap { other -> Double? in
                            guard let z = embeddings[other] else { return nil }
                            return x.cosineDistance(to: z)
                        }
                        .min()
                    _ = distance
                    if let nearestInGroup, nearestInGroup > (widestMerge ?? 0) {
                        widestMerge = nearestInGroup
                    }
                }
            }
        }

        var closestKept: Double?
        for i in groups.indices {
            for j in groups.indices where j > i {
                guard let distance = groupDistance(
                    groups[i], groups[j], embeddings: embeddings, linkage: linkage
                ) else { continue }
                if distance < (closestKept ?? .infinity) { closestKept = distance }
            }
        }
        return (widestMerge, closestKept)
    }

    // MARK: - Human output

    private func printHuman(
        result: MacParakeetDiarizationResult,
        clusters: [ClusterStats],
        groups: [Group],
        elapsed: TimeInterval,
        selfEcho: [SelfEchoRow],
        reference: String?
    ) {
        print("")
        print(String(format: "diarized in %.1fs — %d clusters, tau=%.2f linkage=%@",
                     elapsed, clusters.count, tau, linkage))
        print("")
        print("cluster    segs    total(s)   avg(s)   max turn(s)   centroid")
        print("-------    ----    --------   ------   -----------   --------")
        for cluster in clusters {
            print(String(format: "%@ %-7d %-10.1f %-8.2f %-13.1f %@",
                         cluster.id.padding(toLength: 10, withPad: " ", startingAt: 0),
                         cluster.segmentCount,
                         cluster.totalSeconds,
                         cluster.averageTurnSeconds,
                         cluster.maxTurnSeconds,
                         cluster.hasEmbedding ? "ok" : "MISSING"))
        }

        print("")
        print("pairwise centroid distance (cosine)")
        let ids = clusters.map(\.id)
        print("          " + ids.map { $0.padding(toLength: 8, withPad: " ", startingAt: 0) }.joined())
        for row in ids {
            var line = row.padding(toLength: 10, withPad: " ", startingAt: 0)
            for column in ids {
                if row == column {
                    line += "   .    "
                } else if let a = result.speakerEmbeddings[row], let b = result.speakerEmbeddings[column],
                          let distance = a.cosineDistance(to: b) {
                    line += String(format: "%-8.3f", distance)
                } else {
                    line += "  --    "
                }
            }
            print(line)
        }

        print("")
        print("consolidated speakers")
        var speaking = 0
        for group in groups {
            let noise = group.totalSeconds < minSpeech
            if !noise { speaking += 1 }
            print(String(format: "  %@ %8.1fs   %@",
                         group.members.joined(separator: "+").padding(toLength: 22, withPad: " ", startingAt: 0),
                         group.totalSeconds,
                         noise ? "(under \(String(format: "%.0f", minSpeech))s — noise)" : ""))
        }

        let (widest, closest) = Self.separation(
            groups: groups, embeddings: result.speakerEmbeddings, linkage: Linkage(rawValue: linkage) ?? .single
        )
        print("")
        print("\(clusters.count) clusters → \(groups.count) groups, \(speaking) above the noise floor")
        if let widest, let closest {
            print(String(format: "decision band: widest merge %.3f, closest pair left apart %.3f (empty width %.3f)",
                         widest, closest, closest - widest))
        }

        guard let reference, !selfEcho.isEmpty else { return }
        print("")
        print("self-echo test against \(reference)")
        for row in selfEcho {
            let distance = row.distance.map { String(format: "%.3f", $0) } ?? "--"
            print(String(format: "  %@ %8.1fs   distance=%@   coincides=%5.1f%%   %@",
                         row.members.joined(separator: "+").padding(toLength: 22, withPad: " ", startingAt: 0),
                         row.totalSeconds,
                         distance.padding(toLength: 7, withPad: " ", startingAt: 0),
                         row.overlapRatio * 100,
                         row.verdict))
        }
    }

    // MARK: - JSON output

    struct JSONCluster: Encodable {
        let id: String
        let segments: Int
        let totalSeconds: Double
        let averageTurnSeconds: Double
        let maxTurnSeconds: Double
        let hasCentroid: Bool

        init(_ stats: ClusterStats) {
            id = stats.id
            segments = stats.segmentCount
            totalSeconds = stats.totalSeconds
            averageTurnSeconds = stats.averageTurnSeconds
            maxTurnSeconds = stats.maxTurnSeconds
            hasCentroid = stats.hasEmbedding
        }
    }

    struct JSONDistanceRow: Encodable {
        let id: String
        let distances: [String: Double]
    }

    struct JSONGroup: Encodable {
        let members: [String]
        let totalSeconds: Double
        let isNoise: Bool
    }

    struct JSONReport: Encodable {
        let audio: String
        let diarizationSeconds: Double
        let tau: Double
        let linkage: String
        let minSpeechSeconds: Double
        let clusters: [JSONCluster]
        let distances: [JSONDistanceRow]
        let groups: [JSONGroup]
        let selfEchoReference: String?
        let selfEcho: [SelfEchoRow]
    }
}
