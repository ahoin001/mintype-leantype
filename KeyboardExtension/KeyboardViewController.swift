import LeanTypeCore
import LeanTypeDesign
import LeanTypeKeyboardUI
import UIKit

/// Thin composition root for the keyboard extension: wires the system text proxy, shared
/// settings, and lifecycle events into `KeyboardEngine` and `KeyboardView`.
final class KeyboardViewController: UIInputViewController {
    private let settingsStore = AppGroupSettingsStore()
    private let statusStore = KeyboardStatusStore()
    private var settingsObserver: DarwinNotificationObserver?
    private var heightConstraint: NSLayoutConstraint?
    private var settings = KeyboardSettings.default

    private lazy var engine = KeyboardEngine(
        document: TextDocumentProxyAdapter(proxy: textDocumentProxy),
        traits: InputTraits(proxy: textDocumentProxy),
        showsNextKeyboardKey: needsInputModeSwitchKey
    )

    private lazy var keyboardView = KeyboardView(
        engine: engine,
        theme: resolvedTheme(),
        feedback: FeedbackCoordinator(hapticsEnabled: false, clicksEnabled: true)
    )

    // MARK: - Lifecycle

    override func loadView() {
        let input = KeyboardInputView(frame: .zero, inputViewStyle: .keyboard)
        input.allowsSelfSizing = true
        inputView = input
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installKeyboardView()

        keyboardView.onGlobeEvent = { [weak self] view, event in
            guard let event else { return }
            self?.handleInputModeList(from: view, with: event)
        }
        keyboardView.onNextKeyboard = { [weak self] in self?.advanceToNextInputMode() }
        keyboardView.onDismiss = { [weak self] in self?.dismissKeyboard() }

        settingsObserver = DarwinNotificationObserver(name: SharedContainer.settingsDidChangeNotification) { [weak self] in
            self?.reloadSettings()
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: KeyboardViewController, _: UITraitCollection) in
            controller.applyTheme()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadSettings()
        engine.setShowsNextKeyboardKey(needsInputModeSwitchKey)
        engine.update(traits: InputTraits(proxy: textDocumentProxy))
        engine.reset()
        keyboardView.feedback.prepare()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        engine.cancelAllTouches()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        heightConstraint?.constant = keyboardView.preferredHeight
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        keyboardView.purgeCaches()
    }

    // MARK: - Host document events

    override func textDidChange(_: (any UITextInput)?) {
        engine.update(traits: InputTraits(proxy: textDocumentProxy))
        engine.documentDidChange()
        applyTheme()
    }

    override func selectionDidChange(_: (any UITextInput)?) {
        engine.documentDidChange()
    }

    // MARK: - Private

    private func installKeyboardView() {
        guard let container = inputView else { return }
        keyboardView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(keyboardView)

        // Just below required so it never fights the system's own sizing constraint.
        let height = keyboardView.heightAnchor.constraint(equalToConstant: keyboardView.preferredHeight)
        height.priority = .required - 1
        heightConstraint = height

        NSLayoutConstraint.activate([
            keyboardView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            keyboardView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            keyboardView.topAnchor.constraint(equalTo: container.topAnchor),
            keyboardView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            height,
        ])
    }

    /// Settings sync and haptics need Full Access. Without it the keyboard still works fully
    /// with defaults (App Review 4.4.1) and shows a gentle reminder in the dock.
    private func reloadSettings() {
        let fullAccess = hasFullAccess
        settings = fullAccess ? settingsStore.load() : .default
        if fullAccess {
            statusStore.recordFullAccessSeen()
        }

        engine.update(settings: settings)
        keyboardView.feedback.hapticsEnabled = fullAccess && settings.hapticsEnabled
        keyboardView.feedback.clicksEnabled = settings.keyClicksEnabled
        keyboardView.persistentMessage = fullAccess ? nil : .fullAccessRequired
        applyTheme()
    }

    private func applyTheme() {
        keyboardView.theme = resolvedTheme()
    }

    private func resolvedTheme() -> Theme {
        let prefersDark = switch textDocumentProxy.keyboardAppearance {
        case .dark: true
        case .light: false
        default: traitCollection.userInterfaceStyle == .dark
        }
        return ThemeCatalog.theme(for: settings.theme, prefersDark: prefersDark)
    }
}
