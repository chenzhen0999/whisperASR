import Foundation
import SpeakerKit
import ArgmaxCore

/// Argmax's open-source Pyannote community-1 pipeline. Models and reference
/// voices stay local; the existing word alignment attaches its turns to text.
struct SpeakerKitDiarizationProvider: DiarizationProvider {
    var displayName: String { "On-device (SpeakerKit / Pyannote)" }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperASR/Models/SpeakerKit", isDirectory: true)
    }

    func diarize(audioURL: URL, knownSpeakers: [KnownSpeakerSample],
                 progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerDiarizationResult {
        try await SpeakerKitDiarizationRuntime.shared.diarize(audioURL: audioURL,
                                                              knownSpeakers: knownSpeakers, progress: progress)
    }

    /// Preserve simultaneous speakers for alignment and clean reference extraction.
    static func rawTurns(in result: DiarizationResult, duration: Double) -> [SpeakerTurn] {
        guard duration.isFinite, duration > 0 else { return [] }
        return result.segments.flatMap { segment -> [SpeakerTurn] in
            guard segment.startTime.isFinite, segment.endTime.isFinite else { return [] }
            let start = max(0, Double(segment.startTime)), end = min(duration, Double(segment.endTime))
            guard start.isFinite, end.isFinite, end > start else { return [] }
            return segment.speaker.speakerIds.map {
                SpeakerTurn(start: start, end: end, label: String($0), speakerID: nil)
            }
        }.sorted { $0.start < $1.start }
    }
}

private actor SpeakerKitDiarizationRuntime {
    static let shared = SpeakerKitDiarizationRuntime()
    private var preparation: Task<SpeakerKit, Error>?

    private func prepare(progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerKit {
        if preparation == nil {
            preparation = Task.detached(priority: .utility) {
                let config = PyannoteConfig(downloadBase: SpeakerKitDiarizationProvider.directory.path,
                                            verbose: false)
                let diarizer = SpeakerKitDiarizer.pyannote(config: config)
                try await (diarizer as ArgmaxCore.ModelManager).downloadModels { update in
                    progress(0.01 + min(1, max(0, update.fractionCompleted)) * 0.24)
                }
                try await diarizer.loadModels()
                return try await SpeakerKit(SpeakerKitConfig(download: false, verbose: false, diarizer: diarizer))
            }
        }
        do { return try await preparation!.value }
        catch { preparation = nil; throw error }
    }

    func diarize(audioURL: URL, knownSpeakers: [KnownSpeakerSample],
                 progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerDiarizationResult {
        progress(0.01)
        let kit = try await prepare(progress: progress)
        try Task.checkCancellation()
        progress(0.25)
        let audio = try await AudioLoader.loadSamples(url: audioURL)
        guard !audio.isEmpty else { throw DiarizationError.providerUnavailable("the audio file is empty") }
        try Task.checkCancellation()
        let options = PyannoteDiarizationOptions(useExclusiveReconciliation: false, centroidSource: .trainableOnly)
        let result = try await kit.diarize(audioArray: audio, options: options) { update in
            progress(0.25 + min(1, max(0, update.fractionCompleted)) * 0.65)
        }
        try Task.checkCancellation()
        let turns = SpeakerKitDiarizationProvider.rawTurns(in: result, duration: Double(audio.count) / 16_000)

        // SpeakerKit centroids have their own acoustic embedding space. Extract
        // references with this same pipeline; never reuse or overwrite FluidAudio's cache.
        var references: [SpeakerEmbeddingMatcher.Reference] = []
        for (index, known) in knownSpeakers.enumerated() {
            try Task.checkCancellation()
            do {
                let samples = try await AudioLoader.loadSamples(url: known.fileURL)
                guard !samples.isEmpty else { continue }
                let reference = try await kit.diarize(audioArray: samples,
                    options: PyannoteDiarizationOptions(numberOfSpeakers: 1, centroidSource: .trainableOnly))
                if let embedding = reference.speakerCentroidEmbeddings.sorted(by: { $0.key < $1.key }).first?.value {
                    references.append(.init(speakerID: known.speakerID, embedding: embedding))
                }
            } catch is CancellationError { throw CancellationError() }
            catch { print("[Diarization] skipping unreadable SpeakerKit voice reference: \(error.localizedDescription)") }
            progress(0.9 + 0.1 * Double(index + 1) / Double(knownSpeakers.count))
        }
        try Task.checkCancellation()
        let clusters = result.speakerCentroidEmbeddings.sorted { $0.key < $1.key }
            .map { (id: String($0.key), embedding: $0.value) }
        let identities = SpeakerEmbeddingMatcher.assign(clusters: clusters, references: references, turns: turns)
        let names = Dictionary(knownSpeakers.map { ($0.speakerID, $0.name) }, uniquingKeysWith: { first, _ in first })
        progress(1)
        return .init(turns: turns.map { turn in
            let id = identities[turn.label]
            let label = id.flatMap { names[$0] } ?? "Speaker \((Int(turn.label) ?? 0) + 1)"
            return SpeakerTurn(start: turn.start, end: turn.end, label: label, speakerID: id)
        })
    }
}
