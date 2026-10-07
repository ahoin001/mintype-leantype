import LeanTypeCore
import LeanTypeDesign
import UIKit

/// The key canvas. Owns key views and the callout, converts UIKit touches (including
/// coalesced high-frequency samples) into Core `TouchSample`s, and routes the globe key to the
/// system input-mode switcher.
final class KeyboardTouchView: UIView {
    var onTouchSamples: (([TouchSample]) -> Void)?
    /// Called for every touch event on the globe key, as `handleInputModeList(from:with:)`
    /// expects (tap switches keyboards, long press shows the list).
    var onGlobeEvent: ((UIView, UIEvent?) -> Void)?
    var onAccessibilityActivate: ((KeyID) -> Void)?

    private let calloutView = CalloutView()
    /// Views for every layer seen so far, so switching layers mid-slide never allocates.
    private var viewPool: [KeyID: KeyView] = [:]
    private var visibleIDs: [KeyID] = []
    private var geometry: KeyboardGeometry?
    private var state: KeyboardViewState?
    private var theme: Theme?
    private var style = KeyStyle.pebble
    private var globeTouches: Set<ObjectIdentifier> = []
    private var globeKeyID: KeyID?
    /// Globe touches bypass the engine, so their highlight is tracked here.
    private var isGlobePressed = false
    private var areLabelsHidden = false
    private var accessibilityKeys: [KeyAccessibilityElement] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clipsToBounds = false
        addSubview(calloutView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Applying engine output

    func apply(geometry newGeometry: KeyboardGeometry) {
        geometry = newGeometry
        style = newGeometry.metrics.isCompact ? .compactPebble : .pebble
        let ids = newGeometry.keys.map(\.id)
        let visible = Set(ids)

        for id in visibleIDs where !visible.contains(id) {
            viewPool[id]?.removeFromSuperview()
        }
        for frame in newGeometry.keys {
            let view = viewPool[frame.id] ?? makeKeyView(for: frame.id)
            if view.superview == nil {
                insertSubview(view, belowSubview: calloutView)
            }
            view.frame = frame.visualFrame
            view.setContentHidden(areLabelsHidden)
        }
        visibleIDs = ids
        globeKeyID = newGeometry.keys.first { $0.key.kind == .nextKeyboard }?.id
        rebuildAccessibilityElements()
        render()
    }

    func apply(state newState: KeyboardViewState) {
        let trackpadChanged = newState.interaction.isTrackpadActive != state?.interaction.isTrackpadActive
        state = newState
        render()
        if trackpadChanged {
            setLabelsHidden(newState.interaction.isTrackpadActive)
        }
    }

    func apply(theme newTheme: Theme) {
        theme = newTheme
        render()
    }

    /// Drops key views for layers not on screen and the callout's label views.
    func purgeCaches() {
        let visible = Set(visibleIDs)
        viewPool = viewPool.filter { visible.contains($0.key) }
        calloutView.purge()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        calloutView.frame = bounds
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        var samples: [TouchSample] = []
        for touch in touches {
            let point = touch.location(in: self)
            if let globeKeyID, geometry?.key(at: point)?.id == globeKeyID {
                globeTouches.insert(ObjectIdentifier(touch))
                setGlobePressed(true)
                onGlobeEvent?(self, event)
                continue
            }
            samples.append(sample(for: touch, at: point, phase: .began))
        }
        send(samples)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        var samples: [TouchSample] = []
        var forwardedGlobe = false
        for touch in touches {
            if globeTouches.contains(ObjectIdentifier(touch)) {
                if !forwardedGlobe {
                    onGlobeEvent?(self, event)
                    forwardedGlobe = true
                }
                continue
            }
            let id = touchID(for: touch)
            let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
            for sampleTouch in coalesced {
                samples.append(TouchSample(
                    id: id,
                    location: sampleTouch.location(in: self),
                    timestamp: sampleTouch.timestamp,
                    phase: .moved
                ))
            }
        }
        send(samples)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event: event, phase: .ended)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event: event, phase: .cancelled)
    }

    private func finish(_ touches: Set<UITouch>, event: UIEvent?, phase: TouchPhase) {
        var samples: [TouchSample] = []
        for touch in touches {
            if globeTouches.remove(ObjectIdentifier(touch)) != nil {
                onGlobeEvent?(self, event)
                setGlobePressed(false)
                continue
            }
            samples.append(sample(for: touch, at: touch.location(in: self), phase: phase))
        }
        send(samples)
    }

    private func sample(for touch: UITouch, at point: CGPoint, phase: TouchPhase) -> TouchSample {
        TouchSample(id: touchID(for: touch), location: point, timestamp: touch.timestamp, phase: phase)
    }

    private func touchID(for touch: UITouch) -> TouchID {
        TouchID(rawValue: ObjectIdentifier(touch).hashValue)
    }

    private func send(_ samples: [TouchSample]) {
        guard !samples.isEmpty else { return }
        onTouchSamples?(samples)
    }

    // MARK: - Rendering

    private func render() {
        guard let geometry, let state, let theme else { return }
        let compact = geometry.metrics.isCompact
        for frame in geometry.keys {
            guard let view = viewPool[frame.id] else { continue }
            let presentation = KeyPresentationProvider.presentation(for: frame.key, state: state)
            view.configure(
                label: presentation.label,
                colors: theme.colors(for: presentation.family),
                shadow: theme.keyShadow,
                style: style,
                isPressed: state.interaction.pressedKeys.contains(frame.id) || (isGlobePressed && frame.id == globeKeyID),
                isEnabled: presentation.isEnabled,
                isCompact: compact
            )
        }
        calloutView.apply(theme: theme, style: style, isCompact: compact)
        calloutView.show(state.interaction.callout)
        updateAccessibilityLabels()
    }

    private func setLabelsHidden(_ hidden: Bool) {
        areLabelsHidden = hidden
        let views = visibleIDs.compactMap { viewPool[$0] }
        UIView.animate(withDuration: Motion.modeChange, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            views.forEach { $0.setContentHidden(hidden) }
        }
    }

    private func setGlobePressed(_ pressed: Bool) {
        guard pressed != isGlobePressed else { return }
        isGlobePressed = pressed
        render()
    }

    private func makeKeyView(for id: KeyID) -> KeyView {
        let view = KeyView(style: style)
        viewPool[id] = view
        return view
    }

    // MARK: - Accessibility

    private func rebuildAccessibilityElements() {
        guard let geometry else { return }
        accessibilityKeys = geometry.keys.map { frame in
            let element = KeyAccessibilityElement(accessibilityContainer: self, keyID: frame.id)
            element.accessibilityFrameInContainerSpace = frame.visualFrame
            element.onActivate = { [weak self] id in self?.onAccessibilityActivate?(id) }
            return element
        }
        accessibilityElements = accessibilityKeys
        updateAccessibilityLabels()
    }

    private func updateAccessibilityLabels() {
        guard let geometry, let state else { return }
        for (element, frame) in zip(accessibilityKeys, geometry.keys) {
            let presentation = KeyPresentationProvider.presentation(for: frame.key, state: state)
            element.accessibilityLabel = presentation.accessibilityLabel
            element.accessibilityTraits = presentation.isEnabled ? .keyboardKey : [.keyboardKey, .notEnabled]
        }
    }
}

/// A VoiceOver target for one key, activated directly instead of through gestures.
final class KeyAccessibilityElement: UIAccessibilityElement {
    let keyID: KeyID
    var onActivate: ((KeyID) -> Void)?

    init(accessibilityContainer container: Any, keyID: KeyID) {
        self.keyID = keyID
        super.init(accessibilityContainer: container)
        isAccessibilityElement = true
    }

    override func accessibilityActivate() -> Bool {
        onActivate?(keyID)
        return true
    }
}
