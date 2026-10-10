import CoreGraphics

/// How a word sits on the strokes that drew it.
///
/// One moving finger is measured against that polyline. A tapped letter is lifted out of the
/// word first, so the curve still separates the letters the finger actually drew. Two thumbs
/// are measured as sequential slices when each thumb owns a run of the word, and as an
/// interleaving when the thumbs trade letters. A word the strokes do not explain scores as a miss.
enum StrokeFit {
    /// Worse than any real fit, so a word off the strokes cannot outrank one they follow.
    static let miss = -8.0

    struct Thumb {
        var letters: [UInt8]
        var path: [CGPoint]
    }

    static func score(
        _ word: [UInt8],
        gesture: SwipeGesture,
        layout: LetterLayout,
        pathScore: inout PathScore
    ) -> Double {
        let taps = tapLetters(in: gesture)
        let thumbs = thumbs(in: gesture)
        if thumbs.count >= 2 {
            return bestStripped(word, taps: taps) { kept in
                multi(kept, thumbs: thumbs, layout: layout, pathScore: &pathScore)
            }
        }
        guard let path = movingPath(in: gesture, thumbs: thumbs) else { return 0 }
        return bestStripped(word, taps: taps) { kept in
            pathFit(kept, path: path, layout: layout, pathScore: &pathScore)
        }
    }

    // MARK: - Thumbs

    /// Anchors each moving thumb aimed at, in the order that thumb drew them.
    static func thumbs(in gesture: SwipeGesture) -> [Thumb] {
        var order: [Int] = []
        var letters: [Int: [UInt8]] = [:]
        for event in gesture.evidence.events where event.role == .anchor && event.strokeIndex >= 0 {
            guard let letter = event.letter.lowercased().utf8.first else { continue }
            if letters[event.strokeIndex] == nil {
                order.append(event.strokeIndex)
                letters[event.strokeIndex] = []
            }
            if letters[event.strokeIndex]?.last != letter {
                letters[event.strokeIndex]?.append(letter)
            }
        }
        return order.compactMap { index in
            guard gesture.strokePaths.indices.contains(index), gesture.strokePaths[index].count >= 2,
                  let aimed = letters[index], !aimed.isEmpty else { return nil }
            return Thumb(letters: aimed, path: gesture.strokePaths[index])
        }
    }

    /// Both thumbs followed their own aimed letters. One thumb off its path rejects the pair.
    static func anchorsFit(
        _ thumbs: [Thumb],
        layout: LetterLayout,
        pathScore: inout PathScore
    ) -> Double {
        guard !thumbs.isEmpty else { return 0 }
        var total = 0.0
        for thumb in thumbs {
            let fit = pathFit(thumb.letters, path: thumb.path, layout: layout, pathScore: &pathScore)
            guard fit < 0, fit > miss else { return miss }
            total += fit
        }
        return total / Double(thumbs.count)
    }

    // MARK: - Private

    private static func movingPath(in gesture: SwipeGesture, thumbs: [Thumb]) -> [CGPoint]? {
        if let path = thumbs.first?.path { return path }
        if let path = gesture.strokePaths.first(where: { $0.count >= 2 }) { return path }
        if gesture.path.count >= 2 { return gesture.path }
        return nil
    }

    private static func tapLetters(in gesture: SwipeGesture) -> [UInt8] {
        gesture.evidence.events.compactMap { event in
            guard event.isTap else { return nil }
            return event.letter.lowercased().utf8.first
        }
    }

    /// Tries each way of lifting the tapped letters out, and keeps the fit that actually measures.
    /// One or two taps stay a handful of attempts. Longer tap runs drop the letters from the left.
    private static func bestStripped(_ word: [UInt8], taps: [UInt8], score: ([UInt8]) -> Double) -> Double {
        guard !taps.isEmpty else { return score(word) }
        let attempts = removals(of: word, taps: taps)
        guard !attempts.isEmpty else { return score(word) }
        var best: Double?
        var unmeasured = false
        for kept in attempts {
            let fit = score(kept)
            if fit < 0, fit > miss {
                if best == nil || fit > best! { best = fit }
            } else if fit > miss {
                unmeasured = true
            }
        }
        if let best { return best }
        return unmeasured ? 0 : miss
    }

    private static func removals(of word: [UInt8], taps: [UInt8]) -> [[UInt8]] {
        if taps.count == 1 {
            return word.indices.compactMap { index in
                guard word[index] == taps[0] else { return nil }
                var kept = word
                kept.remove(at: index)
                return kept
            }
        }
        if taps.count == 2 {
            var attempts: [[UInt8]] = []
            for first in word.indices where word[first] == taps[0] {
                for second in word.indices where second > first && word[second] == taps[1] {
                    var kept: [UInt8] = []
                    kept.reserveCapacity(word.count - 2)
                    for index in word.indices where index != first && index != second {
                        kept.append(word[index])
                    }
                    attempts.append(kept)
                }
            }
            return attempts
        }
        return [stripLeftmost(word, taps: taps)]
    }

    private static func stripLeftmost(_ word: [UInt8], taps: [UInt8]) -> [UInt8] {
        var kept: [UInt8] = []
        kept.reserveCapacity(word.count)
        var tap = 0
        for letter in word {
            if tap < taps.count, letter == taps[tap] {
                tap += 1
                continue
            }
            kept.append(letter)
        }
        return kept
    }

