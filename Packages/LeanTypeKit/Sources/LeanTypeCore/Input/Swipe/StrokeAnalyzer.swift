import CoreGraphics

/// Geometry of strokes: length, even resampling, and the salient points where a letter was
/// most likely intended (start, sharp turns, pauses, end).
enum StrokeAnalyzer {
    /// Spacing used when looking for turns, in points.
    static let turnSpacing: CGFloat = 6
    /// Direction changes sharper than this (radians) are turns.
    static let turnAngle: CGFloat = 0.85
    /// Slower than this (points per second) mid-stroke is a pause on a key.
    static let pauseSpeed: Double = 90
    /// Salient points closer together than this merge into one.
    static let mergeDistance: CGFloat = 14

    static func length(of path: some Collection<CGPoint>) -> CGFloat {
        var total: CGFloat = 0
        var previous: CGPoint?
        for point in path {
            if let previous {
                total += hypot(point.x - previous.x, point.y - previous.y)
            }
            previous = point
        }
        return total
    }

    /// Resamples `path` to exactly `output.count` evenly spaced points, writing into `output`
    /// so hot loops never allocate. A single-point path fills `output` with that point.
    static func resample(_ path: UnsafeBufferPointer<CGPoint>, into output: UnsafeMutableBufferPointer<CGPoint>) {
        let count = output.count
        guard count > 0, let first = path.first else { return }
        let total = length(of: path)
        guard total > 0, count > 1 else {
            for index in 0..<count { output[index] = first }
            return
        }

        let interval = total / CGFloat(count - 1)
        output[0] = first
        var written = 1
        var carried: CGFloat = 0
        var previous = first
        var index = 1
        while index < path.count, written < count {
            let current = path[index]
            let segment = hypot(current.x - previous.x, current.y - previous.y)
            if carried + segment >= interval, segment > 0 {
                let t = (interval - carried) / segment
                let point = CGPoint(x: previous.x + t * (current.x - previous.x), y: previous.y + t * (current.y - previous.y))
                output[written] = point
                written += 1
                previous = point
                carried = 0
            } else {
                carried += segment
                previous = current
                index += 1
            }
        }
        let last = path[path.count - 1]
        while written < count {
            output[written] = last
            written += 1
        }
    }

    /// Start, turns, pauses, and end of one stroke, in time order.
    static func salientPoints(of stroke: [StrokePoint]) -> [StrokePoint] {
        guard let first = stroke.first, let last = stroke.last else { return [] }
        guard stroke.count > 2 else { return first == last ? [first] : [first, last] }

        var salient = [first]
        let spaced = evenlySpaced(stroke, spacing: turnSpacing)
        if spaced.count >= 5 {
            var best: (point: StrokePoint, angle: CGFloat)?
            for index in 2..<(spaced.count - 2) {
                let angle = turnAngle(spaced[index - 2].location, spaced[index].location, spaced[index + 2].location)
                if angle >= Self.turnAngle {
                    if angle > (best?.angle ?? 0) { best = (spaced[index], angle) }
                } else if let found = best {
                    append(found.point, to: &salient)
                    best = nil
                }
            }
            if let best { append(best.point, to: &salient) }
        }

        for index in 1..<(stroke.count - 1) {
            let before = stroke[index - 1]
            let after = stroke[index + 1]
            let elapsed = after.time - before.time
            guard elapsed > 0 else { continue }
            let speed = Double(hypot(after.location.x - before.location.x, after.location.y - before.location.y)) / elapsed
            if speed < pauseSpeed {
                append(stroke[index], to: &salient)
            }
        }

        append(last, to: &salient, force: true)
        return salient.sorted { $0.time < $1.time }
    }

    // MARK: - Private

    private static func append(_ point: StrokePoint, to points: inout [StrokePoint], force: Bool = false) {
        if let near = points.firstIndex(where: { hypot($0.location.x - point.location.x, $0.location.y - point.location.y) < mergeDistance }) {
            if force { points[near] = point }
            return
        }
        points.append(point)
    }

