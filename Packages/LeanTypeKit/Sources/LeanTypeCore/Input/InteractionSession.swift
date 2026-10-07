import Foundation

/// What sessions can see and do. Implemented by `KeyboardEngine`.
@MainActor
protocol SessionContext: AnyObject {
    var geometry: KeyboardGeometry { get }
    var settings: KeyboardSettings { get }
    var currentLayer: KeyboardLayer { get }
    var composer: InputComposer { get }
    var isReturnKeyEnabled: Bool { get }
    /// Area callouts may occupy: the key area plus the dock above it.
    var calloutBounds: CGRect { get }

    /// How a character will appear if committed now (shift applied).
    func displayText(for character: String) -> String

    @discardableResult
    func perform(_ intent: KeyboardIntent) -> Bool
    func emit(_ feedback: FeedbackEvent)
    /// Runs `action` later and then refreshes what's on screen.
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> any Cancellable
}

extension SessionContext {
    func previewCallout(for key: KeyFrame) -> CalloutState? {
        guard settings.keyPreviewsEnabled, let character = key.key.kind.character else { return nil }
        let layout = CalloutGeometry.layout(
            anchor: key.visualFrame,
            optionCount: 1,
            metrics: geometry.metrics,
            bounds: calloutBounds
        )
        return CalloutState(keyID: key.id, layout: layout, content: .preview(displayText(for: character)))
    }
}

/// The state machine for one finger, created when it lands and discarded when it lifts.
///
/// Sessions begin in their initializer. After a session commits or gives up it should report
/// `.none` presentation and ignore further events for that finger.
@MainActor
protocol InteractionSession: AnyObject {
    var presentation: SessionPresentation { get }

    func moved(_ track: TouchTrack)
    func ended(_ track: TouchTrack)
    func cancelled()
    /// Another finger landed while this one is down. Tap sessions commit immediately
    /// (rollover) so fast alternating thumbs never drop or reorder keys.
    func otherTouchBegan()
}

/// Produces the session for a finger that lands on a letter key. Tap typing ships in v1; swipe
/// modes (single-finger paths and two-thumb Nintype-style slides) plug in here, emitting into
/// the same `InputComposer`.
@MainActor
protocol TypingMode {
    func makeSession(for key: KeyFrame, track: TouchTrack, context: any SessionContext) -> any InteractionSession
}

struct TapTypingMode: TypingMode {
    func makeSession(for key: KeyFrame, track: TouchTrack, context: any SessionContext) -> any InteractionSession {
        CharacterTapSession(key: key, context: context)
    }
}

/// Picks the session for a finger based on the key it landed on.
@MainActor
struct SessionArbiter {
    var typingMode: any TypingMode = TapTypingMode()

    func makeSession(for key: KeyFrame, track: TouchTrack, context: any SessionContext) -> any InteractionSession {
        switch key.key.kind {
        case .character:
            typingMode.makeSession(for: key, track: track, context: context)
        case .space:
            SpaceSession(key: key, context: context)
        case .backspace:
            BackspaceSession(key: key, context: context)
        case .shift:
            ShiftSession(key: key, context: context)
        case let .layerSwitch(target):
            LayerSwitchSession(key: key, target: target, track: track, context: context)
        case .returnKey:
            TapActionSession(key: key, intent: .returnKey, context: context)
        case .nextKeyboard:
            TapActionSession(key: key, intent: .nextKeyboard, context: context)
        }
    }
}
