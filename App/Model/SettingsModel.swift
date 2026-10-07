import LeanTypeCore
import Observation

/// The app's single source of truth for keyboard settings. Every change is persisted to the
/// shared App Group and announced to the running keyboard extension.
@MainActor
@Observable
final class SettingsModel {
    var settings: KeyboardSettings {
        didSet {
            guard settings != oldValue, !isLoading else { return }
            store.save(settings)
            DarwinNotifications.post(SharedContainer.settingsDidChangeNotification)
        }
    }

    @ObservationIgnored private let store: any SettingsStore
    @ObservationIgnored private var isLoading = false

    init(store: any SettingsStore = AppGroupSettingsStore()) {
        self.store = store
        settings = store.load()
    }

    /// Picks up changes the keyboard made itself (one-handed mode from the dock), so the app
    /// never writes a stale copy back over them.
    func reload() {
        isLoading = true
        settings = store.load()
        isLoading = false
    }
}

/// What the app can learn about keyboard setup. The keyboard records when it last ran with
/// Full Access, which is the only reliable signal available to the containing app.
@MainActor
@Observable
final class SetupStatusModel {
    private(set) var hasSeenFullAccess = false

    @ObservationIgnored private let store = KeyboardStatusStore()

    init() {
        refresh()
    }

    func refresh() {
        hasSeenFullAccess = store.lastSeenWithFullAccess != nil
    }
}