    private static func multi(
        _ word: [UInt8],
        thumbs: [Thumb],
        layout: LetterLayout,
        pathScore: inout PathScore
    ) -> Double {
        if let parts = slices(of: word, thumbs: thumbs) {
            return combined(parts, thumbs: thumbs, layout: layout, pathScore: &pathScore)
        }
        guard let parts = interleaved(word, thumbs: thumbs) else { return miss }
        var total = 0.0
        var counted = 0
        for (slice, thumb) in parts {
            let fit = pathFit(slice, path: thumb.path, layout: layout, pathScore: &pathScore)
            guard fit < 0, fit > miss else { return miss }
            total += fit
            counted += 1
        }
        guard counted > 0 else { return 0 }
        return total / Double(counted)
    }

    /// One slice per thumb, in thumb order. The last thumb keeps the rest of the word.
    private static func slices(of word: [UInt8], thumbs: [Thumb]) -> [[UInt8]]? {
        var cursor = 0
        var result: [[UInt8]] = []
        result.reserveCapacity(thumbs.count)
        for (index, thumb) in thumbs.enumerated() {
            if index == thumbs.count - 1 {
                guard cursor < word.count else { return nil }
                let rest = Array(word[cursor...])
                guard matchEnd(thumb.letters, in: rest, from: 0) != nil else { return nil }
                result.append(rest)
            } else {
                guard let end = matchEnd(thumb.letters, in: word, from: cursor) else { return nil }
                result.append(Array(word[cursor...end]))
                cursor = end + 1
            }
        }
        return result
    }

    private static func matchEnd(_ letters: [UInt8], in word: [UInt8], from start: Int) -> Int? {
        guard start <= word.count else { return nil }
        var cursor = start
        var last = start - 1
        for letter in letters {
            guard cursor < word.count, let found = word[cursor...].firstIndex(of: letter) else { return nil }
            last = found
            cursor = found + 1
        }
        guard last >= start else { return nil }
        return last
    }

    /// Letters of an interleaved word, grouped onto the thumb that aimed at them.
    /// Nil when either thumb's anchors are not in the word.
    private static func interleaved(_ word: [UInt8], thumbs: [Thumb]) -> [([UInt8], Thumb)]? {
        guard !word.isEmpty else { return nil }
        var used = Array(repeating: false, count: word.count)
        var anchors: [[Int]] = []
        anchors.reserveCapacity(thumbs.count)
        for thumb in thumbs {
            var indexes: [Int] = []
            var cursor = 0
            for letter in thumb.letters {
                guard let found = (cursor..<word.count).first(where: { !used[$0] && word[$0] == letter }) else { return nil }
                used[found] = true
                indexes.append(found)
                cursor = found + 1
            }
            guard !indexes.isEmpty else { return nil }
            anchors.append(indexes)
        }
        guard spansOverlap(anchors) else { return nil }
        var owners = Array(repeating: 0, count: word.count)
        for (thumb, indexes) in anchors.enumerated() {
            for index in indexes { owners[index] = thumb }
        }
        for index in word.indices where !used[index] {
            owners[index] = nearestThumb(index, anchors: anchors)
        }
        var parts = thumbs.map { _ in [UInt8]() }
        for index in word.indices {
            parts[owners[index]].append(word[index])
        }
        return zip(parts, thumbs).map { ($0, $1) }
    }

    /// The thumbs trade letters through the word. Two blocks, one after the other, are a split
    /// and are scored by `slices` instead. A reversed split is not an interleaving.
    private static func spansOverlap(_ anchors: [[Int]]) -> Bool {
        for left in 0..<anchors.count {
            for right in (left + 1)..<anchors.count {
                guard let a0 = anchors[left].first, let a1 = anchors[left].last,
                      let b0 = anchors[right].first, let b1 = anchors[right].last else { continue }
                if a0 <= b1, b0 <= a1 { return true }
            }
        }
        return false
    }

    private static func nearestThumb(_ index: Int, anchors: [[Int]]) -> Int {
        var bestThumb = 0
        var bestDistance = Int.max
        for (thumb, indexes) in anchors.enumerated() {
            guard let first = indexes.first, let last = indexes.last else { continue }
            let distance = index < first ? first - index : (index > last ? index - last : 0)
            if distance < bestDistance {
                bestDistance = distance
                bestThumb = thumb
            }
        }
        return bestThumb
    }

    private static func combined(
        _ parts: [[UInt8]],
        thumbs: [Thumb],
        layout: LetterLayout,
        pathScore: inout PathScore
    ) -> Double {
        var total = 0.0
        var counted = 0
        for (thumb, slice) in zip(thumbs, parts) {
            let fit = pathFit(slice, path: thumb.path, layout: layout, pathScore: &pathScore)
            if fit != 0 || slice.count >= 2 {
                total += fit
                counted += 1
            }
        }
        guard counted > 0 else { return 0 }
        return total / Double(counted)
    }

    private static func pathFit(
        _ letters: [UInt8],
        path: [CGPoint],
        layout: LetterLayout,
        pathScore: inout PathScore
    ) -> Double {
        guard letters.count >= 2, pathScore.prepare(path, layout: layout) else { return 0 }
        if let fit = pathScore.measure(letters, mustExceed: -.infinity, gateLength: false, layout: layout).score {
            return fit
        }
        return miss
    }
}
