import Foundation

/// The lookup form of a word: lowercase ASCII letters only. Accents fold away and apostrophes
/// vanish, so typing or swiping "cafe" finds "café" and "dont" finds "don't".
public enum LexiconKey {
    public static let firstLetter = UInt8(ascii: "a")
    public static let letterCount = 26

    /// The key for `word`, or an empty array if it has no letters.
    public static func make(_ word: some StringProtocol) -> [UInt8] {
        var key: [UInt8] = []
        key.reserveCapacity(word.utf8.count)
        // Fast path: plain ASCII needs no Unicode folding.
        if word.utf8.allSatisfy({ $0 < 0x80 }) {
            for byte in word.utf8 {
                if let letter = letter(forASCII: byte) { key.append(letter) }
            }
            return key
        }
        let folded = String(word).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
        for byte in folded.utf8 {
            if let letter = letter(forASCII: byte) { key.append(letter) }
        }
        return key
    }

    /// Index 0-25 for a key byte.
    @inline(__always)
    public static func index(of letter: UInt8) -> Int {
        Int(letter &- firstLetter)
    }

    @inline(__always)
    private static func letter(forASCII byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): byte
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): byte + 32
        default: nil
        }
    }
}
