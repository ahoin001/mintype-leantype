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
    /// The last finger lifted. The engine keeps the beat open for the leash, then calls `finishNow`.
    var onBeatIdle: (() -> Void)?
    /// A new stroke or tap joined the beat, so the leash wait should be cancelled.
    var onBeatContinued: (() -> Void)?

    private var active: [TouchID: StrokeBuffer] = [:]
    private var finished: [StrokeBuffer] = []
    /// Letter fingers still down that have not started a stroke. Each is one tap in this beat.
    private var held: [TouchID: StrokeObservation] = [:]
    /// Holds that are an accent popup, so a long dwell still types the letter.
    private var accentHolds: Set<TouchID> = []
    /// Taps that lifted while the beat was open, in touch-down order.
    private var liftedTaps: [StrokeObservation] = []
    /// A letter that lifted while a partner was still down, before any stroke existed.
    /// Its composer ticket stays pending so nothing types until the partner travels or lifts.
    private var parked: [ParkedTap] = []
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
    /// The fingers are up and the beat is waiting out the leash before it decodes.
    private var holdingBeat = false
    /// The preview decode for an observation set that has not changed since.
    private var previewCache: (identity: Int, result: DecodeResult)?
    /// Space, return, or punctuation that should follow the word once it commits.
    private var trailing: [KeyboardIntent] = []

    private struct WeakSession {
        weak var session: SwipeSession?
    }

    private struct ParkedTap {
        var observation: StrokeObservation
        var character: String
        var ticket: InputComposer.Ticket
    }

    init(composer: InputComposer, decode: @escaping Decoder) {
        self.composer = composer
        self.decode = decode
    }

    /// A stroke, a held letter, or a beat waiting out the leash. The word waits for the last of these.
    var isCollecting: Bool { !active.isEmpty || !held.isEmpty || holdingBeat }

    /// A letter finger is on the glass, whether or not it has started to draw.
    var hasLetterFingerDown: Bool {
        !active.isEmpty || !held.isEmpty || liveUndecidedCount > 0
    }

    /// Another letter finger besides `session`, or none when `session` is nil and any finger is down.
    func hasLetterFingerDown(besides session: SwipeSession?) -> Bool {
        if !active.isEmpty || !held.isEmpty { return true }
        for entry in undecided.values {
            guard let other = entry.session else { continue }
            if let session, other === session { continue }
            return true
        }
        return false
    }

    /// Moving strokes already in this beat, including ones that have lifted.
    var strokeChainCount: Int { active.count + finished.count }

    /// The beat is only waiting out the leash. A new stroke should decode it instead of raw-merging.
    var isIdleHold: Bool { holdingBeat && active.isEmpty && held.isEmpty }

    /// Drops the latest tap in an open beat and refreshes the preview. Committed text stays.
    func dropLatestObservation() -> Bool {
        guard isCollecting || holdingBeat else { return false }
        guard let index = liftedTaps.indices.max(by: { liftedTaps[$0].time < liftedTaps[$1].time }) else {
            return !active.isEmpty || !finished.isEmpty || !held.isEmpty
        }
        liftedTaps.remove(at: index)
        schedulePreview()
        return true
    }

    /// A new travel may open a chain. The thumb that already lifted can start again.
    /// A second finger down at once takes the other chain. A third finger stays a tap.
    func chainThumb(preferring side: Int) -> Int? {
        ThumbLanes(active: Set(active.values.map(\.thumb))).assigned(side)
    }

    func registerUndecided(_ session: SwipeSession) {
        undecided[ObjectIdentifier(session)] = WeakSession(session: session)
    }

    func unregisterUndecided(_ session: SwipeSession) {
        undecided.removeValue(forKey: ObjectIdentifier(session))
    }

    /// A letter finger that has not traveled. It stays out of the polyline.
    /// `keepsRest` is an accent popup: the letter stays even after a long dwell.
    func hold(_ id: TouchID, keepsRest: Bool = false, _ observation: StrokeObservation) {
        held[id] = observation
        if keepsRest {
            accentHolds.insert(id)
        } else {
            accentHolds.remove(id)
        }
    }

    /// The held finger lifted without leaving its key. The letter joins the beat at its touch-down time.
    /// A long rest beside another stroke stays, and the dictionary may skip it.
    func liftHold(_ id: TouchID, at time: Double) {
        let keepsRest = accentHolds.remove(id) != nil
        if var observation = held.removeValue(forKey: id) {
            let elapsed = time - observation.time
            if !keepsRest, elapsed >= SwipeSession.restDuration, strokeChainCount > 0 {
                observation.mark = .rest
            } else if elapsed >= GestureComposer.dwellDuration {
                observation.mark = .pin
            }
            liftedTaps.append(observation)
        }
        finishIfIdle()
    }

    /// The touch was cancelled. The letter is not part of the word.
    func dropHold(_ id: TouchID) {
        held.removeValue(forKey: id)
        accentHolds.remove(id)
        finishIfIdle()
    }

    /// The held finger started to travel, so it becomes a stroke of the same beat.
    func promoteHold(_ id: TouchID, track: TouchTrack, keyWidth: CGFloat, thumb: Int) {
        held.removeValue(forKey: id)
        accentHolds.remove(id)
        join(track, keyWidth: keyWidth, thumb: thumb)
    }

    /// The accent row stays closed while a partner is down or a beat is already open.
    func blocksAccent(for session: SwipeSession) -> Bool {
        isCollecting || hasLetterFingerDown(besides: session)
    }

    /// Keeps a lifted letter out of the document while a partner finger is still down.
    func parkTap(_ observation: StrokeObservation, character: String, ticket: InputComposer.Ticket) {
        parked.append(ParkedTap(observation: observation, character: character, ticket: ticket))
    }

    /// The partner never traveled. The parked letters type in touch-down order.
    func releaseParkedTaps() {
        let taps = parked.sorted { $0.observation.time < $1.observation.time }
        parked.removeAll()
        for tap in taps {
            composer.commit(tap.ticket, [.tapCharacter(tap.character, at: tap.observation.point, time: tap.observation.time)])
        }
    }

    /// A stroke started. The parked letters join it, and their tickets do not also type.
    func absorbParkedTaps() {
        let taps = parked
        parked.removeAll()
        for tap in taps {
            composer.cancel(tap.ticket)
            liftedTaps.append(tap.observation)
        }
    }

    /// A tap that landed and lifted while this beat was open.
    func noteTap(_ observation: StrokeObservation) {
        noteContinued()
        liftedTaps.append(observation)
        schedulePreview()
        finishIfIdle()
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
    func begin(_ track: TouchTrack, ticket: InputComposer.Ticket, keyWidth: CGFloat = StrokeBuffer.referenceKeyWidth, thumb: Int = 0) {
        if let previous = self.ticket {
            composer.cancel(previous)
        }
        finished.removeAll()
        liftedTaps.removeAll()
        held.removeAll()
        accentHolds.removeAll()
        absorbParkedTaps()
        self.ticket = ticket
        add(track, keyWidth: keyWidth, thumb: thumb)
    }

    /// Adds `track` as another stroke of the gesture in progress.
    func join(_ track: TouchTrack, keyWidth: CGFloat = StrokeBuffer.referenceKeyWidth, thumb: Int = 0) {
        noteContinued()
        add(track, keyWidth: keyWidth, thumb: thumb)
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
        accentHolds.removeAll()
        liftedTaps.removeAll()
        for tap in parked {
            composer.cancel(tap.ticket)
        }
        parked.removeAll()
        holdingBeat = false
        trailing.removeAll()
        if let ticket {
            composer.cancel(ticket)
        }
        ticket = nil
        onPreview?(nil)
    }

    // MARK: - Private

    private func add(_ track: TouchTrack, keyWidth: CGFloat, thumb: Int) {
        var stroke = StrokeBuffer(start: Self.point(track.start), keyWidth: keyWidth, thumb: thumb)
        if track.current.timestamp > track.start.timestamp {
            stroke.append(Self.point(track.current))
        }
        active[track.id] = stroke
    }

    private func finishIfIdle() {
        guard active.isEmpty, held.isEmpty else { return }
        guard ticket != nil, !finished.isEmpty || !liftedTaps.isEmpty else {
            holdingBeat = false
            if let ticket {
                composer.cancel(ticket)
                self.ticket = nil
            }
            return
        }
        holdingBeat = true
        if let onBeatIdle {
            onBeatIdle()
        } else {
            finishGesture()
        }
    }

    /// Commits the open beat now. Fingers still down are included. Returns false when there is nothing to commit.
    @discardableResult
    func finishNow(then intents: [KeyboardIntent] = []) -> Bool {
        let pending = ticket != nil && (holdingBeat || !active.isEmpty || !finished.isEmpty || !held.isEmpty || !liftedTaps.isEmpty)
        guard pending else { return false }
        absorbParkedTaps()
        trailing.append(contentsOf: intents)
        noteContinued()
        for stroke in active.values {
            var stroke = stroke
            stroke.finish(at: stroke.end)
            finished.append(stroke)
        }
        active.removeAll()
        liftedTaps.append(contentsOf: held.values)
        held.removeAll()
        accentHolds.removeAll()
        finishGesture()
        return true
    }

    private func noteContinued() {
        guard holdingBeat else { return }
        holdingBeat = false
        onBeatContinued?()
    }

    private var liveUndecidedCount: Int {
        undecided.values.compactMap(\.session).count
    }

    private func pendingTaps() -> [StrokeObservation] {
        liftedTaps + Array(held.values)
    }

    private func finishGesture() {
        let strokes = finished
        let taps = liftedTaps
        let extra = trailing
        finished.removeAll()
        liftedTaps.removeAll()
        trailing.removeAll()
        holdingBeat = false
        guard let ticket else { return }
        self.ticket = nil

        let cached = previewCache
        invalidatePreview()
        guard let gesture = GestureComposer.compose(strokes, taps: taps, tuning: evidenceTuning),
              gesture.path.count >= 2 || !gesture.tracedLetters.isEmpty else {
            if extra.isEmpty {
                composer.cancel(ticket)
            } else {
                composer.commit(ticket, extra)
            }
            onPreview?(nil)
            return
        }
        if let cached, cached.identity == Self.identity(of: gesture) {
            commit(cached.result, gesture: gesture, ticket: ticket, then: extra)
            onPreview?(nil)
            onFinish?()
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
            commit(result, gesture: gesture, ticket: ticket, then: extra)
            onPreview?(nil)
            onFinish?()
        }
    }

    /// The decoded word, or the letters the thumbs aimed at when nothing matched.
    /// A return trip is already gone from those letters, so it cannot be typed.
    private func commit(_ result: DecodeResult, gesture: SwipeGesture, ticket: InputComposer.Ticket, then extra: [KeyboardIntent]) {
        var intents: [KeyboardIntent]
        if !result.isEmpty {
            intents = [.commitSwipe(result.words, unsure: result.isUnsure, strokes: gesture.strokeCount, observations: gesture.observations, strokePaths: gesture.strokePaths)]
        } else {
            let traced = gesture.tracedLetters
            if traced.isEmpty {
                intents = []
            } else if traced.count == 1 {
                intents = [.insert(traced)]
            } else {
                intents = [.commitSwipe([traced], unsure: true, strokes: gesture.strokeCount, observations: gesture.observations, strokePaths: gesture.strokePaths)]
            }
        }
        intents.append(contentsOf: extra)
        if intents.isEmpty {
            composer.cancel(ticket)
        } else {
            composer.commit(ticket, intents)
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
            previewCache = (Self.identity(of: gesture), result)
            onPreview?(result)
        }
    }

    private func invalidatePreview() {
        generation += 1
        previewToken += 1
        previewPointCount = 0
        previewTask?.cancel()
        previewTask = nil
        previewCache = nil
    }

    private static func identity(of gesture: SwipeGesture) -> Int {
        var hasher = Hasher()
        hasher.combine(gesture.tracedLetters)
        hasher.combine(gesture.path.count)
        for observation in gesture.observations {
            hasher.combine(observation.time)
            hasher.combine(observation.letter)
            hasher.combine(observation.mark)
        }
        return hasher.finalize()
    }

    private static func point(_ sample: TouchSample) -> StrokePoint {
        StrokePoint(location: sample.location, time: sample.timestamp)
    }
}

    /// Which thumbs are drawing right now. A thumb that has lifted is not active, so it can start again.
    /// A second finger that lands while one thumb is drawing takes the other chain, even on the same side.
    struct ThumbLanes: Equatable, Sendable {
        var active: Set<Int>

        func assigned(_ preferred: Int) -> Int? {
            if active.count >= 2 { return nil }
            if !active.contains(preferred) { return preferred }
            let other = preferred == 0 ? 1 : 0
            if active.contains(other) { return nil }
            return other
        }
    }
