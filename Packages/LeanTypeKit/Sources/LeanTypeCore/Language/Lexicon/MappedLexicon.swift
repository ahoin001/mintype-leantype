import Foundation

/// A read-only memory mapping of a file. Pages are loaded on demand and, being clean, can be
/// dropped by the system under memory pressure without counting against the extension's
/// dirty-memory budget.
final class MappedFile: @unchecked Sendable {
    // @unchecked: the mapping is PROT_READ and never mutated after init, so sharing the
    // pointer across threads is safe.
    let bytes: UnsafeRawBufferPointer

    init(url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let size = Int(info.st_size)
        guard let address = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0), address != MAP_FAILED else {
            throw CocoaError(.fileReadUnknown)
        }
        bytes = UnsafeRawBufferPointer(start: address, count: size)
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: bytes.baseAddress), bytes.count)
    }
}

/// The English word list, read in place from a memory-mapped `LexiconFormat` file.
///
/// Lookups never allocate except to build the strings they return. Thread-safe and
/// `Sendable`: the swipe decoder reads it off the main thread.
public final class MappedLexicon: Sendable {
    public let wordCount: Int
    /// Natural-log occurrence counts that frequency byte 0 and 255 stand for.
    let logCountRange: ClosedRange<Double>

    private let file: MappedFile
    private let keyOffsets: Int
    private let frequencies: Int
    private let keyBlob: Int
    private let displayIndex: Int
    private let displayCount: Int
    private let displayBlob: Int
    private let bucketOffsets: Int
    private let bucketEntries: Int

    public convenience init(url: URL) throws {
        try self.init(file: MappedFile(url: url))
    }

    /// The word list bundled with LeanType.
    public static func bundled() throws -> MappedLexicon {
        guard let url = Bundle.module.url(forResource: "lexicon", withExtension: "bin") else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return try MappedLexicon(url: url)
    }

    init(file: MappedFile) throws {
        self.file = file
        let bytes = file.bytes
        guard bytes.count >= LexiconFormat.headerSize else { throw LexiconFormat.Error.tooSmall }
        guard bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian == LexiconFormat.magic else {
            throw LexiconFormat.Error.badMagic
        }
        let version = bytes.loadUnaligned(fromByteOffset: 4, as: UInt16.self).littleEndian
        guard version == LexiconFormat.version else { throw LexiconFormat.Error.unsupportedVersion(version) }

        func header(_ offset: Int) -> Int {
            Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian)
        }
        wordCount = header(8)
        let keyBlobSize = header(12)
        displayCount = header(16)
        let displayBlobSize = header(20)
        let logMin = Double(Float(bitPattern: UInt32(header(24))))
        let logMax = Double(Float(bitPattern: UInt32(header(28))))
        logCountRange = logMin...max(logMin, logMax)

