import FluidAudio
import Foundation

/// Eight-speaker end-to-end diarization. The longer fast128 window favors file
/// accuracy over live latency; it is separate from the Nemotron transcription model.
struct NemotronDiarizationProvider: DiarizationProvider {
    var displayName: String { "On-device (Nemotron 3, up to 8 speakers)" }

    func diarize(audioURL: URL, knownSpeakers: [KnownSpeakerSample],
                 progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerDiarizationResult {
        try await NemotronDiarizationRuntime.shared.diarize(audioURL: audioURL,
                                                          knownSpeakers: knownSpeakers, progress: progress)
    }
}

private actor NemotronDiarizationRuntime {
    static let shared = NemotronDiarizationRuntime()
    private var models: Nemotron3Models?
    private var preparation: Task<Void, Error>?

    func diarize(audioURL: URL, knownSpeakers: [KnownSpeakerSample],
                 progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerDiarizationResult {
        let config = Nemotron3Config.fast128
        if preparation == nil {
            preparation = Task {
                self.models = try await Nemotron3Models.loadFromHuggingFace(config: config, progressHandler: { update in
                    progress(update.fractionCompleted * 0.3)
                })
            }
        }
        do { try await preparation!.value }
        catch { preparation = nil; throw error }
        guard let models else { throw DiarizationError.providerUnavailable("Nemotron models did not load") }
        try Task.checkCancellation()
        progress(0.3)
        let samples = try await AudioLoader.loadSamples(url: audioURL)
        guard !samples.isEmpty else { throw DiarizationError.providerUnavailable("the audio file is empty") }
        try Task.checkCancellation()
        let diarizer = Nemotron3Diarizer(config: config, models: models)
        let (probabilities, frames) = try diarizer.processComplete(samples)
        let duration = Double(samples.count) / 16_000
        let turns = Nemotron3Diarizer.segments(probabilities: probabilities, frameCount: frames)
            .compactMap { segment -> SpeakerTurn? in
                let start = Double(segment.startSeconds), end = min(duration, Double(segment.endSeconds))
                guard end > start else { return nil }
                return SpeakerTurn(start: start, end: end,
                                   label: "Speaker \(segment.speakerIndex + 1)", speakerID: nil)
            }
        try Task.checkCancellation()
        progress(0.85)
        let result = try await matchVoices(turns: turns, audio: samples, knownSpeakers: knownSpeakers)
        progress(1)
        return result
    }

    /// Sortformer slots are not voice embeddings. Extract references and clean
    /// slot audio with the same WeSpeaker model before comparing identities.
    private func matchVoices(turns: [SpeakerTurn], audio: [Float],
                             knownSpeakers: [KnownSpeakerSample]) async throws -> SpeakerDiarizationResult {
        guard !knownSpeakers.isEmpty else { return .init(turns: turns) }
        let models = try await DiarizerModels.downloadIfNeeded()
        let extractor = DiarizerManager()
        extractor.initialize(models: models)
        var references: [SpeakerEmbeddingMatcher.Reference] = []
        var extracted: [UUID: [Float]] = [:]
        for known in knownSpeakers {
            try Task.checkCancellation()
            let embedding: [Float]
            if let cached = known.embedding, !cached.isEmpty { embedding = cached }
            else {
                guard let samples = try? await AudioLoader.loadSamples(url: known.fileURL),
                      let value = try? extractor.extractSpeakerEmbedding(from: samples) else { continue }
                embedding = value
                extracted[known.sampleID] = value
            }
            references.append(.init(speakerID: known.speakerID, embedding: embedding))
        }
        var clusters: [(id: String, embedding: [Float])] = []
        for label in Set(turns.map(\.label)).sorted() {
            try Task.checkCancellation()
            guard let speaker = turns.first(where: { $0.label == label }) else { continue }
            let ranges = DiarizationService.cleanRanges(start: 0, end: Double(audio.count) / 16_000,
                                                       speaker: speaker, turns: turns)
            guard let range = ranges.filter({ $0.end - $0.start >= 2.3 })
                .max(by: { $0.end - $0.start < $1.end - $1.start }) else { continue }
            let start = Int((range.start + 0.15) * 16_000)
            let end = min(audio.count, Int(min(range.end - 0.15, range.start + 5.15) * 16_000))
            guard start >= 0, end > start,
                  let embedding = try? extractor.extractSpeakerEmbedding(from: Array(audio[start..<end])) else { continue }
            clusters.append((label, embedding))
        }
        let identities = SpeakerEmbeddingMatcher.assign(clusters: clusters, references: references, turns: turns)
        let names = Dictionary(knownSpeakers.map { ($0.speakerID, $0.name) }, uniquingKeysWith: { first, _ in first })
        return .init(turns: turns.map { turn in
            let id = identities[turn.label]
            return SpeakerTurn(start: turn.start, end: turn.end,
                               label: id.flatMap { names[$0] } ?? turn.label, speakerID: id)
        }, extractedEmbeddings: extracted)
    }
}
