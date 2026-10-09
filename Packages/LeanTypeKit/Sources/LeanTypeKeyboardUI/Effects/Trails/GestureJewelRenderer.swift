import LeanTypeCore
import LeanTypeDesign
import UIKit

/// The ring, bead, and short trail for a shift scrub.
///
/// A delete scrub draws on the backspace key, and the space-bar trackpad draws on the space
/// bar. A ring above the finger has nothing to do with either key. Same rule as a word swipe
/// for the gestures that do: the contact stays empty, and the ring sits one radius above
/// the thumb. A display link runs only while a jewel is up.
@MainActor
final class GestureJewelRenderer {
    static let lifetime: CFTimeInterval = 0.3
    static let sampleCapacity = 32
    static let characterStride: CGFloat = 7
    static let wordStride: CGFloat = 22
    static let crumbTravel: CGFloat = 36

    private let stage: EffectsStage
    private var ring: CAShapeLayer?
    private var beadLayer: CAShapeLayer?
    private var trail: CAShapeLayer?
    private var bits: [CALayer] = []
    private var samples: [FingerJewel.Sample] = []
    private var mark: GestureMark?
    private var action = CGVector.zero
    private var displayLink: CADisplayLink?
    private var drawnRadius: CGFloat = 0
    private var pending: [KeyboardEvent] = []

    var level: EffectsLevel = .full {
        didSet { if level == .off { end(animated: false) } }
    }

    var palette: EffectPalette
    var intensity: CGFloat = 1

    init(stage: EffectsStage, palette: EffectPalette) {
        self.stage = stage
        self.palette = palette
        samples.reserveCapacity(Self.sampleCapacity)
    }

    func ingest(_ mark: GestureMark?) {
        guard level > .off else { return }
        guard let mark else {
            end(animated: true)
            return
        }
        self.mark = mark
        if case let .scrub(scrub) = mark.action, scrub.step > 0 || scrub.restoring {
            action = CGVector(dx: scrub.travelsRight ? 1 : -1, dy: 0)
        }
        ensureLayers()
        startDisplayLink()
        render()
        flushPending()
    }

    func handle(_ event: KeyboardEvent) {
        guard level == .full, !UIAccessibility.isReduceMotionEnabled, isBit(event) else { return }
        if ring != nil {
            apply(event)
        } else if pending.count < FingerJewel.glintLimit(intensity: intensity) {
            pending.append(event)
        }
    }

    func end(animated: Bool) {
        let layers = [ring, beadLayer, trail].compactMap { $0 }
        let flying = bits
        guard !layers.isEmpty || !flying.isEmpty else { return }
        stopDisplayLink()
        mark = nil
        action = .zero
        pending.removeAll(keepingCapacity: true)
        samples.removeAll(keepingCapacity: true)
        ring = nil
        beadLayer = nil
        trail = nil
        bits.removeAll(keepingCapacity: true)
        let pool = stage.pool
        for bit in flying {
            pool.recycle(bit)
        }
        guard animated, level == .full, let host = layers.first else {
            for layer in layers { pool.recycle(layer) }
            return
        }
        for layer in layers where layer !== host {
            EffectAnimation.play([EffectAnimation.basic("opacity", from: layer.opacity, to: 0)], on: layer, duration: 0.16)
        }
        EffectAnimation.play(
            [EffectAnimation.basic("opacity", from: host.opacity, to: 0)],
            on: host,
            duration: 0.16
        ) {
            for layer in layers {
                pool.recycle(layer)
            }
        }
    }

    private func flushPending() {
        guard ring != nil, !pending.isEmpty else { return }
        let events = pending
        pending.removeAll(keepingCapacity: true)
        for event in events {
            apply(event)
        }
    }

    private func isBit(_ event: KeyboardEvent) -> Bool {
        switch event {
        case .deleteStep, .cursorStep: true
        default: false
        }
    }

    private func apply(_ event: KeyboardEvent) {
        switch event {
        case let .deleteStep(character, restoring):
            dropCrumb(character, restoring: restoring)
        case let .cursorStep(direction, byWord):
            action = CGVector(dx: CGFloat(direction.signum()), dy: 0)
            nudgeCursor(direction: direction, byWord: byWord)
        default:
            break
        }
    }

    // MARK: - Frames

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: JewelDisplayLink { [weak self] in self?.render() }, selector: #selector(JewelDisplayLink.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func render() {
        guard let mark, let ring, let beadLayer, let trail else { return }
        let contact = stage.point(fromKeyArea: mark.contact)
        let placed = FingerJewel.placeAbove(contact: contact, action: action, intensity: intensity)
        if abs(drawnRadius - placed.radius) > 0.5 {
            drawnRadius = placed.radius
            ring.path = UIBezierPath(ovalIn: CGRect(x: -placed.radius, y: -placed.radius, width: placed.radius * 2, height: placed.radius * 2)).cgPath
            let beadRadius = 4.5 * min(max(intensity, 0.8), 1.35)
            beadLayer.path = UIBezierPath(ovalIn: CGRect(x: -beadRadius, y: -beadRadius, width: beadRadius * 2, height: beadRadius * 2)).cgPath
        }
        ring.position = placed.center
        beadLayer.position = placed.bead
        trail.frame = stage.bounds

