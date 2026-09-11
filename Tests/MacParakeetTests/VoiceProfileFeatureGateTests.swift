import Foundation
import XCTest
@testable import MacParakeetCore

final class VoiceProfileFeatureGateTests: XCTestCase {
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
        XCTAssertFalse(UserDefaultsAppRuntimePreferences.rememberSpeakersEnabled(
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
