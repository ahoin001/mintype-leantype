import LeanTypeCore
import LeanTypeDesign
import UIKit

/// What fills the keyboard behind the keys.
public enum KeyboardBackground: Equatable, Sendable {
    /// The theme gradient. The companion preview has no system tray behind it.
    case theme
    /// Clear, so the system keyboard chrome (the globe and mic bar) shows through.
    case system
}

/// The complete keyboard surface: soft gradient background, dock with suggestions, keys,
/// callouts, swipe trails, and effects, driven by a `KeyboardEngine`. Used by the extension
/// and by the companion app's live preview.
public final class KeyboardView: UIView {
    /// Width of the keys in one-handed mode, as a fraction of the keyboard.
    static let oneHandedWidth: CGFloat = 0.84

    public let engine: KeyboardEngine
    public let feedback: FeedbackCoordinator

    public var theme: Theme {
        didSet { if theme != oldValue { applyTheme() } }
    }

    /// A message that stays in the dock until cleared (e.g. the Full Access reminder).
    public var persistentMessage: DockMessage? {
        didSet { updateDock() }
    }

    /// Forced metrics, for previews that should not follow the device's size class.
    public var metricsOverride: KeyboardMetrics? {
        didSet { setNeedsLayout() }
    }

    public var onDismiss: (() -> Void)? {
        get { dock.onDismiss }
        set { dock.onDismiss = newValue }
    }

    public var onGlobeEvent: ((UIView, UIEvent?) -> Void)? {
        get { keysView.onGlobeEvent }
        set { keysView.onGlobeEvent = newValue }
    }

    public var onNextKeyboard: (() -> Void)?

    /// Clear in the extension so the system tray shows through. The preview keeps the gradient.
    public var backgroundStyle: KeyboardBackground = .theme {
        didSet { if backgroundStyle != oldValue { applyTheme() } }
    }

    /// The user changed one-handed mode from the keyboard itself; the host should persist it.
    public var onOneHandedChange: ((OneHandedMode) -> Void)? {
        didSet {
            dock.onOneHanded = onOneHandedChange == nil ? nil : { [weak self] in
                guard let self else { return }
                setOneHanded(oneHandedMode == .off ? .right : .off)
            }
        }
    }

    private let background = CAGradientLayer()
    private let dock = DockView()
    private let keysView = KeyboardTouchView()
    private let panel = OneHandedPanel()
    private let stage: EffectsStage
    private let effects: EffectsCoordinator
    /// The user chose what a tap on delete removes; the host should persist it.
    public var onBackspaceTapChange: ((BackspaceTapAction) -> Void)?

    private var observers: [any KeyboardEventObserver] = []
    private var heightScale = 1.0
    private var oneHandedMode = OneHandedMode.off
    private let coach = CoachHints()
    private var pendingHint: CoachHints.Hint?
    private var hintHide: Timer?

    public init(engine: KeyboardEngine, theme: Theme, feedback: FeedbackCoordinator) {
        self.engine = engine
        self.theme = theme
        self.feedback = feedback
        stage = EffectsStage(scale: UITraitCollection.current.displayScale)
        effects = EffectsCoordinator(stage: stage, theme: theme, settings: engine.settings.effects)
        super.init(frame: .zero)

        layer.addSublayer(background)
        layer.addSublayer(stage.backdrop)
        addSubview(dock)
        addSubview(keysView)
        addSubview(panel)
        addSubview(stage)
        panel.isHidden = true
        observers = [feedback, effects]

        keysView.onTouchSamples = { [weak self] samples in
            guard let self else { return }
            engine.handle(samples)
            effects.trails.ingest(samples, strokes: engine.state.interaction.strokes)
        }
        keysView.onAccessibilityActivate = { [weak self] id in
            self?.engine.activateKey(id)
        }
        dock.onSelectCandidate = { [weak self] index in
            self?.engine.acceptCandidate(index)
        }
        dock.wordMemory = { [weak self] word in
            self?.engine.language?.memory(of: word) ?? .unavailable
        }
        dock.onRememberWord = { [weak self] word in
            self?.engine.rememberWord(word)
        }
        dock.onForgetWord = { [weak self] word in
            self?.engine.forgetWord(word)
        }
        dock.onBanWord = { [weak self] word in
            self?.engine.banWord(word)
        }
        dock.onWordmarkTap = { [weak self] in
            self?.dock.toggleDeleteMenu()
        }
        dock.onBackspaceChoice = { [weak self] action in
            guard let self else { return }
            var settings = engine.settings
            settings.backspaceTapAction = action
            update(settings: settings)
            onBackspaceTapChange?(action)
        }
        dock.onMenuVisibilityChange = { [weak self] in
            self?.flushHint()
        }
        effects.onFlowChange = { [weak self] flow in
            guard let self else { return }
            dock.setFlow(flow)
            keysView.noteFlow(flow, effectsEnabled: effects.level > .off)
        }
        panel.onExpand = { [weak self] in self?.setOneHanded(.off) }
        panel.onSwitchSide = { [weak self] in
            guard let self else { return }
            setOneHanded(oneHandedMode == .left ? .right : .left)
        }

        engine.delegate = self
        keysView.apply(geometry: engine.geometry)
        keysView.apply(state: engine.state)
        applySettings(engine.settings)
        applyTheme()

        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (view: KeyboardView, _: UITraitCollection) in
            view.invalidateIntrinsicContentSize()
            view.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Metrics for the current size class (compact rows in iPhone landscape), at the user's
    /// chosen key height.
    public var metrics: KeyboardMetrics {
        let base = metricsOverride ?? (traitCollection.verticalSizeClass == .compact ? .landscape : .portrait)
        return base.scaled(by: heightScale)
    }

    public var preferredHeight: CGFloat {
        metrics.totalHeight(rowCount: engine.geometry.layout.rows.count)
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight)
    }

