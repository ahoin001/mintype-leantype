import LeanTypeCore
import UIKit

/// Draws the ring around each swiping finger and the trail that leaves from behind it.
///
/// The contact itself stays empty: a fingertip would hide anything drawn there. A ring clears
/// the finger, a bead sits on the trailing rim, and the trail runs backward from that bead.
/// Every touch keeps its last few dozen points in a fixed ring buffer, so when a finger turns
/// into a stroke its trail appears with the path it already drew. A display link runs only
/// while at least one trail is live. When the finger lifts, the ring and the trail collapse
/// into the suggestion bar. Reduce Motion draws the ring alone.
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

    private struct Glint {
        var location: CGPoint
        var birth: CFTimeInterval
        var spin: CGFloat
    }

    private struct Spark {
        var location: CGPoint
        var birth: CFTimeInterval
    }

    private struct Trail {
        let shape: CAShapeLayer
        /// Soft disc behind a comet's head. A painted glow, so the bloom does not need a live shadow.
        let glow: CAShapeLayer?
        let gradient: CAGradientLayer?
        let style: EffectsSettings.TrailStyle
        var center: CGPoint?
        var glints: [Glint] = []
        var sparks: [Spark] = []
        var lastHeading: CGFloat?
        var lastSampleTime: Double = 0
        var arrivals: Int = 0
        /// 0 on a straight run, 1 through a turn. Prism rings spread with it.
        var split: CGFloat = 0
        var hue: CGFloat = 0
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
    private var sampleBuffer: [FingerJewel.Sample] = []

    var level: EffectsLevel = .full {
        didSet {
            if level == .off {
                spectacle = false
                hideGlyphs()
                filament?.isHidden = true
                cancelEcho()
                endAll(animated: false)
            }
        }
    }

    var style: EffectsSettings.TrailStyle = .lantern
    var palette: EffectPalette
    var intensity: CGFloat = 1
    /// Typing rhythm, 0...1. The echo waits until this reaches the prism step.
    var flow: Double = 0
    private(set) var spectacle = false
    /// Lifetime used by the ribbon currently being drawn.
    private var frameLifetime = TrailRenderer.lifetime
    private var glyphs: [CATextLayer] = []
    private var glyphCount = 0
    /// Letters poured on the last lift. Kept so a late commit can drop the ones the swipe skipped,
    /// even after the pool has started the next word.
    private var pouredLetters: [String] = []
    private var filament: CAShapeLayer?
    private var echoShape: CAShapeLayer?
    private var lastPath: [CGPoint] = []
    private var lastHues: [CGFloat] = []
    private var pathOpen = false

    static let glyphCap = 12
    static let echoDuration: CFTimeInterval = 0.18
    static let prismFlow = 0.7

    init(stage: EffectsStage, palette: EffectPalette) {
        self.stage = stage
        self.palette = palette
        leftEdge.reserveCapacity(Self.pointCapacity)
        rightEdge.reserveCapacity(Self.pointCapacity)
    }

    /// Records touch movement (key-area coordinates) and starts or ends trails to match the
    /// set of fingers currently drawing strokes.
    func ingest(_ samples: [TouchSample], strokes: Set<TouchID>, thumbs: [TouchID: Int] = [:]) {
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
                if spectacle, let history = histories[sample.id] {
                    rememberPath(history, hue: trails[sample.id]?.hue)
                }
                recycleHistory(of: sample.id)
            }
            if spectacle, sample.phase == .began {
                cancelEcho()
            }
        }
        for id in strokes where trails[id] == nil {
            begin(id, thumb: thumbs[id])
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

    private func begin(_ id: TouchID, thumb: Int?) {
        guard let shape = stage.pool.shape() else { return }
        let startX = histories[id].flatMap { $0.count > 0 ? $0[0].location.x : nil } ?? stage.bounds.midX
        // The thumb tag is fixed at touch-down, so a finger that crosses the middle keeps its color.
        let hueOffset: CGFloat = if let thumb {
            thumb == 0 ? 0 : 0.38
        } else {
            startX < stage.bounds.midX ? 0 : 0.38
        }
        let color = palette.shifted(by: hueOffset)
        shape.frame = stage.bounds
        shape.strokeColor = nil
        shape.lineWidth = 0
        shape.shadowOpacity = 0
        shape.shadowRadius = 0
        shape.shadowPath = nil
        shape.fillColor = color.withAlphaComponent(0.85).cgColor
        shape.fillRule = .evenOdd

        var gradient: CAGradientLayer?
        var glow: CAShapeLayer?
        switch style {
        case .prism:
            let wash = spareGradients.popLast() ?? CAGradientLayer()
            wash.actions = LayerPool.noActions
            wash.contentsScale = shape.contentsScale
            wash.frame = stage.bounds
            wash.startPoint = CGPoint(x: 0, y: 0.5)
            wash.endPoint = CGPoint(x: 1, y: 0.5)
            wash.colors = palette.prism(count: 7, offset: hueOffset)
            shape.fillColor = UIColor.white.cgColor
            wash.mask = shape
            gradient = wash
        case .comet:
            shape.fillColor = color.withAlphaComponent(0.95).cgColor
            if let halo = stage.pool.shape() {
                halo.frame = shape.frame
                halo.fillColor = color.withAlphaComponent(0.28).cgColor
                halo.shadowOpacity = 0
                glow = halo
            }
        case .silk:
            shape.fillColor = color.withAlphaComponent(0.78).cgColor
            shape.strokeColor = palette.shifted(by: hueOffset + 0.06).withAlphaComponent(0.5).cgColor
            shape.lineWidth = 1.4
            shape.lineJoin = .round
            shape.lineCap = .round
        case .lantern, .constellation, .ember:
            break
        }

        var trail = Trail(shape: shape, glow: glow, gradient: gradient, style: style)
        trail.hue = hueOffset
        let opacity = Float(min(0.6 + 0.35 * intensity, 1))
        trail.root.opacity = opacity
        trail.glow?.opacity = opacity
        if let glow = trail.glow {
            stage.present(glow)
        }
        stage.present(trail.root)
        trails[id] = trail
        startDisplayLink()
        render()
    }

    private func end(_ id: TouchID, animated: Bool) {
        guard let trail = trails.removeValue(forKey: id) else { return }
        let collapseGlyphs = trails.isEmpty
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
            if let glow = trail.glow {
                stage.pool.recycle(glow)
            }
            stage.pool.recycle(trail.shape)
        }
        if animated, trail.style == .prism {
            restorePrismFrame(trail)
        }
        guard animated, let bounds = trail.shape.path?.boundingBoxOfPath, !bounds.isNull else {
            if collapseGlyphs { hideGlyphs() }
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
        if let glow = trail.glow {
            EffectAnimation.play(
                [
                    EffectAnimation.basic("transform", from: NSValue(caTransform3D: CATransform3DIdentity), to: NSValue(caTransform3D: collapse)),
                    EffectAnimation.basic("opacity", from: glow.opacity, to: 0),
                ],
                on: glow,
                duration: Self.collapseDuration,
                timing: EffectAnimation.easeIn
            )
        }
        EffectAnimation.play(
            [
                EffectAnimation.basic("transform", from: NSValue(caTransform3D: CATransform3DIdentity), to: NSValue(caTransform3D: collapse)),
                EffectAnimation.basic("opacity", from: root.opacity, to: 0),
            ],
            on: root,
            duration: Self.collapseDuration,
            timing: EffectAnimation.easeIn
        ) { finish() }
        if collapseGlyphs {
            pourGlyphs(toward: target, scale: scale)
        }
        if spectacle, trails.isEmpty {
            filament?.isHidden = true
        }
    }

    // MARK: - Frames

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkTarget { [weak self] in self?.render() }, selector: #selector(DisplayLinkTarget.tick))
        // 60 is enough for a dozen beads or stars. 120 would redraw the trail twice as often
        // on the same thread that has to take the next tap.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
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
        guard level > .off else { return }
        let now = CACurrentMediaTime()
        let ringOnly = level < .full
        for id in Array(trails.keys) {
            let fast = tipPace(of: histories[id])
            frameLifetime = spectacle ? Self.lifetime * (1 + 0.4 * fast) : Self.lifetime
            let life = trails[id]?.style == .comet ? Self.cometLifetime : frameLifetime
            histories[id]?.dropOlder(than: now - life)
            guard var trail = trails[id], let points = histories[id], points.count > 0 else {
                trails[id]?.shape.path = nil
                trails[id]?.shape.shadowPath = nil
                trails[id]?.glow?.path = nil
                continue
            }
            let contact = points[points.count - 1].location
            let velocity = velocity(of: points)
            let jewel = FingerJewel.place(
                contact: contact,
                previousCenter: trail.center,
                velocity: velocity,
                intensity: intensity
            )
            trail.center = jewel.center
            let turned = noteHeading(on: &trail, points: points)
            let visible = visibleSamples(from: points, jewel: jewel)
            if !ringOnly {
                noteParticles(on: &trail, points: points, jewel: jewel, turned: turned, now: now)
            }

            let path = CGMutablePath()
            var cometGlow: CGPath?
            if !ringOnly {
                switch trail.style {
                case .lantern:
                    if let ribbon = ribbon(through: visible, now: now) { path.addPath(ribbon) }
                case .comet:
                    let drawn = comet(through: visible, now: now)
                    if let beads = drawn.path { path.addPath(beads) }
                    cometGlow = drawn.glow
                case .prism:
                    if let ribbon = ribbon(through: visible, now: now, widthScale: 1.45) { path.addPath(ribbon) }
                case .constellation:
                    addStars(trail.glints, now: now, to: path)
                case .ember:
                    addSparks(trail.sparks, now: now, to: path)
                case .silk:
                    if let silk = silkRibbon(through: visible, now: now) { path.addPath(silk) }
                }
            }
            let breath: CGFloat = (!ringOnly && trail.style == .lantern) ? 1.6 * CGFloat(sin(now * 3.2)) : 0
            addRings(for: trail.style, jewel: jewel, split: trail.split, breath: breath, to: path)
            if !ringOnly, trail.style != .comet {
                path.addPath(beadPath(at: jewel.bead, style: trail.style))
            }
            if trail.style == .prism {
                let tail = visible.first?.location ?? jewel.bead
                let head = visible.last?.location ?? jewel.bead
                placePrism(trail, path: path, from: tail, to: head)
            } else {
                trail.shape.path = path
                trail.glow?.path = cometGlow
            }
            if spectacle {
                let base = Float(min(0.6 + 0.35 * intensity, 1))
                trail.root.opacity = min(1, base * Float(1 + 0.35 * fast))
            }
            trails[id] = trail
        }
        updateFilament()
    }

    private func tipPace(of points: TrailPoints?) -> CGFloat {
        guard let points, points.count >= 2 else { return 0 }
        let last = points[points.count - 1]
        let earlier = points[points.count - 2]
        let dt = max(last.time - earlier.time, 1.0 / 90)
        let speed = hypot(last.location.x - earlier.location.x, last.location.y - earlier.location.y) / CGFloat(dt)
        return min(max((speed - 160) / 1100, 0), 1)
    }

    private func velocity(of points: TrailPoints) -> CGVector {
        guard points.count >= 2 else { return .zero }
        let last = points[points.count - 1]
        let previous = points[points.count - 2]
        let elapsed = max(last.time - previous.time, 1.0 / 120)
        return CGVector(
            dx: (last.location.x - previous.location.x) / CGFloat(elapsed),
            dy: (last.location.y - previous.location.y) / CGFloat(elapsed)
        )
    }

    private func visibleSamples(from points: TrailPoints, jewel: FingerJewel) -> [FingerJewel.Sample] {
        sampleBuffer.removeAll(keepingCapacity: true)
        sampleBuffer.reserveCapacity(points.count)
        for index in 0..<points.count {
            let point = points[index]
            sampleBuffer.append(FingerJewel.Sample(location: point.location, time: point.time))
        }
        return FingerJewel.visibleTrail(
            samples: sampleBuffer,
            center: jewel.center,
            radius: jewel.radius,
            bead: jewel.bead,
            drawsTrail: jewel.drawsTrail
        )
    }

    /// Remembers the heading and eases `split` open through a turn.
    private func noteHeading(on trail: inout Trail, points: TrailPoints) -> Bool {
        guard points.count >= 2 else { return false }
        let latest = points[points.count - 1].location
        let earlier = points[points.count - 2].location
        let heading = atan2(latest.y - earlier.y, latest.x - earlier.x)
        var turned = false
        if let last = trail.lastHeading {
            var delta = abs(heading - last)
            if delta > .pi { delta = 2 * .pi - delta }
            turned = delta > 0.4
            let target: CGFloat = delta > 0.25 ? 1 : 0
            trail.split += (target - trail.split) * 0.35
        }
        trail.lastHeading = heading
        return turned
    }

    private func noteParticles(
        on trail: inout Trail,
        points: TrailPoints,
        jewel: FingerJewel,
        turned: Bool,
        now: CFTimeInterval
    ) {
        let life: CFTimeInterval = 0.45
        trail.glints.removeAll { now - $0.birth > life }
        trail.sparks.removeAll { now - $0.birth > life }
        guard jewel.drawsTrail, points.count >= 2 else { return }
        let newest = points[points.count - 1].time
        let grew = newest != trail.lastSampleTime
        if grew {
            trail.lastSampleTime = newest
            trail.arrivals += 1
        }
        let periodic = grew && trail.arrivals.isMultiple(of: 6)
        if trail.style == .constellation, grew, (turned || periodic), trail.glints.count < FingerJewel.glintLimit(intensity: intensity) {
            let spin = trail.lastHeading ?? 0
            trail.glints.append(Glint(location: jewel.bead, birth: now, spin: spin))
        }
        if trail.style == .ember, grew, (turned || trail.arrivals.isMultiple(of: 3)), trail.sparks.count < FingerJewel.sparkLimit(intensity: intensity) {
            trail.sparks.append(Spark(location: jewel.bead, birth: now))
        }
    }

    private func addRings(
        for style: EffectsSettings.TrailStyle,
        jewel: FingerJewel,
        split: CGFloat,
        breath: CGFloat,
        to path: CGMutablePath
    ) {
        let radius = jewel.radius + breath
        if style == .prism {
            let spread = 2.4 * min(max(split, 0), 1)
            for offset in [-spread, 0, spread] {
                let center = CGPoint(
                    x: jewel.center.x + jewel.direction.dx * offset,
                    y: jewel.center.y + jewel.direction.dy * offset
                )
                addRing(center: center, radius: radius, thickness: 1.5, to: path)
            }
        } else {
            let thickness: CGFloat = style == .lantern ? 2.6 : 2.2
            addRing(center: jewel.center, radius: radius, thickness: thickness, to: path)
        }
    }

    /// A filled band, so the center of the ring stays empty under an even-odd fill.
    private func addRing(center: CGPoint, radius: CGFloat, thickness: CGFloat, to path: CGMutablePath) {
        let outer = max(radius, thickness + 1)
        let inner = max(outer - thickness, 1)
        path.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
        path.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
    }

    private func beadPath(at point: CGPoint, style: EffectsSettings.TrailStyle) -> CGPath {
        let scale = min(max(intensity, 0.7), 1.25)
        let radius: CGFloat
        switch style {
        case .ember: radius = 7
        case .silk, .prism: radius = 4.5
        case .constellation, .lantern: radius = 5.2
        case .comet: radius = 8
        }
        let size = radius * scale
        return CGPath(ellipseIn: CGRect(x: point.x - size, y: point.y - size, width: size * 2, height: size * 2), transform: nil)
    }

    /// Fits the rainbow to the ribbon and runs it from the tail to the head, so a short swipe
    /// still shifts color and the gradient is only as large as the stroke.
    private func placePrism(_ trail: Trail, path: CGPath, from tail: CGPoint, to head: CGPoint) {
        guard let wash = trail.gradient else {
            trail.shape.path = path
            return
        }
        var box = path.boundingBoxOfPath
        guard !box.isNull, !box.isEmpty else {
            trail.shape.path = nil
            return
        }
        box = box.insetBy(dx: -12, dy: -12)
        if box.width < 1 { box.size.width = 1 }
        if box.height < 1 { box.size.height = 1 }
        var shift = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        trail.shape.frame = CGRect(origin: .zero, size: box.size)
        trail.shape.path = path.copy(using: &shift)
        wash.frame = box
        var tip = head
        if hypot(head.x - tail.x, head.y - tail.y) < 4 {
            tip = CGPoint(x: tail.x + 12, y: tail.y)
        }
        wash.startPoint = unit(tail, in: box)
        wash.endPoint = unit(tip, in: box)
    }

    private func unit(_ point: CGPoint, in box: CGRect) -> CGPoint {
        CGPoint(
            x: min(max((point.x - box.minX) / box.width, 0), 1),
            y: min(max((point.y - box.minY) / box.height, 0), 1)
        )
    }

    /// Puts a prism trail back in stage coordinates so the lift animation can find its center.
    private func restorePrismFrame(_ trail: Trail) {
        guard let wash = trail.gradient else { return }
        let box = wash.frame
        guard box.width > 1, box.height > 1 else { return }
        if let path = trail.shape.path {
            var shift = CGAffineTransform(translationX: box.minX, y: box.minY)
            trail.shape.path = path.copy(using: &shift)
        }
        trail.shape.frame = stage.bounds
        wash.frame = stage.bounds
    }

    private func addStars(_ glints: [Glint], now: CFTimeInterval, to path: CGMutablePath) {
        for glint in glints {
            let age = CGFloat(min(max((now - glint.birth) / 0.45, 0), 1))
            let twinkle = 0.86 + 0.14 * CGFloat(sin(now * 10 + Double(glint.spin) * 3))
            let radius = (7.5 * (1 - age) + 1.2) * twinkle * min(max(intensity, 0.7), 1.25)
            guard radius > 0.8 else { continue }
            let drift = age * 8
            let center = CGPoint(
                x: glint.location.x + cos(glint.spin) * drift,
                y: glint.location.y + sin(glint.spin) * drift
            )
            addStar(at: center, radius: radius, rotation: glint.spin + age * 0.6, to: path)
        }
    }

    private func addStar(at center: CGPoint, radius: CGFloat, rotation: CGFloat, to path: CGMutablePath) {
        let inner = radius * 0.38
        for index in 0..<8 {
            let angle = rotation + CGFloat(index) * .pi / 4
            let reach = index.isMultiple(of: 2) ? radius : inner
            let point = CGPoint(x: center.x + cos(angle) * reach, y: center.y + sin(angle) * reach)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
    }

    private func addSparks(_ sparks: [Spark], now: CFTimeInterval, to path: CGMutablePath) {
        let scale = min(max(intensity, 0.7), 1.25)
        for spark in sparks {
            let age = CGFloat(min(max((now - spark.birth) / 0.45, 0), 1))
            let radius = (3.4 * (1 - age) + 0.4) * scale
            guard radius > 0.4 else { continue }
            let center = CGPoint(x: spark.location.x, y: spark.location.y - age * 36)
            path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
    }

    /// Beads along the path that has already left the ring. The last bead is the rim, not the contact.
    /// `glow` is a wider disc at that rim, painted faint on its own layer.
    private func comet(through points: [FingerJewel.Sample], now: CFTimeInterval) -> (path: CGPath?, glow: CGPath?) {
        let count = points.count
        guard count >= 1 else { return (nil, nil) }
        let path = CGMutablePath()
        let beads = min(Self.cometBeads, count)
        let scale = min(max(intensity, 0.7), 1.25)
        var glow: CGPath?
        for bead in 0..<beads {
            let index = beads == 1 ? count - 1 : Int((CGFloat(bead) / CGFloat(beads - 1) * CGFloat(count - 1)).rounded())
            let point = points[index]
            let progress = CGFloat(bead) / CGFloat(max(beads - 1, 1))
            let freshness = CGFloat(max(0, 1 - (now - point.time) / Self.cometLifetime))
            let isHead = bead == beads - 1
            let radius = (isHead ? 8 : 1.4 + 3.6 * progress) * (isHead ? 1 : max(freshness, 0.35)) * scale
            guard radius > 0.5 else { continue }
            path.addEllipse(in: CGRect(
                x: point.location.x - radius,
                y: point.location.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            if isHead {
                let halo = radius * 2.6
                glow = CGPath(ellipseIn: CGRect(
                    x: point.location.x - halo,
                    y: point.location.y - halo,
                    width: halo * 2,
                    height: halo * 2
                ), transform: nil)
            }
        }
        return (path.isEmpty ? nil : path, glow)
    }

    /// Two copies of the stroke, a few samples apart, so a turn folds behind the finger.
    private func silkRibbon(through points: [FingerJewel.Sample], now: CFTimeInterval) -> CGPath? {
        guard let body = ribbon(through: points, now: now, kind: .silk) else { return nil }
        guard let echo = ribbon(through: points, now: now, kind: .silk, lag: 3, widthScale: 0.62) else { return body }
        let path = CGMutablePath()
        path.addPath(body)
        path.addPath(echo)
        return path
    }

    private enum RibbonKind {
        case taper
        case silk
    }

    private func ribbon(
        through points: [FingerJewel.Sample],
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
            let freshness = CGFloat(max(0, 1 - (now - point.time) / frameLifetime))
            let half: CGFloat
            switch kind {
            case .taper:
                half = Self.maximumWidth * 0.5 * scale * pow(progress, 0.7) * (0.35 + 0.65 * freshness) * widthScale
            case .silk:
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

    // MARK: - Spectacle

    func setSpectacle(_ enabled: Bool) {
        let next = enabled && level == .full
        guard next != spectacle else { return }
        spectacle = next
        if spectacle {
            prepareSpectacleLayers()
        } else {
            hideGlyphs()
            filament?.isHidden = true
            cancelEcho()
        }
    }

    /// A letter the finger just collected. The layer comes from a pool built when Spectacle turns on.
    func noteLetter(_ letter: String, at point: CGPoint) {
        guard spectacle, level == .full, glyphCount < Self.glyphCap else { return }
        prepareSpectacleLayers()
        let layer = glyphs[glyphCount]
        layer.removeAllAnimations()
        layer.string = letter
        layer.position = point
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        layer.isHidden = false
        glyphCount += 1
    }

    /// Drops glyphs whose letter the swipe did not keep.
    func noteKept(_ letters: [String]) {
        guard spectacle else { return }
        var remaining = letters.map { $0.lowercased() }
        if pouredLetters.isEmpty {
            hideUnkeptGlyphs(count: glyphCount, remaining: &remaining)
            return
        }
        for index in pouredLetters.indices {
            let shown = pouredLetters[index].lowercased()
            let current = (glyphs[index].string as? String)?.lowercased() ?? ""
            guard current == shown else { continue }
            if let found = remaining.firstIndex(of: shown) {
                remaining.remove(at: found)
            } else {
                glyphs[index].removeAllAnimations()
                glyphs[index].isHidden = true
            }
        }
        pouredLetters.removeAll(keepingCapacity: true)
    }

    private func hideUnkeptGlyphs(count: Int, remaining: inout [String]) {
        for index in 0..<count {
            let shown = (glyphs[index].string as? String)?.lowercased() ?? ""
            if let found = remaining.firstIndex(of: shown) {
                remaining.remove(at: found)
            } else {
                glyphs[index].isHidden = true
            }
        }
    }

    func noteCommit(sure: Bool) {
        guard spectacle, level == .full, sure, flow >= Self.prismFlow else { return }
        playEcho()
    }

    private func prepareSpectacleLayers() {
        if glyphs.isEmpty {
            for _ in 0..<Self.glyphCap {
                let layer = CATextLayer()
                layer.bounds = CGRect(x: 0, y: 0, width: 28, height: 28)
                layer.contentsScale = stage.layer.contentsScale
                layer.alignmentMode = .center
                layer.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
                layer.fontSize = 17
                layer.foregroundColor = palette.ink.cgColor
                layer.isHidden = true
                layer.actions = LayerPool.noActions
                stage.present(layer)
                glyphs.append(layer)
            }
        }
        if filament == nil, let shape = stage.pool.shape() {
            shape.frame = stage.bounds
            shape.fillColor = nil
            shape.lineWidth = 1.5
            shape.lineCap = .round
            shape.strokeColor = palette.ink.withAlphaComponent(0.35).cgColor
            shape.isHidden = true
            stage.present(shape)
            filament = shape
        }
        if echoShape == nil, let shape = stage.pool.shape() {
            shape.frame = stage.bounds
            shape.fillColor = nil
            shape.lineWidth = 2
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.isHidden = true
            stage.present(shape)
            echoShape = shape
        }
    }

    private func rememberPath(_ history: TrailPoints, hue: CGFloat?) {
        if !pathOpen {
            lastPath.removeAll(keepingCapacity: true)
            lastHues.removeAll(keepingCapacity: true)
            pathOpen = true
        }
        for index in 0..<history.count {
            guard lastPath.count < Self.pointCapacity else { break }
            lastPath.append(history[index].location)
        }
        if let hue, lastHues.count < 2 {
            lastHues.append(hue)
        }
    }

    private func updateFilament() {
        guard spectacle, level == .full, trails.count >= 2 else {
            filament?.isHidden = true
            return
        }
        var heads: [CGPoint] = []
        heads.reserveCapacity(2)
        for trail in trails.values {
            guard let center = trail.center else { continue }
            heads.append(center)
            if heads.count == 2 { break }
        }
        guard heads.count == 2, let filament else { return }
        let path = CGMutablePath()
        path.move(to: heads[0])
        path.addLine(to: heads[1])
        filament.path = path
        filament.isHidden = false
    }

    private func pourGlyphs(toward target: CGPoint, scale: CGFloat) {
        guard glyphCount > 0 else { return }
        pouredLetters.removeAll(keepingCapacity: true)
        for index in 0..<glyphCount {
            let layer = glyphs[index]
            pouredLetters.append((layer.string as? String) ?? "")
            guard !layer.isHidden else { continue }
            let dx = target.x - layer.position.x
            let dy = target.y - layer.position.y
            let collapse = CATransform3DScale(CATransform3DMakeTranslation(dx, dy, 0), scale, scale, 1)
            EffectAnimation.play(
                [
                    EffectAnimation.basic("transform", from: NSValue(caTransform3D: CATransform3DIdentity), to: NSValue(caTransform3D: collapse)),
                    EffectAnimation.basic("opacity", from: layer.opacity, to: 0),
                ],
                on: layer,
                duration: Self.collapseDuration,
                timing: EffectAnimation.easeIn
            )
        }
        glyphCount = 0
    }

    private func hideGlyphs() {
        for layer in glyphs {
            layer.removeAllAnimations()
            layer.isHidden = true
            layer.transform = CATransform3DIdentity
        }
        glyphCount = 0
        pouredLetters.removeAll(keepingCapacity: true)
    }

    private func playEcho() {
        guard lastPath.count >= 2 else { return }
        prepareSpectacleLayers()
        guard let echoShape else { return }
        let path = CGMutablePath()
        path.move(to: lastPath[0])
        for point in lastPath.dropFirst() {
            path.addLine(to: point)
        }
        echoShape.path = path
        echoShape.strokeColor = echoColor().cgColor
        echoShape.opacity = 0.45
        echoShape.isHidden = false
        pathOpen = false
        EffectAnimation.play(
            [EffectAnimation.basic("opacity", from: 0.45, to: 0)],
            on: echoShape,
            duration: Self.echoDuration,
            timing: EffectAnimation.easeOut
        ) { [weak echoShape] in
            echoShape?.isHidden = true
        }
    }

    private func echoColor() -> UIColor {
        switch lastHues.count {
        case 0:
            return palette.ink.withAlphaComponent(0.45)
        case 1:
            return palette.shifted(by: lastHues[0]).withAlphaComponent(0.55)
        default:
            let blended = (lastHues[0] + lastHues[1]) / 2
            return palette.shifted(by: blended).withAlphaComponent(0.55)
        }
    }

    private func cancelEcho() {
        pathOpen = false
        echoShape?.removeAllAnimations()
        echoShape?.isHidden = true
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
