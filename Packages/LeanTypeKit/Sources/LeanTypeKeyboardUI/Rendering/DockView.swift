import LeanTypeDesign
import UIKit

/// A short status shown in the dock above the keys.
public enum DockMessage: Hashable, Sendable {
    case trackpad
    case capsLock
    /// Persistent reminder when the keyboard runs without Full Access.
    case fullAccessRequired

    var symbolName: String {
        switch self {
        case .trackpad: "cursorarrow.motionlines"
        case .capsLock: "capslock.fill"
        case .fullAccessRequired: "lock.open"
        }
    }

    var text: String {
        switch self {
        case .trackpad: "Trackpad"
        case .capsLock: "Caps Lock"
        case .fullAccessRequired: "Allow Full Access in Settings for haptics & your settings"
        }
    }
}

/// The calm strip above the keys: a quiet wordmark at rest, a status pill when something
/// is happening, and a dismiss button. It also gives top-row callouts room to draw.
final class DockView: UIView {
    var onDismiss: (() -> Void)? {
        didSet { dismissButton.isHidden = onDismiss == nil }
    }

    private let wordmark = UILabel()
    private let pill = UIView()
    private let pillIcon = UIImageView()
    private let pillLabel = UILabel()
    private let dismissButton = UIButton(type: .system)
    private var message: DockMessage?

    override init(frame: CGRect) {
        super.init(frame: frame)

        wordmark.text = "leantype"
        wordmark.font = Typography.rounded(size: 13, weight: .semibold)
        wordmark.textAlignment = .center
        wordmark.isAccessibilityElement = false

        pill.layer.cornerCurve = .continuous
        pill.alpha = 0
        pillIcon.contentMode = .center
        pillIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        pillLabel.font = Typography.keyFont(.status, compact: false)
        pillLabel.adjustsFontSizeToFitWidth = true
        pillLabel.minimumScaleFactor = 0.8
        pill.addSubview(pillIcon)
        pill.addSubview(pillLabel)
        pill.isAccessibilityElement = true
        pill.accessibilityTraits = .staticText

        dismissButton.setImage(
            UIImage(
                systemName: "keyboard.chevron.compact.down",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            ),
            for: .normal
        )
        dismissButton.accessibilityLabel = "Hide keyboard"
        dismissButton.isHidden = true
        dismissButton.addAction(UIAction { [weak self] _ in self?.onDismiss?() }, for: .touchUpInside)

        addSubview(wordmark)
        addSubview(pill)
        addSubview(dismissButton)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: Theme) {
        wordmark.textColor = theme.secondaryLabel.uiColor.withAlphaComponent(0.55)
        pill.backgroundColor = theme.statusPillFill.uiColor
        pillIcon.tintColor = theme.accentKey.fill.uiColor
        pillLabel.textColor = theme.letterKey.label.uiColor
        dismissButton.tintColor = theme.secondaryLabel.uiColor
    }

    func show(_ newMessage: DockMessage?) {
        guard newMessage != message else { return }
        message = newMessage
        if let newMessage {
            pillIcon.image = UIImage(systemName: newMessage.symbolName)
            pillLabel.text = newMessage.text
            pill.accessibilityLabel = newMessage.text
            setNeedsLayout()
            layoutIfNeeded()
        }
        UIView.animate(
            withDuration: Motion.modeChange,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
        ) {
            self.pill.alpha = newMessage == nil ? 0 : 1
            self.wordmark.alpha = newMessage == nil ? 1 : 0
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let buttonSize = bounds.height
        dismissButton.frame = CGRect(x: bounds.maxX - buttonSize - 4, y: 0, width: buttonSize, height: buttonSize)
        wordmark.frame = bounds.insetBy(dx: buttonSize + 8, dy: 0)

        let maxPillWidth = bounds.width - 2 * (buttonSize + 8)
        let iconWidth: CGFloat = 16
        let textWidth = min(pillLabel.intrinsicContentSize.width, maxPillWidth - iconWidth - 30)
        let pillWidth = iconWidth + textWidth + 30
        let pillHeight = min(26, bounds.height - 8)
        pill.frame = CGRect(
            x: (bounds.width - pillWidth) / 2,
            y: (bounds.height - pillHeight) / 2,
            width: pillWidth,
            height: pillHeight
        )
        pill.layer.cornerRadius = pillHeight / 2
        pillIcon.frame = CGRect(x: 12, y: 0, width: iconWidth, height: pillHeight)
        pillLabel.frame = CGRect(x: 12 + iconWidth + 6, y: 0, width: textWidth, height: pillHeight)
    }
}
