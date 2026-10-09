import Foundation

/// A small bonus for a word the previous word tends to be followed by.
/// The bonus stays under `ReadingPolicy.exactLead`, so a decisive path still wins.
/// It is a score, not a required prefix and not a rank gate.
enum FollowerPrior {
    static let weight = 0.45

    static func bonus(for word: String, expected: [String]) -> Double {
        let key = word.lowercased()
        return expected.contains { $0.lowercased() == key } ? weight : 0
    }

    static func applying(_ readings: [DecodeResult.Reading], expected: [String]) -> [DecodeResult.Reading] {
        guard !expected.isEmpty else { return readings }
        return readings
            .map { reading in
                let bonus = bonus(for: reading.word, expected: expected)
                guard bonus > 0 else { return reading }
                return DecodeResult.Reading(word: reading.word, score: reading.score + bonus)
            }
            .sorted { $0.score > $1.score }
    }
}
