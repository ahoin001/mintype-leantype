import LeanTypeCore
import LeanTypeDesign
import UIKit

/// The complete keyboard surface: soft gradient background, dock, keys, and callouts, driven
/// by a `KeyboardEngine`. Used by the extension and by the companion app's live preview.
public final class KeyboardView: UIView {
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

    private let background = CAGradientLayer()
    private let dock = DockView()
    private let keysView = KeyboardTouchView()

    public init(engine: KeyboardEngine, theme: Theme, feedback: FeedbackCoordinator) {
        self.engine = engine
        self.theme = theme
        self.feedback = feedback
        super.init(frame: .zero)

        layer.addSublayer(background)
        addSubview(dock)
        addSubview(keysView)

        keysView.onTouchSamples = { [weak self] samples in
            self?.engine.handle(samples)
        }
        keysView.onAccessibilityActivate = { [weak self] id in
            self?.engine.activateKey(id)
        }

        engine.delegate = self
        keysView.apply(geometry: engine.geometry)
        keysView.apply(state: engine.state)
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

    /// Metrics for the current size class: compact rows in iPhone landscape.
    public var metrics: KeyboardMetrics {
        metricsOverride ?? (traitCollection.verticalSizeClass == .compact ? .landscape : .portrait)
    }

    public var preferredHeight: CGFloat {
        metrics.totalHeight(rowCount: engine.geometry.layout.rows.count)
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight)
    }

    public func purgeCaches() {
        keysView.purgeCaches()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let metrics = metrics
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = bounds
        CATransaction.commit()

        dock.frame = CGRect(x: 0, y: 0, width: bounds.width, height: metrics.dockHeight)
        keysView.frame = CGRect(
            x: 0,
            y: metrics.dockHeight,
            width: bounds.width,
            height: max(bounds.height - metrics.dockHeight, 0)
        )
        engine.updateLayout(size: keysView.bounds.size, metrics: metrics)
    }

    // MARK: - Private

    private func applyTheme() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.colors = [theme.backgroundTop.cgColor, theme.backgroundBottom.cgColor]
        CATransaction.commit()
        dock.apply(theme: theme)
        keysView.apply(theme: theme)
    }

    private func updateDock() {
        let state = engine.state
        let message: DockMessage? = if state.interaction.isTrackpadActive {
            .trackpad
        } else if state.shift == .locked {
            .capsLock
        } else {
            persistentMessage
        }
        dock.show(message)
    }
}

extension KeyboardView: KeyboardEngineDelegate {
    public func keyboardEngine(_: KeyboardEngine, didUpdateGeometry geometry: KeyboardGeometry) {
        keysView.apply(geometry: geometry)
    }

    public func keyboardEngine(_: KeyboardEngine, didUpdateState state: KeyboardViewState) {
        keysView.apply(state: state)
        updateDock()
    }

    public func keyboardEngine(_: KeyboardEngine, didEmit event: FeedbackEvent) {
        feedback.handle(event)
    }

    public func keyboardEngineDidRequestNextKeyboard(_: KeyboardEngine) {
        onNextKeyboard?()
    }
}
