import CoreGraphics

/// The words a swipe might be, best first, each with the score that ranked it.
public struct DecodeResult: Hashable, Sendable {
    public struct Reading: Hashable, Sendable {
        public let word: String
        /// Log-likelihood of the gesture plus the frequency prior. Higher is better.
        public let score: Double
    }

    /// How far ahead the top word must be before the keyboard treats it as the one to accept.
    public static let confidenceMargin = 0.35

    public let readings: [Reading]
    /// High means this beat is its own word. Low means it still belongs to the open word.
    /// Spelling confidence stays on `isUnsure`; the two are not the same decision.
    public let boundaryConfidence: Double
    /// The path moved on and this decode should take the previous preview down.
    public let withdrawsPreview: Bool

    public init(readings: [Reading], boundaryConfidence: Double = 1, withdrawsPreview: Bool = false) {
        self.readings = readings
        self.boundaryConfidence = boundaryConfidence
        self.withdrawsPreview = withdrawsPreview
    }

    func replacingReadings(_ readings: [Reading]) -> DecodeResult {
        DecodeResult(readings: readings, boundaryConfidence: boundaryConfidence, withdrawsPreview: withdrawsPreview)
    }

    public static let empty = DecodeResult(readings: [])

    public var words: [String] { readings.map(\.word) }
    public var isEmpty: Bool { readings.isEmpty }

    /// The top two readings are close enough that accepting the first would be a coin-flip.
    public var isUnsure: Bool {
        guard readings.count >= 2 else { return false }
        return readings[0].score - readings[1].score < Self.confidenceMargin
    }
}

/// Turns a swipe into words, SHARK²-style.
///
/// Candidates come from the lexicon's first-and-last-letter buckets around where the gesture
/// starts and ends, so only a few thousand words are ever looked at. Each candidate's ideal
/// path (key center to key center) is resampled to the same number of points as the gesture
/// and scored on two channels: *location* (how far the gesture is from the ideal path, in key
/// widths) and *shape* (the same comparison after both are centered and scaled, which
/// forgives a swipe drawn a little off to one side). A frequency prior breaks ties toward
/// common words.
///
/// Runs off the main thread; all scratch memory is allocated once per decoder.
actor PathDecoder {
    /// Candidates examined per first/last letter pair, most frequent first.
    /// Most-frequent-first. Common words sit at the front, so a shorter scan stays fast as the
    /// list grows; personal words are scored separately.
    static let bucketScanLimit = 180
    /// Letters considered for the start and end of the gesture.
    static let endpointLetters = 3
    static let endpointRadius: CGFloat = 1.25
    static let resultLimit = 4

    static let locationSigma: CGFloat = PathScore.locationSigma
    static let shapeSigma: CGFloat = PathScore.shapeSigma
    static let endpointSigma: CGFloat = PathScore.endpointSigma
    static let frequencyWeight = 0.22
    static let locationCutoff: CGFloat = PathScore.locationCutoff

    let lexicon: MappedLexicon

    /// Set when the last decode had to look past the most common words in a bucket.
    private(set) var scannedBeyondCommon = false

    private var scorer = PathScore()

    init(lexicon: MappedLexicon) {
        self.lexicon = lexicon
    }

    /// The most likely words for `gesture`, best first, with the scores that ranked them.
    func decode(_ gesture: SwipeGesture, layout: LetterLayout, personal: [PersonalLexicon.Entry]) -> DecodeResult {
        let state = Signposts.swipe.beginInterval("Decode")
        defer { Signposts.swipe.endInterval("Decode", state) }
        guard scorer.prepare(gesture.path, layout: layout) else { return .empty }

        let starts = layout.letters(near: scorer.start, within: Self.endpointRadius, limit: Self.endpointLetters)
        let ends = layout.letters(near: scorer.end, within: Self.endpointRadius, limit: Self.endpointLetters)
        var ranking = Ranking(limit: Self.resultLimit * 2)
        var bestLocation = CGFloat.greatestFiniteMagnitude
        scannedBeyondCommon = false

        let buckets = starts.flatMap { first in
            ends.map { last in lexicon.bucket(first: first, last: last) }
        }
        for bucket in buckets {
            consider(
                bucket,
                through: Self.bucketScanLimit,
                gateLength: !gesture.isMultiStroke,
                layout: layout,
                bestLocation: &bestLocation,
                ranking: &ranking
            )
        }
        // The common slice missed the finger. The rest of those buckets still gets a look.
        if bestLocation >= Self.locationCutoff {
            scannedBeyondCommon = true
            for bucket in buckets {
                consider(
                    bucket,
                    from: Self.bucketScanLimit,
                    gateLength: !gesture.isMultiStroke,
                    layout: layout,
                    bestLocation: &bestLocation,
                    ranking: &ranking
                )
            }
        }
        for (offset, entry) in personal.enumerated() {
            guard let first = entry.key.first, let last = entry.key.last,
                  starts.contains(first), ends.contains(last) else { continue }
            let prior = Self.frequencyWeight * entry.logCount
            let measured = scorer.measure(entry.key, mustExceed: ranking.threshold - prior, gateLength: !gesture.isMultiStroke, layout: layout)
            if let location = measured.location {
                bestLocation = min(bestLocation, location)
            }
            guard let fit = measured.score else { continue }
            ranking.insert(.personal(offset), score: fit + prior)
        }

        var seen = Set<String>()
        var readings: [DecodeResult.Reading] = []
        for entry in ranking.best {
            let word: String = switch entry.candidate {
            case let .dictionary(index): lexicon.display(at: index)
            case let .personal(offset): personal[offset].display
            }
            if seen.insert(word.lowercased()).inserted {
                readings.append(DecodeResult.Reading(word: word, score: entry.score))
            }
            if readings.count == Self.resultLimit { break }
        }
        return DecodeResult(readings: readings)
    }

    /// Scores `bucket[start..<end]`, keeping the closest location seen.
    private func consider(
        _ bucket: UnsafeBufferPointer<UInt32>,
        from start: Int = 0,
        through end: Int? = nil,
        gateLength: Bool,
        layout: LetterLayout,
        bestLocation: inout CGFloat,
        ranking: inout Ranking
    ) {
        let last = min(end ?? bucket.count, bucket.count)
        guard start < last else { return }
        for offset in start..<last {
            let index = Int(bucket[offset])
            let prior = Self.frequencyWeight * lexicon.logCount(at: index)
            let measured = scorer.measure(
                lexicon.key(at: index),
                mustExceed: ranking.threshold - prior,
                gateLength: gateLength,
                layout: layout
            )
            if let location = measured.location {
                bestLocation = min(bestLocation, location)
            }
            guard let fit = measured.score else { continue }
            ranking.insert(.dictionary(index), score: fit + prior)
        }
    }
}

/// A fixed-size list of the best-scoring candidates.
private struct Ranking {
    enum Candidate {
        case dictionary(Int)
        case personal(Int)
    }

    let limit: Int
    private(set) var entries: [(candidate: Candidate, score: Double)] = []

    init(limit: Int) {
        self.limit = limit
        entries.reserveCapacity(limit + 1)
    }

    var best: [(candidate: Candidate, score: Double)] { entries }

    /// The score a new candidate must beat to make the list.
    var threshold: Double {
        entries.count == limit ? entries[limit - 1].score : -.infinity
    }

    mutating func insert(_ candidate: Candidate, score: Double) {
        if entries.count == limit, let worst = entries.last, score <= worst.score { return }
        let position = entries.firstIndex { $0.score < score } ?? entries.count
        entries.insert((candidate, score), at: position)
        if entries.count > limit { entries.removeLast() }
    }
}
