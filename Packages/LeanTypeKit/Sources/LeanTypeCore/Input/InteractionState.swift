import CoreGraphics

/// A callout drawn above a key: either a preview of the pressed letter or a row of long-press
/// alternates with one selected.
public struct CalloutState: Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        case preview(String)
        case alternates([String], selectedIndex: Int)
    }

    public let keyID: KeyID
    public let layout: CalloutLayout
    public let content: Content
    /// The balloon scales up out of its key. Letter previews stay instant.
    public let growsFromKey: Bool

    public init(keyID: KeyID, layout: CalloutLayout, content: Content, growsFromKey: Bool = false) {
        self.keyID = keyID
        self.layout = layout
        self.content = content
        self.growsFromKey = growsFromKey
    }
}

/// What one finger's session wants drawn right now.
struct SessionPresentation {
    var pressedKey: KeyID?
    var callout: CalloutState?
    var isTrackpadActive = false
    /// The finger is drawing a swipe stroke (and should leave a trail).
    var isStroke = false
    /// Set while this finger is scrubbing or the space bar is a trackpad.
    var jewel: GestureMark?

    static let none = SessionPresentation()
}

/// One step of a delete scrub: which key, whether the step put a letter back, and which way it leaned.
public struct ScrubMark: Hashable, Sendable {
    public var keyID: KeyID
    /// The latest step put a letter back.
    public var restoring: Bool
    /// The bite leans this way. Deleting travels left. Restoring travels right.
    public var travelsRight: Bool
    /// Increments on every letter removed or put back, so a second bite in the same direction still plays.
    public var step: Int

    public init(keyID: KeyID, restoring: Bool, travelsRight: Bool, step: Int) {
        self.keyID = keyID
        self.restoring = restoring
        self.travelsRight = travelsRight
        self.step = step
    }
}

/// Where a scrub or trackpad finger is, so the jewel can sit above the contact.
public struct GestureMark: Hashable, Sendable {
    public enum Action: Hashable, Sendable {
        case scrub(ScrubMark)
        case trackpad
    }

    public var contact: CGPoint
    public var action: Action

    public init(contact: CGPoint, action: Action) {
        self.contact = contact
        self.action = action
    }
}

/// Everything about in-flight touches the renderer needs, aggregated across fingers.
public struct InteractionState: Hashable, Sendable {
    public var pressedKeys: Set<KeyID>
    public var callout: CalloutState?
    public var isTrackpadActive: Bool
    /// Fingers currently drawing swipe strokes.
    public var strokes: Set<TouchID>
    /// The scrub or trackpad finger, so a jewel can ride above it.
    public var jewel: GestureMark?

    public init(
        pressedKeys: Set<KeyID>,
        callout: CalloutState?,
        isTrackpadActive: Bool,
        strokes: Set<TouchID> = [],
        jewel: GestureMark? = nil
    ) {
        self.pressedKeys = pressedKeys
        self.callout = callout
        self.isTrackpadActive = isTrackpadActive
        self.strokes = strokes
        self.jewel = jewel
    }

    public static let idle = InteractionState(pressedKeys: [], callout: nil, isTrackpadActive: false)
}
