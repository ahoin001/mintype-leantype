/// Tracks every finger on the keyboard, routes each to its own session, and aggregates what
/// the sessions want drawn. Knows nothing about UIKit; the view feeds it `TouchSample`s.
@MainActor
final class TouchEngine {
    private struct ActiveTouch {
        var track: TouchTrack
        let session: any InteractionSession
        /// The finger was taken over by another finger's session (e.g. two-finger trackpad).
        let isAbsorbed: Bool
    }

    private unowned let context: any SessionContext
    var arbiter = SessionArbiter()
    private var touches: [TouchID: ActiveTouch] = [:]
    /// Touch-down order, so the most recent finger's callout wins.
    private var order: [TouchID] = []

    private(set) var interaction = InteractionState.idle
    var onInteractionChange: ((InteractionState) -> Void)?

    init(context: any SessionContext) {
        self.context = context
    }

    var hasActiveTouches: Bool {
        !touches.isEmpty
    }

    /// Processes a batch of samples (typically one UIKit event, including coalesced moves)
    /// and publishes presentation changes once at the end.
    func handle(_ samples: [TouchSample]) {
        for sample in samples {
            process(sample)
        }
        refreshPresentation()
    }

    func cancelAll() {
        let active = order.compactMap { touches[$0] }.filter { !$0.isAbsorbed }
        touches.removeAll()
        order.removeAll()
        active.forEach { $0.session.cancelled() }
        refreshPresentation()
    }

    func refreshPresentation() {
        var pressed = Set<KeyID>()
        var callout: CalloutState?
        var isTrackpadActive = false
        var strokes = Set<TouchID>()

        for id in order {
            guard let touch = touches[id], !touch.isAbsorbed else { continue }
            let presentation = touch.session.presentation
            if let key = presentation.pressedKey {
                pressed.insert(key)
            }
            callout = presentation.callout ?? callout
            isTrackpadActive = isTrackpadActive || presentation.isTrackpadActive
            if presentation.isStroke {
                strokes.insert(id)
            }
        }

        let next = InteractionState(
            pressedKeys: pressed,
            callout: callout,
            isTrackpadActive: isTrackpadActive,
            strokes: strokes
        )
        guard next != interaction else { return }
        interaction = next
        onInteractionChange?(next)
    }

    private func process(_ sample: TouchSample) {
        switch sample.phase {
        case .began:
            guard touches[sample.id] == nil, let key = context.geometry.key(at: sample.location) else { return }
            let track = TouchTrack(start: sample)
            if let owner = absorbingSession(for: track) {
                touches[sample.id] = ActiveTouch(track: track, session: owner, isAbsorbed: true)
                order.append(sample.id)
                return
            }
            for id in order where touches[id]?.isAbsorbed == false {
                touches[id]?.session.otherTouchBegan()
            }
            let session = arbiter.makeSession(for: key, track: track, context: context)
            touches[sample.id] = ActiveTouch(track: track, session: session, isAbsorbed: false)
            order.append(sample.id)

        case .moved:
            guard var active = touches[sample.id] else { return }
            active.track.append(sample)
            touches[sample.id] = active
            if active.isAbsorbed {
                active.session.absorbedTouchMoved(active.track)
            } else {
                active.session.moved(active.track)
            }

        case .ended:
            guard var active = remove(sample.id) else { return }
            active.track.append(sample)
            if active.isAbsorbed {
                active.session.absorbedTouchEnded(active.track)
            } else {
                active.session.ended(active.track)
            }

        case .cancelled:
            guard let active = remove(sample.id) else { return }
            if active.isAbsorbed {
                active.session.absorbedTouchEnded(active.track)
            } else {
                active.session.cancelled()
            }
        }
    }

    /// The most recent primary session that wants to take over a newly landed finger.
    private func absorbingSession(for track: TouchTrack) -> (any InteractionSession)? {
        for id in order.reversed() {
            guard let touch = touches[id], !touch.isAbsorbed else { continue }
            if touch.session.absorbTouch(track) {
                return touch.session
            }
        }
        return nil
    }

    private func remove(_ id: TouchID) -> ActiveTouch? {
        order.removeAll { $0 == id }
        return touches.removeValue(forKey: id)
    }
}
