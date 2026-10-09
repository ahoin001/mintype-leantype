import CoreGraphics
import Foundation

/// One curve this user has already claimed for a word.
public struct StrokePrototype: Codable, Hashable, Sendable {
    public var word: String
    public var samples: [StrokeSample]
    public var uses: Int
    public var lastUsed: Date

    public init(word: String, samples: [StrokeSample], uses: Int = 1, lastUsed: Date) {
        self.word = word
        self.samples = samples
        self.uses = uses
        self.lastUsed = lastUsed
    }
}

/// A point on a remembered curve, in key widths, so a rotation does not invalidate it.
public struct StrokeSample: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    var point: CGPoint { CGPoint(x: x, y: y) }
}

/// Where remembered curves are kept. A nil file means they last for this session.
public protocol StrokeStore: Sendable {
    func load() -> [StrokePrototype]
    func save(_ prototypes: [StrokePrototype])
}

/// `StrokePrototypes.json` in the App Group, beside habits and word pairs.
public struct AppGroupStrokeStore: StrokeStore {
    private let file: CodableFileStore<[StrokePrototype]>

    public init(fileName: String = "StrokePrototypes.json") {
        file = CodableFileStore { LearningDirectory.fileURL(named: fileName) }
    }

    public func load() -> [StrokePrototype] {
        file.load() ?? []
    }

    public func save(_ prototypes: [StrokePrototype]) {
        file.save(prototypes)
    }
}

/// The curves behind corrections. Picking a word remembers the stroke that missed it,
/// and a later stroke that follows that curve lets the word lead.
@MainActor
final class StrokeMemory {
    static let capacity = 160
    static let sampleCount = 16
    /// Closer than this, in key widths, the remembered curve explains the finger.
    static let matchDistance: CGFloat = 0.42

    private var prototypes: [StrokePrototype]
    private let store: (any StrokeStore)?
    private var scratch = Array(repeating: CGPoint.zero, count: sampleCount)

    init(store: (any StrokeStore)? = nil) {
        self.store = store
        prototypes = store?.load() ?? []
    }

    /// `path` is what the finger drew when the user chose `word` instead.
    func remember(_ word: String, path: [CGPoint], layout: LetterLayout) {
        let word = word.lowercased()
        guard word.count >= 2, let samples = samples(of: path, layout: layout) else { return }
        if let index = prototypes.firstIndex(where: { $0.word == word }) {
            prototypes[index].samples = samples
            prototypes[index].uses += 1
            prototypes[index].lastUsed = .now
        } else {
            prototypes.append(StrokePrototype(word: word, samples: samples, lastUsed: .now))
        }
        if prototypes.count > Self.capacity {
            prototypes.sort { $0.lastUsed > $1.lastUsed }
            prototypes.removeLast(prototypes.count - Self.capacity)
        }
        store?.save(prototypes)
    }

    /// Drops the curve stored for `word`. Other curves stay.
    func forget(_ word: String) {
        let word = word.lowercased()
        let before = prototypes.count
        prototypes.removeAll { $0.word == word }
        if prototypes.count != before {
            store?.save(prototypes)
        }
    }

    /// Moves a remembered word first when this finger repeats its curve, far enough ahead
    /// that an aligned graze cannot take the place back.
    func applying(to result: DecodeResult, path: [CGPoint], layout: LetterLayout) -> DecodeResult {
        guard path.count >= 2, let drawn = samples(of: path, layout: layout) else { return result }
        let drawnPoints = drawn.map(\.point)
        var best: (word: String, distance: CGFloat)?
        for prototype in prototypes {
            let distance = Self.distance(drawnPoints, prototype.samples.map(\.point))
            guard distance < Self.matchDistance else { continue }
            if let current = best, distance >= current.distance { continue }
            best = (prototype.word, distance)
        }
        guard let best else { return result }
        guard let leader = result.readings.first, best.word != leader.word.lowercased() else { return result }
        var readings = result.readings
        let score = leader.score + ReadingPolicy.exactLead + 0.01
        if let index = readings.firstIndex(where: { $0.word.compare(best.word, options: .caseInsensitive) == .orderedSame }) {
            readings[index] = DecodeResult.Reading(word: readings[index].word, score: score)
        } else {
            readings.append(DecodeResult.Reading(word: best.word, score: score))
        }
        readings.sort { $0.score > $1.score }
        return result.replacingReadings(readings)
    }

    // MARK: - Private

    private func samples(of path: [CGPoint], layout: LetterLayout) -> [StrokeSample]? {
        guard path.count >= 2 else { return nil }
        path.withUnsafeBufferPointer { source in
            scratch.withUnsafeMutableBufferPointer { StrokeAnalyzer.resample(source, into: $0) }
        }
        return scratch.map { point in
            StrokeSample(
                x: Double(point.x / layout.keyWidth),
                y: Double(point.y / layout.keyHeight)
            )
        }
    }

    /// Mean distance of a short monotonic alignment, in the same units as the stored samples.
    private static func distance(_ drawn: [CGPoint], _ remembered: [CGPoint]) -> CGFloat {
        let count = min(drawn.count, remembered.count)
        guard count > 1 else { return .greatestFiniteMagnitude }
        let radius = 3
        var previous = Array(repeating: CGFloat.greatestFiniteMagnitude / 4, count: count)
        var current = previous
        previous[0] = hypot(drawn[0].x - remembered[0].x, drawn[0].y - remembered[0].y)
        for row in 1..<count {
            for index in 0..<count { current[index] = CGFloat.greatestFiniteMagnitude / 4 }
            let lower = max(0, row - radius)
            let upper = min(count - 1, row + radius)
            for column in lower...upper {
                let step = hypot(drawn[row].x - remembered[column].x, drawn[row].y - remembered[column].y)
                var best = previous[column]
                if column > 0 {
                    best = min(best, previous[column - 1])
                    best = min(best, current[column - 1])
                }
                current[column] = best + step
            }
            swap(&previous, &current)
        }
        return previous[count - 1] / CGFloat(count)
    }
}
