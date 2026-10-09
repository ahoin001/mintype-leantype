import Foundation

/// Collects the strokes of one swipe gesture (one finger, or several thumbs sliding in turn),
/// and when the last finger lifts, decodes them and commits the word in its typing-order slot.
///
/// A gesture holds a single composer ticket, taken from the first stroke's tap session, so a
/// letter tapped before the swipe lands before the swiped word and one tapped after waits for
/// the decoder.
@MainActor
final class SwipeCoordinator {
    typealias Decoder = @MainActor (SwipeGesture) async -> DecodeResult

    /// How often a gesture in progress asks the decoder for a preview.
    static let previewSpacing: Duration = .milliseconds(16)

    private let composer: InputComposer
    private let decode: Decoder
    /// Called after a decoded word is committed, so the engine can publish new state.
    var onFinish: (() -> Void)?
    /// A preview of the word being drawn, or `nil` when the gesture ended. Empty results are
    /// not delivered: the previous preview stays up.
    var onPreview: ((DecodeResult?) -> Void)?

    private var active: [TouchID: StrokeBuffer] = [:]
    private var finished: [StrokeBuffer] = []
    /// Letter fingers still down that have not started a stroke. Each is one tap in this beat.
    private var held: [TouchID: StrokeObservation] = [:]
    /// Taps that lifted while the beat was open, in touch-down order.
    private var liftedTaps: [StrokeObservation] = []
    private var ticket: InputComposer.Ticket?
    private var decodeTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewToken = 0
    private var generation = 0
    /// How many samples the preview currently on the bar was decoded from.
    private var previewPointCount = 0
    /// Dwell and the other aim thresholds. The engine scales these as the typist speeds up.
    var evidenceTuning = EvidenceTuning.standard
    /// Letter fingers still deciding between a tap and a stroke. Weak, so a session the touch
    /// engine has already dropped cannot keep the coordinator alive.
    private var undecided: [ObjectIdentifier: WeakSession] = [:]

    private struct WeakSession {
        weak var session: SwipeSession?
    }

    init(composer: InputComposer, decode: @escaping Decoder) {
        self.composer = composer
        self.decode = decode
    }

    /// A stroke or a held letter is still down. The word waits until both have lifted.
    var isCollecting: Bool { !active.isEmpty || !held.isEmpty }

    func registerUndecided(_ session: SwipeSession) {
        undecided[ObjectIdentifier(session)] = WeakSession(session: session)
    }

    func unregisterUndecided(_ session: SwipeSession) {
        undecided.removeValue(forKey: ObjectIdentifier(session))
    }

    /// A letter finger that has not traveled. It stays out of the polyline.
    func hold(_ id: TouchID, _ observation: StrokeObservation) {
        held[id] = observation
    }

    /// The held finger lifted without leaving its key. The letter joins the beat at its touch-down time.
    func liftHold(_ id: TouchID) {
        if let observation = held.removeValue(forKey: id) {
            liftedTaps.append(observation)
        }
        finishIfIdle()
    }

    /// The touch was cancelled. The letter is not part of the word.
    func dropHold(_ id: TouchID) {
        held.removeValue(forKey: id)
        finishIfIdle()
    }

    /// The held finger started to travel, so it becomes a stroke of the same beat.
    func promoteHold(_ id: TouchID, track: TouchTrack) {
        held.removeValue(forKey: id)
        join(track)
    }

    /// A tap that landed and lifted while this beat was open.
    func noteTap(_ observation: StrokeObservation) {
        liftedTaps.append(observation)
        schedulePreview()
    }

    /// Fingers that were waiting when this gesture began become strokes of it.
    func enlistUndecidedPartners() {
        let partners = undecided.values.compactMap(\.session)
        undecided.removeAll()
        for partner in partners {
            partner.joinCurrentGesture()
        }
    }

    /// Starts a gesture with `track` as its first stroke, holding `ticket` for the word.
    func begin(_ track: TouchTrack, ticket: InputComposer.Ticket) {
        if let previous = self.ticket {
            composer.cancel(previous)
        }
        finished.removeAll()
        liftedTaps.removeAll()
        held.removeAll()
        self.ticket = ticket
        add(track)
    }

    /// Adds `track` as another stroke of the gesture in progress.
    func join(_ track: TouchTrack) {
        add(track)
    }

    func moved(_ track: TouchTrack) {
        active[track.id]?.append(Self.point(track.current))
        schedulePreview()
    }

    func arrive(_ id: TouchID, letter: String, at center: CGPoint, touch: CGPoint? = nil, time: Double) {
        active[id]?.arrive(letter, at: center, touch: touch ?? center, time: time)
    }

