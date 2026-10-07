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
    static func compose(_ strokes: [StrokeBuffer]) -> SwipeGesture? {
        let strokes = strokes.filter { !$0.points.isEmpty }
        guard !strokes.isEmpty else { return nil }
        let traced = tracedLetters(in: strokes)
        let observations = observations(in: strokes)
        if strokes.count == 1 {
            return SwipeGesture(
                path: strokes[0].points.map(\.location),
                strokeCount: 1,
                tracedLetters: traced,
                observations: observations
            )
        }

        let arrivals = strokes.flatMap(\.arrivals).sorted { $0.time < $1.time }
        var path: [CGPoint] = []
        var letters: [String] = []
        for arrival in arrivals where letters.last != arrival.letter {
            letters.append(arrival.letter)
            path.append(arrival.center)
        }
        if path.count >= 2 {
            return SwipeGesture(path: path, strokeCount: strokes.count, tracedLetters: traced, observations: observations)
        }

        let salient = strokes
            .flatMap { StrokeAnalyzer.salientPoints(of: $0.points) }
            .sorted { $0.time < $1.time }
            .map(\.location)
        return SwipeGesture(path: salient, strokeCount: strokes.count, tracedLetters: traced, observations: observations)
    }

    /// One observation per new letter, in the order thumbs reached them, with the direction
    /// of travel from the previous letter.
    private static func observations(in strokes: [StrokeBuffer]) -> [StrokeObservation] {
        let arrivals = strokes.flatMap(\.arrivals).sorted { $0.time < $1.time }
        var result: [StrokeObservation] = []
        var previous: CGPoint?
        for arrival in arrivals {
            if result.last?.letter == arrival.letter {
                previous = arrival.center
                continue
            }
            var directionX: CGFloat = 0
            var directionY: CGFloat = 0
            if let previous {
                let rawX = arrival.center.x - previous.x
                let rawY = arrival.center.y - previous.y
                let length = hypot(rawX, rawY)
                if length > 1 {
                    directionX = rawX / length
                    directionY = rawY / length
                }
            }
            result.append(StrokeObservation(
                time: arrival.time,
                point: arrival.center,
                directionX: directionX,
                directionY: directionY,
                letter: arrival.letter
            ))
            previous = arrival.center
        }
        return result
    }

    /// Letters in the order thumbs reached them, skipping a letter repeated by the same thumb.
    private static func tracedLetters(in strokes: [StrokeBuffer]) -> String {
        var letters: [String] = []
        for arrival in strokes.flatMap(\.arrivals).sorted(by: { $0.time < $1.time }) where letters.last != arrival.letter {
            letters.append(arrival.letter)
        }
        return letters.joined()
    }
}
