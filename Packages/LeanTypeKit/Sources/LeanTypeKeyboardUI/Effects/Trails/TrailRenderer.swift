import LeanTypeCore
import UIKit

/// Draws the trail behind each swiping finger.
///
/// Every touch keeps its last few dozen points in a fixed ring buffer, so when a finger turns
/// into a stroke its trail appears with the path it already drew. A display link runs only
/// while at least one trail is live. Theme and Prism are a tapered ribbon. Comet is a bright
/// head with a short tail of beads. Brush is a stroke whose width follows how fast the finger
/// moves. When the finger lifts, the trail collapses into the suggestion bar.
@MainActor
final class TrailRenderer {
    nonisolated static let pointCapacity = 64
    /// How long a point stays in the ribbon.
    static let lifetime: CFTimeInterval = 0.3
    /// Beads stay a little longer than a ribbon, so the tail is readable.
    static let cometLifetime: CFTimeInterval = 0.5
    static let maximumWidth: CGFloat = 7
    static let collapseDuration: CFTimeInterval = 0.26
    static let cometBeads = 12

    private struct Trail {
        let shape: CAShapeLayer
        let gradient: CAGradientLayer?
        let style: EffectsSettings.TrailStyle
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
        // A thumb on the right half shifts hue, so two trails through one word stay distinct.
        let hueOffset: CGFloat = startX < stage.bounds.midX ? 0 : 0.38
        let color = palette.shifted(by: hueOffset)
        shape.frame = stage.bounds
        shape.strokeColor = nil
        shape.lineWidth = 0
        shape.shadowOpacity = 0
        shape.shadowRadius = 0
        shape.shadowPath = nil
        shape.fillColor = color.withAlphaComponent(0.85).cgColor

        var gradient: CAGradientLayer?
        switch style {
        case .prism:
            let wash = spareGradients.popLast() ?? CAGradientLayer()
            wash.actions = LayerPool.noActions
            wash.frame = stage.bounds
            wash.startPoint = CGPoint(x: 0, y: 0.5)
            wash.endPoint = CGPoint(x: 1, y: 0.5)
            wash.colors = palette.prism(count: 5, offset: hueOffset)
            shape.fillColor = UIColor.white.cgColor
            wash.mask = shape
            gradient = wash
        case .comet:
            shape.fillColor = color.withAlphaComponent(0.95).cgColor
            shape.shadowColor = color.cgColor
            shape.shadowRadius = 12
            shape.shadowOpacity = 0.9
            shape.shadowOffset = .zero
        case .brush:
            shape.fillColor = color.withAlphaComponent(0.78).cgColor
            shape.strokeColor = palette.shifted(by: hueOffset + 0.06).withAlphaComponent(0.5).cgColor
            shape.lineWidth = 1.4
            shape.lineJoin = .round
            shape.lineCap = .round
        case .theme:
            break
        }

