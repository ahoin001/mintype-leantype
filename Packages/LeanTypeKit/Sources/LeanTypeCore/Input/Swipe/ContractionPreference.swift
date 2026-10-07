import Foundation

/// Puts a contraction ahead of the same letters written without an apostrophe.
enum ContractionPreference {
    /// When the thumb ended on the apostrophe, a display that contains `'` leads the plain one.
    /// Otherwise the list stays in the order the decoder ranked it.
    static func apply(_ result: DecodeResult, prefersContraction: Bool) -> DecodeResult {
        guard prefersContraction, result.readings.count > 1 else { return result }
        var readings = result.readings
        var index = 0
        while index < readings.count {
            let plain = readings[index]
            guard !plain.word.contains("'") else {
                index += 1
                continue
            }
            let key = LexiconKey.make(plain.word)
            if let match = readings[(index + 1)...].firstIndex(where: { candidate in
                candidate.word.contains("'") && LexiconKey.make(candidate.word) == key
            }) {
                let contraction = readings.remove(at: match)
                readings.insert(contraction, at: index)
                index += 2
            } else {
                index += 1
            }
        }
        return DecodeResult(readings: readings)
    }
}
