import LeanTypeCore
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

/// The calm strip above the keys. At rest it shows a quiet wordmark that warms with typing
/// flow; while typing it holds suggestions; a status pill takes over when something modal is
/// happening. Side buttons switch to one-handed mode and hide the keyboard. It also gives
/// top-row callouts room to draw.
final class DockView: UIView {
    var onDismiss: (() -> Void)? {
        didSet { setNeedsLayout() }
    }

    /// Shown when set: switches to one-handed typing.
    var onOneHanded: (() -> Void)? {
        didSet { setNeedsLayout() }
    }

    var onSelectCandidate: ((Int) -> Void)? {
        get { suggestions.onSelect }
        set { suggestions.onSelect = newValue }
    }

    private let wordmark = UILabel()
    private let suggestions = SuggestionStrip()
    private let pill = UIView()
    private let pillIcon = UIImageView()
    private let pillLabel = UILabel()
    private let dismissButton = DockView.makeButton(symbol: "keyboard.chevron.compact.down", label: "Hide keyboard")
    private let oneHandedButton = DockView.makeButton(symbol: "keyboard.onehanded.right", label: "One-handed keyboard")
    private var message: DockMessage?
    private var candidates = CandidateState.empty
    private var theme: Theme?
    private var palette: EffectPalette?

    override init(frame: CGRect) {
        super.init(frame: frame)

        wordmark.text = "leantype"
        wordmark.font = Typography.rounded(size: 13, weight: .semibold)
        wordmark.textAlignment = .center
        wordmark.isAccessibilityElement = false

        suggestions.alpha = 0

        pill.layer.cornerCurve = .continuous
        pill.alpha = 0
        pill.isUserInteractionEnabled = false
        pillIcon.contentMode = .center
        pillIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        pillLabel.font = Typography.keyFont(.status, compact: false)
        pillLabel.adjustsFontSizeToFitWidth = true
        pillLabel.minimumScaleFactor = 0.8
        pill.addSubview(pillIcon)
        pill.addSubview(pillLabel)
        pill.isAccessibilityElement = true
        pill.accessibilityTraits = .staticText

        dismissButton.addAction(UIAction { [weak self] _ in self?.onDismiss?() }, for: .touchUpInside)
        oneHandedButton.addAction(UIAction { [weak self] _ in self?.onOneHanded?() }, for: .touchUpInside)

        addSubview(wordmark)
        addSubview(suggestions)
        addSubview(pill)
        addSubview(dismissButton)
        addSubview(oneHandedButton)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: Theme) {
        self.theme = theme
        palette = EffectPalette(theme: theme)
        wordmark.textColor = theme.secondaryLabel.uiColor.withAlphaComponent(0.55)
        pill.backgroundColor = theme.statusPillFill.uiColor
        pillIcon.tintColor = theme.accentKey.fill.uiColor
        pillLabel.textColor = theme.letterKey.label.uiColor
        dismissButton.tintColor = theme.secondaryLabel.uiColor
        oneHandedButton.tintColor = theme.secondaryLabel.uiColor
        suggestions.apply(theme: theme)
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
        updateVisibility()
    }

    func show(_ newCandidates: CandidateState) {
        guard newCandidates != candidates else { return }
        let visibilityChanged = newCandidates.isEmpty != candidates.isEmpty
        candidates = newCandidates
        suggestions.show(newCandidates)
        if visibilityChanged { updateVisibility() }
    }

    /// Warms the wordmark from its quiet gray toward the accent as flow builds.
    func setFlow(_ flow: FlowLevel) {
        guard let theme, let palette else { return }
        let resting = theme.secondaryLabel.uiColor.withAlphaComponent(0.55)
        let color = flow.value < 0.05 ? resting : palette.shifted(by: 0.1 * CGFloat(flow.value)).withAlphaComponent(0.55 + 0.4 * flow.value)
        UIView.transition(with: wordmark, duration: 0.5, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.wordmark.textColor = color
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let buttonSize = bounds.height
        dismissButton.isHidden = onDismiss == nil
        oneHandedButton.isHidden = onOneHanded == nil
        dismissButton.frame = CGRect(x: bounds.maxX - buttonSize - 4, y: 0, width: buttonSize, height: buttonSize)
        oneHandedButton.frame = CGRect(x: 4, y: 0, width: buttonSize, height: buttonSize)

        let leading: CGFloat = oneHandedButton.isHidden ? 6 : buttonSize + 8
        let trailing: CGFloat = dismissButton.isHidden ? 6 : buttonSize + 8
        let center = CGRect(x: leading, y: 0, width: max(bounds.width - leading - trailing, 0), height: bounds.height)
        wordmark.frame = center
        suggestions.frame = center

        let iconWidth: CGFloat = 16
        let textWidth = min(pillLabel.intrinsicContentSize.width, center.width - iconWidth - 30)
        let pillWidth = iconWidth + textWidth + 30
        let pillHeight = min(26, bounds.height - 8)
        pill.frame = CGRect(
            x: center.midX - pillWidth / 2,
            y: (bounds.height - pillHeight) / 2,
            width: pillWidth,
            height: pillHeight
        )
        pill.layer.cornerRadius = pillHeight / 2
        pillIcon.frame = CGRect(x: 12, y: 0, width: iconWidth, height: pillHeight)
        pillLabel.frame = CGRect(x: 12 + iconWidth + 6, y: 0, width: textWidth, height: pillHeight)
    }

    // MARK: - Private

    /// The pill wins over suggestions (it's modal), suggestions win over the wordmark.
    private func updateVisibility() {
        let showsPill = message != nil && (message == .trackpad || candidates.isEmpty)
        let showsSuggestions = !showsPill && !candidates.isEmpty
        suggestions.isUserInteractionEnabled = showsSuggestions
        UIView.animate(
            withDuration: Motion.modeChange,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
        ) {
            self.pill.alpha = showsPill ? 1 : 0
            self.suggestions.alpha = showsSuggestions ? 1 : 0
            self.wordmark.alpha = showsPill || showsSuggestions ? 0 : 1
        }
    }

    private static func makeButton(symbol: String, label: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(
            UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)),
            for: .normal
        )
        button.accessibilityLabel = label
        button.isHidden = true
        return button
    }
}