        let trail = Trail(shape: shape, gradient: gradient, style: style)
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
            let life = trail.style == .comet ? Self.cometLifetime : Self.lifetime
            histories[id]?.dropOlder(than: now - life)
            guard let points = histories[id] else {
                trail.shape.path = nil
                trail.shape.shadowPath = nil
                continue
            }
            switch trail.style {
            case .theme, .prism:
                trail.shape.path = ribbon(through: points, now: now)
                trail.shape.shadowPath = nil
            case .comet:
                let drawn = comet(through: points, now: now)
                trail.shape.path = drawn.path
                trail.shape.shadowPath = drawn.head
            case .brush:
                trail.shape.path = brush(through: points, now: now)
                trail.shape.shadowPath = nil
            }
        }
    }

    /// Beads along the recent path, small at the tail and a glowing head under the finger.
    private func comet(through points: TrailPoints, now: CFTimeInterval) -> (path: CGPath?, head: CGPath?) {
        let count = points.count
        guard count >= 1 else { return (nil, nil) }
        let path = CGMutablePath()
        let beads = min(Self.cometBeads, count)
        let scale = min(max(intensity, 0.7), 1.25)
        var head: CGPath?
        for bead in 0..<beads {
            let index = beads == 1 ? count - 1 : Int((CGFloat(bead) / CGFloat(beads - 1) * CGFloat(count - 1)).rounded())
            let point = points[index]
            let progress = CGFloat(bead) / CGFloat(max(beads - 1, 1))
            let freshness = CGFloat(max(0, 1 - (now - point.time) / Self.cometLifetime))
            let isHead = bead == beads - 1
            let radius = (isHead ? 7.5 : 1.4 + 3.6 * progress) * (isHead ? 1 : max(freshness, 0.35)) * scale
            guard radius > 0.5 else { continue }
            let beadPath = CGPath(ellipseIn: CGRect(
                x: point.location.x - radius,
                y: point.location.y - radius,
                width: radius * 2,
                height: radius * 2
            ), transform: nil)
            path.addPath(beadPath)
            if isHead { head = beadPath }
        }
        return (path.isEmpty ? nil : path, head)
    }

    /// The ribbon's width follows speed, with a fainter copy lagging a few samples behind.
    private func brush(through points: TrailPoints, now: CFTimeInterval) -> CGPath? {
        guard let body = ribbon(through: points, now: now, kind: .brush) else { return nil }
        guard let echo = ribbon(through: points, now: now, kind: .brush, lag: 3, widthScale: 0.62) else { return body }
        let path = CGMutablePath()
        path.addPath(body)
        path.addPath(echo)
        return path
    }

    private enum RibbonKind {
        case taper
        case brush
    }

    private func ribbon(
        through points: TrailPoints,
        now: CFTimeInterval,
        kind: RibbonKind = .taper,
        lag: Int = 0,
        widthScale: CGFloat = 1
    ) -> CGPath? {
        let count = points.count
        guard count >= 2 else { return nil }
        let scale = min(max(intensity, 0.7), 1.25)

        leftEdge.removeAll(keepingCapacity: true)
        rightEdge.removeAll(keepingCapacity: true)
        var heading: CGFloat = 0
        var tipRadius: CGFloat = 0
        for index in 0..<count {
            let source = max(index - lag, 0)
            let point = points[source]
            let previous = points[max(source - 1, 0)].location
            let next = points[min(source + 1, count - 1)].location
            var dx = next.x - previous.x
            var dy = next.y - previous.y
            let length = max((dx * dx + dy * dy).squareRoot(), 0.001)
            dx /= length
            dy /= length
            let progress = CGFloat(source) / CGFloat(count - 1)
            let freshness = CGFloat(max(0, 1 - (now - point.time) / Self.lifetime))
            let half: CGFloat
            switch kind {
            case .taper:
                half = Self.maximumWidth * 0.5 * scale * pow(progress, 0.7) * (0.35 + 0.65 * freshness) * widthScale
            case .brush:
                let earlier = points[max(source - 1, 0)]
                let dt = max(point.time - earlier.time, 1.0 / 90)
                let speed = hypot(point.location.x - earlier.location.x, point.location.y - earlier.location.y) / CGFloat(dt)
                let fast = min(max((speed - 160) / 1100, 0), 1)
                half = (1.3 + 6.4 * (1 - fast)) * scale * (0.4 + 0.6 * freshness) * widthScale
            }
            leftEdge.append(CGPoint(x: point.location.x - dy * half, y: point.location.y + dx * half))
            rightEdge.append(CGPoint(x: point.location.x + dy * half, y: point.location.y - dx * half))
            heading = atan2(dy, dx)
            tipRadius = half
        }

        let path = CGMutablePath()
        path.move(to: leftEdge[0])
        for index in 1..<count {
            path.addLine(to: leftEdge[index])
        }
        path.addArc(
            center: points[max(count - 1 - lag, 0)].location,
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
