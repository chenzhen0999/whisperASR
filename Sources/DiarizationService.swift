import Foundation

/// Selects an engine and aligns its turns with the ASR words.
enum DiarizationService {
    static let useRemoteKey = "diarizationUseRemote"
    static let useOfflineKey = "diarizationUseOfflineVBx"
    static let useNemotronKey = "diarizationUseNemotron"
    static let useSpeakerKitKey = "diarizationUseSpeakerKit"

    static func provider(defaults: UserDefaults = .standard) -> DiarizationProvider {
        if defaults.bool(forKey: useRemoteKey) {
            return OpenAIDiarizationProvider(apiKey: defaults.string(forKey: "translationAPIKey") ?? "")
        }
        if defaults.bool(forKey: useSpeakerKitKey) { return SpeakerKitDiarizationProvider() }
        if defaults.bool(forKey: useNemotronKey) { return NemotronDiarizationProvider() }
        if defaults.bool(forKey: useOfflineKey) { return OfflineDiarizationProvider() }
        return LocalDiarizationProvider()
    }

    private static func identity(_ turn: SpeakerTurn) -> String {
        turn.speakerID?.uuidString ?? turn.label
    }

    /// Sum a speaker's covered time, including multiple turns but never counting
    /// overlapping windows twice. Ties retain the earliest turn's speaker.
    static func bestTurn(for start: Double, end: Double, turns: [SpeakerTurn]) -> SpeakerTurn? {
        guard start.isFinite, end.isFinite, end > start else { return nil }
        var intervals: [String: [(Double, Double)]] = [:]
        var representatives: [SpeakerTurn] = []
        for turn in turns where turn.start.isFinite && turn.end.isFinite {
            let lower = max(start, turn.start), upper = min(end, turn.end)
            guard upper > lower else { continue }
            let key = identity(turn)
            if intervals[key] == nil { representatives.append(turn) }
            intervals[key, default: []].append((lower, upper))
        }
        var best: SpeakerTurn?
        var bestOverlap = 0.0
        for turn in representatives {
            let spans = intervals[identity(turn)]!.sorted { $0.0 < $1.0 }
            var covered = 0.0, previousEnd = start
            for (lower, upper) in spans {
                covered += max(0, upper - max(lower, previousEnd))
                previousEnd = max(previousEnd, upper)
            }
            if covered > bestOverlap { bestOverlap = covered; best = turn }
        }
        return best
    }

    @MainActor
    static func assignSpeakers(to segments: [TranscriptionSegment],
                               turns: [SpeakerTurn]) -> [TranscriptionSegment] {
        let turns = turns.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        return segments.flatMap { segment -> [TranscriptionSegment] in
            guard let end = segment.end, end > segment.start else {
                return [label(segment, with: nil, turns: [])]
            }
            let candidates = turns.filter { $0.end > segment.start && $0.start < end }
            guard let words = segment.words, !words.isEmpty,
                  words.map(\.text).joined() == segment.text,
                  words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start
                      && $0.start >= segment.start && $0.end <= end }),
                  zip(words, words.dropFirst()).allSatisfy({ $0.start <= $1.start }) else {
                // Old transcripts have no word timing. Never invent text positions.
                return [label(segment, with: bestTurn(for: segment.start, end: end, turns: candidates),
                              turns: candidates)]
            }
            var output: [TranscriptionSegment] = []
            var group: [TranscriptionWord] = []
            var groupTurn: SpeakerTurn?
            var groupStart = segment.start
            @MainActor func close(at boundary: Double) {
                guard !group.isEmpty else { return }
                let part = TranscriptionSegment(start: groupStart, end: boundary,
                                                text: group.map(\.text).joined(), words: group)
                output.append(label(part, with: groupTurn, turns: candidates))
                group.removeAll()
                groupStart = boundary
            }
            for word in words {
                let turn = bestTurn(for: word.start, end: max(word.end, word.start + 0.01), turns: candidates)
                if !group.isEmpty, groupTurn.map(identity) != turn.map(identity), word.start > groupStart {
                    close(at: word.start)
                }
                if group.isEmpty { groupTurn = turn }
                group.append(word)
            }
            close(at: end)
            return output
        }
    }

    @MainActor
    private static func label(_ segment: TranscriptionSegment, with turn: SpeakerTurn?,
                              turns: [SpeakerTurn]) -> TranscriptionSegment {
        var updated = segment
        updated.diarizationLabel = turn?.label
        updated.speakerID = nil
        updated.speakerName = turn?.label
        updated.speakerColor = turn.map { SpeakerStats.stableColor(for: $0.label) }
        updated.speakerSampleRanges = []
        guard let turn else { return updated }
        if let id = turn.speakerID, let profile = SpeakerLibrary.speaker(id: id) {
            updated.speakerID = profile.id
            updated.speakerName = profile.name
            updated.speakerColor = profile.colorHex
        }
        updated.speakerSampleRanges = cleanRanges(start: segment.start, end: segment.end ?? segment.start,
                                                  speaker: turn, turns: turns)
        return updated
    }

    /// Only single-speaker regions can become voice references. Subtract crosstalk
    /// even if the word assignment had to choose one of the overlapping voices.
    static func cleanRanges(start: Double, end: Double, speaker: SpeakerTurn,
                            turns: [SpeakerTurn]) -> [SpeakerSampleRange] {
        let relevant = turns.filter { $0.end > start && $0.start < end }
        let boundaries = Set([start, end] + relevant.flatMap { [max(start, $0.start), min(end, $0.end)] }).sorted()
        var ranges: [SpeakerSampleRange] = []
        for (lower, upper) in zip(boundaries, boundaries.dropFirst()) where upper > lower {
            let active = relevant.filter { $0.start < upper && $0.end > lower }
            guard !active.isEmpty, active.allSatisfy({ identity($0) == identity(speaker) }) else { continue }
            if let last = ranges.last, last.end == lower {
                ranges[ranges.count - 1] = .init(start: last.start, end: upper)
            } else {
                ranges.append(.init(start: lower, end: upper))
            }
        }
        return ranges
    }
}
