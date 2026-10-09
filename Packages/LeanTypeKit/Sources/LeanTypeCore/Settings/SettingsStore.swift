import Foundation

public enum SharedContainer {
    /// App Group shared by the companion app and the keyboard extension.
    public static let appGroupIdentifier = "group.com.leantype.shared"
    /// Darwin notification posted by the app whenever settings change.
    public static let settingsDidChangeNotification = "com.leantype.settings.didChange"
    /// Darwin notification posted by the app after it clears learned words.
    public static let learnedWordsDidChangeNotification = "com.leantype.learnedWords.didChange"

    /// A file in the shared container; `nil` when the container is unavailable (the extension
    /// without Full Access).
    public static func fileURL(named name: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appending(path: name, directoryHint: .notDirectory)
    }

    /// The leash the keyboard would use right now, written so the companion can show it.
    public static let recommendedLeashKey = "recommendedLeash.v1"

    public static func saveRecommendedLeash(_ seconds: Double) {
        UserDefaults(suiteName: appGroupIdentifier)?.set(seconds, forKey: recommendedLeashKey)
    }

    public static func recommendedLeash() -> Double {
        let stored = UserDefaults(suiteName: appGroupIdentifier)?.double(forKey: recommendedLeashKey) ?? 0
        if stored > 0 { return min(0.55, max(0.16, stored)) }
        return TypingRhythm.coldLeash
    }
}

public protocol SettingsStore: Sendable {
    func load() -> KeyboardSettings
    func save(_ settings: KeyboardSettings)
}

/// Persists settings as a single JSON value in App Group `UserDefaults`.
///
/// The keyboard extension can only read this when the user has granted Full Access; without
/// it the suite is empty and `load()` returns defaults.
public struct AppGroupSettingsStore: SettingsStore {
    static let settingsKey = "keyboardSettings.v1"

    private let suiteName: String

    public init(suiteName: String = SharedContainer.appGroupIdentifier) {
        self.suiteName = suiteName
    }

    public func load() -> KeyboardSettings {
        guard let data = defaults?.data(forKey: Self.settingsKey),
              let settings = try? JSONDecoder().decode(KeyboardSettings.self, from: data)
        else {
            return .default
        }
        return settings
    }

    public func save(_ settings: KeyboardSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults?.set(data, forKey: Self.settingsKey)
    }

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }
}

/// Lightweight status the keyboard reports back to the app, so onboarding can tell whether
/// the keyboard has run with Full Access. Only writable when Full Access is on, which is
/// exactly the signal the app needs.
public struct KeyboardStatusStore: Sendable {
    static let lastFullAccessKey = "keyboardStatus.lastFullAccess"

    private let suiteName: String

    public init(suiteName: String = SharedContainer.appGroupIdentifier) {
        self.suiteName = suiteName
    }

    public func recordFullAccessSeen(at date: Date = .now) {
        UserDefaults(suiteName: suiteName)?.set(date, forKey: Self.lastFullAccessKey)
    }

    public var lastSeenWithFullAccess: Date? {
        UserDefaults(suiteName: suiteName)?.object(forKey: Self.lastFullAccessKey) as? Date
    }
}
