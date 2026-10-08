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
    /// Wider than 1 only while the space bar is a trackpad.
    private var span: CGFloat = 1
    private var restingColor: UIColor?
    private var pressedColor: UIColor?
    private var shadowBounds: CGRect = .zero
    private var gulpStep = 0
    private var gulpToken = 0
    private var iconIsGulping = false

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
        hint: String? = nil,
        trackpadOpen: Bool = false,
        gulp: (travelsRight: Bool, step: Int)? = nil
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
        let open = trackpadOpen && !UIAccessibility.isReduceMotionEnabled
        let nextSpan: CGFloat = open ? Motion.trackpadSpan : 1
        let spanChanged = abs(nextSpan - span) > 0.001
        span = nextSpan
        applyFill(pressed: pressed, suggested: suggested, animateSpan: spanChanged)
        if let gulp, gulp.step != gulpStep {
            gulpStep = gulp.step
            playGulp(travelsRight: gulp.travelsRight)
        } else if gulp == nil {
            gulpStep = 0
        }
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

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 2, dy: 0)
        if !iconIsGulping {
            icon.frame = bounds
        }
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
    private func applyFill(pressed: Bool, suggested: Bool, animateSpan: Bool) {
        let wasLit = isPressed || isSuggested
        isPressed = pressed
        isSuggested = suggested
        let lit = pressed || suggested
        let target = lit ? pressedColor : restingColor
        let transform = currentTransform()

        if animateSpan {
            UIView.animate(
                withDuration: Motion.modeChange,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
            ) {
                self.backgroundColor = target
                self.transform = transform
            }
        } else if wasLit, !lit {
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

    /// The trackpad opens the bar sideways. A press, on any other key, scales evenly and at once.
    private func currentTransform() -> CGAffineTransform {
        if span != 1 {
            return CGAffineTransform(scaleX: span, y: 1)
        }
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
            if let image, icon.image != nil, !UIAccessibility.isReduceMotionEnabled {
                icon.setSymbolImage(image, contentTransition: .replace)
            } else {
                icon.image = image
            }
        }
    }

    /// The glyph leans into the finger, then settles back on the key. A new bite starts from
    /// wherever the last one was drawn.
    private func playGulp(travelsRight: Bool) {
        guard !UIAccessibility.isReduceMotionEnabled, bounds.width > 1 else { return }
        iconIsGulping = true
        gulpToken += 1
        let token = gulpToken
        let resting = bounds
        let lean = (travelsRight ? 1 : -1) * resting.width * 0.16
        let stretched = resting.insetBy(dx: -resting.width * 0.1, dy: resting.height * 0.08).offsetBy(dx: lean, dy: 0)
        MorphDriver.move(icon, to: stretched, kind: .stretch, duration: Motion.gulp * 0.62, travels: true) { [weak self] in
            guard let self, self.gulpToken == token else { return }
            MorphDriver.move(self.icon, to: resting, kind: .settle, duration: Motion.gulp * 0.38, travels: true) { [weak self] in
                guard let self, self.gulpToken == token else { return }
                self.iconIsGulping = false
                self.icon.frame = self.bounds
            }
        }
    }
}
