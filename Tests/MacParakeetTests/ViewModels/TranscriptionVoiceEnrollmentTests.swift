import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

/// Records what the view model asks of the voiceprint service and returns
/// scripted answers, so the offer's conditions can be exercised without a
/// database or a diarizer.
private final class StubVoiceprintService: SpeakerVoiceprintServicing, @unchecked Sendable {
    private let lock = NSLock()
    private let candidate: SpeakerClusterObservation?
    private let enrollment: SpeakerProfileEnrollment
    private let enrollError: Error?

    private var storedCandidateRequests: [(UUID, String, String)] = []
    private var storedEnrollments: [(String, Bool)] = []

    var candidateRequests: [(UUID, String, String)] {
        lock.lock(); defer { lock.unlock() }
        return storedCandidateRequests
    }
    var enrollments: [(String, Bool)] {
        lock.lock(); defer { lock.unlock() }
        return storedEnrollments
    }

    /// `mergeEnrollment` mirrors the real service: an accepted merge skips the
    /// pollution guard, so it cannot answer with the same conflict twice.
    private let mergeEnrollment: SpeakerProfileEnrollment?

    init(
        candidate: SpeakerClusterObservation?,
        enrollment: SpeakerProfileEnrollment = .rejectedEmptyName,
        mergeEnrollment: SpeakerProfileEnrollment? = nil,
        enrollError: Error? = nil
    ) {
        self.candidate = candidate
        self.enrollment = enrollment
        self.mergeEnrollment = mergeEnrollment
        self.enrollError = enrollError
    }

    func evaluate(
        transcriptionId _: UUID,
        fingerprint _: TranscriptFingerprint,
        clusters _: [SpeakerClusterObservation]
    ) async throws -> [SpeakerVoiceprintSuggestion] { [] }

    func enrollmentCandidate(
        transcriptionId: UUID,
        speakerId: String,
        fingerprint: TranscriptFingerprint
    ) async throws -> SpeakerClusterObservation? {
        lock.lock()
        storedCandidateRequests.append((transcriptionId, speakerId, fingerprint.rawValue))
        lock.unlock()
        return candidate
    }

    func pruneExpiredCandidates() async throws {}

    func enroll(
        displayName: String,
        observation _: SpeakerClusterObservation,
        transcriptionId _: UUID,
        fingerprint _: TranscriptFingerprint,
        allowMergeIntoExistingName: Bool
    ) async throws -> SpeakerProfileEnrollment {
        lock.lock()
        storedEnrollments.append((displayName, allowMergeIntoExistingName))
        lock.unlock()
        if let enrollError { throw enrollError }
        if allowMergeIntoExistingName, let mergeEnrollment { return mergeEnrollment }
        return enrollment
    }

    func confirm(
        _: SpeakerVoiceprintSuggestion,
        observation _: SpeakerClusterObservation,
        transcriptionId _: UUID,
        fingerprint _: TranscriptFingerprint
    ) async throws {}

    func dismiss(
        _: SpeakerVoiceprintSuggestion,
        transcriptionId _: UUID,
        fingerprint _: TranscriptFingerprint
    ) async throws {}
}

private final class StubAttributionReader: SpeakerAttributionReading, @unchecked Sendable {
    private let projection: SpeakerAttributionProjection

    init(projection: SpeakerAttributionProjection) {
        self.projection = projection
    }

    func resolve(transcriptionId _: UUID) throws -> SpeakerAttributionProjection? { projection }
    func resolve(transcription _: Transcription) throws -> SpeakerAttributionProjection {
        projection
    }
}

private final class StubCorrectionService: SpeakerCorrectionServicing, @unchecked Sendable {
    let result: SpeakerCorrectionResult

    init(result: SpeakerCorrectionResult) {
        self.result = result
    }

    func apply(
        transcriptionId _: UUID,
        command _: SpeakerCorrectionCommand,
        expectedFingerprint _: TranscriptFingerprint,
        expectedRevision _: Int
    ) async throws -> SpeakerCorrectionResult { result }

    func undo(
        transcriptionId _: UUID,
        expectedFingerprint _: TranscriptFingerprint,
        expectedRevision _: Int
    ) async throws -> SpeakerCorrectionResult { result }

