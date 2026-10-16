import XCTest
import SpeakerKit
@testable import WhisperASR

final class SpeakerKitDiarizationTests: XCTestCase {
    func testSelectionAndBackupKeepOlderConfigurationsCompatible() throws {
        let suite = "WhisperASRTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: DiarizationService.useOfflineKey)
        defaults.set(true, forKey: DiarizationService.useNemotronKey)
        defaults.set(true, forKey: DiarizationService.useSpeakerKitKey)
        XCTAssertTrue(DiarizationService.provider(defaults: defaults) is SpeakerKitDiarizationProvider)
        defaults.set(true, forKey: DiarizationService.useRemoteKey)
        XCTAssertTrue(DiarizationService.provider(defaults: defaults) is OpenAIDiarizationProvider)
        defaults.set(false, forKey: DiarizationService.useRemoteKey)
        defaults.set(false, forKey: DiarizationService.useSpeakerKitKey)
        XCTAssertTrue(DiarizationService.provider(defaults: defaults) is NemotronDiarizationProvider)
        let old = try JSONDecoder().decode(BackupService.BackupConfiguration.self, from: Data("{}".utf8))
        XCTAssertNil(old.diarizationUseSpeakerKit)
        let saved = BackupService.BackupConfiguration(diarizationUseSpeakerKit: true)
        XCTAssertEqual(try JSONDecoder().decode(BackupService.BackupConfiguration.self,
            from: JSONEncoder().encode(saved)).diarizationUseSpeakerKit, true)
    }

    func testRawTurnsKeepOverlapAndRejectInvalidOrPaddedTimes() {
        let result = DiarizationResult(speakerCount: 5, totalFrames: 900, frameRate: 100, segments: [
            .init(speaker: .speakerId(0), startTime: -1, endTime: 2, frameRate: 100),
            .init(speaker: .multiple([1, 2]), startTime: 1, endTime: 3, frameRate: 100),
            .init(speaker: .noMatch, startTime: 0, endTime: 1, frameRate: 100),
            .init(speaker: .speakerId(3), startTime: 4, endTime: 9, frameRate: 100),
            .init(speaker: .speakerId(4), startTime: .nan, endTime: 2, frameRate: 100)
        ])
        let turns = SpeakerKitDiarizationProvider.rawTurns(in: result, duration: 5)
        XCTAssertEqual(turns.count, 4)
        XCTAssertEqual(Set(turns.map(\.label)), ["0", "1", "2", "3"])
        XCTAssertEqual(turns.first?.start, 0)
        XCTAssertEqual(turns.last?.end, 5)
        let clean = DiarizationService.cleanRanges(start: 0, end: 5, speaker: turns[0], turns: turns)
        XCTAssertEqual(clean, [.init(start: 0, end: 1)])
    }

    /// Downloads the actual Core ML models and checks known-voice compatibility.
    func testActualInferenceAndReferenceRecognition() async throws {
        guard let path = ProcessInfo.processInfo.environment["SPEAKERKIT_TEST_AUDIO"] else {
            throw XCTSkip("Set SPEAKERKIT_TEST_AUDIO to a clean single-speaker clip for actual inference.")
        }
        let url = URL(fileURLWithPath: path)
        let provider = SpeakerKitDiarizationProvider()
        let result = try await provider.diarize(audioURL: url, knownSpeakers: [], progress: { _ in })
        XCTAssertFalse(result.turns.isEmpty)
        XCTAssertTrue(result.turns.allSatisfy { $0.start >= 0 && $0.end > $0.start })
        let id = UUID()
        let recognized = try await provider.diarize(audioURL: url,
            knownSpeakers: [.init(speakerID: id, sampleID: UUID(), name: "Test Voice",
                                 fileURL: url, embedding: [1])], progress: { _ in })
        XCTAssertTrue(recognized.turns.contains { $0.speakerID == id },
                      "SpeakerKit must extract its own reference, ignoring the incompatible legacy embedding.")
        XCTAssertTrue(recognized.extractedEmbeddings.isEmpty)
    }
}
