import LeanTypeCore
import LeanTypeDesign
import UIKit

/// The balloon that rises out of a pressed key: a letter preview, or the long-press
/// alternates row with a selection pill. A letter preview appears at once. A digit flick
/// or a hold row grows out of its key, then fades away on dismiss.
final class CalloutView: UIView {
    private static let maxOptions = KeyShortcuts.maxCount

    private let shape = CAShapeLayer()
    private let selection = CALayer()
    private var labels: [UILabel] = []
    private var current: CalloutState?
    private var theme: Theme?
    private var style = KeyStyle.pebble
    private var isCompact = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        alpha = 0

        shape.shadowOpacity = 1
        shape.shadowOffset = CGSize(width: 0, height: 2)
        shape.shadowRadius = 4
        layer.addSublayer(shape)

        selection.cornerCurve = .continuous
        selection.isHidden = true
        layer.addSublayer(selection)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: Theme, style: KeyStyle, isCompact: Bool) {
        self.theme = theme
        self.style = style
        self.isCompact = isCompact
        if let current {
            render(current)
        }
    }

    func show(_ callout: CalloutState?, fades: Bool = false) {
        guard callout != current else { return }
        let wasHidden = current == nil || alpha < 0.5
        let wasGrowing = current?.growsFromKey == true
        current = callout

        guard let callout else {
            UIView.animate(withDuration: Motion.calloutDismiss, delay: 0, options: [.beginFromCurrentState]) {
                self.alpha = 0
                self.transform = .identity
            }
            return
        }
        if wasHidden { selection.isHidden = true }
        render(callout)
        let grow = callout.growsFromKey && !wasGrowing && !UIAccessibility.isReduceMotionEnabled
        if grow {
            let origin = CGPoint(x: callout.layout.anchorFrame.midX, y: callout.layout.anchorFrame.minY)
            setScale(0.9, around: origin)
            alpha = 0
            UIView.animate(
                withDuration: Motion.calloutPresent,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
            ) {
                self.setScale(1, around: origin)
                self.alpha = 1
            }
        } else if fades, wasHidden {
            transform = .identity
            alpha = 0
            UIView.animate(withDuration: Motion.calloutDismiss, delay: 0, options: [.beginFromCurrentState]) {
                self.alpha = 1
            }
        } else if !wasGrowing {
            layer.removeAllAnimations()
            transform = .identity
            alpha = 1
        } else {
            alpha = 1
        }
    }

    /// Scales around a point in this view. The transform's origin is the view's center,
    /// so the point is measured from there and the balloon stays planted on its key.
    private func setScale(_ scale: CGFloat, around point: CGPoint) {
        let dx = point.x - bounds.midX
        let dy = point.y - bounds.midY
        transform = CGAffineTransform(translationX: dx, y: dy)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -dx, y: -dy)
    }

    /// Releases label views; they are recreated on demand.
    func purge() {
        guard current == nil else { return }
        labels.forEach { $0.removeFromSuperview() }
        labels.removeAll()
    }

    // MARK: - Rendering

    private func render(_ callout: CalloutState) {
        guard let theme else { return }
        let selected = draw(callout, theme: theme)
        if case .alternates = callout.content {
            placeSelection(selected, fill: theme.selectionFill.uiColor)
        }
    }

    /// Draws the balloon and its labels without implicit animations. Returns the selected
    /// cell, which is placed afterwards so its stretch is not swallowed by this transaction.
    private func draw(_ callout: CalloutState, theme: Theme) -> CGRect? {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let layout = callout.layout
        let path = BalloonPath.make(
            bubble: layout.bubbleFrame,
            key: layout.anchorFrame,
            bubbleRadius: style.calloutCornerRadius,
            keyRadius: style.cornerRadius
        )
        shape.path = path
        shape.shadowPath = path
        shape.fillColor = theme.calloutFill.cgColor
        shape.shadowColor = theme.keyShadow.withAlpha(min(theme.keyShadow.alpha * 1.4, 0.5)).cgColor

        switch callout.content {
        case let .preview(text):
            selection.isHidden = true
            layoutLabels(texts: [text], frames: layout.optionFrames, selectedIndex: nil, theme: theme, role: .callout)
            return nil
        case let .alternates(options, selectedIndex):
            let frames = Array(layout.optionFrames.prefix(Self.maxOptions))
            layoutLabels(
                texts: Array(options.prefix(frames.count)),
                frames: frames,
                selectedIndex: selectedIndex,
                theme: theme,
                role: .calloutAlternate
            )
            guard frames.indices.contains(selectedIndex) else { return nil }
            return frames[selectedIndex].insetBy(dx: 3, dy: 5)
        }
    }

    /// The selection pill stretches between cells. Its first appearance sits in place,
    /// because the balloon itself is what grows out of the key.
    private func placeSelection(_ frame: CGRect?, fill: UIColor) {
        guard let frame else {
            selection.isHidden = true
            return
        }
        let wasVisible = !selection.isHidden
        selection.backgroundColor = fill.cgColor
        selection.cornerRadius = style.cornerRadius
        selection.isHidden = false
        let travels = wasVisible && !UIAccessibility.isReduceMotionEnabled
        MorphDriver.move(selection, to: frame, kind: .stretch, duration: Motion.pillTravel, travels: travels)
    }

    private func layoutLabels(
        texts: [String],
        frames: [CGRect],
        selectedIndex: Int?,
        theme: Theme,
        role: Typography.KeyRole
    ) {
        while labels.count < texts.count {
            let label = UILabel()
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            addSubview(label)
            labels.append(label)
        }
        let font = Typography.keyFont(role, compact: isCompact)
        for (index, label) in labels.enumerated() {
            guard index < texts.count, index < frames.count else {
                label.isHidden = true
                continue
            }
            label.isHidden = false
            label.text = texts[index]
            label.font = font
            label.frame = frames[index]
            label.textColor = (index == selectedIndex ? theme.selectionLabel : theme.calloutLabel).uiColor
        }
    }
}

