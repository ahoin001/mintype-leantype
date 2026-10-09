import LeanTypeDesign
import UIKit

/// One soft, puffy key. Purely visual: touches are handled by `KeyboardTouchView`.
///
/// Rendering is kept cheap: a single layer with a solid fill, continuous corners, a hairline
/// rim, and a shadow whose path is precomputed so Core Animation never needs an offscreen pass.
final class KeyView: UIView {
    private let label = UILabel()
    private let icon = UIImageView()
    /// Created on first use: most keys never show a hint.
    private var hintLabel: UILabel?
    private var style: KeyStyle
    private var currentLabel: KeyLabel?
    private var isCompact = false
    private var isPressed = false
    private var isSuggested = false
    private var restingColor: UIColor?
    private var pressedColor: UIColor?
    private var shadowBounds: CGRect = .zero
    /// The scrub or trackpad bubble and its highlight. Nil unless that gesture is in progress.
    private var bubble: CAShapeLayer?
    private var highlight: CAShapeLayer?
    private var bubbleStep = 0

    init(style: KeyStyle) {
        self.style = style
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false

        layer.cornerCurve = .continuous
        layer.shadowOpacity = 1
        layer.allowsEdgeAntialiasing = true

        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        label.baselineAdjustment = .alignCenters
        icon.contentMode = .center
        addSubview(label)
        addSubview(icon)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(
        label newLabel: KeyLabel,
        colors: Theme.KeyColors,
        shadow: RGBA,
        style newStyle: KeyStyle,
        isPressed pressed: Bool,
        isSuggested suggested: Bool = false,
        isEnabled: Bool,
        isCompact compact: Bool,
        hint: String? = nil
    ) {
        applyHint(hint, color: colors.label)
        if newStyle != style {
            style = newStyle
            shadowBounds = .zero
            setNeedsLayout()
        }
        if newLabel != currentLabel || compact != isCompact {
            currentLabel = newLabel
            isCompact = compact
            applyLabel(newLabel)
        }

        layer.cornerRadius = style.cornerRadius
        layer.borderWidth = style.rimWidth
        layer.borderColor = colors.rim.cgColor
        layer.shadowColor = shadow.cgColor
        layer.shadowOffset = style.shadowOffset
        layer.shadowRadius = style.shadowRadius

        let tint = colors.label.uiColor.withAlphaComponent(isEnabled ? 1 : 0.4)
        label.textColor = tint
        icon.tintColor = tint
        restingColor = colors.fill.uiColor
        pressedColor = colors.pressedFill.uiColor
        applyFill(pressed: pressed, suggested: suggested)
    }

    /// The new layer's label settles in. The key body stays where layout put it.
    func arrive(after delay: TimeInterval) {
        let scale = Motion.rowArrivalScale
        let shrunk = CGAffineTransform(scaleX: scale, y: scale)
        let views = labelViews
        views.forEach { $0.transform = shrunk }
        UIView.animate(
            withDuration: Motion.rowArrival,
            delay: delay,
            options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            views.forEach { $0.transform = .identity }
        }
    }

    func setContentHidden(_ hidden: Bool) {
        let alpha: CGFloat = hidden ? 0 : 1
        label.alpha = alpha
        icon.alpha = alpha
        hintLabel?.alpha = alpha
    }

    /// A bubble inside the delete key. `lean` is −1 while the finger is left of the key
    /// (deleting) and +1 while it is to the right (putting letters back). The bubble tracks
    /// that directly; the keycap itself stays put.
    func showScrubBubble(lean: CGFloat, restoring: Bool, step: Int, color: UIColor) {
        let bubble = ensureBubble(color: color)
        let clamped = min(1, max(-1, lean))
        let radius = min(bounds.width, bounds.height) * 0.36
        let reach = max(0, bounds.midX - radius - 3)
        let reduced = UIAccessibility.isReduceMotionEnabled
        let pose = scrubPose(lean: clamped, restoring: restoring, reduced: reduced)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bubble.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        bubble.cornerRadius = radius
        bubble.position = CGPoint(x: bounds.midX + clamped * reach, y: bounds.midY)
        bubble.opacity = 1
        if bubble.animation(forKey: "gulp") == nil {
            bubble.transform = pose
        }
        highlight?.bounds = CGRect(x: 0, y: 0, width: radius * 0.7, height: radius * 0.7)
        highlight?.cornerRadius = radius * 0.35
        highlight?.position = CGPoint(x: radius * 0.62, y: radius * 0.58)
        CATransaction.commit()

        guard !reduced, step != bubbleStep else { return }
        bubbleStep = step
        let kick: CGFloat = restoring ? 1.2 : 0.74
        let from = CATransform3DScale(pose, kick, restoring ? kick : 1.06, 1)
        let gulp = CABasicAnimation(keyPath: "transform")
        gulp.fromValue = from
        gulp.toValue = pose
        gulp.duration = Motion.keyRelease
        gulp.timingFunction = CAMediaTimingFunction(name: .easeOut)
        bubble.add(gulp, forKey: "gulp")
    }

    /// A bubble on the space bar. `centerX` is in the key's coordinates and already clamped.
    /// `lean` is −1 at the left (flat, caret moving left) and +1 at the right (round).
    func showTrackpadBubble(centerX: CGFloat, lean: CGFloat, gulpScale: CGFloat, gulpID: Int, pulse: Bool, color: UIColor) {
        let bubble = ensureBubble(color: color, aboveContent: true)
        let clamped = min(1, max(-1, lean))
        let radius = min(bounds.width, bounds.height) * 0.36
        let reduced = UIAccessibility.isReduceMotionEnabled
        let pose = trackpadPose(lean: clamped, reduced: reduced)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bubble.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        bubble.cornerRadius = radius
        bubble.position = CGPoint(x: centerX, y: bounds.midY)
        bubble.opacity = 1
        if bubble.animation(forKey: "gulp") == nil {
            bubble.transform = pose
        }
        highlight?.bounds = CGRect(x: 0, y: 0, width: radius * 0.7, height: radius * 0.7)
        highlight?.cornerRadius = radius * 0.35
        highlight?.position = CGPoint(x: radius * 0.62, y: radius * 0.58)
        CATransaction.commit()

        let scale = pulse ? 1.16 : gulpScale
        let token = pulse ? gulpID &+ 1_000_000 : gulpID
        guard !reduced, scale > 1, token != bubbleStep else { return }
        bubbleStep = token
        let kick: CGFloat = pulse ? 1.16 : scale
        let from = CATransform3DScale(pose, kick, kick, 1)
        let gulp = CABasicAnimation(keyPath: "transform")
        gulp.fromValue = from
        gulp.toValue = pose
        gulp.duration = Motion.keyRelease
        gulp.timingFunction = CAMediaTimingFunction(name: .easeOut)
        bubble.add(gulp, forKey: "gulp")
    }

    /// The bubble settles back into the key.
    func hideScrubBubble() {
        bubbleStep = 0
        guard let bubble else { return }
        self.bubble = nil
        highlight = nil
        guard !UIAccessibility.isReduceMotionEnabled else {
            bubble.removeFromSuperlayer()
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = bubble.presentation()?.opacity ?? bubble.opacity
        fade.toValue = 0
        fade.duration = Motion.keyRelease
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            bubble.removeFromSuperlayer()
        }
        bubble.opacity = 0
        bubble.add(fade, forKey: "out")
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 2, dy: 0)
        icon.frame = bounds
        hintLabel?.frame = CGRect(x: bounds.maxX - 13, y: 2, width: 11, height: 12)
        if bounds != shadowBounds {
            shadowBounds = bounds
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: style.cornerRadius).cgPath
        }
    }

    // MARK: - Private

    /// Presses apply instantly (they happen hundreds of times a day); releases ease back.
    /// A suggested key uses the pressed fill without the press scale, so the preview word
    /// reads as lit letters rather than fingers.
    private func applyFill(pressed: Bool, suggested: Bool) {
        let wasLit = isPressed || isSuggested
        isPressed = pressed
        isSuggested = suggested
        let lit = pressed || suggested
        let target = lit ? pressedColor : restingColor
        let transform = currentTransform()

        if wasLit, !lit {
            UIView.animate(
                withDuration: Motion.keyRelease,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
            ) {
                self.backgroundColor = target
                self.transform = transform
            }
        } else {
            UIView.performWithoutAnimation {
                backgroundColor = target
                self.transform = transform
            }
        }
    }

    /// Deleting flattens the bubble toward the left. Restoring rounds it up on the right.
    /// Reduced motion keeps a circle so the slide is the only change.
    private func scrubPose(lean: CGFloat, restoring: Bool, reduced: Bool) -> CATransform3D {
        guard !reduced else { return CATransform3DIdentity }
        let amount = abs(lean)
        let wide: CGFloat = restoring ? 0.88 : 1.2
        let tall: CGFloat = restoring ? 1.16 : 0.76
        return CATransform3DMakeScale(1 + (wide - 1) * amount, 1 + (tall - 1) * amount, 1)
    }

    /// Left flattens the bubble. Right rounds it up. Reduced motion keeps a circle.
    private func trackpadPose(lean: CGFloat, reduced: Bool) -> CATransform3D {
        guard !reduced else { return CATransform3DIdentity }
        let amount = abs(lean)
        let wide: CGFloat = lean < 0 ? 1.22 : 0.86
        let tall: CGFloat = lean < 0 ? 0.74 : 1.18
        return CATransform3DMakeScale(1 + (wide - 1) * amount, 1 + (tall - 1) * amount, 1)
    }

    private func ensureBubble(color: UIColor, aboveContent: Bool = false) -> CAShapeLayer {
        if let bubble { 
            bubble.backgroundColor = color.withAlphaComponent(0.5).cgColor
            return bubble
        }
        let bubble = CAShapeLayer()
        bubble.backgroundColor = color.withAlphaComponent(0.5).cgColor
        bubble.cornerCurve = .continuous
        let shine = CAShapeLayer()
        shine.backgroundColor = UIColor.white.withAlphaComponent(0.38).cgColor
        shine.cornerCurve = .continuous
        bubble.addSublayer(shine)
        if aboveContent {
            layer.addSublayer(bubble)
        } else {
            layer.insertSublayer(bubble, below: icon.layer)
        }
        self.bubble = bubble
        highlight = shine
        return bubble
    }

    /// A press scales evenly and at once. The keycap itself never stretches.
    private func currentTransform() -> CGAffineTransform {
        let scale = isPressed && !UIAccessibility.isReduceMotionEnabled ? style.pressedScale : 1
        return CGAffineTransform(scaleX: scale, y: scale)
    }

    private func applyHint(_ hint: String?, color: RGBA) {
        guard let hint else {
            hintLabel?.isHidden = true
            return
        }
        let hintLabel = hintLabel ?? makeHintLabel()
        hintLabel.isHidden = false
        if hintLabel.text != hint { hintLabel.text = hint }
        hintLabel.textColor = color.uiColor.withAlphaComponent(0.42)
    }

    private func makeHintLabel() -> UILabel {
        let hint = UILabel()
        hint.font = Typography.rounded(size: 9.5, weight: .semibold)
        hint.textAlignment = .center
        hint.isAccessibilityElement = false
        addSubview(hint)
        hintLabel = hint
        setNeedsLayout()
        return hint
    }

    private var labelViews: [UIView] {
        hintLabel.map { [label, icon, $0] } ?? [label, icon]
    }

    private func applyLabel(_ keyLabel: KeyLabel) {
        switch keyLabel {
        case let .text(text, role):
            label.isHidden = false
            icon.isHidden = true
            label.text = text
            label.font = Typography.keyFont(role, compact: isCompact)
        case let .symbol(name):
            label.isHidden = true
            icon.isHidden = false
            let image = UIImage(systemName: name, withConfiguration: Typography.symbolConfiguration(compact: isCompact))
            icon.image = image
        }
    }
}
