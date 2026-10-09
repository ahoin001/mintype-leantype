import Foundation

/// What the search considered. Off unless a test or a debug sink asks for it.
struct DecodeTrace: Sendable {
    /// Where a known word was lost, given this trace.
    enum Loss: String, Sendable {
        /// The word was the reading that led.
        case none
        /// The word never entered the beam or the final list.
        case recall
        /// The word was a candidate and did not lead.
        case rank
        /// The decode was fine and the word was joined or split wrongly.
        case boundary
        /// A finger was treated as a tap or a stroke against the label.
        case classification
    }

    var aimedLetters: String = ""
    var beamWords: [String] = []
    var readings: [String] = []
    var recovered: Bool = false

    func loss(expecting word: String, joinedWrong: Bool = false, misclassified: Bool = false) -> Loss {
        if misclassified { return .classification }
        if joinedWrong { return .boundary }
        let key = word.lowercased()
        let seen = (beamWords + readings).contains { $0.lowercased() == key }
        if !seen { return .recall }
        if readings.first?.lowercased() == key { return .none }
        return .rank
    }
}

/// A box the search can fill without changing its return type. Nil at the call site
/// means the shipping keyboard records nothing.
final class DecodeTraceSink: @unchecked Sendable {
    var trace = DecodeTrace()
}
