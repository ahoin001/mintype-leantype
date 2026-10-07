import Foundation

/// One `Codable` value in a JSON file, written atomically so the app and the extension never
/// see a half-written file. Failures read as "nothing saved yet": every caller has a sensible
/// empty default, and none of this data is worth crashing a keyboard over.
struct CodableFileStore<Value: Codable>: Sendable {
    private let url: @Sendable () -> URL?

    init(url: @escaping @Sendable () -> URL?) {
        self.url = url
    }

    func load() -> Value? {
        guard let url = url(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        guard let url = url(), let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func remove() {
        guard let url = url() else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
