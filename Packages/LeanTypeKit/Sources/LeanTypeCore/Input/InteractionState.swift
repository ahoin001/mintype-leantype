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
    /// Set while this finger is scrubbing delete or shift. Letter keys under it are not a swipe.
    var scrub: ScrubMark?

    static let none = SessionPresentation()
}

/// The glyph bite on the key a scrub started on.
public struct ScrubMark: Hashable, Sendable {
    public var keyID: KeyID
    /// The latest step put a letter back, so the key shows the undo arrow.
    public var restoring: Bool
    /// The bite leans this way. Delete travels left; shift travels right.
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

/// Everything about in-flight touches the renderer needs, aggregated across fingers.
public struct InteractionState: Hashable, Sendable {
    public var pressedKeys: Set<KeyID>
    public var callout: CalloutState?
    public var isTrackpadActive: Bool
    /// Fingers currently drawing swipe strokes.
    public var strokes: Set<TouchID>
    /// The shift or delete key currently scrubbing, if a finger that started there is still down.
    public var scrub: ScrubMark?

    public init(
        pressedKeys: Set<KeyID>,
        callout: CalloutState?,
        isTrackpadActive: Bool,
        strokes: Set<TouchID> = [],
        scrub: ScrubMark? = nil
    ) {
        self.pressedKeys = pressedKeys
        self.callout = callout
        self.isTrackpadActive = isTrackpadActive
        self.strokes = strokes
        self.scrub = scrub
    }

    public static let idle = InteractionState(pressedKeys: [], callout: nil, isTrackpadActive: false)
}
