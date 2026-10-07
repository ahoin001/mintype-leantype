import LeanTypeDesign
import UIKit

/// One soft, puffy key. Purely visual: touches are handled by `KeyboardTouchView`.
///
/// Rendering is kept cheap: a single layer with a solid fill, continuous corners, a hairline
/// rim, and a shadow whose path is precomputed so Core Animation never needs an offscreen pass.
final class KeyView: UIView {
    private let label = UILabel()
    private let icon = UIImageView()
    private var style: KeyStyle
    private var currentLabel: KeyLabel?
    private var isCompact = false
    private var isPressed = false
    private var restingColor: UIColor?
    private var pressedColor: UIColor?
    private var shadowBounds: CGRect = .zero

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
        isEnabled: Bool,
        isCompact compact: Bool
    ) {
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
        setPressed(pressed)
    }

    func setContentHidden(_ hidden: Bool) {
        let alpha: CGFloat = hidden ? 0 : 1
        label.alpha = alpha
        icon.alpha = alpha
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 2, dy: 0)
        icon.frame = bounds
        if bounds != shadowBounds {
            shadowBounds = bounds
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: style.cornerRadius).cgPath
        }
    }

    // MARK: - Private

    /// Presses apply instantly (they happen hundreds of times a day); releases ease back.
    private func setPressed(_ pressed: Bool) {
        let wasPressed = isPressed
        isPressed = pressed
        let target = pressed ? pressedColor : restingColor
        let scale = pressed && !UIAccessibility.isReduceMotionEnabled ? style.pressedScale : 1
        let transform = CGAffineTransform(scaleX: scale, y: scale)

        if wasPressed, !pressed {
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
            icon.image = UIImage(systemName: name, withConfiguration: Typography.symbolConfiguration(compact: isCompact))
        }
    }
}
