/// Tracks every finger on the keyboard, routes each to its own session, and aggregates what
/// the sessions want drawn. Knows nothing about UIKit; the view feeds it `TouchSample`s.
@MainActor
final class TouchEngine {
    private struct ActiveTouch {
        var track: TouchTrack
        let session: any InteractionSession
    }

    private unowned let context: any SessionContext
    private var arbiter = SessionArbiter()
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
        let active = order.compactMap { touches[$0] }
        touches.removeAll()
        order.removeAll()
        active.forEach { $0.session.cancelled() }
        refreshPresentation()
    }

    func refreshPresentation() {
        var pressed = Set<KeyID>()
        var callout: CalloutState?
        var isTrackpadActive = false

        for id in order {
            guard let presentation = touches[id]?.session.presentation else { continue }
            if let key = presentation.pressedKey {
                pressed.insert(key)
            }
            callout = presentation.callout ?? callout
            isTrackpadActive = isTrackpadActive || presentation.isTrackpadActive
        }

        let next = InteractionState(pressedKeys: pressed, callout: callout, isTrackpadActive: isTrackpadActive)
        guard next != interaction else { return }
        interaction = next
        onInteractionChange?(next)
    }

    private func process(_ sample: TouchSample) {
        switch sample.phase {
        case .began:
            guard touches[sample.id] == nil, let key = context.geometry.key(at: sample.location) else { return }
            for id in order {
                touches[id]?.session.otherTouchBegan()
            }
            let track = TouchTrack(start: sample)
            let session = arbiter.makeSession(for: key, track: track, context: context)
            touches[sample.id] = ActiveTouch(track: track, session: session)
            order.append(sample.id)

        case .moved:
            guard var active = touches[sample.id] else { return }
            active.track.append(sample)
            touches[sample.id] = active
            active.session.moved(active.track)

        case .ended:
            guard var active = remove(sample.id) else { return }
            active.track.append(sample)
            active.session.ended(active.track)

        case .cancelled:
            remove(sample.id)?.session.cancelled()
        }
    }

    private func remove(_ id: TouchID) -> ActiveTouch? {
        order.removeAll { $0 == id }
        return touches.removeValue(forKey: id)
    }
}