    private static func turnAngle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        let first = atan2(b.y - a.y, b.x - a.x)
        let second = atan2(c.y - b.y, c.x - b.x)
        var delta = abs(second - first)
        if delta > .pi { delta = 2 * .pi - delta }
        return delta
    }

    private static func evenlySpaced(_ stroke: [StrokePoint], spacing: CGFloat) -> [StrokePoint] {
        var result = [stroke[0]]
        var anchor = stroke[0].location
        for point in stroke.dropFirst() where hypot(point.location.x - anchor.x, point.location.y - anchor.y) >= spacing {
            result.append(point)
            anchor = point.location
        }
        return result
    }
}

/// Merges the strokes of one gesture into the path the decoder reads.
enum GestureComposer {
    /// A bend shallower than this, in radians, is the finger sliding on. A row change such as
    /// R between T and A is about thirty-five degrees, so the bar sits just under that. A wobble
    /// stays a crossing. `StrokeAnalyzer.turnAngle` is a sharper test for the raw polyline,
    /// and it would drop those real corners.
    static let aimTurn: CGFloat = 0.50
    /// A bend this sharp is a real hook even when every key is on one row. A shallower wobble
    /// along QWERTY's top or home row stays a graze, so "you" does not have to spell U and I.
    static let sameRowTurn: CGFloat = 1.20
    /// How long a finger must sit on one key before that key is a letter. Travel, however
    /// slow, is not a pause.
    static let dwellDuration: Double = 0.18
    /// A dwell stays inside this radius of the key center, in points.
    static let dwellRadius: CGFloat = 24
    /// Movement beyond this, in points, is the finger leaving rather than pausing.
    static let dwellTravel: CGFloat = 12

    /// `taps` are thumbs that never left their key. They do not change the moving finger's polyline.
    /// `tuning` decides which mid-stroke keys are anchors. The rest stay on the gesture as crossings.
    static func compose(
        _ strokes: [StrokeBuffer],
        taps: [StrokeObservation] = [],
        tuning: EvidenceTuning = .standard
    ) -> SwipeGesture? {
        let strokes = strokes.filter { !$0.points.isEmpty }
        guard !strokes.isEmpty || !taps.isEmpty else { return nil }
        let moving = strokes.max { length($0) < length($1) }
        let path = moving?.points.map(\.location) ?? []
        let strokePaths = strokes.map { $0.points.map(\.location) }
        var events = strokes.enumerated().flatMap { index, stroke in
            strokeEvents(in: stroke, strokeIndex: index, tuning: tuning)
        }
        for (offset, tap) in taps.enumerated() {
            events.append(event(from: tap, finger: offset))
        }
        events.sort { $0.time < $1.time }
        events = collapsingBounces(events)
        events = directed(events)
        let aimed = events.filter(\.isAimed)
        let observations = observations(from: aimed)
        let traced = BeatChooser.collapse(aimed.map(\.letter).joined())
        guard path.count >= 2 || !traced.isEmpty else { return nil }
        let prefersContraction = strokes.contains { StrokeLetters.endsOnApostrophe($0.arrivals) }
        return SwipeGesture(
            path: path,
            strokeCount: max(strokes.count, path.count >= 2 ? 1 : 0),
            strokePaths: strokePaths,
            tracedLetters: traced,
            observations: observations,
            evidence: SwipeEvidence(events: events, aimedLetters: traced),
            prefersContraction: prefersContraction
        )
    }

    // MARK: - Private