    func redo(
        transcriptionId _: UUID,
        expectedFingerprint _: TranscriptFingerprint,
        expectedRevision _: Int
    ) async throws -> SpeakerCorrectionResult { result }
}

@MainActor
final class TranscriptionVoiceEnrollmentTests: XCTestCase {
    private let identity = SpeakerModelIdentity(
        embeddingModelId: "test-model",
        aggregationProfileId: "test-aggregation"
    )

    // MARK: Offering

    func testRenamingASpeakerOffersToRememberTheVoice() async throws {
        let transcription = makeTranscription()
        let service = StubVoiceprintService(candidate: observation())
        let viewModel = try await configured(transcription, voiceprints: service)

        XCTAssertTrue(viewModel.renameSpeaker(id: "S1", to: "  Sarah  "))

        try await waitUntil { viewModel.pendingVoiceEnrollment != nil }
        let offer = try XCTUnwrap(viewModel.pendingVoiceEnrollment)
        // The trimmed label, since that is what the profile will be named.
        XCTAssertEqual(offer.displayName, "Sarah")
        XCTAssertEqual(offer.speakerId, "S1")
        XCTAssertEqual(service.candidateRequests.count, 1)
        XCTAssertEqual(service.candidateRequests.first?.1, "S1")
        // Nothing is stored by merely offering.
        XCTAssertTrue(service.enrollments.isEmpty)
    }

    /// The offer must not promise what enrollment would refuse: with no
    /// candidate left — window lapsed, feature off at capture, or too little
    /// speech — the rename stays silent.
    func testNoOfferWhenNoCandidateRemains() async throws {
        let transcription = makeTranscription()
        let service = StubVoiceprintService(candidate: nil)
        let viewModel = try await configured(transcription, voiceprints: service)

        viewModel.renameSpeaker(id: "S1", to: "Sarah")

        try await waitUntil { service.candidateRequests.count == 1 }
        XCTAssertNil(viewModel.pendingVoiceEnrollment)
    }

    func testNoOfferWhenTheServiceIsAbsent() async throws {
        let transcription = makeTranscription()
        let viewModel = try await configured(transcription, voiceprints: nil)

        viewModel.renameSpeaker(id: "S1", to: "Sarah")

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(viewModel.pendingVoiceEnrollment)
    }

