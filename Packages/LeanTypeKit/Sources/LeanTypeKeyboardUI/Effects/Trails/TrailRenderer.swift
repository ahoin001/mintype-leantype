import LeanTypeCore
import UIKit

/// Draws the glowing ribbon behind each swiping finger.
///
/// Every touch keeps its last few dozen points in a fixed ring buffer, so when a finger turns
/// into a stroke its trail appears with the path it already drew. A display link runs only
/// while at least one trail is live; each frame rebuilds a tapered outline (thin and faded at
/// the tail, full width at the fingertip). When the finger lifts, the ribbon collapses into
/// the suggestion bar, where the word appears.
@MainActor
final class TrailRenderer {
    nonisolated static let pointCapacity = 64
    /// How long a point stays in the ribbon.
    static let lifetime: CFTimeInterval = 0.3
    static let maximumWidth: CGFloat = 7
    static let collapseDuration: CFTimeInterval = 0.26

    private struct Trail {
        let shape: CAShapeLayer
        let gradient: CAGradientLayer?
        var root: CALayer { gradient ?? shape }
    }

    /// Histories kept for reuse, enough for a burst of overlapping taps.
    static let spareHistoryLimit = 4

    private let stage: EffectsStage
    private var histories: [TouchID: TrailPoints] = [:]
    private var spareHistories: [TrailPoints] = []
    private var trails: [TouchID: Trail] = [:]
    private var spareGradients: [CAGradientLayer] = []
    private var displayLink: CADisplayLink?
    /// Scratch edges for building ribbons, so frames don't allocate.
    private var leftEdge: [CGPoint] = []
    private var rightEdge: [CGPoint] = []

    var level: EffectsLevel = .full {
        didSet { if level == .off { endAll(animated: false) } }
    }

    var style: EffectsSettings.TrailStyle = .theme
    var palette: EffectPalette
    var intensity: CGFloat = 1

    init(stage: EffectsStage, palette: EffectPalette) {
        self.stage = stage
        self.palette = palette
        leftEdge.reserveCapacity(Self.pointCapacity)
        rightEdge.reserveCapacity(Self.pointCapacity)
    }

    /// Records touch movement (key-area coordinates) and starts or ends trails to match the
    /// set of fingers currently drawing strokes.
    func ingest(_ samples: [TouchSample], strokes: Set<TouchID>) {
        guard level > .off else { return }
        for sample in samples {
            let point = TrailPoint(location: stage.point(fromKeyArea: sample.location), time: sample.timestamp)
            switch sample.phase {
            case .began:
                var history = spareHistories.popLast() ?? TrailPoints()
                history.append(point)
                histories[sample.id] = history
            case .moved:
                histories[sample.id]?.append(point)
            case .ended, .cancelled:
                recycleHistory(of: sample.id)
            }
        }
        for id in strokes where trails[id] == nil {
            begin(id)
        }
        // Copy first: end() removes the entry, and enumerating trails.keys while mutating traps.
        for id in Array(trails.keys) where !strokes.contains(id) {
            end(id, animated: level == .full)
        }
    }

    func endAll(animated: Bool) {
        for id in Array(trails.keys) {
            end(id, animated: animated)
        }
        for id in Array(histories.keys) {
            recycleHistory(of: id)
        }
    }

    private func recycleHistory(of id: TouchID) {
        guard var history = histories.removeValue(forKey: id), spareHistories.count < Self.spareHistoryLimit else { return }
        history.removeAll()
        spareHistories.append(history)
    }

    // MARK: - Lifecycle of one trail

    private func begin(_ id: TouchID) {
        guard let shape = stage.pool.shape() else { return }
        let startX = histories[id].flatMap { $0.count > 0 ? $0[0].location.x : nil } ?? stage.bounds.midX
        let hueOffset: CGFloat = startX < stage.bounds.midX ? 0 : 0.38
        shape.frame = stage.bounds
        shape.strokeColor = nil
        shape.lineWidth = 0

        let trail: Trail
        if style == .prism {
            let gradient = spareGradients.popLast() ?? CAGradientLayer()
            gradient.actions = LayerPool.noActions
            gradient.frame = stage.bounds
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            gradient.colors = palette.prism(count: 5, offset: hueOffset)
            shape.fillColor = UIColor.white.cgColor
            gradient.mask = shape
            trail = Trail(shape: shape, gradient: gradient)
        } else {
            shape.fillColor = palette.shifted(by: hueOffset).withAlphaComponent(0.85).cgColor
            trail = Trail(shape: shape, gradient: nil)
        }
        trail.root.opacity = Float(min(0.6 + 0.35 * intensity, 1))
        stage.present(trail.root)
        trails[id] = trail
        startDisplayLink()
        render()
    }