    /// Start, lift, sharp turns, and dwells are anchors. Every other key the finger entered
    /// stays as a crossing, so a straight run can still offer the letters it passed through.
    /// A return trip is already gone. Repeating the same letter does not add a second event.
    private static func strokeEvents(in stroke: StrokeBuffer, strokeIndex: Int, tuning: EvidenceTuning) -> [SwipeEvent] {
        let arrivals = StrokeLetters.aimedArrivals(stroke.arrivals)
        guard !arrivals.isEmpty else { return [] }
        // The entry sample is the key boundary, which is still on the way in. The corner
        // happens later, where the finger comes nearest the letter.
        let approaches = arrivals.enumerated().map { index, arrival in
            let end = index + 1 < arrivals.count ? arrivals[index + 1].time : (stroke.points.last?.time ?? arrival.time)
            return closestApproach(to: arrival, until: end, in: stroke)
        }
        var turns: [CGFloat] = []
        turns.reserveCapacity(arrivals.count)
        for (index, _) in arrivals.enumerated() {
            if index > 0, index + 1 < arrivals.count {
                // The finger's path, not the key centers. Centers zigzag across rows even when
                // the stroke is straight, and that was promoting every graze to a corner.
                turns.append(turn(approaches[index - 1], approaches[index], approaches[index + 1]))
            } else {
                turns.append(0)
            }
        }
        var events: [SwipeEvent] = []
        for (index, arrival) in arrivals.enumerated() {
            let nextTime = index + 1 < arrivals.count ? arrivals[index + 1].time : (stroke.points.last?.time ?? arrival.time)
            let approach = approaches[index]
            let turnAngle = turns[index]
            let dwell = dwellDuration(on: arrival, until: nextTime, in: stroke, tuning: tuning)
            let endpoint = index == 0 || index == arrivals.count - 1
            // One corner, one anchor, unless the finger actually landed on this key. A graze
            // on the shoulder of a sharper bend stays a crossing. A second press of the same
            // key, such as the last L in "pill", keeps the key and makes it the endpoint.
            let previousTurn = index > 0 ? turns[index - 1] : 0
            let nextTurn = index + 1 < turns.count ? turns[index + 1] : 0
            let turnBar = onOneRow(arrivals, around: index) ? max(tuning.aimTurn, Self.sameRowTurn) : tuning.aimTurn
            let peaked = turnAngle >= turnBar && turnAngle >= previousTurn && turnAngle >= nextTurn
            let onCenter = hypot(approach.x - arrival.center.x, approach.y - arrival.center.y) <= 8
            let aimedCorner = turnAngle >= turnBar && onCenter
            let anchored = endpoint || peaked || aimedCorner || dwell >= tuning.dwellDuration
            if events.last?.letter == arrival.letter {
                if anchored, let last = events.indices.last {
                    events[last].role = .anchor
                    events[last].time = arrival.time
                    events[last].point = approach
                }
                continue
            }
            events.append(SwipeEvent(
                time: arrival.time,
                point: approach,
                letter: arrival.letter,
                role: anchored ? .anchor : .crossing,
                strokeIndex: strokeIndex,
                turn: turnAngle,
                dwell: dwell,
                speed: speed(at: arrival.time, in: stroke),
                distanceToCenter: hypot(approach.x - arrival.center.x, approach.y - arrival.center.y)
            ))
        }
        return events
    }

    /// The sample nearest this key while it was the key under the thumb.
    private static func closestApproach(to arrival: KeyArrival, until end: Double, in stroke: StrokeBuffer) -> CGPoint {
        var best = arrival.touch
        var bestDistance = hypot(arrival.touch.x - arrival.center.x, arrival.touch.y - arrival.center.y)
        for point in stroke.points where point.time >= arrival.time && point.time <= end {
            let distance = hypot(point.location.x - arrival.center.x, point.location.y - arrival.center.y)
            if distance < bestDistance {
                bestDistance = distance
                best = point.location
            }
        }
        return best
    }

    /// The keys on either side share this key's row. A wobble there is not a corner.
    private static func onOneRow(_ arrivals: [KeyArrival], around index: Int) -> Bool {
        guard index > 0, index + 1 < arrivals.count else { return false }
        let y = arrivals[index].center.y
        return abs(arrivals[index - 1].center.y - y) < 8 && abs(arrivals[index + 1].center.y - y) < 8
    }

