import Foundation
import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

/// An empty store that answers every administration call, so the gate can be
/// checked against the shape production actually has: the service is wired even
/// when the flag is off.
private final class EmptyVoiceStore: SpeakerVoiceprintServicing, @unchecked Sendable {
    func evaluate(
        transcriptionId _: UUID, fingerprint _: TranscriptFingerprint,
        clusters _: [SpeakerClusterObservation]
    ) async throws -> [SpeakerVoiceprintSuggestion] { [] }
    func enrollmentCandidate(
        transcriptionId _: UUID, speakerId _: String, fingerprint _: TranscriptFingerprint
    ) async throws -> SpeakerClusterObservation? { nil }
    func pruneExpiredCandidates() async throws {}
    func enroll(
        displayName _: String, observation _: SpeakerClusterObservation,
        transcriptionId _: UUID, fingerprint _: TranscriptFingerprint,
        allowMergeIntoExistingName _: Bool
    ) async throws -> SpeakerProfileEnrollment { .rejectedEmptyName }
    func confirm(
        _: SpeakerVoiceprintSuggestion, transcriptionId _: UUID,
        fingerprint _: TranscriptFingerprint
    ) async throws {}
    func dismiss(
        _: SpeakerVoiceprintSuggestion, transcriptionId _: UUID,
        fingerprint _: TranscriptFingerprint
    ) async throws {}
    func assign(
        profileId _: UUID, toSpeakerId _: String, transcriptionId _: UUID,
        fingerprint _: TranscriptFingerprint
    ) async throws -> SpeakerManualAssignment { .unknownProfile }
    func pendingSuggestions(
        transcriptionId _: UUID, fingerprint _: TranscriptFingerprint
    ) async throws -> [SpeakerVoiceprintSuggestion] { [] }
    func confirmedVoiceHolders(
        transcriptionId _: UUID, fingerprint _: TranscriptFingerprint
    ) async throws -> [UUID: String] { [:] }
    func enrolledVoices() async throws -> [EnrolledVoice] { [] }
    func samples(profileId _: UUID) async throws -> [SpeakerProfileExemplar] { [] }
    func renameProfile(id _: UUID, to _: String) async throws {}
    func deleteSample(id _: UUID, profileId _: UUID) async throws -> Bool { false }
    func forgetVoice(profileId _: UUID) async throws {}
    func forgetAllVoices() async throws {}
}

final class VoiceProfileFeatureGateTests: XCTestCase {
    /// Both halves of the settings gate are false for a release user who never
    /// enrolled anyone, so no profile administration is offered at all. The
    /// "Forget stored voices" row in Reset & Cleanup is deliberately outside
    /// this gate and stays reachable whatever this answers.
    @MainActor
    func testNoManagementSurfaceWithoutTheFlagOrStoredVoices() async {
        let viewModel = VoiceProfilesViewModel(service: EmptyVoiceStore())

        await viewModel.load()

        XCTAssertFalse(AppFeatures.isVoiceProfilesAvailable(arguments: []))
        XCTAssertFalse(viewModel.hasEnrolledVoices)
    }

    func testVoiceProfilesAreNotReleased() {
        XCTAssertFalse(AppFeatures.voiceProfilesEnabled)
        XCTAssertFalse(AppFeatures.isVoiceProfilesAvailable(arguments: []))
        #if DEBUG
        XCTAssertTrue(AppFeatures.isVoiceProfilesAvailable(arguments: ["--enable-voice-profiles"]))
        #else
        XCTAssertFalse(AppFeatures.isVoiceProfilesAvailable(arguments: ["--enable-voice-profiles"]))
        #endif
    }

    func testSavedOptInAndConsentCannotBypassReleaseGate() {
        let suite = "VoiceProfileFeatureGateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.rememberSpeakersKey)
        defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.meetingSpeakerDiarizationKey)
        defaults.set(Date(), forKey: UserDefaultsAppRuntimePreferences.voiceprintConsentAcknowledgedAtKey)
        XCTAssertFalse(
            UserDefaultsAppRuntimePreferences.rememberSpeakersEnabled(
                defaults: defaults, arguments: []
            ))
        let withOverride = UserDefaultsAppRuntimePreferences.rememberSpeakersEnabled(
            defaults: defaults, arguments: ["--enable-voice-profiles"]
        )
        #if DEBUG
        XCTAssertTrue(withOverride)
        #else
        XCTAssertFalse(withOverride)
        #endif
    }
}
