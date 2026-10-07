import Foundation

/// Everything the renderer needs besides geometry. Published only when something changes.
public struct KeyboardViewState: Hashable, Sendable {
    public var layer: KeyboardLayer
    public var shift: ShiftState
    public var interaction: InteractionState
    public var returnKey: ReturnKeyKind
    public var isReturnKeyEnabled: Bool
}

@MainActor
public protocol KeyboardEngineDelegate: AnyObject {
    func keyboardEngine(_ engine: KeyboardEngine, didUpdateGeometry geometry: KeyboardGeometry)
    func keyboardEngine(_ engine: KeyboardEngine, didUpdateState state: KeyboardViewState)
    func keyboardEngine(_ engine: KeyboardEngine, didEmit feedback: FeedbackEvent)
    func keyboardEngineDidRequestNextKeyboard(_ engine: KeyboardEngine)
}

/// The keyboard's brain: turns touches into edits and mode changes, and publishes what should
/// be drawn. UIKit-free, so the whole input pipeline is unit-testable and reusable by the
/// companion app's live preview.
@MainActor
public final class KeyboardEngine {
    static let doubleSpaceInterval: TimeInterval = 0.45

    public weak var delegate: (any KeyboardEngineDelegate)?

    public private(set) var settings: KeyboardSettings
    public private(set) var traits: InputTraits
    public private(set) var geometry: KeyboardGeometry
    public private(set) var state: KeyboardViewState

    private let editor: TextEditor
    private let scheduler: any Scheduler
    private let shift = ShiftController()
    private var layer: KeyboardLayer
    private var showsNextKeyboardKey: Bool
    private var insertionCount = 0
    private var lastSpaceTime: TimeInterval?
    private var lastObservedContext: String?

    lazy var composer = InputComposer { [weak self] intents in
        self?.performBatch(intents)
    }

    private lazy var touchEngine: TouchEngine = {
        let engine = TouchEngine(context: self)
        engine.onInteractionChange = { [weak self] _ in self?.publishState() }
        return engine
    }()

    public init(
        document: any TextDocument,
        settings: KeyboardSettings = .default,
        traits: InputTraits = .default,
        showsNextKeyboardKey: Bool = true,
        metrics: KeyboardMetrics = .portrait,
        scheduler: (any Scheduler)? = nil
    ) {
        editor = TextEditor(document: document)
        self.scheduler = scheduler ?? MainQueueScheduler()
        self.settings = settings
        self.traits = traits
        self.showsNextKeyboardKey = showsNextKeyboardKey

        let layer = Self.initialLayer(for: traits)
        self.layer = layer
        let layout = LayoutProvider.layout(
            for: layer,
            context: LayoutContext(variant: traits.variant, showsNextKeyboardKey: showsNextKeyboardKey)
        )
        geometry = KeyboardGeometry(layout: layout, size: .zero, metrics: metrics)
        state = KeyboardViewState(
            layer: layer,
            shift: .off,
            interaction: .idle,
            returnKey: traits.returnKey,
            isReturnKeyEnabled: true
        )
        refreshTextState()
    }

    /// Height the keyboard wants for its current metrics, dock included.
    public var preferredHeight: CGFloat {
        geometry.metrics.totalHeight(rowCount: geometry.layout.rows.count)
    }

    // MARK: - Inputs from the host

    /// Sets the key area size (excluding the dock) and spacing; recomputes frames if changed.
    public func updateLayout(size: CGSize, metrics: KeyboardMetrics) {
        guard size != geometry.size || metrics != geometry.metrics else { return }
        rebuildGeometry(size: size, metrics: metrics)
    }

    public func setShowsNextKeyboardKey(_ shows: Bool) {
        guard shows != showsNextKeyboardKey else { return }
        showsNextKeyboardKey = shows
        rebuildGeometry()
    }

    public func update(settings: KeyboardSettings) {
        guard settings != self.settings else { return }
        self.settings = settings
        refreshTextState()
    }

    public func update(traits: InputTraits) {
        guard traits != self.traits else { return }
        let variantChanged = traits.variant != self.traits.variant
        self.traits = traits
        if variantChanged {
            layer = Self.initialLayer(for: traits)
            rebuildGeometry()
        }
        refreshTextState()
    }

    /// Call when the host reports text or selection changes. Hosts also report our own edits,
    /// so a manual shift choice only resets when the visible context actually differs.
    public func documentDidChange() {
        if editor.contextBefore != lastObservedContext {
            shift.noteContextChanged()
        }
        refreshTextState()
    }

    /// Returns to a fresh state, e.g. when the keyboard reappears in a new field.
    public func reset() {
        touchEngine.cancelAll()
        composer.reset()
        shift.reset()
        lastSpaceTime = nil
        let initial = Self.initialLayer(for: traits)
        if initial != layer {
            layer = initial
            rebuildGeometry()
        }
        refreshTextState()
    }

    public func handle(_ samples: [TouchSample]) {
        let interval = Signposts.input.beginInterval("Touch batch")
        touchEngine.handle(samples)
        Signposts.input.endInterval("Touch batch", interval)
    }

    public func cancelAllTouches() {
        touchEngine.cancelAll()
        composer.reset()
    }

