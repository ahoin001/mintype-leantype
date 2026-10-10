import CoreGraphics
import Foundation

/// Mean touch error per thumb, as a fraction of a key, capped so a bad log cannot move the aim by a whole key.
struct TouchBias: Equatable, Sendable {
    var left = CGVector.zero
    var right = CGVector.zero

    static let fractionCap: CGFloat = 0.2

    static func summarizing(_ samples: [TouchOffsetLog.Sample]) -> TouchBias {
        var leftX = 0.0
        var leftY = 0.0
        var leftCount = 0
        var rightX = 0.0
        var rightY = 0.0
        var rightCount = 0
        for sample in samples {
            if sample.side == "left" {
                leftX += sample.dx
                leftY += sample.dy
                leftCount += 1
            } else {
                rightX += sample.dx
                rightY += sample.dy
                rightCount += 1
            }
        }
        return TouchBias(
            left: mean(leftX, leftY, count: leftCount),
            right: mean(rightX, rightY, count: rightCount)
        )
    }

    /// The recent log, or zero when there is nothing to read. Called off the touch-move path.
    static func load(sampleLimit: Int = 256) -> TouchBias {
        guard let url = LearningDirectory.fileURL(named: "touch-offsets.jsonl"),
              let data = try? Data(contentsOf: url), !data.isEmpty
        else { return TouchBias() }
        let truncated = data.count > 65_536
        let tail = truncated ? Data(data.suffix(65_536)) : data
        let text = String(decoding: tail, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if truncated, !lines.isEmpty { lines.removeFirst() }
        var samples: [TouchOffsetLog.Sample] = []
        samples.reserveCapacity(min(sampleLimit, 256))
        for line in lines.reversed() {
            guard let decoded = try? JSONDecoder().decode([TouchOffsetLog.Sample].self, from: Data(line.utf8)) else { continue }
            for sample in decoded.reversed() {
                samples.append(sample)
                if samples.count >= sampleLimit { return summarizing(samples) }
            }
        }
        return summarizing(samples)
    }

    /// The shift to subtract from a touch so it moves back toward the key the finger meant.
    func offset(thumb: Int, keyWidth: CGFloat, keyHeight: CGFloat) -> CGVector {
        let fraction = thumb == 0 ? left : right
        return CGVector(dx: fraction.dx * keyWidth, dy: fraction.dy * keyHeight)
    }

    private static func mean(_ dx: Double, _ dy: Double, count: Int) -> CGVector {
        guard count > 0 else { return .zero }
        return CGVector(
            dx: capped(dx / Double(count)),
            dy: capped(dy / Double(count))
        )
    }

    private static func capped(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, -Double(fractionCap)), Double(fractionCap)))
    }
}

/// How far an accepted touch sat from the key it was meant for, per side of the keyboard.
/// Appended after a committed word. The ranker does not read this file.
enum TouchOffsetLog {
    struct Sample: Codable, Equatable {
        var side: String
        var dx: Double
        var dy: Double
    }

    static func samples(letters: [String], points: [CGPoint], layout: LetterLayout) -> [Sample] {
        guard letters.count == points.count else { return [] }
        let width = max(layout.keyWidth, 1)
        let height = max(layout.keyHeight, 1)
        var samples: [Sample] = []
        for (letter, point) in zip(letters, points) {
            guard let byte = letter.lowercased().utf8.first else { continue }
            let center = layout.center(of: byte)
            let side = point.x < layout.handMidline ? "left" : "right"
            samples.append(Sample(
                side: side,
                dx: Double((point.x - center.x) / width),
                dy: Double((point.y - center.y) / height)
            ))
        }
        return samples
    }

    static func record(letters: [String], points: [CGPoint], layout: LetterLayout) {
        let samples = samples(letters: letters, points: points, layout: layout)
        guard !samples.isEmpty,
              let url = LearningDirectory.fileURL(named: "touch-offsets.jsonl"),
              let data = try? JSONEncoder().encode(samples)
        else { return }
        append(data, to: url)
    }

    private static func append(_ data: Data, to url: URL) {
        var line = data
        line.append(UInt8(ascii: "\n"))
        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }
}

/// How often a decode ran out of time, by the shape of the gesture. Local only. Nothing is uploaded.
enum ClockExpiryLog {
    static func note(_ gesture: SwipeGesture) {
        let kind = switch gesture.strokeCount {
        case 0: "tap-only"
        case 1: "one-stroke"
        default: "two-thumb"
        }
        guard let url = LearningDirectory.fileURL(named: "clock-expirations.jsonl") else { return }
        var line = Data(kind.utf8)
        line.append(UInt8(ascii: "\n"))
        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }
}

/// A full decode trace. Written only when gesture traces are turned on. Nothing is uploaded.
enum GestureTraceLog {
    struct Record: Codable {
        var aimed: String
        var beam: [String]
        var readings: [String]
        var recovered: Bool
    }

    static func append(_ trace: DecodeTrace) {
        guard let url = LearningDirectory.fileURL(named: "gesture-traces.jsonl") else { return }
        let record = Record(aimed: trace.aimedLetters, beam: trace.beamWords, readings: trace.readings, recovered: trace.recovered)
        guard let data = try? JSONEncoder().encode(record) else { return }
        var line = data
        line.append(UInt8(ascii: "\n"))
        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }
}
