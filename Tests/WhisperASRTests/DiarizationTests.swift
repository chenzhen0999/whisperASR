import XCTest
@testable import WhisperASR

final class DiarizationTests: XCTestCase {
    func testBackupKeepsOfflinePreferenceAndAcceptsOlderConfiguration() throws {
        let old = try JSONDecoder().decode(BackupService.BackupConfiguration.self,
                                          from: Data(#"{"diarizationUseRemote":false}"#.utf8))
        XCTAssertNil(old.diarizationUseOffline)
        let saved = BackupService.BackupConfiguration(diarizationUseOffline: true)
        let restored = try JSONDecoder().decode(BackupService.BackupConfiguration.self,
                                               from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored.diarizationUseOffline, true)
    }

    func testBetterModelSelectionPreservesLocalDefaultAndRemoteOverride() {
        let suite = "WhisperASRTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(DiarizationService.provider(defaults: defaults) is LocalDiarizationProvider)
        defaults.set(true, forKey: DiarizationService.useOfflineKey)
        XCTAssertTrue(DiarizationService.provider(defaults: defaults) is OfflineDiarizationProvider)
        defaults.set(true, forKey: DiarizationService.useRemoteKey)
        XCTAssertTrue(DiarizationService.provider(defaults: defaults) is OpenAIDiarizationProvider)
        defaults.set(false, forKey: DiarizationService.useRemoteKey)
        defaults.set(false, forKey: DiarizationService.useOfflineKey)
        XCTAssertTrue(DiarizationService.provider(defaults: defaults) is LocalDiarizationProvider)
    }

    /// Opt-in end-to-end check: downloads the actual models and diarizes a local
    /// speech fixture. Example: VBX_TEST_AUDIO=/tmp/speech.wav swift test.
    @MainActor
    func testOfflineModelsAndInference() async throws {
        guard let path = ProcessInfo.processInfo.environment["VBX_TEST_AUDIO"] else {
            throw XCTSkip("Set VBX_TEST_AUDIO to run the model download and inference check.")
        }
        let audioURL = URL(fileURLWithPath: path)
        let store = OfflineDiarizationModels.shared
        async let first = store.prepare()
        async let second = store.prepare()
        _ = try await (first, second)
        XCTAssertTrue(store.isReady)
        XCTAssertFalse(store.isDownloading)
        XCTAssertNil(store.error)

        let result = try await OfflineDiarizationProvider().diarize(
            audioURL: audioURL, knownSpeakers: [], progress: { _ in })
        XCTAssertFalse(result.turns.isEmpty, "Speech should produce speaker turns.")
        XCTAssertTrue(result.turns.allSatisfy { $0.start >= 0 && $0.end > $0.start })
        XCTAssertTrue(result.turns.allSatisfy { !$0.label.isEmpty })

        let samples = try await AudioLoader.loadSamples(url: audioURL)
        let referenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vbx-reference-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: referenceURL) }
        try VoiceSampleExtractor.makeWAV(samples: samples, start: 0, end: 5)
            .write(to: referenceURL)
        let speakerID = UUID()
        // Recognize the reference clip itself. A synthetic voice can fragment
        // across a longer recording, so this checks embedding compatibility
        // without treating synthetic speech as a recognition benchmark.
        let recognized = try await OfflineDiarizationProvider().diarize(
            audioURL: referenceURL,
            knownSpeakers: [.init(speakerID: speakerID, sampleID: UUID(), name: "Test Voice",
                                 fileURL: referenceURL, embedding: [1])],
            progress: { _ in })
        XCTAssertTrue(recognized.turns.contains { $0.speakerID == speakerID },
                      "Known voices must be matched using offline embeddings, ignoring the legacy cache.")
        XCTAssertTrue(recognized.extractedEmbeddings.isEmpty,
                      "Offline embeddings must not overwrite the legacy voice cache.")
    }
}
