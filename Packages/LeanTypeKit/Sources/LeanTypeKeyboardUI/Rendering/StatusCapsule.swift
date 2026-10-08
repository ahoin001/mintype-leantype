import LeanTypeDesign
import UIKit

/// The dock's status capsule. It grows out of a circle at the wordmark's center, lets the
/// icon and label follow, and collapses with more damping than the open. Layout owns the
/// resting frame; this view only morphs between rests.
final class StatusCapsule: UIView {
    private let pill = UIView()
    private let icon = UIImageView()
    private let label = UILabel()
    private var isShown = false
    private var isResting = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false

        pill.layer.cornerCurve = .continuous
        pill.alpha = 0
        pill.layer.shadowColor = UIColor.black.cgColor
        pill.layer.shadowOffset = CGSize(width: 0, height: 3)
        pill.layer.shadowRadius = 5
        pill.layer.shadowOpacity = 0
        icon.contentMode = .center
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        label.font = Typography.keyFont(.status, compact: false)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8
        pill.addSubview(icon)
        pill.addSubview(label)
        pill.isAccessibilityElement = true
        pill.accessibilityTraits = .staticText
        addSubview(pill)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: Theme) {
        pill.backgroundColor = theme.statusPillFill.uiColor
        icon.tintColor = theme.accentKey.fill.uiColor
        label.textColor = theme.letterKey.label.uiColor
    }

    func setMessage(_ message: DockMessage) {
        icon.image = UIImage(systemName: message.symbolName)
        label.text = message.text
        pill.accessibilityLabel = message.text
        guard isShown else { return }
        place(restingFrame(), kind: .stretch, duration: Motion.pillTravel)
    }

    func setShown(_ shown: Bool, travels: Bool) {
        guard shown != isShown else { return }
        if shown {
            let target = restingFrame()
            guard target.width > 1 else { return }
            isShown = true
            isResting = false
            pill.frame = seed(for: target)
            pill.layer.cornerRadius = target.height / 2
            pill.alpha = 1
            icon.alpha = 0
            label.alpha = 0
            layoutContent(in: target.size)
            fadeShadow(to: 0.18, duration: Motion.modeChange)
            MorphDriver.move(pill, to: target, kind: .expand, duration: Motion.modeChange, travels: travels) { [weak self] in
                self?.isResting = true
            }
            let delay = travels ? Motion.contentDelay : 0
            MorphDriver.reveal(icon, after: delay, travels: travels)
            MorphDriver.reveal(label, after: delay, travels: travels)
        } else {
            isShown = false
            dismiss(travels: travels)
        }
    }

    /// Keeps the resting capsule aligned when the dock resizes. A morph in flight is left alone.
    func layoutIfResting() {
        guard isResting else { return }
        let target = restingFrame()
        pill.frame = target
        pill.layer.cornerRadius = target.height / 2
        layoutContent(in: target.size)
    }

    // MARK: - Private

    private func dismiss(travels: Bool) {
        isResting = false
        icon.alpha = 0
        label.alpha = 0
        fadeShadow(to: 0, duration: Motion.modeChange)
        let destination = seed(for: pill.frame)
        MorphDriver.move(
            pill,
            to: destination,
            kind: .contract,
            duration: Motion.modeChange * 1.25,
            travels: travels
        ) { [weak self] in
            self?.pill.alpha = 0
            self?.isResting = true
        }
    }

    private func place(_ target: CGRect, kind: Morph, duration: TimeInterval) {
        guard target.width > 1 else { return }
        isResting = false
        pill.layer.cornerRadius = target.height / 2
        layoutContent(in: target.size)
        let travels = !UIAccessibility.isReduceMotionEnabled
        MorphDriver.move(pill, to: target, kind: kind, duration: duration, travels: travels) { [weak self] in
            self?.isResting = true
        }
    }

    private func restingFrame() -> CGRect {
        let iconWidth: CGFloat = 16
        let textWidth = min(label.intrinsicContentSize.width, max(bounds.width - iconWidth - 30, 0))
        let width = min(iconWidth + textWidth + 30, bounds.width)
        let height = min(26, max(bounds.height - 8, 0))
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    /// A circle the height of the capsule, at its center. The open grows out of this.
    private func seed(for frame: CGRect) -> CGRect {
        CGRect(
            x: frame.midX - frame.height / 2,
            y: frame.minY,
            width: frame.height,
            height: frame.height
        )
    }

    private func layoutContent(in size: CGSize) {
        icon.frame = CGRect(x: 12, y: 0, width: 16, height: size.height)
        label.frame = CGRect(x: 34, y: 0, width: max(size.width - 46, 0), height: size.height)
    }

    private func fadeShadow(to opacity: Float, duration: TimeInterval) {
        let animation = CABasicAnimation(keyPath: "shadowOpacity")
        animation.fromValue = pill.layer.presentation()?.shadowOpacity ?? pill.layer.shadowOpacity
        animation.toValue = opacity
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pill.layer.shadowOpacity = opacity
        pill.layer.add(animation, forKey: "shadow")
    }
}
