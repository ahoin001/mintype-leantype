import Foundation

/// One correction the user undid: do not replace `preferred` with `rejected` again.
public struct RejectedCorrection: Codable, Hashable, Sendable {
    public var preferred: String
    public var rejected: String
    public var lastUsed: Date

    public init(preferred: String, rejected: String, lastUsed: Date) {
        self.preferred = preferred
        self.rejected = rejected
        self.lastUsed = lastUsed
    }
}

/// Where rejected corrections are kept. A nil file URL (no Full Access) means the list lasts
/// only for this session.
public protocol RejectionStore: Sendable {
    func load() -> [RejectedCorrection]
    func save(_ entries: [RejectedCorrection])
}

/// `RejectedCorrections.json` in the App Group, same home as learned words.
public struct AppGroupRejectionStore: RejectionStore {
    private let file: CodableFileStore<[RejectedCorrection]>

    public init(fileName: String = "RejectedCorrections.json") {
        file = CodableFileStore { SharedContainer.fileURL(named: fileName) }
    }

    public func load() -> [RejectedCorrection] {
        file.load() ?? []
    }

    public func save(_ entries: [RejectedCorrection]) {
        file.save(entries)
    }
}

/// A short memory of corrections the user refused. Newest uses stay; the least recent drop
/// once the list is full. Matching is case-insensitive.
@MainActor
final class RejectionMemory {
    static let capacity = 200

    private var entries: [RejectedCorrection]
    private let store: (any RejectionStore)?

    init(store: (any RejectionStore)? = nil) {
        self.store = store
        entries = store?.load() ?? []
        if entries.count > Self.capacity {
            trim()
        }
    }

    func rejects(replacing preferred: String, with rejected: String) -> Bool {
        let preferred = preferred.lowercased()
        let rejected = rejected.lowercased()
        return entries.contains { $0.preferred == preferred && $0.rejected == rejected }
    }

    /// Drops every "keep this spelling" note for `preferred`.
    func forget(preferred: String) {
        let preferred = preferred.lowercased()
        let before = entries.count
        entries.removeAll { $0.preferred == preferred }
        if entries.count != before {
            store?.save(entries)
        }
    }

    func note(preferred: String, rejected: String, at date: Date = .now) {
        let preferred = preferred.lowercased()
        let rejected = rejected.lowercased()
        guard !preferred.isEmpty, !rejected.isEmpty, preferred != rejected else { return }
        entries.removeAll { $0.preferred == preferred && $0.rejected == rejected }
        entries.append(RejectedCorrection(preferred: preferred, rejected: rejected, lastUsed: date))
        if entries.count > Self.capacity {
            trim()
        }
        store?.save(entries)
    }

    /// If the top reading is a word the user already rejected, a stored preference in the
    /// same result moves ahead of it. The most recently used preference wins.
    func applying(to result: DecodeResult) -> DecodeResult {
        guard let top = result.readings.first else { return result }
        let topKey = top.word.lowercased()
        guard let match = entries.reversed().first(where: { entry in
            entry.rejected == topKey && result.readings.contains { $0.word.lowercased() == entry.preferred }
        }) else { return result }
        guard let index = result.readings.firstIndex(where: { $0.word.lowercased() == match.preferred }), index != 0 else {
            return result
        }
        var readings = result.readings
        let chosen = readings.remove(at: index)
        readings.insert(chosen, at: 0)
        return DecodeResult(readings: readings)
    }

    private func trim() {
        entries.sort { $0.lastUsed < $1.lastUsed }
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }
}
