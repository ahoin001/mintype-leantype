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

    /// Draw each letter's flick-down character in its corner.
    var showsHints = false {
        didSet { if showsHints != oldValue { render() } }
    }

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
    /// The letter key that was down on the previous state, so a release can grow a flow rim.
    private var pressedIDs: Set<KeyID> = []
    private var flowValue = 0.0
    private var flowEffectsEnabled = false
    /// The layer last laid out, so a switch can bring the new labels in by row.
    private var shownLayer: KeyboardLayer?
    private let flowRim = CAShapeLayer()
    private let rimHost = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clipsToBounds = false
        rimHost.isUserInteractionEnabled = false
        rimHost.isAccessibilityElement = false
        addSubview(rimHost)
        addSubview(calloutView)
        flowRim.fillColor = nil
        flowRim.lineWidth = 2
        flowRim.opacity = 0
        rimHost.layer.addSublayer(flowRim)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Applying engine output

    func apply(geometry newGeometry: KeyboardGeometry, travels: Bool) {
        let layerChanged = shownLayer != nil && shownLayer != newGeometry.layout.layer
        shownLayer = newGeometry.layout.layer
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
        if layerChanged, travels {
            arrive(in: newGeometry)
        }
    }

    /// New labels settle from a slightly smaller size, one row after another.
    /// Shift and caps never come through here; they only change a label in place.
    private func arrive(in geometry: KeyboardGeometry) {
        for row in geometry.rows.enumerated() {
            let delay = TimeInterval(row.offset) * Motion.rowStagger
            for frame in row.element {
                viewPool[frame.id]?.arrive(after: delay)
            }
        }
    }

    /// Flow from the engine. The rim only appears once typing has a rhythm and effects are on.
    func noteFlow(_ flow: FlowLevel, effectsEnabled: Bool) {
        flowValue = flow.value
        flowEffectsEnabled = effectsEnabled
    }

    func apply(state newState: KeyboardViewState) {
        let trackpadChanged = newState.interaction.isTrackpadActive != state?.interaction.isTrackpadActive
        let released = pressedIDs.subtracting(newState.interaction.pressedKeys)
        pressedIDs = newState.interaction.pressedKeys
        state = newState
        if let id = released.first(where: isLetterKey) {
            flashFlowRim(on: id)
        }
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
        rimHost.frame = bounds
        insertSubview(rimHost, belowSubview: calloutView)
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        var samples: [TouchSample] = []
        for touch in touches {
            let point = touch.preciseLocation(in: self)
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
                    location: sampleTouch.preciseLocation(in: self),
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
            samples.append(sample(for: touch, at: touch.preciseLocation(in: self), phase: phase))
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
        let suggested = suggestedKeyIDs(in: state, geometry: geometry)
        for frame in geometry.keys {
            guard let view = viewPool[frame.id] else { continue }
            let presentation = KeyPresentationProvider.presentation(for: frame.key, state: state, showsHints: showsHints)
            view.configure(
                label: presentation.label,
                colors: theme.colors(for: presentation.family),
                shadow: theme.keyShadow,
                style: style,
                isPressed: state.interaction.pressedKeys.contains(frame.id) || (isGlobePressed && frame.id == globeKeyID),
                isSuggested: suggested.contains(frame.id),
                isEnabled: presentation.isEnabled,
                isCompact: compact,
                hint: presentation.hint,
                trackpadOpen: frame.key.kind == .space && state.interaction.isTrackpadActive
            )
        }
        calloutView.apply(theme: theme, style: style, isCompact: compact)
        let fingerCallout = state.interaction.callout
        let callout = fingerCallout ?? swipeWordCallout(in: state, geometry: geometry)
        let fades = fingerCallout == nil && callout != nil && UIAccessibility.isReduceMotionEnabled
        calloutView.show(callout, fades: fades)
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

    /// The word a swipe is about to commit, growing out of the key of its last letter.
    /// A finger's own callout, when one is up, keeps the balloon.
    private func swipeWordCallout(in state: KeyboardViewState, geometry: KeyboardGeometry) -> CalloutState? {
        guard state.candidates.isTentative, state.layer == .letters, !state.interaction.strokes.isEmpty else { return nil }
        let index = state.candidates.highlightedIndex ?? 0
        guard state.candidates.candidates.indices.contains(index) else { return nil }
        let word = state.candidates.candidates[index].text
        guard let last = word.last(where: \.isLetter) else { return nil }
        let letter = String(last).lowercased()
        guard let frame = geometry.keys.first(where: { $0.key.kind.character?.lowercased() == letter }) else { return nil }
        let dock = geometry.metrics.dockHeight
        let bounds = CGRect(x: 0, y: -dock, width: geometry.size.width, height: geometry.size.height + dock)
        let widths = CalloutGeometry.cellWidths(for: [word], keyWidth: frame.visualFrame.width, available: bounds.width)
        let layout = CalloutGeometry.layout(
            anchor: frame.visualFrame,
            optionCount: 1,
            metrics: geometry.metrics,
            bounds: bounds,
            cellWidths: widths
        )
        return CalloutState(keyID: frame.id, layout: layout, content: .preview(word))
    }

    /// Letter keys that spell the word the swipe preview is about to commit.
    private func suggestedKeyIDs(in state: KeyboardViewState, geometry: KeyboardGeometry) -> Set<KeyID> {
        guard state.candidates.isTentative, state.layer == .letters else { return [] }
        let index = state.candidates.highlightedIndex ?? 0
        guard state.candidates.candidates.indices.contains(index) else { return [] }
        let letters = Set(state.candidates.candidates[index].text.lowercased().filter(\.isLetter).map(String.init))
        guard !letters.isEmpty else { return [] }
        return Set(geometry.keys.compactMap { frame in
            guard let character = frame.key.kind.character?.lowercased(), letters.contains(character) else { return nil }
            return frame.id
        })
    }

    private func isLetterKey(_ id: KeyID) -> Bool {
        guard let character = geometry?.keys.first(where: { $0.id == id })?.key.kind.character,
              character.count == 1, let first = character.first
        else { return false }
        return first.isLetter
    }

    /// A single accent ring on the key that was just released. One layer, one shot, then gone.
    private func flashFlowRim(on id: KeyID) {
        guard flowEffectsEnabled, flowValue > 0.35, !UIAccessibility.isReduceMotionEnabled,
              let theme, let frame = geometry?.keys.first(where: { $0.id == id })
        else { return }
        let rect = frame.visualFrame.insetBy(dx: -2, dy: -2)
        flowRim.frame = rect
        flowRim.path = UIBezierPath(
            roundedRect: CGRect(origin: .zero, size: rect.size),
            cornerRadius: style.cornerRadius + 2
        ).cgPath
        flowRim.strokeColor = theme.accentKey.fill.uiColor.cgColor
        flowRim.removeAnimation(forKey: "fade")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.85
        fade.toValue = 0
        fade.duration = 0.2
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        flowRim.opacity = 0
        flowRim.add(fade, forKey: "fade")
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
            let presentation = KeyPresentationProvider.presentation(for: frame.key, state: state, showsHints: showsHints)
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