    func ended(_ track: TouchTrack) {
        guard var stroke = active.removeValue(forKey: track.id) else { return }
        stroke.finish(at: Self.point(track.current))
        finished.append(stroke)
        finishIfIdle()
    }

    func cancelled(_ track: TouchTrack) {
        guard active.removeValue(forKey: track.id) != nil else { return }
        finishIfIdle()
    }

    /// Drops everything in flight, including a decode that hasn't returned yet.
    func reset() {
        invalidatePreview()
        generation += 1
        decodeTask?.cancel()
        decodeTask = nil
        active.removeAll()
        finished.removeAll()
        held.removeAll()
        liftedTaps.removeAll()
        if let ticket {
            composer.cancel(ticket)
        }
        ticket = nil
        onPreview?(nil)
    }

    // MARK: - Private

    private func add(_ track: TouchTrack) {
        var stroke = StrokeBuffer(start: Self.point(track.start))
        if track.current.timestamp > track.start.timestamp {
            stroke.append(Self.point(track.current))
        }
        active[track.id] = stroke
    }

    private func finishIfIdle() {
        guard active.isEmpty, held.isEmpty else { return }
        finishGesture()
    }

    private func pendingTaps() -> [StrokeObservation] {
        liftedTaps + Array(held.values)
    }

    private func finishGesture() {
        let strokes = finished
        let taps = liftedTaps
        finished.removeAll()
        liftedTaps.removeAll()
        guard let ticket else { return }
        self.ticket = nil

        invalidatePreview()
        guard let gesture = GestureComposer.compose(strokes, taps: taps, tuning: evidenceTuning),
              gesture.path.count >= 2 || !gesture.tracedLetters.isEmpty else {
            composer.cancel(ticket)
            onPreview?(nil)
            return
        }
        generation += 1
        let expected = generation
        decodeTask = Task { [weak self, decode] in
            let result = await decode(gesture)
            guard let self else { return }
            // A newer gesture (or a reset) took over while this decode ran. Drop the slot or
            // every later tap waits behind a ticket that will never resolve.
            guard expected == generation else {
                composer.cancel(ticket)
                return
            }
            decodeTask = nil
            commit(result, gesture: gesture, ticket: ticket)
            onPreview?(nil)
            onFinish?()
        }
    }

    /// The decoded word, or the letters the thumbs aimed at when nothing matched.
    /// A return trip is already gone from those letters, so it cannot be typed.
    private func commit(_ result: DecodeResult, gesture: SwipeGesture, ticket: InputComposer.Ticket) {
        if !result.isEmpty {
            composer.commit(ticket, [.commitSwipe(result.words, unsure: result.isUnsure, strokes: gesture.strokeCount, observations: gesture.observations, strokePaths: gesture.strokePaths)])
            return
        }
        let traced = gesture.tracedLetters
        if traced.isEmpty {
            composer.cancel(ticket)
        } else if traced.count == 1 {
            composer.commit(ticket, [.insert(traced)])
        } else {
            composer.commit(ticket, [.commitSwipe([traced], unsure: true, strokes: gesture.strokeCount, observations: gesture.observations, strokePaths: gesture.strokePaths)])
        }
    }

    /// One preview at a time. The wait batches the points that arrive while it sleeps, and the
    /// generation check drops a preview that returns after the finger has lifted.
    private func schedulePreview() {
        guard previewTask == nil else { return }
        previewToken += 1
        let token = previewToken
        let expected = generation
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: Self.previewSpacing)
            guard let self else { return }
            guard token == previewToken, expected == generation, isCollecting else {
                previewTask = nil
                return
            }
            let strokes = finished + active.values
            guard let gesture = GestureComposer.compose(strokes, taps: pendingTaps(), tuning: evidenceTuning) else {
                previewTask = nil
                return
            }
            let result = await decode(gesture)
            previewTask = nil
            guard token == previewToken, expected == generation, isCollecting else { return }
            let grown = gesture.path.count
            let missed = result.isEmpty || (result.readings.first?.score ?? 0) < AlignmentCosts.previewFloor
            if missed, grown >= 8, previewPointCount >= 4, grown > previewPointCount {
                previewPointCount = grown
                onPreview?(DecodeResult(readings: [], withdrawsPreview: true))
                return
            }
            guard !result.isEmpty else { return }
            previewPointCount = grown
            onPreview?(result)
        }
    }

    private func invalidatePreview() {
        generation += 1
        previewToken += 1
        previewPointCount = 0
        previewTask?.cancel()
        previewTask = nil
    }

    private static func point(_ sample: TouchSample) -> StrokePoint {
        StrokePoint(location: sample.location, time: sample.timestamp)
    }
}