    /// Longest stretch the finger stayed near this key without wandering off, in seconds.
    private static func dwellDuration(
        on arrival: KeyArrival,
        until end: Double,
        in stroke: StrokeBuffer,
        tuning: EvidenceTuning
    ) -> Double {
        var spanStart: Double?
        var traveled: CGFloat = 0
        var previous: CGPoint?
        var best = 0.0
        for point in stroke.points where point.time >= arrival.time && point.time <= end {
            let near = hypot(point.location.x - arrival.center.x, point.location.y - arrival.center.y) <= tuning.dwellRadius
            if near {
                if spanStart == nil {
                    spanStart = point.time
                    traveled = 0
                } else if let previous {
                    traveled += hypot(point.location.x - previous.x, point.location.y - previous.y)
                }
                previous = point.location
                if let spanStart, traveled <= tuning.dwellTravel {
                    best = max(best, point.time - spanStart)
                }
            } else {
                spanStart = nil
                traveled = 0
                previous = nil
            }
        }
        return best
    }

    private static func speed(at time: Double, in stroke: StrokeBuffer) -> Double {
        let points = stroke.points
        guard points.count >= 2 else { return 0 }
        var bestIndex = 0
        var bestGap = Double.greatestFiniteMagnitude
        for (index, point) in points.enumerated() {
            let gap = abs(point.time - time)
            if gap < bestGap {
                bestGap = gap
                bestIndex = index
            }
        }
        let current = points[bestIndex]
        let other = bestIndex == 0 ? points[1] : points[bestIndex - 1]
        let elapsed = abs(current.time - other.time)
        guard elapsed > 0 else { return 0 }
        return Double(hypot(current.location.x - other.location.x, current.location.y - other.location.y)) / elapsed
    }

    /// Drops a letter that only bounces back to the one before it ("ghghgh" becomes "gh").
    /// Crossings collapse with the same rule so a wobble does not flood the beam.
    private static func collapsingBounces(_ events: [SwipeEvent]) -> [SwipeEvent] {
        var output: [SwipeEvent] = []
        for event in events {
            if output.count >= 2 {
                let previous = output[output.count - 1].letter
                let before = output[output.count - 2].letter
                if event.letter == before, previous != event.letter {
                    output.removeLast()
                    continue
                }
            }
            output.append(event)
        }
        return output
    }

    private static func directed(_ events: [SwipeEvent]) -> [SwipeEvent] {
        var directed: [SwipeEvent] = []
        directed.reserveCapacity(events.count)
        var previous: CGPoint?
        for event in events {
            var event = event
            if let previous {
                let rawX = event.point.x - previous.x
                let rawY = event.point.y - previous.y
                let length = hypot(rawX, rawY)
                if length > 1 {
                    event.directionX = rawX / length
                    event.directionY = rawY / length
                }
            }
            directed.append(event)
            previous = event.point
        }
        return directed
    }

    private static func event(from tap: StrokeObservation, finger: Int) -> SwipeEvent {
        SwipeEvent(
            time: tap.time,
            point: tap.point,
            letter: tap.letter,
            role: .tap,
            strokeIndex: -2 - finger
        )
    }

    private static func turn(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        let first = atan2(b.y - a.y, b.x - a.x)
        let second = atan2(c.y - b.y, c.x - b.x)
        var delta = abs(second - first)
        if delta > .pi { delta = 2 * .pi - delta }
        return delta
    }

    /// Aimed letters only. Their point stays the key center when the event point is the finger,
    /// so a join still sees where the thumb was aiming. Direction is from the previous aim.
    private static func observations(from events: [SwipeEvent]) -> [StrokeObservation] {
        var result: [StrokeObservation] = []
        var previous: CGPoint?
        for event in events where event.isAimed {
            var directionX: CGFloat = 0
            var directionY: CGFloat = 0
            if let previous {
                let rawX = event.point.x - previous.x
                let rawY = event.point.y - previous.y
                let length = hypot(rawX, rawY)
                if length > 1 {
                    directionX = rawX / length
                    directionY = rawY / length
                }
            }
            result.append(StrokeObservation(
                time: event.time,
                point: event.point,
                directionX: directionX,
                directionY: directionY,
                letter: event.letter,
                isTap: event.isTap,
                strokeIndex: event.isTap ? -1 : event.strokeIndex
            ))
            previous = event.point
        }
        return result
    }

    private static func length(_ stroke: StrokeBuffer) -> CGFloat {
        StrokeAnalyzer.length(of: stroke.points.map(\.location))
    }
}
