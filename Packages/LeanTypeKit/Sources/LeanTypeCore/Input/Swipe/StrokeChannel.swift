import CoreGraphics

/// The steps the alignment beam walks. Corners stay events. Keys the finger only crossed
/// while traveling in a straight line between two corners become one optional channel.
enum StrokeChannel {
    /// How far, in key widths, a crossing may sit from the segment between two corners
    /// and still be a graze rather than its own step.
    static let slack: CGFloat = 0.5

    /// One beam decision. Either a single event, or a run of on-line grazes.
    struct Step: Sendable {
        var time: Double
        var strokeIndex: Int
        /// An anchor, a tap, or a crossing that left the straight line.
        var event: SwipeEvent?
        /// Grazes between two corners. The beam skips them together, or inserts one letter.
        var channel: [SwipeEvent]

        var isChannel: Bool { event == nil && !channel.isEmpty }
    }

    /// Per stroke, then back into time order so two thumbs stay interleaved.
    static func steps(from events: [SwipeEvent], keyWidth: CGFloat, keyHeight: CGFloat) -> [Step] {
        let width = max(keyWidth, 1)
        let height = max(keyHeight, 1)
        var grouped: [Int: [SwipeEvent]] = [:]
        var order: [Int] = []
        for event in events {
            if grouped[event.strokeIndex] == nil {
                order.append(event.strokeIndex)
            }
            grouped[event.strokeIndex, default: []].append(event)
        }
        var steps: [Step] = []
        for index in order {
            let stroke = (grouped[index] ?? []).sorted { $0.time < $1.time }
            steps.append(contentsOf: strokeSteps(on: stroke, keyWidth: width, keyHeight: height))
        }
        return steps.sorted { $0.time < $1.time }
    }

    // MARK: - Private

    private static func strokeSteps(on stroke: [SwipeEvent], keyWidth: CGFloat, keyHeight: CGFloat) -> [Step] {
        let anchors = stroke.indices.filter { stroke[$0].role != .crossing }
        guard anchors.count >= 2 else {
            return stroke.map { required($0) }
        }

        var onLine = Set<Int>()
        for (start, end) in zip(anchors, anchors.dropFirst()) {
            for index in (start + 1)..<end where stroke[index].role == .crossing {
                let distance = segmentDistance(
                    stroke[index].point,
                    stroke[start].point,
                    stroke[end].point,
                    keyWidth: keyWidth,
                    keyHeight: keyHeight
                )
                if distance <= slack {
                    onLine.insert(index)
                }
            }
        }

        var steps: [Step] = []
        var pending: [SwipeEvent] = []
        func flush() {
            guard let first = pending.first else { return }
            steps.append(Step(time: first.time, strokeIndex: first.strokeIndex, event: nil, channel: pending))
            pending.removeAll(keepingCapacity: true)
        }
        for (index, event) in stroke.enumerated() {
            if onLine.contains(index) {
                pending.append(event)
            } else {
                flush()
                steps.append(required(event))
            }
        }
        flush()
        return steps
    }

    private static func required(_ event: SwipeEvent) -> Step {
        Step(time: event.time, strokeIndex: event.strokeIndex, event: event, channel: [])
    }

    /// Distance in key widths from `point` to the segment `start`–`end`. Vertical travel
    /// is scaled so one row counts as one key.
    private static func segmentDistance(
        _ point: CGPoint,
        _ start: CGPoint,
        _ end: CGPoint,
        keyWidth: CGFloat,
        keyHeight: CGFloat
    ) -> CGFloat {
        func norm(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x / keyWidth, y: point.y / keyHeight)
        }
        let point = norm(point)
        let start = norm(start)
        let end = norm(end)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.0001 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let raw = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
        let t = min(1, max(0, raw))
        let projected = CGPoint(x: start.x + dx * t, y: start.y + dy * t)
        return hypot(point.x - projected.x, point.y - projected.y)
    }
}
