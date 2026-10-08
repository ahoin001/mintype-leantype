import CoreGraphics

/// Reorders sequence readings so a word has to agree with every thumb that moved.
///
/// The sequence still supplies the words. This does not search the dictionary. Each moving
/// thumb keeps its own polyline, and a reading leads only when those polylines sit on the
/// letters that thumb aimed at. A word that skips a thumb loses to one that uses them all.
/// Among words that fit, path distance breaks a close sequence score and nothing wider.
enum ThumbFit {
    /// Mean distance, in key widths, past which a thumb's path is not on its letters.
    static let strayDistance: CGFloat = 1.6
    private static let sampleCount = 8

    static func adjust(
        _ result: DecodeResult,
        observations: [StrokeObservation],
        strokePaths: [[CGPoint]],
        layout: LetterLayout
    ) -> DecodeResult {
        let thumbs = movingThumbs(observations: observations, paths: strokePaths)
        guard thumbs.count > 1, result.readings.count > 1 else { return result }

        let scored = result.readings.map { reading in
            (reading: reading, fit: assess(reading.word, thumbs: thumbs, layout: layout))
        }
        let fitting = scored.filter(\.fit.fitsAll)
        guard let leader = fitting.max(by: { $0.reading.score < $1.reading.score }) else { return result }

        var winner = leader
        for candidate in fitting {
            let gap = leader.reading.score - candidate.reading.score
            guard gap <= DecodeResult.confidenceMargin else { continue }
            let winnerNet = winner.reading.score - winner.fit.penalty
            let candidateNet = candidate.reading.score - candidate.fit.penalty
            if candidateNet > winnerNet {
                winner = candidate
            }
        }
        guard winner.reading.word != result.readings[0].word else { return result }
        var readings = result.readings.filter { $0.word != winner.reading.word }
        readings.insert(
            DecodeResult.Reading(word: winner.reading.word, score: result.readings[0].score + 0.01),
            at: 0
        )
        return DecodeResult(readings: readings)
    }

    // MARK: - Private

    private struct Thumb {
        var letters: [UInt8]
        var path: [CGPoint]
    }

    private struct Assessment {
        var fitsAll: Bool
        var penalty: Double
    }

    private static func movingThumbs(observations: [StrokeObservation], paths: [[CGPoint]]) -> [Thumb] {
        var order: [Int] = []
        var letters: [Int: [UInt8]] = [:]
        for observation in observations where !observation.isTap && observation.strokeIndex >= 0 {
            guard let letter = LexiconKey.make(observation.letter).first else { continue }
            if letters[observation.strokeIndex] == nil {
                order.append(observation.strokeIndex)
                letters[observation.strokeIndex] = []
            }
            if letters[observation.strokeIndex]?.last != letter {
                letters[observation.strokeIndex]?.append(letter)
            }
        }
        return order.compactMap { index in
            guard paths.indices.contains(index), paths[index].count >= 2,
                  let aimed = letters[index], !aimed.isEmpty else { return nil }
            return Thumb(letters: aimed, path: paths[index])
        }
    }

    private static func assess(_ word: String, thumbs: [Thumb], layout: LetterLayout) -> Assessment {
        let letters = LexiconKey.make(word)
        guard let chunks = chunks(of: letters, thumbs: thumbs) else {
            return Assessment(fitsAll: false, penalty: 100)
        }
        var fitsAll = true
        var penalty = 0.0
        for (thumb, chunk) in zip(thumbs, chunks) {
            let aimed = pathDistance(thumb.path, letters: thumb.letters, layout: layout)
            if aimed > strayDistance { fitsAll = false }
            penalty += Double(pathDistance(thumb.path, letters: chunk, layout: layout))
        }
        return Assessment(fitsAll: fitsAll, penalty: penalty / Double(thumbs.count))
    }

    /// One chunk per thumb, in order. Each chunk holds that thumb's aimed letters.
    /// The last thumb also keeps whatever letters remain, so a longer word has to be drawn.
    private static func chunks(of word: [UInt8], thumbs: [Thumb]) -> [[UInt8]]? {
        var cursor = 0
        var result: [[UInt8]] = []
        for (index, thumb) in thumbs.enumerated() {
            if index == thumbs.count - 1 {
                guard cursor < word.count else { return nil }
                let rest = Array(word[cursor...])
                guard endOfMatch(thumb.letters, in: rest, from: 0) != nil else { return nil }
                result.append(rest)
            } else {
                guard let end = endOfMatch(thumb.letters, in: word, from: cursor) else { return nil }
                result.append(Array(word[cursor...end]))
                cursor = end + 1
            }
        }
        return result
    }

    /// Index of the last aimed letter, matched in order from `start`.
    private static func endOfMatch(_ letters: [UInt8], in word: [UInt8], from start: Int) -> Int? {
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

    /// Mean distance, in key widths, between the finger and the key centers of `letters`.
    private static func pathDistance(_ path: [CGPoint], letters: [UInt8], layout: LetterLayout) -> CGFloat {
        var ideal: [CGPoint] = []
        ideal.reserveCapacity(letters.count)
        for letter in letters {
            let center = layout.center(of: letter)
            if ideal.last != center { ideal.append(center) }
        }
        guard !ideal.isEmpty, !path.isEmpty else { return .greatestFiniteMagnitude }
        var samples = [CGPoint](repeating: .zero, count: sampleCount)
        var targets = [CGPoint](repeating: .zero, count: sampleCount)
        path.withUnsafeBufferPointer { source in
            samples.withUnsafeMutableBufferPointer { StrokeAnalyzer.resample(source, into: $0) }
        }
        ideal.withUnsafeBufferPointer { source in
            targets.withUnsafeMutableBufferPointer { StrokeAnalyzer.resample(source, into: $0) }
        }
        var total: CGFloat = 0
        for index in 0..<sampleCount {
            total += layout.normalizedDistance(samples[index], targets[index])
        }
        return total / CGFloat(sampleCount)
    }
}
