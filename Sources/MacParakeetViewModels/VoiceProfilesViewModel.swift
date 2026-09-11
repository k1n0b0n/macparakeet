import Foundation
import MacParakeetCore
import Observation

/// Backs the Voice Profiles sheet: what is stored, why one may never match, and
/// every way to remove it.
///
/// Deliberately usable with the feature switched off. Someone who turns
/// "Remember speakers" back off still owns the voices already stored, and this
/// is the only surface that can show or delete them.
@MainActor
@Observable
public final class VoiceProfilesViewModel {
    public private(set) var voices: [EnrolledVoice] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    /// Samples for the rows the user has expanded, loaded on demand — a profile
    /// holds at most ten, but there is no reason to read every profile's.
    public private(set) var samplesByProfile: [UUID: [SpeakerProfileExemplar]] = [:]
    public var expandedProfileIDs: Set<UUID> = []
    public var selectedProfileIDs: Set<UUID> = []

    private let service: SpeakerVoiceprintServicing?

    public init(service: SpeakerVoiceprintServicing? = nil) {
        self.service = service
    }

    public var isEmpty: Bool { !isLoading && voices.isEmpty }

    public func load() async {
        guard let service else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            voices = try await service.enrolledVoices()
            // Drop expansion and selection for rows that no longer exist, so a
            // deletion elsewhere cannot leave a stale id selected.
            let live = Set(voices.map(\.id))
            expandedProfileIDs.formIntersection(live)
            selectedProfileIDs.formIntersection(live)
            samplesByProfile = samplesByProfile.filter { live.contains($0.key) }
        } catch {
            errorMessage = "Could not read the stored voices."
        }
    }

    public func toggleExpansion(_ profileId: UUID) async {
        if expandedProfileIDs.contains(profileId) {
            expandedProfileIDs.remove(profileId)
            return
        }
        expandedProfileIDs.insert(profileId)
        await loadSamples(profileId)
    }

    private func loadSamples(_ profileId: UUID) async {
        guard let service, samplesByProfile[profileId] == nil else { return }
        do {
            samplesByProfile[profileId] = try await service.samples(profileId: profileId)
        } catch {
            errorMessage = "Could not read this voice's samples."
        }
    }

    public func rename(_ profileId: UUID, to displayName: String) async {
        guard let service else { return }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try await service.renameProfile(id: profileId, to: name)
            await load()
        } catch SpeakerProfileStoreError.nameAlreadyTaken {
            errorMessage = "Another voice is already named \(name)."
        } catch {
            errorMessage = "Could not rename this voice."
        }
    }

    /// `false` when this was the last sample: the store refuses it, because a
    /// profile with none is named and can never match.
    @discardableResult
    public func deleteSample(id: UUID, profileId: UUID) async -> Bool {
        guard let service else { return false }
        do {
            let deleted = try await service.deleteSample(id: id, profileId: profileId)
            guard deleted else { return false }
            samplesByProfile[profileId] = nil
            await loadSamples(profileId)
            await load()
            return true
        } catch {
            errorMessage = "Could not delete this sample."
            return false
        }
    }

    public func forget(_ profileId: UUID) async {
        guard let service else { return }
        do {
            try await service.forgetVoice(profileId: profileId)
            await load()
        } catch {
            errorMessage = "Could not forget this voice."
        }
    }

    public func forgetSelected() async {
        guard let service else { return }
        do {
            for profileId in selectedProfileIDs {
                try await service.forgetVoice(profileId: profileId)
            }
            selectedProfileIDs.removeAll()
            await load()
        } catch {
            // Some may already be gone; reload so the list shows what is true
            // rather than what was attempted.
            errorMessage = "Could not forget every selected voice."
            await load()
        }
    }

    public func forgetAll() async {
        guard let service else { return }
        do {
            try await service.forgetAllVoices()
            await load()
        } catch {
            errorMessage = "Could not forget the stored voices."
        }
    }

    public func clearError() {
        errorMessage = nil
    }

    /// Plain-language state for one row, so the view does not decide what
    /// "never recognized" means.
    public func statusDetail(for voice: EnrolledVoice) -> String {
        if voice.usesRetiredModel {
            return
                "Saved with an older voice model, so it can no longer be matched. Remove it and name this speaker again in a recent meeting."
        }
        if let matchedAt = voice.profile.lastMatchedAt {
            return "Last recognized \(matchedAt.formatted(date: .abbreviated, time: .shortened))."
        }
        if let distance = voice.lastEvaluatedDistance {
            return String(
                format:
                    "Never recognized. Closest match so far was %.2f, and %.2f or lower is needed.",
                distance,
                voice.acceptanceThreshold
            )
        }
        return "Never compared against a recording yet."
    }
}
