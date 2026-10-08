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

    public init(readings: [Reading]) {
        self.readings = readings
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
    static let sampleCount = 32
    /// Candidates examined per first/last letter pair, most frequent first.
    /// Most-frequent-first. Common words sit at the front, so a shorter scan stays fast as the
    /// list grows; personal words are scored separately.
    static let bucketScanLimit = 180
    /// Letters considered for the start and end of the gesture.
    static let endpointLetters = 3
    static let endpointRadius: CGFloat = 1.25
    static let resultLimit = 4

    /// Scoring constants (location, shape, and endpoint spread in key widths; prior weight per
    /// log unit).
    static let locationSigma: CGFloat = 0.42
    static let shapeSigma: CGFloat = 0.3
    static let endpointSigma: CGFloat = 0.55
    static let frequencyWeight = 0.22
    /// Candidates with a mean distance beyond this (key widths) are discarded early.
    static let locationCutoff: CGFloat = 1.6

    let lexicon: MappedLexicon

    /// Set when the last decode had to look past the most common words in a bucket.
    private(set) var scannedBeyondCommon = false

    private var gesturePoints: [CGPoint]
    private var gestureShape: [CGPoint]
    private var idealPath: [CGPoint]
    private var idealPoints: [CGPoint]
    private var idealShape: [CGPoint]

    init(lexicon: MappedLexicon) {
        self.lexicon = lexicon
        gesturePoints = Array(repeating: .zero, count: Self.sampleCount)
        gestureShape = Array(repeating: .zero, count: Self.sampleCount)
        idealPath = []
        idealPath.reserveCapacity(32)
        idealPoints = Array(repeating: .zero, count: Self.sampleCount)
        idealShape = Array(repeating: .zero, count: Self.sampleCount)
    }

    /// The most likely words for `gesture`, best first, with the scores that ranked them.
    func decode(_ gesture: SwipeGesture, layout: LetterLayout, personal: [PersonalLexicon.Entry]) -> DecodeResult {
        let state = Signposts.swipe.beginInterval("Decode")
        defer { Signposts.swipe.endInterval("Decode", state) }
        guard gesture.path.count >= 2 else { return .empty }

        gesture.path.withUnsafeBufferPointer { path in
            gesturePoints.withUnsafeMutableBufferPointer { StrokeAnalyzer.resample(path, into: $0) }
        }
        normalize(gesturePoints, into: &gestureShape, layout: layout)
        let gestureLength = StrokeAnalyzer.length(of: gesture.path) / layout.keyWidth

        let starts = layout.letters(near: gesturePoints[0], within: Self.endpointRadius, limit: Self.endpointLetters)
        let ends = layout.letters(near: gesturePoints[Self.sampleCount - 1], within: Self.endpointRadius, limit: Self.endpointLetters)
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
                gestureLength: gestureLength,
                isMultiStroke: gesture.isMultiStroke,
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
                    gestureLength: gestureLength,
                    isMultiStroke: gesture.isMultiStroke,
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
            let measured = entry.key.withUnsafeBytes {
                measure($0, mustExceed: ranking.threshold - prior, gestureLength: gestureLength, isMultiStroke: gesture.isMultiStroke, layout: layout)
            }
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

    // MARK: - Scoring

    /// Log-likelihood of the gesture given `key`. `location` is the mean distance in key
    /// widths once the path is long enough to measure, even when that distance is too far to score.
    private func measure(
        _ key: UnsafeRawBufferPointer,
        mustExceed floor: Double,
        gestureLength: CGFloat,
        isMultiStroke: Bool,
        layout: LetterLayout
    ) -> (score: Double?, location: CGFloat?) {
        guard key.count >= 2 else { return (nil, nil) }

        // Where the finger lands and lifts is deliberate; a mean over the whole path would let
        // "help" beat "hello" for a swipe that ends dead on the o.
        let startMiss = layout.normalizedDistance(gesturePoints[0], layout.center(of: key[0]))
        let endMiss = layout.normalizedDistance(gesturePoints[Self.sampleCount - 1], layout.center(of: key[key.count - 1]))
        let endpointTerm = Double((startMiss * startMiss + endMiss * endMiss) / (2 * Self.endpointSigma * Self.endpointSigma))
        guard -endpointTerm > floor else { return (nil, nil) }

        idealPath.removeAll(keepingCapacity: true)
        for letter in key {
            let center = layout.center(of: letter)
            if idealPath.last != center {
                idealPath.append(center)
            }
        }
        guard idealPath.count >= 2 else { return (nil, nil) }

        if !isMultiStroke {
            // A swipe for "dictionary" isn't half a key long, and "on" isn't three rows.
            let idealLength = StrokeAnalyzer.length(of: idealPath) / layout.keyWidth
            let ratio = (gestureLength + 0.5) / (idealLength + 0.5)
            guard ratio > 0.45, ratio < 2.2 else { return (nil, nil) }
        }

        idealPath.withUnsafeBufferPointer { path in
            idealPoints.withUnsafeMutableBufferPointer { StrokeAnalyzer.resample(path, into: $0) }
        }

        var location: CGFloat = 0
        for index in 0..<Self.sampleCount {
            location += layout.normalizedDistance(gesturePoints[index], idealPoints[index])
        }
        location /= CGFloat(Self.sampleCount)
        guard location < Self.locationCutoff else { return (nil, location) }
        let locationTerm = Double(location * location / (2 * Self.locationSigma * Self.locationSigma))
        guard -(endpointTerm + locationTerm) > floor else { return (nil, location) }

        normalize(idealPoints, into: &idealShape, layout: layout)
        var shape: CGFloat = 0
        for index in 0..<Self.sampleCount {
            let dx = gestureShape[index].x - idealShape[index].x
            let dy = gestureShape[index].y - idealShape[index].y
            shape += (dx * dx + dy * dy).squareRoot()
        }
        shape /= CGFloat(Self.sampleCount)

        let shapeTerm = Double(shape * shape / (2 * Self.shapeSigma * Self.shapeSigma))
        return (-(endpointTerm + locationTerm + shapeTerm), location)
    }

    /// Scores `bucket[start..<end]`, keeping the closest location seen.
    private func consider(
        _ bucket: UnsafeBufferPointer<UInt32>,
        from start: Int = 0,
        through end: Int? = nil,
        gestureLength: CGFloat,
        isMultiStroke: Bool,
        layout: LetterLayout,
        bestLocation: inout CGFloat,
        ranking: inout Ranking
    ) {
        let last = min(end ?? bucket.count, bucket.count)
        guard start < last else { return }
        for offset in start..<last {
            let index = Int(bucket[offset])
            let prior = Self.frequencyWeight * lexicon.logCount(at: index)
            let measured = measure(
                lexicon.key(at: index),
                mustExceed: ranking.threshold - prior,
                gestureLength: gestureLength,
                isMultiStroke: isMultiStroke,
                layout: layout
            )
            if let location = measured.location {
                bestLocation = min(bestLocation, location)
            }
            guard let fit = measured.score else { continue }
            ranking.insert(.dictionary(index), score: fit + prior)
        }
    }

    /// Centers `points` on their centroid and scales by their larger extent (in key units), so
    /// only the shape remains. Tiny gestures keep a minimum scale so noise isn't magnified.
    private func normalize(_ points: [CGPoint], into output: inout [CGPoint], layout: LetterLayout) {
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        var sumX: CGFloat = 0, sumY: CGFloat = 0
        for point in points {
            let x = point.x / layout.keyWidth
            let y = point.y / layout.keyHeight
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            sumX += x; sumY += y
        }
        let count = CGFloat(points.count)
        let scale = max(maxX - minX, maxY - minY, 1)
        let centerX = sumX / count
        let centerY = sumY / count
        for (index, point) in points.enumerated() {
            output[index] = CGPoint(x: (point.x / layout.keyWidth - centerX) / scale, y: (point.y / layout.keyHeight - centerY) / scale)
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