/// Builds the balloon outline: a rounded bubble joined to the key below it by a smooth neck.
enum BalloonPath {
    static func make(bubble: CGRect, key: CGRect, bubbleRadius: CGFloat, keyRadius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let radius = min(bubbleRadius, bubble.height / 2, bubble.width / 2)
        let keyCorner = min(keyRadius, key.height / 2, key.width / 2)
        let neckRise = min(radius, 8)
        let neckDrop = min(key.height * 0.3, 10)
        let neckTop = bubble.maxY - neckRise
        let neckBottom = key.minY + neckDrop
        let neckMid = (neckTop + neckBottom) / 2

        path.move(to: CGPoint(x: bubble.minX, y: bubble.minY + radius))
        path.addArc(
            tangent1End: CGPoint(x: bubble.minX, y: bubble.minY),
            tangent2End: CGPoint(x: bubble.minX + radius, y: bubble.minY),
            radius: radius
        )
        path.addLine(to: CGPoint(x: bubble.maxX - radius, y: bubble.minY))
        path.addArc(
            tangent1End: CGPoint(x: bubble.maxX, y: bubble.minY),
            tangent2End: CGPoint(x: bubble.maxX, y: bubble.minY + radius),
            radius: radius
        )
        path.addLine(to: CGPoint(x: bubble.maxX, y: neckTop))
        path.addCurve(
            to: CGPoint(x: key.maxX, y: neckBottom),
            control1: CGPoint(x: bubble.maxX, y: neckMid),
            control2: CGPoint(x: key.maxX, y: neckMid)
        )
        path.addLine(to: CGPoint(x: key.maxX, y: key.maxY - keyCorner))
        path.addArc(
            tangent1End: CGPoint(x: key.maxX, y: key.maxY),
            tangent2End: CGPoint(x: key.maxX - keyCorner, y: key.maxY),
            radius: keyCorner
        )
        path.addLine(to: CGPoint(x: key.minX + keyCorner, y: key.maxY))
        path.addArc(
            tangent1End: CGPoint(x: key.minX, y: key.maxY),
            tangent2End: CGPoint(x: key.minX, y: key.maxY - keyCorner),
            radius: keyCorner
        )
        path.addLine(to: CGPoint(x: key.minX, y: neckBottom))
        path.addCurve(
            to: CGPoint(x: bubble.minX, y: neckTop),
            control1: CGPoint(x: key.minX, y: neckMid),
            control2: CGPoint(x: bubble.minX, y: neckMid)
        )
        path.closeSubpath()
        return path
    }
}
