import Foundation

/// The on-disk word list: one flat, little-endian file designed to be memory-mapped and read
/// in place, so the keyboard never copies it into its own (dirty) memory.
///
/// Layout, every section 4-byte aligned:
/// - Header (`headerSize` bytes): magic, version, counts, and the log-count range that
///   frequencies are quantized over.
/// - `keyOffsets`: `wordCount + 1` UInt32 offsets into `keyBlob`.
/// - `frequencies`: one UInt8 per word, the log count quantized to 0...255.
/// - `keyBlob`: the lookup keys (`LexiconKey`), sorted bytewise; equal keys are adjacent,
///   most frequent first.
/// - `displayIndex`: sparse (wordIndex, offset, length) UInt32 triples, sorted by word, for
///   words whose display form differs from their key ("don't", "I", "café").
/// - `displayBlob`: UTF-8 display forms.
/// - `bucketOffsets`: 26 × 26 + 1 UInt32 offsets into `bucketEntries`.
/// - `bucketEntries`: word indices grouped by (first letter, last letter), most frequent first.
///   This is what swipe decoding scans.
public enum LexiconFormat {
    public static let magic: UInt32 = 0x584C_544C // "LTLX"
    public static let version: UInt16 = 1
    public static let headerSize = 32
    public static let bucketCount = LexiconKey.letterCount * LexiconKey.letterCount

    /// One word to write.
    public struct Entry: Hashable, Sendable {
        public let display: String
        public let count: UInt64

        public init(display: String, count: UInt64) {
            self.display = display
            self.count = count
        }
    }

    public enum Error: Swift.Error, Equatable {
        case tooSmall
        case badMagic
        case unsupportedVersion(UInt16)
        case corrupt(String)
    }

    /// Serializes `entries`. Words without letters are skipped; duplicates by display keep
    /// the larger count.
    public static func write(_ entries: [Entry]) -> Data {
        var unique: [String: UInt64] = [:]
        for entry in entries where entry.count > 0 {
            unique[entry.display] = max(unique[entry.display] ?? 0, entry.count)
        }
        let words = unique.compactMap { display, count -> (key: [UInt8], display: String, count: UInt64)? in
            let key = LexiconKey.make(display)
            return key.isEmpty ? nil : (key, display, count)
        }
        .sorted { lhs, rhs in
            if lhs.key != rhs.key { return lhs.key.lexicographicallyPrecedes(rhs.key) }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.display < rhs.display
        }

        let counts = words.map { Double($0.count) }
        let logMin = Float(log(counts.min() ?? 1))
        let logMax = Float(log(counts.max() ?? 1))
        let span = max(logMax - logMin, .ulpOfOne)

        var keyOffsets: [UInt32] = [0]
        var keyBlob: [UInt8] = []
        var frequencies: [UInt8] = []
        var displayIndex: [UInt32] = []
        var displayBlob: [UInt8] = []
        for (index, word) in words.enumerated() {
            keyBlob.append(contentsOf: word.key)
            keyOffsets.append(UInt32(keyBlob.count))
            let normalized = (Float(log(Double(word.count))) - logMin) / span
            frequencies.append(UInt8((normalized * 255).rounded()))
            if Array(word.display.utf8) != word.key {
                let bytes = Array(word.display.utf8)
                displayIndex.append(contentsOf: [UInt32(index), UInt32(displayBlob.count), UInt32(bytes.count)])
                displayBlob.append(contentsOf: bytes)
            }
        }

        var buckets = [[UInt32]](repeating: [], count: bucketCount)
        for (index, word) in words.enumerated() {
            buckets[bucket(first: word.key[0], last: word.key[word.key.count - 1])].append(UInt32(index))
        }
        var bucketOffsets: [UInt32] = [0]
        var bucketEntries: [UInt32] = []
        for var bucket in buckets {
            bucket.sort { frequencies[Int($0)] > frequencies[Int($1)] }
            bucketEntries.append(contentsOf: bucket)
            bucketOffsets.append(UInt32(bucketEntries.count))
        }

        var data = Data()
        data.appendLittleEndian(magic)
        data.appendLittleEndian(version)
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt32(words.count))
        data.appendLittleEndian(UInt32(keyBlob.count))
        data.appendLittleEndian(UInt32(displayIndex.count / 3))
        data.appendLittleEndian(UInt32(displayBlob.count))
        data.appendLittleEndian(logMin.bitPattern)
        data.appendLittleEndian(logMax.bitPattern)
        precondition(data.count == headerSize)

        keyOffsets.forEach { data.appendLittleEndian($0) }
        data.append(contentsOf: frequencies)
        data.padToFourBytes()
        data.append(contentsOf: keyBlob)
        data.padToFourBytes()
        displayIndex.forEach { data.appendLittleEndian($0) }
        data.append(contentsOf: displayBlob)
        data.padToFourBytes()
        bucketOffsets.forEach { data.appendLittleEndian($0) }
        bucketEntries.forEach { data.appendLittleEndian($0) }
        return data
    }

    @inline(__always)
    static func bucket(first: UInt8, last: UInt8) -> Int {
        LexiconKey.index(of: first) * LexiconKey.letterCount + LexiconKey.index(of: last)
    }

    static func aligned(_ value: Int) -> Int {
        (value + 3) & ~3
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func padToFourBytes() {
        while count % 4 != 0 { append(0) }
    }
}
