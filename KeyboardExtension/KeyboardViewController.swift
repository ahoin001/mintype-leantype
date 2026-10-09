import LeanTypeCore
import LeanTypeDesign
import LeanTypeKeyboardUI
import MetricKit
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

    /// Loaded on first use, after the crash log is installed, so a failure while mapping the
    /// dictionary is recorded instead of killing the process with an empty log.
    private lazy var language = LanguageModel.bundled(
        store: AppGroupLearnedWordsStore(),
        rejections: AppGroupRejectionStore(),
        wordContext: AppGroupWordContextStore(),
        habits: AppGroupHabitStore(),
        strokes: AppGroupStrokeStore(),
        blocklist: AppGroupBlocklistStore()
    )
    private let crashMonitor = ExtensionCrashMonitor()

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
        ExtensionDiagnostics.install()
        crashMonitor.start()
        DiagnosticLog.shared.mark("Starting")
        installKeyboardView()
        DiagnosticLog.shared.mark("Keyboard built")

        keyboardView.onGlobeEvent = { [weak self] view, event in
            guard let event else { return }
            self?.handleInputModeList(from: view, with: event)
        }
        keyboardView.onNextKeyboard = { [weak self] in self?.advanceToNextInputMode() }
        keyboardView.onDismiss = { [weak self] in self?.dismissKeyboard() }
        keyboardView.backgroundStyle = .system
        keyboardView.onOneHandedChange = { [weak self] mode in self?.persistOneHanded(mode) }
        keyboardView.onBackspaceTapChange = { [weak self] action in self?.persistBackspace(action) }
        keyboardView.addEventObserver(stats)

        notificationObservers = [
            DarwinNotificationObserver(name: SharedContainer.settingsDidChangeNotification) { [weak self] in
                self?.reloadSettings()
            },
            DarwinNotificationObserver(name: SharedContainer.learnedWordsDidChangeNotification) { [weak self] in
                self?.engine.reloadLearnedWords()
            },
        ]
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: KeyboardViewController, _: UITraitCollection) in
            controller.applyTheme()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        DiagnosticLog.shared.mark(hasFullAccess ? "Opening with Full Access" : "Opening")
        reloadSettings()
        DiagnosticLog.shared.mark("Settings loaded")
        engine.setShowsNextKeyboardKey(needsInputModeSwitchKey)
        engine.update(traits: InputTraits(proxy: textDocumentProxy))
        engine.reset()
        keyboardView.feedback.prepare()
        keyboardView.keyboardWillAppear()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        DiagnosticLog.shared.markOpened()
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
            // Choices made from the dock still hold for this session.
            let oneHanded = settings.oneHandedMode
            let backspace = settings.backspaceTapAction
            settings = .default
            settings.oneHandedMode = oneHanded
            settings.backspaceTapAction = backspace
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

    private func persistBackspace(_ action: BackspaceTapAction) {
        settings.backspaceTapAction = action
        guard hasFullAccess else { return }
        settingsStore.save(settings)
        DarwinNotifications.post(SharedContainer.settingsDidChangeNotification)
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

/// Installs a last-chance writer for Objective-C exceptions. Swift fatal errors and memory
/// kills skip this and show up through MetricKit on the next launch instead.
@MainActor
enum ExtensionDiagnostics {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.prefix(16).joined(separator: "\n")
            DiagnosticLog.shared.recordCrash(
                summary: exception.reason ?? exception.name.rawValue,
                detail: stack
            )
        }
    }
}

/// Forwards iOS crash and hang reports into the shared diagnostic file the app displays.
final class ExtensionCrashMonitor: NSObject, MXMetricManagerSubscriber {
    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {}

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                record(crash)
            }
            for hang in payload.hangDiagnostics ?? [] {
                DiagnosticLog.shared.recordCrash(summary: "Stopped responding", detail: "Hang \(hang.hangDuration)")
            }
        }
    }

    private func record(_ crash: MXCrashDiagnostic) {
        var parts: [String] = []
        if let reason = crash.terminationReason, !reason.isEmpty { parts.append(reason) }
        if let name = crash.exceptionReason?.exceptionName, !name.isEmpty { parts.append(name) }
        if parts.isEmpty, let signal = crash.signal { parts.append("Signal \(signal)") }
        if parts.isEmpty { parts.append("Closed by iOS") }

        var detail = crash.virtualMemoryRegionInfo ?? ""
        if let text = String(data: crash.callStackTree.jsonRepresentation(), encoding: .utf8) {
            if !detail.isEmpty { detail += "\n" }
            detail += text
        }
        DiagnosticLog.shared.recordCrash(summary: parts.joined(separator: "\n"), detail: detail)
    }
}
