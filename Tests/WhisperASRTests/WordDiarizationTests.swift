import XCTest
import FluidAudio
@testable import WhisperASR

final class WordDiarizationTests: XCTestCase {
    private func turn(_ start: Double, _ end: Double, _ label: String) -> SpeakerTurn {
        .init(start: start, end: end, label: label, speakerID: nil)
    }

    func testWordsPreserveSubwordsPunctuationAndSplitUTF8() throws {
        let chinese = Array("你好".utf8)
        let tokens: [WhisperASR.WordTiming.Token] = [
            .init(bytes: Array(" Hel".utf8), start: 0, end: 0.3),
            .init(bytes: Array("lo, ".utf8), start: 0.3, end: 0.6),
            .init(bytes: Array(chinese.prefix(1)), start: 1, end: 1.1),
            .init(bytes: Array(chinese.dropFirst()), start: 1.1, end: 2),
            .init(bytes: Array("！".utf8), start: 2, end: 2.1)
        ]
        let text = " Hello, 你好！"
        let words = try XCTUnwrap(WhisperASR.WordTiming.words(tokens: tokens, text: text))
        XCTAssertEqual(words.map(\.text).joined(), text)
        XCTAssertEqual(words.first?.start, 0)
        XCTAssertEqual(words.first?.end, 0.6)
        XCTAssertTrue(words.contains { $0.start == 1 })
        XCTAssertNil(WhisperASR.WordTiming.words(tokens: tokens, text: "edited text"))
    }

    @MainActor
    func testSpeakerChangesSplitWithoutLosingTextAndSurviveCoding() throws {
        let text = "Hello. Yes! Back again."
        let words: [TranscriptionWord] = [
            .init(start: 0, end: 1, text: "Hello. "),
            .init(start: 1, end: 2, text: "Yes! "),
            .init(start: 2, end: 3, text: "Back "),
            .init(start: 3, end: 4, text: "again.")
        ]
        let segment = TranscriptionSegment(start: 0, end: 4, text: text, words: words)
        let turns = [turn(0, 1, "A"), turn(1, 2, "B"), turn(2, 4, "A")]
        let split = DiarizationService.assignSpeakers(to: [segment], turns: turns)
        XCTAssertEqual(split.map(\.diarizationLabel), ["A", "B", "A"])
        XCTAssertEqual(split.map(\.text).joined(), text)
        XCTAssertEqual(split.map(\.start), [0, 1, 2])
        XCTAssertEqual(split.map(\.end), [1, 2, 4])
        XCTAssertEqual(split.flatMap { $0.words ?? [] }, words)
        let restored = try JSONDecoder().decode([TranscriptionSegment].self, from: JSONEncoder().encode(split))
        XCTAssertEqual(restored, split)
        XCTAssertEqual(DiarizationService.assignSpeakers(to: restored, turns: turns), split)
        let ref = turns.map { DERSpeakerSegment(speaker: $0.label, start: $0.start, end: $0.end) }
        let before = DiarizationDER.compute(ref: ref, hyp: [.init(speaker: "A", start: 0, end: 4)])
        let after = DiarizationDER.compute(ref: ref, hyp: split.map {
            .init(speaker: $0.diarizationLabel!, start: $0.start, end: $0.end!)
        })
        XCTAssertEqual(before.der, 0.25, accuracy: 0.001)
        XCTAssertEqual(after.der, 0, accuracy: 0.001)
    }

