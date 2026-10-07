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
    static let previewSpacing: Duration = .milliseconds(50)

    private let composer: InputComposer
    private let decode: Decoder
    /// Called after a decoded word is committed, so the engine can publish new state.
    var onFinish: (() -> Void)?
    /// A preview of the word being drawn, or `nil` when the gesture ended. Empty results are
    /// not delivered: the previous preview stays up.
    var onPreview: ((DecodeResult?) -> Void)?

    private var active: [TouchID: StrokeBuffer] = [:]
    private var finished: [StrokeBuffer] = []
    private var ticket: InputComposer.Ticket?
    private var decodeTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewToken = 0
    private var generation = 0

    init(composer: InputComposer, decode: @escaping Decoder) {
        self.composer = composer
        self.decode = decode
    }

    /// Fingers are down drawing a gesture; new fingers on letters join it.
    var isCollecting: Bool { !active.isEmpty }

    /// Starts a gesture with `track` as its first stroke, holding `ticket` for the word.
    func begin(_ track: TouchTrack, ticket: InputComposer.Ticket) {
        if let previous = self.ticket {
            composer.cancel(previous)
        }
        finished.removeAll()
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

    func ended(_ track: TouchTrack) {
        guard var stroke = active.removeValue(forKey: track.id) else { return }
        stroke.finish(at: Self.point(track.current))
        finished.append(stroke)
        if active.isEmpty {
            finishGesture()
        }
    }

    func cancelled(_ track: TouchTrack) {
        guard active.removeValue(forKey: track.id) != nil else { return }
        if active.isEmpty {
            finishGesture()
        }
    }

    /// Drops everything in flight, including a decode that hasn't returned yet.
    func reset() {
        invalidatePreview()
        generation += 1
        decodeTask?.cancel()
        decodeTask = nil
        active.removeAll()
        finished.removeAll()
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

    private func finishGesture() {
        let strokes = finished.map(\.points)
        finished.removeAll()
        guard let ticket else { return }
        self.ticket = nil

        invalidatePreview()
        guard let gesture = GestureComposer.compose(strokes) else {
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
            if result.isEmpty {
                composer.cancel(ticket)
            } else {
                composer.commit(ticket, [.commitSwipe(result.words, unsure: result.isUnsure)])
            }
            onPreview?(nil)
            onFinish?()
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
            previewTask = nil
            guard token == previewToken, expected == generation, isCollecting else { return }
            let strokes = finished.map(\.points) + active.values.map(\.points)
            guard let gesture = GestureComposer.compose(strokes) else { return }
            let result = await decode(gesture)
            guard token == previewToken, expected == generation, isCollecting, !result.isEmpty else { return }
            onPreview?(result)
        }
    }

    private func invalidatePreview() {
        generation += 1
        previewToken += 1
        previewTask?.cancel()
        previewTask = nil
    }

    private static func point(_ sample: TouchSample) -> StrokePoint {
        StrokePoint(location: sample.location, time: sample.timestamp)
    }
}
