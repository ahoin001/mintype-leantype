import LeanTypeCore
import LeanTypeDesign
import LeanTypeKeyboardUI
import UIKit

/// Thin composition root for the keyboard extension: wires the system text proxy, shared
/// settings, the language model, and lifecycle events into `KeyboardEngine` and `KeyboardView`.
final class KeyboardViewController: UIInputViewController {
    private let settingsStore = AppGroupSettingsStore()
    private let statusStore = KeyboardStatusStore()
    private let stats = FlowStatsRecorder()
    private var notificationObservers: [DarwinNotificationObserver] = []
    private var heightConstraint: NSLayoutConstraint?
    private var settings = KeyboardSettings.default

    /// The memory-mapped dictionary costs almost no dirty memory, so it loads with the keyboard.
    private let language = LanguageModel.bundled(store: AppGroupLearnedWordsStore())

    private lazy var engine = KeyboardEngine(
        document: TextDocumentProxyAdapter(proxy: textDocumentProxy),
        traits: InputTraits(proxy: textDocumentProxy),
        showsNextKeyboardKey: needsInputModeSwitchKey,
        language: language
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
        keyboardView.onOneHandedChange = { [weak self] mode in self?.persistOneHanded(mode) }
        keyboardView.addEventObserver(stats)

        notificationObservers = [
            DarwinNotificationObserver(name: SharedContainer.settingsDidChangeNotification) { [weak self] in
                self?.reloadSettings()
            },
            DarwinNotificationObserver(name: SharedContainer.learnedWordsDidChangeNotification) { [weak self] in
                self?.language?.reloadLearnedWords()
            },
        ]
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: KeyboardViewController, _: UITraitCollection) in
            controller.applyTheme()
        }
        loadSupplementaryWords()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadSettings()
        engine.setShowsNextKeyboardKey(needsInputModeSwitchKey)
        engine.update(traits: InputTraits(proxy: textDocumentProxy))
        engine.reset()
        keyboardView.feedback.prepare()
        keyboardView.keyboardWillAppear()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        engine.cancelAllTouches()
        keyboardView.keyboardDidDisappear()
        language?.save()
        stats.flush()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        heightConstraint?.constant = keyboardView.preferredHeight
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        keyboardView.handleMemoryWarning()
        language?.save()
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

    /// Settings sync, haptics, learning, and stats need Full Access. Without it the keyboard
    /// still works fully with defaults (App Review 4.4.1) and shows a gentle reminder in the dock.
    private func reloadSettings() {
        let fullAccess = hasFullAccess
        if fullAccess {
            settings = settingsStore.load()
            statusStore.recordFullAccessSeen()
        } else {
            // One-handed mode chosen from the dock still holds for this session.
            let oneHanded = settings.oneHandedMode
            settings = .default
            settings.oneHandedMode = oneHanded
        }

        keyboardView.update(settings: settings)
        keyboardView.feedback.hapticsEnabled = fullAccess && settings.hapticsEnabled
        keyboardView.feedback.clicksEnabled = settings.keyClicksEnabled
        keyboardView.persistentMessage = fullAccess ? nil : .fullAccessRequired
        language?.isLearningEnabled = fullAccess && settings.learnWordsEnabled
        stats.isEnabled = fullAccess
        applyTheme()
    }

    private func persistOneHanded(_ mode: OneHandedMode) {
        settings.oneHandedMode = mode
        guard hasFullAccess else { return }
        settingsStore.save(settings)
    }

    /// Contact names and text-replacement expansions, so they're never "corrected".
    private func loadSupplementaryWords() {
        guard language != nil else { return }
        requestSupplementaryLexicon { [weak self] lexicon in
            let words = lexicon.entries.map(\.documentText)
            Task { @MainActor in self?.language?.setSupplementaryWords(words) }
        }
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
