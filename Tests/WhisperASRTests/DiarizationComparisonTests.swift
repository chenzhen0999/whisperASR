import XCTest
import FluidAudio
@testable import WhisperASR

/// Local-only, opt-in comparison. Never writes transcripts, paths, or audio into Git.
/// DIARIZATION_TEST_AUDIO=/path/audio.wav DIARIZATION_TEST_MODEL=/path/model.bin swift test --filter DiarizationComparisonTests
final class DiarizationComparisonTests: XCTestCase {
    @MainActor
    func testCompareLocalEnginesAndWordAlignment() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["DIARIZATION_TEST_AUDIO"],
              let modelPath = environment["DIARIZATION_TEST_MODEL"] else {
            throw XCTSkip("Set DIARIZATION_TEST_AUDIO and DIARIZATION_TEST_MODEL to compare actual inference.")
        }
        let url = URL(fileURLWithPath: path)
        let service = TranscriptionService(modelPathOverride: modelPath)
        let transcription = try await service.transcribe(fileURL: url, onProgress: { _ in })
        XCTAssertFalse(transcription.segments.isEmpty)
        let timed = transcription.segments.filter { $0.words != nil }
        let linguistic = transcription.segments.filter { $0.text.contains(where: { $0.isLetter || $0.isNumber }) }
        XCTAssertGreaterThan(timed.count, 0, "Actual ASR must retain usable word timings.")
        XCTAssertEqual(timed.count, linguistic.count, "Every linguistic segment should retain timings.")
        XCTAssertTrue(timed.allSatisfy { $0.words!.map(\.text).joined() == $0.text })
        var report: [String: Any] = [
            "asrSegments": transcription.segments.count,
            "segmentsWithWordTimings": timed.count,
            "words": timed.flatMap { $0.words ?? [] }.count,
            "note": "Projection errors measure agreement with each engine's own turns, not human-annotated accuracy."
        ]
        let providers: [DiarizationProvider] = [LocalDiarizationProvider(), OfflineDiarizationProvider(), NemotronDiarizationProvider()]
        var rows: [[String: Any]] = []
        for provider in providers {
            let start = Date()
            let result = try await provider.diarize(audioURL: url, knownSpeakers: [], progress: { _ in })
            XCTAssertFalse(result.turns.isEmpty, provider.displayName)
            let split = DiarizationService.assignSpeakers(to: transcription.segments, turns: result.turns)
            XCTAssertEqual(split.map(\.text).joined(), transcription.segments.map(\.text).joined())
            let reference = result.turns.map { DERSpeakerSegment(speaker: $0.label, start: $0.start, end: $0.end) }
            // Exactly reproduce the previous longest-individual-turn assignment.
            let old = transcription.segments.compactMap { segment -> DERSpeakerSegment? in
                guard let end = segment.end,
                      let turn = result.turns.max(by: {
                          min(end, $0.end) - max(segment.start, $0.start) < min(end, $1.end) - max(segment.start, $1.start)
                      }), min(end, turn.end) > max(segment.start, turn.start) else { return nil }
                return .init(speaker: turn.label, start: segment.start, end: end)
            }
            let new = split.compactMap { segment -> DERSpeakerSegment? in
                guard let label = segment.diarizationLabel, let end = segment.end else { return nil }
                return .init(speaker: label, start: segment.start, end: end)
            }
            var row: [String: Any] = [
                "engine": provider.displayName,
                "secondsIncludingModelPreparation": Date().timeIntervalSince(start),
                "rawSpeakers": Set(result.turns.map(\.label)).count,
                "rawTurns": result.turns.count,
                "segmentsAfterSplitting": split.count,
                "projectionErrorBefore": DiarizationDER.compute(ref: reference, hyp: old).der,
                "projectionErrorAfter": DiarizationDER.compute(ref: reference, hyp: new).der
            ]
            if let referencePath = environment["DIARIZATION_TEST_REFERENCE"] {
                let data = try Data(contentsOf: URL(fileURLWithPath: referencePath))
                let turns = try JSONDecoder().decode([ReferenceTurn].self, from: data)
                let gold = turns.map { DERSpeakerSegment(speaker: $0.speaker, start: $0.start, end: $0.end) }
                row["rawEngineDER"] = DiarizationDER.compute(ref: gold, hyp: reference, collar: 0.25).der
                row["transcriptDERBefore"] = DiarizationDER.compute(ref: gold, hyp: old, collar: 0.25).der
                row["transcriptDERAfter"] = DiarizationDER.compute(ref: gold, hyp: new, collar: 0.25).der
            }
            if let directory = environment["DIARIZATION_TEST_OUTPUT_DIRECTORY"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let name = provider is NemotronDiarizationProvider ? "nemotron" : (provider is OfflineDiarizationProvider ? "vbx" : "legacy")
                try SubtitleFormatter.makeSRT(split).write(to: folder.appendingPathComponent(name + ".srt"),
                                                          atomically: true, encoding: .utf8)
                try JSONEncoder().encode(split).write(to: folder.appendingPathComponent(name + ".json"))
                // Export the old projection using the same ASR and same turns, for review.
                let baseline = transcription.segments.map { segment -> TranscriptionSegment in
                    var copy = segment
                    copy.diarizationLabel = old.first(where: { $0.start == segment.start })?.speaker
                    return copy
                }
                try SubtitleFormatter.makeSRT(baseline).write(to: folder.appendingPathComponent(name + "-before.srt"),
                                                             atomically: true, encoding: .utf8)
                try JSONEncoder().encode(transcription).write(to: folder.appendingPathComponent("asr.json"))
            }
            rows.append(row)
            print("Compared \(provider.displayName): \(result.turns.count) turns; \(transcription.segments.count) -> \(split.count) segments")
        }
        report["engines"] = rows
        let destination = environment["DIARIZATION_TEST_REPORT"] ?? "/private/tmp/whisperasr-diarization-comparison.json"
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: destination))
    }

    private struct ReferenceTurn: Decodable {
        let start: Double
        let end: Double
        let speaker: String
    }
}