    @MainActor
    func testOldOrInvalidTimingsKeepTextAndClearStaleSpeakers() throws {
        var old = try JSONDecoder().decode(TranscriptionSegment.self,
            from: Data(#"{"start":0,"end":6,"text":"Old transcript"}"#.utf8))
        XCTAssertNil(old.words)
        old.speakerName = "Stale"
        let turns = [turn(0, 2, "A"), turn(2, 5, "B"), turn(5, 6, "A")]
        // A's total is three seconds, tied with B; tie follows earliest speaker.
        XCTAssertEqual(DiarizationService.bestTurn(for: 0, end: 6, turns: turns)?.label, "A")
        let assigned = DiarizationService.assignSpeakers(to: [old], turns: turns)
        XCTAssertEqual(assigned.count, 1)
        XCTAssertEqual(assigned[0].text, old.text)
        let cleared = DiarizationService.assignSpeakers(to: assigned, turns: [])
        XCTAssertNil(cleared[0].speakerName)
        XCTAssertEqual(cleared[0].speakerSampleRanges, [])
        old.words = [.init(start: .nan, end: 2, text: old.text)]
        XCTAssertEqual(DiarizationService.assignSpeakers(to: [old], turns: turns).count, 1)
    }

    func testCumulativeOverlapDoesNotDoubleCountWindows() {
        let turns = [turn(0, 2, "A"), turn(0, 2, "A"), turn(2, 5, "B")]
        XCTAssertEqual(DiarizationService.bestTurn(for: 0, end: 5, turns: turns)?.label, "B")
        let fragmented = [turn(0, 2, "A"), turn(2, 5, "B"), turn(5, 7, "A")]
        XCTAssertEqual(DiarizationService.bestTurn(for: 0, end: 7, turns: fragmented)?.label, "A")
    }

    @MainActor
    func testVoiceSamplesExcludeOverlapAndUnverifiedSegments() {
        let a = turn(0, 10, "A")
        let ranges = DiarizationService.cleanRanges(start: 0, end: 10, speaker: a,
                                                   turns: [a, turn(3, 7, "B")])
        XCTAssertEqual(ranges, [.init(start: 0, end: 3), .init(start: 7, end: 10)])
        var segment = TranscriptionSegment(start: 0, end: 10, text: "mixed")
        XCTAssertNil(VoiceSampleExtractor.bestRange(among: [segment]))
        segment.speakerSampleRanges = ranges
        let sample = VoiceSampleExtractor.bestRange(among: [segment])!
        XCTAssertTrue(sample.end <= 3 || sample.start >= 7)
        XCTAssertGreaterThanOrEqual(sample.end - sample.start, 2)
    }

    func testFragmentsCanShareIdentityButCrosstalkAndAmbiguityCannot() {
        let id = UUID(), other = UUID()
        let clusters = [(id: "A", embedding: [Float(1), 0]), (id: "B", embedding: [Float(1), 0])]
        let references = [SpeakerEmbeddingMatcher.Reference(speakerID: id, embedding: [1, 0])]
        let merged = SpeakerEmbeddingMatcher.assign(clusters: clusters, references: references,
                                                    turns: [turn(0, 2, "A"), turn(3, 5, "B")])
        XCTAssertEqual(merged["A"], id)
        XCTAssertEqual(merged["B"], id)
        let overlapping = SpeakerEmbeddingMatcher.assign(clusters: clusters, references: references,
                                                         turns: [turn(0, 4, "A"), turn(3, 5, "B")])
        XCTAssertEqual(overlapping.count, 1)
        let ambiguous = SpeakerEmbeddingMatcher.assign(clusters: clusters,
            references: references + [.init(speakerID: other, embedding: [1, 0.01])])
        XCTAssertTrue(ambiguous.isEmpty)
    }

    func testNemotronRetainsTimingsThroughSentenceAndGapBoundaries() {
        let tokens: [TokenTiming] = [
            .init(token: "▁", tokenId: 0, startTime: 0, endTime: 0, confidence: 1),
            .init(token: "▁Hel", tokenId: 1, startTime: 0, endTime: 0.2, confidence: 1),
            .init(token: "lo ", tokenId: 2, startTime: 0.2, endTime: 0.4, confidence: 1),
            .init(token: "world!", tokenId: 3, startTime: 0.4, endTime: 1, confidence: 1),
            .init(token: "▁你好", tokenId: 4, startTime: 3, endTime: 4, confidence: 1)
        ]
        let segments = NemotronEngine.makeSegments(from: tokens)
        XCTAssertEqual(segments.map(\.text), ["Hello world!", "你好"])
        XCTAssertTrue(segments.allSatisfy { $0.words?.map(\.text).joined() == $0.text })
        XCTAssertEqual(segments[1].words?.first?.start, 3)
    }

    func testNemotronRecognizesVoiceReference() async throws {
        guard let path = ProcessInfo.processInfo.environment["NEMOTRON_TEST_AUDIO"] else {
            throw XCTSkip("Set NEMOTRON_TEST_AUDIO to a clean single-speaker clip to test recognition.")
        }
        let url = URL(fileURLWithPath: path)
        let id = UUID()
        let result = try await NemotronDiarizationProvider().diarize(audioURL: url,
            knownSpeakers: [.init(speakerID: id, sampleID: UUID(), name: "Test Voice",
                                 fileURL: url, embedding: nil)], progress: { _ in })
        XCTAssertTrue(result.turns.contains { $0.speakerID == id })
        XCTAssertFalse(result.extractedEmbeddings.isEmpty)
    }

    func testNemotronPreferenceBackupAndRemoteOverride() throws {
        let suite = "WhisperASRTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: DiarizationService.useNemotronKey)
        XCTAssertTrue(DiarizationService.provider(defaults: defaults) is NemotronDiarizationProvider)
        defaults.set(true, forKey: DiarizationService.useRemoteKey)
        XCTAssertTrue(DiarizationService.provider(defaults: defaults) is OpenAIDiarizationProvider)
        let config = BackupService.BackupConfiguration(diarizationUseNemotron: true)
        XCTAssertEqual(try JSONDecoder().decode(BackupService.BackupConfiguration.self,
            from: JSONEncoder().encode(config)).diarizationUseNemotron, true)
    }
}