    /// Direct activation for assistive technologies (VoiceOver), bypassing gestures.
    public func activateKey(_ id: KeyID) {
        guard let frame = geometry.frame(for: id) else { return }
        switch frame.key.kind {
        case let .character(character):
            perform(.insert(character))
        case .space:
            perform(.space)
        case .backspace:
            perform(.deleteCharacter)
        case .shift:
            perform(.shiftPressBegan)
            perform(.shiftPressEnded)
        case let .layerSwitch(target):
            perform(.switchLayer(target))
        case .returnKey:
            if isReturnKeyEnabled { perform(.returnKey) }
        case .nextKeyboard:
            perform(.nextKeyboard)
        }
    }

    // MARK: - Applying intents

    @discardableResult
    func perform(_ intent: KeyboardIntent) -> Bool {
        let interval = Signposts.input.beginInterval("Commit")
        defer { Signposts.input.endInterval("Commit", interval) }

        if intent != .space {
            lastSpaceTime = nil
        }

        let changed: Bool
        var changesText = false
        switch intent {
        case let .insert(character):
            editor.insert(displayText(for: character))
            insertionCount += 1
            shift.consumeAfterInsertion()
            changed = true
            changesText = true
        case .space:
            changed = insertSpace()
            changesText = true
        case .returnKey:
            editor.insert("\n")
            changed = true
            changesText = true
        case .deleteWord:
            changed = editor.deleteWord()
            changesText = true
        case .deleteCharacter:
            changed = editor.deleteCharacter()
            changesText = true
        case .restoreCharacter:
            changed = editor.restoreCharacter()
            changesText = changed
        case .restoreLastDeletion:
            changed = editor.restoreLastDeletion()
            changesText = changed
        case let .moveCursor(direction):
            changed = editor.moveCursor(by: direction)
            changesText = changed
        case .shiftPressBegan:
            if shift.pressBegan(at: scheduler.now, insertionCount: insertionCount) {
                emit(.capsLockEngaged)
            }
            changed = true
        case .shiftPressEnded:
            shift.pressEnded(at: scheduler.now, insertionCount: insertionCount)
            changed = true
        case let .switchLayer(target):
            changed = setLayer(target)
        case .nextKeyboard:
            delegate?.keyboardEngineDidRequestNextKeyboard(self)
            changed = true
        }

        if changesText {
            shift.noteContextChanged()
        }
        refreshTextState()
        return changed
    }

    private func performBatch(_ intents: [KeyboardIntent]) {
        for intent in intents {
            perform(intent)
        }
    }

    private func insertSpace() -> Bool {
        let now = scheduler.now
        if settings.doubleSpacePeriodEnabled,
           let lastSpaceTime,
           now - lastSpaceTime < Self.doubleSpaceInterval,
           editor.applyDoubleSpacePeriod() {
            self.lastSpaceTime = nil
        } else {
            editor.insert(" ")
            lastSpaceTime = now
        }
        insertionCount += 1
        if layer != .letters {
            setLayer(.letters)
        }
        return true
    }

    @discardableResult
    private func setLayer(_ target: KeyboardLayer) -> Bool {
        guard target != layer else { return false }
        layer = target
        rebuildGeometry()
        return true
    }

    // MARK: - Derived state

    var isReturnKeyEnabled: Bool {
        !traits.enablesReturnKeyAutomatically || !editor.isDocumentEmpty
    }

    private func refreshTextState() {
        let context = editor.contextBefore
        lastObservedContext = context
        let shouldCapitalize = settings.autoCapitalizationEnabled
            && TextBoundary.shouldAutoCapitalize(before: context, mode: traits.autocapitalization)
        shift.applyAutomatic(shouldCapitalize)
        publishState()
    }

    private func publishState() {
        let next = KeyboardViewState(
            layer: layer,
            shift: shift.state,
            interaction: touchEngine.interaction,
            returnKey: traits.returnKey,
            isReturnKeyEnabled: isReturnKeyEnabled
        )
        guard next != state else { return }
        state = next
        delegate?.keyboardEngine(self, didUpdateState: next)
    }

    private func rebuildGeometry(size: CGSize? = nil, metrics: KeyboardMetrics? = nil) {
        let interval = Signposts.layout.beginInterval("Rebuild geometry")
        defer { Signposts.layout.endInterval("Rebuild geometry", interval) }

        let layout = LayoutProvider.layout(
            for: layer,
            context: LayoutContext(variant: traits.variant, showsNextKeyboardKey: showsNextKeyboardKey)
        )
        geometry = KeyboardGeometry(
            layout: layout,
            size: size ?? geometry.size,
            metrics: metrics ?? geometry.metrics
        )
        delegate?.keyboardEngine(self, didUpdateGeometry: geometry)
        publishState()
    }

    private static func initialLayer(for traits: InputTraits) -> KeyboardLayer {
        traits.variant == .numeric ? .numbers : .letters
    }
}

// MARK: - SessionContext

extension KeyboardEngine: SessionContext {
    var currentLayer: KeyboardLayer { layer }

    var calloutBounds: CGRect {
        let dock = geometry.metrics.dockHeight
        return CGRect(x: 0, y: -dock, width: geometry.size.width, height: geometry.size.height + dock)
    }

    func displayText(for character: String) -> String {
        guard shift.state != .off else { return character }
        let upper = character.uppercased()
        return upper.count == character.count ? upper : character
    }

    func emit(_ feedback: FeedbackEvent) {
        delegate?.keyboardEngine(self, didEmit: feedback)
    }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> any Cancellable {
        scheduler.schedule(after: delay) { [weak self] in
            action()
            self?.touchEngine.refreshPresentation()
        }
    }
}