    // MARK: - Host API

    /// Applies new settings to the engine and every part of the surface.
    public func update(settings: KeyboardSettings) {
        engine.update(settings: settings)
        applySettings(settings)
    }

    /// Statistics or other listeners that want keyboard events alongside feedback and effects.
    public func addEventObserver(_ observer: any KeyboardEventObserver) {
        observers.append(observer)
    }

    public func keyboardWillAppear() {
        effects.keyboardWillAppear()
    }

    public func keyboardDidDisappear() {
        effects.stopAll()
    }

    public func handleMemoryWarning() {
        effects.stopAll()
        effects.handleMemoryWarning()
        keysView.purgeCaches()
    }

    // MARK: - Layout

    public override func layoutSubviews() {
        super.layoutSubviews()
        let metrics = metrics
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = bounds
        stage.backdrop.frame = bounds
        CATransaction.commit()

        dock.frame = CGRect(x: 0, y: 0, width: bounds.width, height: metrics.dockHeight)
        let keyArea = CGRect(
            x: 0,
            y: metrics.dockHeight,
            width: bounds.width,
            height: max(bounds.height - metrics.dockHeight, 0)
        )
        let mode = metrics.isCompact ? .off : oneHandedMode
        let keysWidth = mode == .off ? keyArea.width : (keyArea.width * Self.oneHandedWidth).rounded()
        let keysX = mode == .right ? keyArea.maxX - keysWidth : keyArea.minX
        keysView.frame = CGRect(x: keysX, y: keyArea.minY, width: keysWidth, height: keyArea.height)
        panel.isHidden = mode == .off
        panel.frame = CGRect(
            x: mode == .right ? keyArea.minX : keysView.frame.maxX,
            y: keyArea.minY,
            width: keyArea.width - keysWidth,
            height: keyArea.height
        )
        panel.configure(for: mode)

        stage.frame = bounds
        stage.updateRegions(keyArea: keysView.frame, dock: dock.frame)
        engine.updateLayout(size: keysView.bounds.size, metrics: metrics)
        effects.layoutDidChange()
    }

    // MARK: - Private

    private func applySettings(_ settings: KeyboardSettings) {
        dock.setBackspaceAction(settings.backspaceTapAction)
        keysView.showsHints = settings.secondaryHintsVisible && settings.flickForSecondaryEnabled
        effects.apply(settings: settings.effects)
        if settings.height.scale != heightScale || settings.oneHandedMode != oneHandedMode {
            heightScale = settings.height.scale
            oneHandedMode = settings.oneHandedMode
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    private func setOneHanded(_ mode: OneHandedMode) {
        guard mode != oneHandedMode else { return }
        oneHandedMode = mode
        UIView.animate(withDuration: Motion.modeChange, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
        onOneHandedChange?(mode)
    }

    private func applyTheme() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch backgroundStyle {
        case .theme:
            background.isHidden = false
            background.colors = [theme.backgroundTop.cgColor, theme.backgroundBottom.cgColor]
            isOpaque = true
        case .system:
            background.isHidden = true
            background.colors = nil
            isOpaque = false
            backgroundColor = .clear
        }
        CATransaction.commit()
        dock.apply(theme: theme)
        keysView.apply(theme: theme)
        panel.apply(theme: theme)
        effects.apply(theme: theme)
    }

    private func statusMessage() -> DockMessage? {
        let state = engine.state
        if state.interaction.isTrackpadActive { return .trackpad }
        if state.shift == .locked { return .capsLock }
        return persistentMessage
    }

    private func updateDock() {
        dock.show(statusMessage())
        dock.show(engine.state.interaction.isTrackpadActive ? .empty : engine.state.candidates)
        flushHint()
    }

    private func noteCoach(_ event: KeyboardEvent) {
        guard let hint = coach.consider(event) else { return }
        pendingHint = hint
        flushHint()
    }

    /// Shows a queued hint once status, suggestions, and the delete menu are out of the way.
    private func flushHint() {
        guard let hint = pendingHint, statusMessage() == nil,
              engine.state.candidates.isEmpty, !dock.isDeleteMenuOpen
        else { return }
        pendingHint = nil
        coach.markPresented(hint.id)
        dock.showHint(hint.text)
        hintHide?.invalidate()
        let timer = Timer(timeInterval: 2.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dock.showHint(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hintHide = timer
    }
}

extension KeyboardView: KeyboardEngineDelegate {
    public func keyboardEngine(_: KeyboardEngine, didUpdateGeometry geometry: KeyboardGeometry) {
        keysView.apply(geometry: geometry)
        effects.apply(geometry: geometry)
    }

    public func keyboardEngine(_: KeyboardEngine, didUpdateState state: KeyboardViewState) {
        keysView.apply(state: state)
        effects.shiftDidChange(state.shift)
        updateDock()
    }

    public func keyboardEngine(_: KeyboardEngine, didEmit event: KeyboardEvent) {
        noteCoach(event)
        for observer in observers {
            observer.handle(event)
        }
    }

    public func keyboardEngineDidRequestNextKeyboard(_: KeyboardEngine) {
        onNextKeyboard?()
    }
}
