import CoreGraphics

/// How sure the geometry is that a thumb meant this key.
enum EvidenceRole: Hashable, Sendable {
    /// Start, lift, a sharp turn, or a real dwell. Skipping one is expensive.
    case anchor
    /// A key the path passed through. The beam may insert it.
    case crossing
    /// A thumb that tapped and never drew.
    case tap
}

/// One letter a thumb reached or crossed, with the measurements a later tuning pass can use.
struct SwipeEvent: Hashable, Sendable {
    var time: Double
    var point: CGPoint
    var letter: String
    var role: EvidenceRole
    /// Which moving stroke this belongs to. Each tap gets its own negative index, so two
    /// taps can swap as different fingers. `-1` is unused.
    var strokeIndex: Int
    /// Heading change through this key, in radians. Endpoints stay at zero.
    var turn: CGFloat
    /// How long the finger sat on this key, in seconds.
    var dwell: Double
    /// Speed at the moment the key was entered, in points per second.
    var speed: Double
    /// Distance from the finger to the key center, in points.
    var distanceToCenter: CGFloat
    var directionX: CGFloat
    var directionY: CGFloat

    var isTap: Bool { role == .tap }

    /// An aimed letter: an anchor or a tap. Crossings are evidence, not aim.
    var isAimed: Bool { role == .anchor || role == .tap }

    init(
        time: Double,
        point: CGPoint,
        letter: String,
        role: EvidenceRole,
        strokeIndex: Int,
        turn: CGFloat = 0,
        dwell: Double = 0,
        speed: Double = 0,
        distanceToCenter: CGFloat = 0,
        directionX: CGFloat = 0,
        directionY: CGFloat = 0
    ) {
        self.time = time
        self.point = point
        self.letter = letter
        self.role = role
        self.strokeIndex = strokeIndex
        self.turn = turn
        self.dwell = dwell
        self.speed = speed
        self.distanceToCenter = distanceToCenter
        self.directionX = directionX
        self.directionY = directionY
    }

    /// A tap or an already-aimed stroke letter, for joins that no longer have the polyline.
    static func fromObservation(_ observation: StrokeObservation, tapFinger: Int = 0) -> SwipeEvent {
        SwipeEvent(
            time: observation.time,
            point: observation.point,
            letter: observation.letter,
            role: observation.isTap ? .tap : .anchor,
            strokeIndex: observation.isTap ? -2 - tapFinger : observation.strokeIndex,
            directionX: observation.directionX,
            directionY: observation.directionY
        )
    }
}

/// Everything one beat can tell the decoder: aimed letters and the keys the path only crossed.
public struct SwipeEvidence: Hashable, Sendable {
    var events: [SwipeEvent]
    /// Anchors and taps, bounce-collapsed. Join rules read this, not the crossings.
    var aimedLetters: String

    public static let empty = SwipeEvidence(events: [], aimedLetters: "")

    /// Aimed events in time order, for a beat that was stored as observations.
    static func fromObservations(_ observations: [StrokeObservation]) -> SwipeEvidence {
        var tapFinger = 0
        let events = observations.map { observation -> SwipeEvent in
            let event = SwipeEvent.fromObservation(observation, tapFinger: tapFinger)
            if observation.isTap { tapFinger += 1 }
            return event
        }
        let aimed = BeatChooser.collapse(events.filter(\.isAimed).map(\.letter).joined())
        return SwipeEvidence(events: events, aimedLetters: aimed)
    }
}

/// Thresholds that decide an anchor versus a crossing. The session rhythm scales the dwell.
struct EvidenceTuning: Hashable, Sendable {
    var aimTurn: CGFloat = GestureComposer.aimTurn
    var dwellDuration: Double = GestureComposer.dwellDuration
    var dwellRadius: CGFloat = GestureComposer.dwellRadius
    var dwellTravel: CGFloat = GestureComposer.dwellTravel

    static let standard = EvidenceTuning()
}
