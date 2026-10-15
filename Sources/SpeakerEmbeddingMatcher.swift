import Accelerate
import Foundation

// MARK: - Speaker Embedding Matcher

/// Matches diarization clusters to known voices by cosine similarity of their
/// speaker embeddings (256-dim, L2-normalized by the embedding model).
///
/// The diarizer already recognizes voices it was enrolled with, but it only does
/// so when a cluster is close enough for *its* threshold. This is the second
/// pass: clusters that came back unnamed are compared against the whole library
/// so a voice recorded in an earlier session is still identified.
enum SpeakerEmbeddingMatcher {

    /// Minimum cosine similarity to accept a match. Deliberately strict —
    /// stricter than the diarizer's own acceptance (FluidAudio compares cosine
    /// *distance* against ~0.84, i.e. similarity above ~0.16) — because this pass
    /// only names clusters the diarizer left anonymous, and a false name is worse
    /// than no name.
    static let minSimilarity: Float = 0.65

    /// A known voice to match against.
    struct Reference: Equatable {
        let speakerID: UUID
        let embedding: [Float]
    }

    /// A person may occupy several fragmented clusters. Accept only an unambiguous
    /// voice match, and never merge clusters that speak at the same time.
    static func assign(clusters: [(id: String, embedding: [Float])],
                       references: [Reference], turns: [SpeakerTurn] = [],
                       existing: [String: UUID] = [:]) -> [String: UUID] {
        var candidates: [(cluster: String, speaker: UUID, score: Float)] = []
        for cluster in clusters {
            var scores: [UUID: Float] = [:]
            for reference in references {
                let score = cosineSimilarity(cluster.embedding, reference.embedding)
                if score.isFinite {
                    scores[reference.speakerID] = max(scores[reference.speakerID] ?? -1, score)
                }
            }
            let ranked = scores.sorted { $0.value > $1.value }
            guard let best = ranked.first, best.value >= minSimilarity,
                  ranked.count == 1 || best.value - ranked[1].value >= 0.08 else { continue }
            candidates.append((cluster.id, best.key, best.value))
        }
        var assigned = existing
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            let conflicts = assigned.contains { cluster, speaker in
                guard speaker == candidate.speaker, cluster != candidate.cluster else { return false }
                let other = turns.filter { $0.label == cluster }
                return turns.filter { $0.label == candidate.cluster }.contains { turn in
                    other.contains { min(turn.end, $0.end) - max(turn.start, $0.start) > 0.1 }
                }
            }
            if !conflicts { assigned[candidate.cluster] = candidate.speaker }
        }
        return assigned
    }

    /// Cosine similarity between two vectors; 0 for empty or mismatched inputs.
    /// Embeddings arrive L2-normalized, but the norms are still divided out so a
    /// non-normalized vector can't inflate the score.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        let denominator = (normA * normB).squareRoot()
        return denominator > 0 ? dot / denominator : 0
    }
}