    /// The lookup is async, so the user can have moved on by the time it
    /// returns. Offering then would attach a prompt to the wrong transcript.
    func testAnOfferIsDroppedIfTheTranscriptChanged() async throws {
        let transcription = makeTranscription()
        let service = StubVoiceprintService(candidate: observation())
        let viewModel = try await configured(transcription, voiceprints: service)

        viewModel.renameSpeaker(id: "S1", to: "Sarah")
        viewModel.currentTranscription = makeTranscription()

        try await waitUntil { service.candidateRequests.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(viewModel.pendingVoiceEnrollment)
    }

    // MARK: Answering

    func testAcceptingEnrollsAndReportsSuccess() async throws {
        let transcription = makeTranscription()
        let profile = SpeakerProfile(displayName: "Sarah", identity: identity)
        let service = StubVoiceprintService(
            candidate: observation(), enrollment: .created(profile)
        )
        let viewModel = try await configured(transcription, voiceprints: service)
        viewModel.renameSpeaker(id: "S1", to: "Sarah")
        try await waitUntil { viewModel.pendingVoiceEnrollment != nil }

        viewModel.confirmVoiceEnrollment()

        try await waitUntil { viewModel.voiceEnrollmentMessage != nil }
        XCTAssertEqual(service.enrollments.map(\.0), ["Sarah"])
        XCTAssertEqual(service.enrollments.first?.1, false)
        XCTAssertNil(viewModel.pendingVoiceEnrollment)
    }

    func testDismissingStoresNothing() async throws {
        let transcription = makeTranscription()
        let service = StubVoiceprintService(candidate: observation())
        let viewModel = try await configured(transcription, voiceprints: service)
        viewModel.renameSpeaker(id: "S1", to: "Sarah")
        try await waitUntil { viewModel.pendingVoiceEnrollment != nil }

        viewModel.dismissVoiceEnrollment()

        XCTAssertNil(viewModel.pendingVoiceEnrollment)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(service.enrollments.isEmpty)
    }

    /// Two colleagues called Sarah is the likely cause, not a mistake, so the
    /// conflict is a question rather than an error — and merging happens only
    /// on a second, explicit answer.
    func testANameConflictAsksBeforeMerging() async throws {
        let transcription = makeTranscription()
        let existing = SpeakerProfile(displayName: "Sarah", identity: identity)
        let service = StubVoiceprintService(
            candidate: observation(),
            enrollment: .needsDisambiguation(existing: existing, distance: 0.62),
            mergeEnrollment: .addedExemplar(existing)
        )
        let viewModel = try await configured(transcription, voiceprints: service)
        viewModel.renameSpeaker(id: "S1", to: "Sarah")
        try await waitUntil { viewModel.pendingVoiceEnrollment != nil }

        viewModel.confirmVoiceEnrollment()

        try await waitUntil { viewModel.voiceEnrollmentConflict != nil }
        XCTAssertNil(viewModel.voiceEnrollmentMessage)
        XCTAssertEqual(service.enrollments.count, 1)

        viewModel.confirmVoiceEnrollment(allowMerge: true)

        try await waitUntil { service.enrollments.count == 2 }
        XCTAssertEqual(service.enrollments.last?.1, true)
        XCTAssertNil(viewModel.voiceEnrollmentConflict)
    }

    func testAFailedEnrollmentSaysSoWithoutBlocking() async throws {
        struct Boom: Error {}
        let transcription = makeTranscription()
        let service = StubVoiceprintService(candidate: observation(), enrollError: Boom())
        let viewModel = try await configured(transcription, voiceprints: service)
        viewModel.renameSpeaker(id: "S1", to: "Sarah")
        try await waitUntil { viewModel.pendingVoiceEnrollment != nil }

        viewModel.confirmVoiceEnrollment()

        try await waitUntil { viewModel.voiceEnrollmentMessage != nil }
        // The rename itself is untouched: only the voice was not remembered.
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: Helpers

    private func configured(
        _ transcription: Transcription,
        voiceprints: SpeakerVoiceprintServicing?
    ) async throws -> TranscriptionViewModel {
        let attribution = SpeakerAttributionResolver.resolve(transcription: transcription)
        let projection = SpeakerAttributionProjection(
            automaticTranscription: transcription,
            attribution: attribution,
            correctionsApplied: false
        )
        let viewModel = TranscriptionViewModel()
        viewModel.configure(
            transcriptionService: MockTranscriptionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            speakerAttributionReader: StubAttributionReader(projection: projection),
            speakerCorrectionService: StubCorrectionService(
                result: SpeakerCorrectionResult(
                    attribution: attribution, revision: 1, canUndo: true, canRedo: false
                )
            ),
            speakerVoiceprints: voiceprints
        )
        viewModel.currentTranscription = transcription
        try await waitUntil { viewModel.speakerAttribution != nil }
        return viewModel
    }

    private func observation() -> SpeakerClusterObservation {
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[0] = 1
        guard let embedding = SpeakerEmbedding(rawVector: values, identity: identity) else {
            preconditionFailure("fixture vector must be valid")
        }
        return SpeakerClusterObservation(
            speakerId: "S1", embedding: embedding, speechSeconds: 30, captureDomain: .system
        )
    }

    private func makeTranscription() -> Transcription {
        let words = [
            WordTimestamp(word: "hello", startMs: 0, endMs: 400, confidence: 0.9, speakerId: "S1"),
            WordTimestamp(word: "there", startMs: 450, endMs: 800, confidence: 0.9, speakerId: "S1"),
        ]
        return Transcription(
            fileName: "meeting.wav",
            rawTranscript: "hello there",
            wordTimestamps: words,
            speakerCount: 1,
            speakers: [SpeakerInfo(id: "S1", label: "Others 1")],
            diarizationSegments: [.init(speakerId: "S1", startMs: 0, endMs: 800)],
            transcriptSegments: [
                TranscriptSegmentRecord(
                    startMs: 0,
                    endMs: 800,
                    speakerId: "S1",
                    speakerLabel: "Others 1",
                    text: "hello there",
                    wordRange: .init(startIndex: 0, endIndexExclusive: 2)
                )
            ],
            status: .completed
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline { XCTFail("condition not met in time"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
