import CoreGraphics
import Foundation

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