    private func end(_ id: TouchID, animated: Bool) {
        guard let trail = trails.removeValue(forKey: id) else { return }
        if trails.isEmpty { stopDisplayLink() }

        let root = trail.root
        let finish = { [weak self] in
            guard let self else { return }
            if let gradient = trail.gradient {
                gradient.mask = nil
                gradient.removeAllAnimations()
                gradient.removeFromSuperlayer()
                spareGradients.append(gradient)
            }
            stage.pool.recycle(trail.shape)
        }
        guard animated, let bounds = trail.shape.path?.boundingBoxOfPath, !bounds.isNull else {
            finish()
            return
        }

        // Shrink the ribbon into the suggestion bar's center. Transforms pivot on the layer's
        // anchor (the stage center), so solve for the translation that lands the ribbon there.
        let target = CGPoint(x: stage.dockFrame.midX, y: stage.dockFrame.midY)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let anchor = root.position
        let scale: CGFloat = 0.15
        let offset = CGPoint(
            x: target.x - anchor.x - scale * (center.x - anchor.x),
            y: target.y - anchor.y - scale * (center.y - anchor.y)
        )
        let collapse = CATransform3DScale(CATransform3DMakeTranslation(offset.x, offset.y, 0), scale, scale, 1)
        EffectAnimation.play(
            [
                EffectAnimation.basic("transform", from: NSValue(caTransform3D: CATransform3DIdentity), to: NSValue(caTransform3D: collapse)),
                EffectAnimation.basic("opacity", from: root.opacity, to: 0),
            ],
            on: root,
            duration: Self.collapseDuration,
            timing: EffectAnimation.easeIn
        ) { finish() }
    }

    // MARK: - Frames

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkTarget { [weak self] in self?.render() }, selector: #selector(DisplayLinkTarget.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func render() {
        let interval = Signposts.effects.beginInterval("Trail frame")
        defer { Signposts.effects.endInterval("Trail frame", interval) }
        let now = CACurrentMediaTime()
        for (id, trail) in trails {
            histories[id]?.dropOlder(than: now - Self.lifetime)
            trail.shape.path = histories[id].flatMap { ribbon(through: $0, now: now) }
        }
    }

    /// A closed outline around the points, widening from the tail to a round fingertip.
    private func ribbon(through points: TrailPoints, now: CFTimeInterval) -> CGPath? {
        let count = points.count
        guard count >= 2 else { return nil }
        let maximum = Self.maximumWidth * min(max(intensity, 0.7), 1.25)

        leftEdge.removeAll(keepingCapacity: true)
        rightEdge.removeAll(keepingCapacity: true)
        var heading: CGFloat = 0
        var tipRadius: CGFloat = 0
        for index in 0..<count {
            let point = points[index]
            let previous = points[max(index - 1, 0)].location
            let next = points[min(index + 1, count - 1)].location
            var dx = next.x - previous.x
            var dy = next.y - previous.y
            let length = max((dx * dx + dy * dy).squareRoot(), 0.001)
            dx /= length
            dy /= length
            let progress = CGFloat(index) / CGFloat(count - 1)
            let freshness = CGFloat(max(0, 1 - (now - point.time) / Self.lifetime))
            let half = maximum * 0.5 * pow(progress, 0.7) * (0.35 + 0.65 * freshness)
            leftEdge.append(CGPoint(x: point.location.x - dy * half, y: point.location.y + dx * half))
            rightEdge.append(CGPoint(x: point.location.x + dy * half, y: point.location.y - dx * half))
            heading = atan2(dy, dx)
            tipRadius = half
        }

        // One outline: up the left edge, around a round cap at the fingertip, back down the right.
        let path = CGMutablePath()
        path.move(to: leftEdge[0])
        for index in 1..<count {
            path.addLine(to: leftEdge[index])
        }
        path.addArc(
            center: points[count - 1].location,
            radius: tipRadius,
            startAngle: heading + .pi / 2,
            endAngle: heading - .pi / 2,
            clockwise: true
        )
        for index in stride(from: count - 2, through: 0, by: -1) {
            path.addLine(to: rightEdge[index])
        }
        path.closeSubpath()
        return path
    }
}

struct TrailPoint {
    let location: CGPoint
    let time: CFTimeInterval
}

/// The last `TrailRenderer.pointCapacity` points of a touch, oldest first.
struct TrailPoints {
    private var storage = ContiguousArray<TrailPoint>()
    private var start = 0
    private(set) var count = 0

    init() {
        storage.reserveCapacity(TrailRenderer.pointCapacity)
    }

    subscript(index: Int) -> TrailPoint {
        storage[(start + index) % storage.count]
    }

    mutating func append(_ point: TrailPoint) {
        if storage.count < TrailRenderer.pointCapacity {
            storage.append(point)
            count += 1
        } else {
            storage[(start + count) % storage.count] = point
            if count == storage.count {
                start = (start + 1) % storage.count
            } else {
                count += 1
            }
        }
    }

    /// Empties the buffer but keeps its storage for the next touch.
    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        start = 0
        count = 0
    }

    mutating func dropOlder(than time: CFTimeInterval) {
        while count > 1, self[0].time < time {
            start = (start + 1) % storage.count
            count -= 1
        }
    }
}

/// Breaks the retain cycle between a display link (which retains its target) and its owner.
/// The link is added to the main run loop, so ticks arrive on the main actor.
@MainActor
private final class DisplayLinkTarget {
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func tick() {
        action()
    }
}
