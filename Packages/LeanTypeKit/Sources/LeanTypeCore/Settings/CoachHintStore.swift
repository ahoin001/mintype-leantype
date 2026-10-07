import Foundation

/// Which one-time dock hints have already been shown. Without Full Access the file URL is
/// nil, so nothing is written and the keyboard remembers them only for this session.
public struct CoachHintStore: Sendable {
    private let file: CodableFileStore<Set<String>>

    public init(fileName: String = "CoachHints.json") {
        file = CodableFileStore { SharedContainer.fileURL(named: fileName) }
    }

    public func load() -> Set<String> {
        file.load() ?? []
    }

    public func save(_ seen: Set<String>) {
        file.save(seen)
    }
}
