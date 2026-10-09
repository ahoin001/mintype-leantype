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

    var wordMemory: ((String) -> WordMemory)? {
        get { suggestions.memoryOf }
        set { suggestions.memoryOf = newValue }
    }

    var onRememberWord: ((String) -> Void)? {
        get { suggestions.onRemember }
        set { suggestions.onRemember = newValue }
    }

    var onForgetWord: ((String) -> Void)? {
        get { suggestions.onForget }
        set { suggestions.onForget = newValue }
    }

    var onBanWord: ((String) -> Void)? {
        get { suggestions.onBan }
        set { suggestions.onBan = newValue }
    }

    var onMoreOften: ((String) -> Void)? {
        get { suggestions.onMoreOften }
        set { suggestions.onMoreOften = newValue }
    }

    var onLessOften: ((String) -> Void)? {
        get { suggestions.onLessOften }
        set { suggestions.onLessOften = newValue }
    }

    var useCount: ((String) -> Int)? {
        get { suggestions.useCount }
        set { suggestions.useCount = newValue }
    }

    var menuRows: ((Int) -> [HistoryMenuRow])? {
        get { suggestions.menuRows }
        set { suggestions.menuRows = newValue }
    }

    var onMenuAction: ((Candidate.StripAction) -> Void)? {
        get { suggestions.onMenuAction }
        set { suggestions.onMenuAction = newValue }
    }

    /// A tap on the wordmark. Opens the delete-tap choice.
    var onWordmarkTap: (() -> Void)?

    /// The user picked what a tap on delete removes.
    var onBackspaceChoice: ((BackspaceTapAction) -> Void)?

    /// The delete menu opened or closed, so a waiting hint can take the row.
    var onMenuVisibilityChange: (() -> Void)?

    var isDeleteMenuOpen: Bool { menuOpen }

    private let wordmark = UIButton(type: .system)
    private let suggestions = SuggestionStrip()
    private let capsule = StatusCapsule()
    private let dismissButton = DockView.makeButton(symbol: "keyboard.chevron.compact.down", label: "Hide keyboard")
    private let oneHandedButton = DockView.makeButton(symbol: "keyboard.onehanded.right", label: "One-handed keyboard")
    private let deleteMenu = UIStackView()
    private let wordChoice = UIButton(type: .system)
    private let letterChoice = UIButton(type: .system)
    private var message: DockMessage?
    private var menuOpen = false
    private var backspaceAction = BackspaceTapAction.deleteWord
    private var hintText: String?
    private var candidates = CandidateState.empty
    private var theme: Theme?
    private var palette: EffectPalette?

    override init(frame: CGRect) {
        super.init(frame: frame)

        wordmark.setTitle("leantype", for: .normal)
        wordmark.titleLabel?.font = Typography.rounded(size: 13, weight: .semibold)
        wordmark.titleLabel?.adjustsFontSizeToFitWidth = true
        wordmark.titleLabel?.minimumScaleFactor = 0.7
        wordmark.accessibilityLabel = "LeanType, delete key options"
        wordmark.addAction(UIAction { [weak self] _ in self?.onWordmarkTap?() }, for: .touchUpInside)

        deleteMenu.axis = .horizontal
        deleteMenu.distribution = .fillEqually
        deleteMenu.spacing = 8
        deleteMenu.alpha = 0
        configureChoice(wordChoice, title: "Word", label: "A tap on delete removes a word", action: .deleteWord)
        configureChoice(letterChoice, title: "Letter", label: "A tap on delete removes a letter", action: .deleteCharacter)
        deleteMenu.addArrangedSubview(wordChoice)
        deleteMenu.addArrangedSubview(letterChoice)

        suggestions.alpha = 0

        dismissButton.addAction(UIAction { [weak self] _ in self?.onDismiss?() }, for: .touchUpInside)
        oneHandedButton.addAction(UIAction { [weak self] _ in self?.onOneHanded?() }, for: .touchUpInside)

        addSubview(wordmark)
        addSubview(deleteMenu)
        addSubview(suggestions)
        addSubview(capsule)
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
        wordmark.setTitleColor(theme.secondaryLabel.uiColor.withAlphaComponent(0.55), for: .normal)
        refreshChoices()
        capsule.apply(theme: theme)
        dismissButton.tintColor = theme.secondaryLabel.uiColor
        oneHandedButton.tintColor = theme.secondaryLabel.uiColor
        suggestions.apply(theme: theme)
    }

    /// A commit or a correction, forwarded before the candidate bar updates so the pill can answer it.
    func note(_ event: KeyboardEvent) {
        suggestions.note(event)
    }

    func show(_ newMessage: DockMessage?) {
        guard newMessage != message else { return }
        message = newMessage
        if let newMessage {
            capsule.setMessage(newMessage)
            setNeedsLayout()
            layoutIfNeeded()
        }
        updateVisibility()
    }

    func show(_ newCandidates: CandidateState) {
        guard newCandidates != candidates else {
            suggestions.cancelEmphasis()
            return
        }
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
        guard hintText == nil else { return }
        UIView.transition(with: wordmark, duration: 0.5, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.wordmark.setTitleColor(color, for: .normal)
        }
    }

    func setBackspaceAction(_ action: BackspaceTapAction) {
        guard action != backspaceAction else { return }
        backspaceAction = action
        refreshChoices()
    }

    func toggleDeleteMenu() {
        menuOpen.toggle()
        updateVisibility()
        onMenuVisibilityChange?()
    }

    /// One line in place of the wordmark. Pass nil to restore it.
    func showHint(_ text: String?) {
        hintText = text
        wordmark.setTitle(text ?? "leantype", for: .normal)
        wordmark.accessibilityLabel = text ?? "LeanType, delete key options"
        if let theme {
            let color = text == nil
                ? theme.secondaryLabel.uiColor.withAlphaComponent(0.55)
                : theme.letterKey.label.uiColor
            wordmark.setTitleColor(color, for: .normal)
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
        deleteMenu.frame = center.insetBy(dx: 8, dy: 6)
        suggestions.frame = center
        capsule.frame = center
        capsule.layoutIfResting()
    }

    // MARK: - Private

    /// Status wins, then suggestions, then the delete choice, then the wordmark.
    private func updateVisibility() {
        let showsPill = message != nil && (message == .trackpad || candidates.isEmpty)
        let showsMenu = menuOpen && !showsPill
        let showsSuggestions = !showsPill && !showsMenu && !candidates.isEmpty
        let showsWordmark = !showsPill && !showsMenu && !showsSuggestions
        suggestions.isUserInteractionEnabled = showsSuggestions
        wordmark.isUserInteractionEnabled = showsWordmark
        deleteMenu.isUserInteractionEnabled = showsMenu
        capsule.setShown(showsPill, travels: !UIAccessibility.isReduceMotionEnabled)
        UIView.animate(
            withDuration: Motion.modeChange,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
        ) {
            self.suggestions.alpha = showsSuggestions ? 1 : 0
            self.deleteMenu.alpha = showsMenu ? 1 : 0
            self.wordmark.alpha = showsWordmark ? 1 : 0
        }
    }

    private func configureChoice(_ button: UIButton, title: String, label: String, action: BackspaceTapAction) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = Typography.rounded(size: 15, weight: .semibold)
        button.accessibilityLabel = label
        button.layer.cornerRadius = 8
        button.layer.cornerCurve = .continuous
        button.addAction(UIAction { [weak self] _ in self?.choose(action) }, for: .touchUpInside)
    }

    private func choose(_ action: BackspaceTapAction) {
        backspaceAction = action
        refreshChoices()
        menuOpen = false
        updateVisibility()
        onBackspaceChoice?(action)
        onMenuVisibilityChange?()
    }

    private func refreshChoices() {
        let accent = theme?.accentKey.fill.uiColor ?? tintColor
        let dim = theme?.secondaryLabel.uiColor ?? tintColor
        wordChoice.setTitleColor(backspaceAction == .deleteWord ? accent : dim, for: .normal)
        letterChoice.setTitleColor(backspaceAction == .deleteCharacter ? accent : dim, for: .normal)
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