        keyOffsets = LexiconFormat.headerSize
        frequencies = keyOffsets + (wordCount + 1) * 4
        keyBlob = LexiconFormat.aligned(frequencies + wordCount)
        displayIndex = LexiconFormat.aligned(keyBlob + keyBlobSize)
        displayBlob = displayIndex + displayCount * 12
        bucketOffsets = LexiconFormat.aligned(displayBlob + displayBlobSize)
        bucketEntries = bucketOffsets + (LexiconFormat.bucketCount + 1) * 4
        guard bucketEntries + wordCount * 4 <= bytes.count else {
            throw LexiconFormat.Error.corrupt("sections exceed file size")
        }
    }

    // MARK: - Per-word access

    /// The lookup key of word `index`.
    public func key(at index: Int) -> UnsafeRawBufferPointer {
        let start = u32(keyOffsets, index)
        let end = u32(keyOffsets, index + 1)
        return UnsafeRawBufferPointer(rebasing: file.bytes[(keyBlob + start)..<(keyBlob + end)])
    }

    /// How the word is written ("don't", "I", "café"), which may differ from its key.
    public func display(at index: Int) -> String {
        if let range = displayRange(of: index) {
            return String(decoding: UnsafeRawBufferPointer(rebasing: file.bytes[range]), as: UTF8.self)
        }
        return String(decoding: key(at: index), as: UTF8.self)
    }

    /// Quantized frequency, 0 (rarest) to 255 (most common).
    public func frequency(at index: Int) -> UInt8 {
        file.bytes[frequencies + index]
    }

    /// Natural log of the word's occurrence count, reconstructed from its frequency byte.
    public func logCount(at index: Int) -> Double {
        logCountRange.lowerBound + Double(frequency(at: index)) / 255 * (logCountRange.upperBound - logCountRange.lowerBound)
    }

    // MARK: - Searching

    /// Indices of every word whose key is exactly `key`, most frequent first.
    public func indices(ofKey key: [UInt8]) -> Range<Int> {
        let lower = lowerBound(key, prefixOnly: false)
        var upper = lower
        while upper < wordCount, compare(upper, key, prefixOnly: false) == 0 {
            upper += 1
        }
        return lower..<upper
    }

    /// Indices of every word whose key starts with `prefix`, in key order.
    public func indices(withPrefix prefix: [UInt8]) -> Range<Int> {
        guard !prefix.isEmpty else { return 0..<wordCount }
        let lower = lowerBound(prefix, prefixOnly: true)
        var low = lower
        var high = wordCount
        while low < high {
            let mid = (low + high) / 2
            if compare(mid, prefix, prefixOnly: true) <= 0 { low = mid + 1 } else { high = mid }
        }
        return lower..<low
    }

    public func contains(_ word: some StringProtocol) -> Bool {
        let key = LexiconKey.make(word)
        return !key.isEmpty && !indices(ofKey: key).isEmpty
    }

    /// The most frequent words starting with `prefix`, best first.
    public func completions(prefix: [UInt8], limit: Int) -> [Int] {
        guard limit > 0 else { return [] }
        var best: [Int] = []
        best.reserveCapacity(limit + 1)
        for index in indices(withPrefix: prefix) {
            let frequency = frequency(at: index)
            if best.count == limit, let last = best.last, frequency <= self.frequency(at: last) { continue }
            let position = best.firstIndex { self.frequency(at: $0) < frequency } ?? best.count
            best.insert(index, at: position)
            if best.count > limit { best.removeLast() }
        }
        return best
    }

    /// Word indices whose keys start with `first` and end with `last`, most frequent first.
    public func bucket(first: UInt8, last: UInt8) -> UnsafeBufferPointer<UInt32> {
        let bucket = LexiconFormat.bucket(first: first, last: last)
        let start = u32(bucketOffsets, bucket)
        let end = u32(bucketOffsets, bucket + 1)
        let base = file.bytes.baseAddress!.advanced(by: bucketEntries + start * 4)
        return UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt32.self), count: end - start)
    }

    // MARK: - Private

    @inline(__always)
    private func u32(_ section: Int, _ index: Int) -> Int {
        Int(file.bytes.loadUnaligned(fromByteOffset: section + index * 4, as: UInt32.self).littleEndian)
    }

    private func displayRange(of index: Int) -> Range<Int>? {
        var low = 0
        var high = displayCount
        while low < high {
            let mid = (low + high) / 2
            let word = u32(displayIndex, mid * 3)
            if word == index {
                let offset = displayBlob + u32(displayIndex, mid * 3 + 1)
                return offset..<(offset + u32(displayIndex, mid * 3 + 2))
            }
            if word < index { low = mid + 1 } else { high = mid }
        }
        return nil
    }

    private func lowerBound(_ key: [UInt8], prefixOnly: Bool) -> Int {
        var low = 0
        var high = wordCount
        while low < high {
            let mid = (low + high) / 2
            if compare(mid, key, prefixOnly: prefixOnly) < 0 { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Compares word `index`'s key with `key`. With `prefixOnly`, only the first
    /// `key.count` bytes of the word's key take part.
    private func compare(_ index: Int, _ key: [UInt8], prefixOnly: Bool) -> Int {
        let word = self.key(at: index)
        let length = prefixOnly ? min(word.count, key.count) : word.count
        for offset in 0..<min(length, key.count) {
            let lhs = word[offset]
            let rhs = key[offset]
            if lhs != rhs { return lhs < rhs ? -1 : 1 }
        }
        if prefixOnly {
            return word.count < key.count ? -1 : 0
        }
        return word.count == key.count ? 0 : (word.count < key.count ? -1 : 1)
    }
}
