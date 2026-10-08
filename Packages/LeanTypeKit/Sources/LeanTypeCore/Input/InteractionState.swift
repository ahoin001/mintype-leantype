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

    static let none = SessionPresentation()
}

/// Everything about in-flight touches the renderer needs, aggregated across fingers.
public struct InteractionState: Hashable, Sendable {
    public var pressedKeys: Set<KeyID>
    public var callout: CalloutState?
    public var isTrackpadActive: Bool
    /// Fingers currently drawing swipe strokes.
    public var strokes: Set<TouchID>

    public init(pressedKeys: Set<KeyID>, callout: CalloutState?, isTrackpadActive: Bool, strokes: Set<TouchID> = []) {
        self.pressedKeys = pressedKeys
        self.callout = callout
        self.isTrackpadActive = isTrackpadActive
        self.strokes = strokes
    }

    public static let idle = InteractionState(pressedKeys: [], callout: nil, isTrackpadActive: false)
}