        let now = CACurrentMediaTime()
        if placed.drawsTrail, level == .full, !UIAccessibility.isReduceMotionEnabled {
            samples.append(FingerJewel.Sample(location: placed.bead, time: now))
            if samples.count > Self.sampleCapacity {
                samples.removeFirst(samples.count - Self.sampleCapacity)
            }
        }
        samples.removeAll { now - $0.time > Self.lifetime }
        let visible = FingerJewel.visibleTrail(
            samples: samples,
            center: placed.center,
            radius: placed.radius,
            bead: placed.bead,
            drawsTrail: placed.drawsTrail && level == .full && !UIAccessibility.isReduceMotionEnabled
        )
        trail.path = stroke(through: visible)
    }

    private func stroke(through samples: [FingerJewel.Sample]) -> CGPath? {
        guard samples.count > 1 else { return nil }
        let path = UIBezierPath()
        path.move(to: samples[0].location)
        for sample in samples.dropFirst() {
            path.addLine(to: sample.location)
        }
        return path.cgPath
    }

    private func ensureLayers() {
        guard ring == nil, let ring = stage.pool.shape(), let bead = stage.pool.shape(), let trail = stage.pool.shape() else { return }
        let color = palette.accent
        ring.fillColor = nil
        ring.strokeColor = color.withAlphaComponent(0.9).cgColor
        ring.lineWidth = 1.5
        bead.fillColor = color.cgColor
        bead.strokeColor = nil
        trail.fillColor = nil
        trail.strokeColor = color.withAlphaComponent(0.45).cgColor
        trail.lineWidth = 3
        trail.lineCap = .round
        trail.lineJoin = .round
        stage.present(trail)
        stage.present(ring)
        stage.present(bead)
        self.ring = ring
        beadLayer = bead
        self.trail = trail
        drawnRadius = 0
    }

    // MARK: - Bits that leave the bead

    private func dropCrumb(_ character: String, restoring: Bool) {
        let shown = crumbText(character)
        guard !shown.isEmpty, let origin = beadLayer?.position else { return }
        let away = CGPoint(x: origin.x - Self.crumbTravel, y: origin.y)
        if restoring {
            launch(text: shown, from: away, to: origin)
        } else {
            launch(text: shown, from: origin, to: away)
        }
    }

    private func nudgeCursor(direction: Int, byWord: Bool) {
        guard let origin = beadLayer?.position else { return }
        let length = byWord ? Self.wordStride : Self.characterStride
        let end = CGPoint(x: origin.x + CGFloat(direction.signum()) * length, y: origin.y)
        launch(text: nil, from: origin, to: end)
    }

    private func crumbText(_ character: String) -> String {
        let trimmed = character.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return character.isEmpty ? "" : "·" }
        return String(trimmed.suffix(8))
    }

    private func launch(text: String?, from: CGPoint, to: CGPoint) {
        guard bits.count < FingerJewel.glintLimit(intensity: intensity) else { return }
        let layer: CALayer
        if let text, let glyph = stage.pool.text() {
            let font = Typography.rounded(size: 15, weight: .semibold)
            glyph.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: palette.accent])
            glyph.bounds = CGRect(x: 0, y: 0, width: max(font.pointSize, CGFloat(text.count) * font.pointSize * 0.7), height: font.lineHeight + 2)
            glyph.alignmentMode = .center
            layer = glyph
        } else if let dot = stage.pool.shape() {
            let radius: CGFloat = 3
            dot.path = UIBezierPath(ovalIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)).cgPath
            dot.fillColor = palette.accent.cgColor
            layer = dot
        } else {
            return
        }
        layer.position = from
        layer.opacity = 1
        bits.append(layer)
        stage.present(layer)
        let pool = stage.pool
        EffectAnimation.play(
            [
                EffectAnimation.basic("position", from: NSValue(cgPoint: from), to: NSValue(cgPoint: to)),
                EffectAnimation.basic("opacity", from: 1, to: 0),
            ],
            on: layer,
            duration: 0.28
        ) { [weak self] in
            guard let self else {
                pool.recycle(layer)
                return
            }
            if let index = self.bits.firstIndex(where: { $0 === layer }) {
                self.bits.remove(at: index)
                pool.recycle(layer)
            }
        }
    }
}

/// The link is added to the main run loop, so ticks arrive on the main actor.
@MainActor
private final class JewelDisplayLink {
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func tick() {
        action()
    }
}
