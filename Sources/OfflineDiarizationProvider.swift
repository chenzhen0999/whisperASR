import FluidAudio
import Foundation
import Observation

/// Shares model preparation between Settings and diarization, including an
/// in-flight download if the user starts diarization before it finishes.
@MainActor
@Observable
final class OfflineDiarizationModels {
    static let shared = OfflineDiarizationModels()

    private(set) var isDownloading = false
    private(set) var progress: Double = 0
    private(set) var isReady = false
    private(set) var error: String?
    private var models: OfflineDiarizerModels?
    private var preparationTask: Task<OfflineDiarizerModels, Error>?

    /// Keep the offline bundles separate from the legacy model cache. Both
    /// pipelines can then be selected without replacing one another's files.
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperASR/Models/Diarization-VBx", isDirectory: true)
    }

    func prepare() async throws -> OfflineDiarizerModels {
        if let models { return models }
        if let preparationTask { return try await preparationTask.value }

        isDownloading = true
        progress = 0
        error = nil
        let directory = Self.directory
        let task = Task.detached(priority: .utility) {
            try await OfflineDiarizerModels.load(from: directory, progressHandler: { update in
                Task { @MainActor in
                    guard Self.shared.isDownloading else { return }
                    Self.shared.progress = max(Self.shared.progress, min(1, update.fractionCompleted))
                }
            })
        }
        preparationTask = task
        defer {
            preparationTask = nil
            isDownloading = false
        }
        do {
            let loaded = try await task.value
            models = loaded
            isReady = true
            progress = 1
            return loaded
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }
}

/// Full-recording segmentation, embedding extraction and VBx clustering. Audio
/// stays on this Mac; only model files are downloaded from Hugging Face.
struct OfflineDiarizationProvider: DiarizationProvider {
    var displayName: String { "On-device (Offline VBx)" }

    func diarize(audioURL: URL,
                 knownSpeakers: [KnownSpeakerSample],
                 progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerDiarizationResult {
        let models = try await OfflineDiarizationModels.shared.prepare()
        try Task.checkCancellation()
        progress(0.1)

        var config = OfflineDiarizerConfig()
        config.exposeChunkEmbeddings = true
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        let result = try await manager.process(audioURL, progressCallback: { completed, total in
            progress(0.1 + 0.8 * Double(completed) / Double(max(total, 1)))
        })
        try Task.checkCancellation()

        // Legacy cached embeddings come from a different model. Extract known
        // voices with the offline pipeline instead of comparing incompatible
        // vectors or overwriting the legacy cache.
        var referenceConfig = config
        referenceConfig.clustering.numSpeakers = 1
        let referenceManager = OfflineDiarizerManager(config: referenceConfig)
        referenceManager.initialize(models: models)
        var references: [SpeakerEmbeddingMatcher.Reference] = []
        for (index, known) in knownSpeakers.enumerated() {
            try Task.checkCancellation()
            do {
                let reference = try await referenceManager.process(known.fileURL)
                if let embedding = Self.voiceEmbeddings(in: reference).values.first {
                    references.append(.init(speakerID: known.speakerID, embedding: embedding))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                print("[Diarization] skipping unreadable VBx voice sample for \(known.name): \(error)")
            }
            progress(0.9 + 0.1 * Double(index + 1) / Double(knownSpeakers.count))
        }
        try Task.checkCancellation()

        let clusters = Self.voiceEmbeddings(in: result).sorted { $0.key < $1.key }
            .map { (id: $0.key, embedding: $0.value) }
        let identities = SpeakerEmbeddingMatcher.assign(clusters: clusters, references: references)
        let names = Dictionary(knownSpeakers.map { ($0.speakerID, $0.name) },
                               uniquingKeysWith: { first, _ in first })
        let turns = result.segments.map { segment in
            let speakerID = identities[segment.speakerId]
            let label = speakerID.flatMap { names[$0] }
                ?? "Speaker \(segment.speakerId.hasPrefix("S") ? String(segment.speakerId.dropFirst()) : segment.speakerId)"
            return SpeakerTurn(start: Double(segment.startTimeSeconds),
                               end: Double(segment.endTimeSeconds),
                               label: label, speakerID: speakerID)
        }
        progress(1)
        return SpeakerDiarizationResult(turns: turns)
    }

    /// VBx's speaker database contains clustering-space centroids. Recognition
    /// uses the original 256-dimensional voice embeddings, averaged per cluster,
    /// so the cosine matcher compares acoustic references in the same space.
    private static func voiceEmbeddings(in result: DiarizationResult) -> [String: [Float]] {
        var embeddings: [String: [Float]] = [:]
        let visibleSpeakers = Set(result.segments.map(\.speakerId))
        for chunk in result.chunkEmbeddings ?? [] {
            let raw = chunk.embedding256
            guard visibleSpeakers.contains(chunk.speakerId), !raw.isEmpty,
                  raw.allSatisfy(\.isFinite) else { continue }
            let norm = sqrt(raw.reduce(Float(0)) { $0 + $1 * $1 })
            guard norm.isFinite, norm > 0 else { continue }
            let embedding = raw.map { $0 / norm }
            if var sum = embeddings[chunk.speakerId], sum.count == embedding.count {
                for index in sum.indices { sum[index] += embedding[index] }
                embeddings[chunk.speakerId] = sum
            } else {
                embeddings[chunk.speakerId] = embedding
            }
        }
        return embeddings
    }
}
