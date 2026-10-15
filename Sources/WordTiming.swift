import Foundation

/// Converts model tokens into linguistic words without losing UTF-8 fragments,
/// whitespace, punctuation, or the original text. Chinese uses native word breaking.
enum WordTiming {
    struct Token {
        let bytes: [UInt8]
        let start: Double
        let end: Double
    }

    static func words(tokens: [Token], text: String, trimmingWhitespace: Bool = false) -> [TranscriptionWord]? {
        let raw = String(decoding: tokens.flatMap(\.bytes), as: UTF8.self)
        let normalized = trimmingWhitespace ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : raw
        guard !tokens.isEmpty, normalized == text else { return nil }
        // Whitespace can occupy several tokens; trim the combined text rather
        // than just the first/last token, while retaining each token's byte span.
        let leadingBytes = trimmingWhitespace
            ? raw.utf8.count - raw.drop(while: { $0.isWhitespace }).utf8.count : 0
        var spans: [(range: Range<Int>, token: Token)] = []
        var offset = 0
        for token in tokens {
            spans.append(((offset - leadingBytes)..<(offset + token.bytes.count - leadingBytes), token))
            offset += token.bytes.count
        }
        var ranges: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, range, _, _ in
            ranges.append(range)
        }
        guard !ranges.isEmpty else { return nil }
        var words: [TranscriptionWord] = []
        for (index, range) in ranges.enumerated() {
            let lower = text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound)
            let upper = text.utf8.distance(from: text.utf8.startIndex, to: range.upperBound)
            let matches = spans.filter { $0.range.overlaps(lower..<upper) }.map(\.token)
            guard let start = matches.map(\.start).min(), let end = matches.map(\.end).max(),
                  start.isFinite, end.isFinite, start >= 0, end >= start else { return nil }
            let textStart = index == 0 ? text.startIndex : range.lowerBound
            let textEnd = index + 1 < ranges.count ? ranges[index + 1].lowerBound : text.endIndex
            words.append(.init(start: start, end: end, text: String(text[textStart..<textEnd])))
        }
        return words
    }
}
