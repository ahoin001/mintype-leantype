import LeanTypeCore
import LeanTypeDesign
import UIKit

/// Nintype's gust of wind: a deleted word appears in the dock above backspace and its letters
/// are blown away to the left, tumbling, behind a few streaks of wind. Restoring the word
/// plays the breeze in reverse, carrying the letters back.
@MainActor
final class GustEffect: KeyboardEffect {
    static let minimumLevel = EffectsLevel.full
    static let maximumGlyphs = 14
    static let duration: CFTimeInterval = 0.62
    static let stagger: CFTimeInterval = 0.022
    static let streakCount = 3

    private let font = Typography.rounded(size: 17, weight: .semibold)
    private var generator = SystemRandomNumberGenerator()

    func handle(_ event: KeyboardEvent, in context: EffectContext) {
        switch event {
        case let .wordDeleted(word, origin):
            play(word, origin: origin, reversed: false, in: context)
        case let .deletionRestored(word, origin):
            play(word, origin: origin, reversed: true, in: context)
        default:
            break
        }
    }

    func stop(in _: EffectContext) {}

    // MARK: - Private

    private func play(_ word: String, origin: CGPoint, reversed: Bool, in context: EffectContext) {
        let glyphs = Array(word.suffix(Self.maximumGlyphs))
        guard !glyphs.isEmpty else { return }

        let dock = context.stage.dockFrame
        let anchorX = min(context.stage.point(fromKeyArea: origin).x, dock.maxX - 24)
        let baseline = dock.midY
        let widths = glyphs.map { (String($0) as NSString).size(withAttributes: [.font: font]).width.rounded(.up) }
        var x = anchorX - widths.reduce(0, +)
        let travel = -(dock.width * 0.45) * max(context.intensity, 0.6)
        let color = context.palette.ink.withAlphaComponent(context.palette.isDark ? 0.9 : 0.8)

        for (index, glyph) in glyphs.enumerated() {
            guard let layer = context.pool.text() else { break }
            let width = widths[index]
            layer.string = NSAttributedString(string: String(glyph), attributes: [.font: font, .foregroundColor: color])
            layer.bounds = CGRect(x: 0, y: 0, width: width + 2, height: font.lineHeight)
            layer.position = CGPoint(x: x + width / 2, y: baseline)
            x += width
            context.stage.present(layer)

            // Letters nearest the wind (the left) go first on the way out, last on the way back.
            let order = reversed ? glyphs.count - 1 - index : index
            let lift = CGFloat.random(in: -16...6, using: &generator)
            let spin = CGFloat.random(in: -0.9...0.9, using: &generator)
            let drift = travel * CGFloat.random(in: 0.75...1.15, using: &generator)
            let away = CATransform3DRotate(CATransform3DMakeTranslation(drift, lift, 0), spin, 0, 0, 1)
            let away3D = NSValue(caTransform3D: CATransform3DScale(away, 0.7, 0.7, 1))
            let rest = NSValue(caTransform3D: CATransform3DIdentity)

            let pool = context.pool
            EffectAnimation.play(
                [
                    EffectAnimation.basic("transform", from: reversed ? away3D : rest, to: reversed ? rest : away3D),
                    reversed
                        ? EffectAnimation.keyframes("opacity", [0, 1, 1, 0], times: [0, 0.55, 0.8, 1])
                        : EffectAnimation.keyframes("opacity", [0, 1, 1, 0], times: [0, 0.08, 0.35, 1]),
                ],
                on: layer,
                duration: Self.duration,
                delay: Double(order) * Self.stagger,
                timing: reversed ? EffectAnimation.easeOut : EffectAnimation.easeIn
            ) { pool.recycle(layer) }
        }

        playStreaks(from: anchorX, baseline: baseline, travel: travel, reversed: reversed, in: context)
    }

    /// Thin curved lines that sweep through the dock in the wind's direction.
    private func playStreaks(from anchorX: CGFloat, baseline: CGFloat, travel: CGFloat, reversed: Bool, in context: EffectContext) {
        let color = context.palette.accent.withAlphaComponent(0.55).cgColor
        for index in 0..<Self.streakCount {
            guard let layer = context.pool.shape() else { return }
            let y = baseline + CGFloat(index - 1) * 7 + CGFloat.random(in: -2...2, using: &generator)
            let length = abs(travel) * CGFloat.random(in: 0.7...1.1, using: &generator)
            let path = UIBezierPath()
            path.move(to: CGPoint(x: anchorX + 10, y: y))
            path.addCurve(
                to: CGPoint(x: anchorX - length, y: y - 5),
                controlPoint1: CGPoint(x: anchorX - length * 0.3, y: y + 4),
                controlPoint2: CGPoint(x: anchorX - length * 0.65, y: y - 8)
            )
            layer.path = path.cgPath
            layer.fillColor = nil
            layer.strokeColor = color
            layer.lineWidth = 1.2
            layer.lineCap = .round
            layer.frame = context.stage.bounds
            context.stage.present(layer)

            // A short dash travelling along the curve: strokeStart chases strokeEnd.
            let start = EffectAnimation.keyframes("strokeStart", reversed ? [0.75, 0.35, 0] : [0, 0.4, 0.75], times: [0, 0.6, 1])
            let end = EffectAnimation.keyframes("strokeEnd", reversed ? [1, 0.6, 0.25] : [0.25, 0.75, 1], times: [0, 0.4, 1])
            let pool = context.pool
            EffectAnimation.play(
                [start, end, EffectAnimation.keyframes("opacity", [0, 1, 0], times: [0, 0.3, 1])],
                on: layer,
                duration: Self.duration * 0.85,
                delay: Double(index) * 0.05,
                timing: EffectAnimation.easeInOut
            ) { pool.recycle(layer) }
        }
    }
}
