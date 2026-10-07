import LeanTypeCore
import LeanTypeDesign
import UIKit

/// Three suggestion slots in the dock. The word a space will accept is shown on a soft accent
/// pill; the typed word appears in quotes when autocorrect is about to replace it; an undone
/// correction offers its original back with a return arrow.
final class SuggestionStrip: UIView, UIContextMenuInteractionDelegate {
    var onSelect: ((Int) -> Void)?
    /// Where a suggestion sits in the user's word list. Drives the long-press menu.
    var memoryOf: ((String) -> WordMemory)?
    var onRemember: ((String) -> Void)?
    var onForget: ((String) -> Void)?

    private var slots: [SuggestionSlot] = []
    private var separators: [UIView] = []
    /// One pill for the highlighted word, so it can slide between slots instead of popping.
    private let pill = UIView()
    private(set) var state = CandidateState.empty
    private var theme: Theme?
    private var pillFollowsLayout = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        pill.isUserInteractionEnabled = false
        pill.layer.cornerCurve = .continuous
        pill.alpha = 0
        addSubview(pill)
        addInteraction(UIContextMenuInteraction(delegate: self))
        for index in 0..<CandidateState.capacity {
            let slot = SuggestionSlot()
            slot.addAction(UIAction { [weak self] _ in self?.onSelect?(index) }, for: .touchUpInside)
            slots.append(slot)
            addSubview(slot)
        }
        for _ in 1..<CandidateState.capacity {
            let separator = UIView()
            separator.isUserInteractionEnabled = false
            separators.append(separator)
            addSubview(separator)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: Theme) {
        self.theme = theme
        separators.forEach { $0.backgroundColor = theme.secondaryLabel.uiColor.withAlphaComponent(0.18) }
        render(animated: false)
        placePill(from: nil, animated: false)
    }

    func show(_ newState: CandidateState) {
        guard newState != state else { return }
        let wasShowingPill = state.highlightedIndex != nil && pill.alpha > 0.5
        let from = pill.frame
        state = newState
        let animated = !UIAccessibility.isReduceMotionEnabled && window != nil
        render(animated: animated)
        pillFollowsLayout = false
        setNeedsLayout()
        layoutIfNeeded()
        placePill(from: wasShowingPill ? from : nil, animated: animated)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        positionSlots()
        if pillFollowsLayout {
            placePill(from: nil, animated: false)
        }
    }

    private func positionSlots() {
        let count = max(state.candidates.count, 1)
        let width = bounds.width / CGFloat(count)
        for (index, slot) in slots.enumerated() {
            slot.isHidden = index >= state.candidates.count
            slot.frame = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height).insetBy(dx: 3, dy: 4)
        }
        for (index, separator) in separators.enumerated() {
            separator.isHidden = index + 1 >= state.candidates.count
                || state.highlightedIndex == index || state.highlightedIndex == index + 1
            separator.frame = CGRect(x: CGFloat(index + 1) * width - 0.5, y: bounds.height * 0.28, width: 1, height: bounds.height * 0.44)
        }
    }

    private func render(animated: Bool) {
        guard let theme else { return }
        for (index, slot) in slots.enumerated() {
            guard index < state.candidates.count else { continue }
            let candidate = state.candidates[index]
            let isHighlighted = state.highlightedIndex == index
            let apply = {
                slot.configure(
                    text: Self.title(for: candidate, quoted: self.state.highlightedIndex != nil),
                    symbol: candidate.role == .revert ? "arrow.uturn.backward" : nil,
                    isHighlighted: isHighlighted,
                    theme: theme
                )
            }
            if animated, slot.labelText != nil {
                UIView.transition(with: slot, duration: 0.12, options: .transitionCrossDissolve, animations: apply)
            } else {
                apply()
            }
            slot.accessibilityLabel = candidate.role == .revert ? "Undo correction, \(candidate.text)" : candidate.text
            slot.accessibilityCustomActions = accessibilityActions(for: candidate.text)
        }
    }

    func contextMenuInteraction(
        _: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let word = word(at: location), memoryOf?(word) != .unavailable else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.menu(for: word)
        }
    }

    private func word(at location: CGPoint) -> String? {
        guard let index = slots.firstIndex(where: { !$0.isHidden && $0.frame.contains(location) }),
              index < state.candidates.count
        else { return nil }
        return state.candidates[index].text
    }

    private func menu(for word: String) -> UIMenu? {
        switch memoryOf?(word) ?? .unavailable {
        case .unavailable:
            return nil
        case .fresh, .learning:
            var actions = [rememberAction(word)]
            if memoryOf?(word) == .learning {
                actions.append(forgetAction(word))
            }
            return UIMenu(children: actions)
        case .remembered:
            return UIMenu(children: [forgetAction(word)])
        }
    }

    private func rememberAction(_ word: String) -> UIAction {
        UIAction(title: "Remember", subtitle: "Keep this spelling, and suggest it", image: UIImage(systemName: "brain")) { [weak self] _ in
            self?.onRemember?(word)
        }
    }

    private func forgetAction(_ word: String) -> UIAction {
        UIAction(title: "Forget", subtitle: "Stop suggesting this word", image: UIImage(systemName: "brain"), attributes: .destructive) { [weak self] _ in
            self?.onForget?(word)
        }
    }

    private func accessibilityActions(for word: String) -> [UIAccessibilityCustomAction]? {
        switch memoryOf?(word) ?? .unavailable {
        case .unavailable:
            return nil
        case .fresh:
            return [UIAccessibilityCustomAction(name: "Remember \(word)") { [weak self] _ in
                self?.onRemember?(word)
                return true
            }]
        case .learning:
            return [
                UIAccessibilityCustomAction(name: "Remember \(word)") { [weak self] _ in
                    self?.onRemember?(word)
                    return true
                },
                UIAccessibilityCustomAction(name: "Forget \(word)") { [weak self] _ in
                    self?.onForget?(word)
                    return true
                },
            ]
        case .remembered:
            return [UIAccessibilityCustomAction(name: "Forget \(word)") { [weak self] _ in
                self?.onForget?(word)
                return true
            }]
        }
    }

    /// Slides the accent pill when it was already on screen; otherwise it appears in place.
    private func placePill(from previous: CGRect?, animated: Bool) {
        guard let theme, let index = state.highlightedIndex, slots.indices.contains(index), !slots[index].isHidden else {
            let hide = { self.pill.alpha = 0 }
            if animated {
                UIView.animate(withDuration: 0.12, animations: hide) { _ in self.pillFollowsLayout = true }
            } else {
                hide()
                pillFollowsLayout = true
            }
            return
        }
        pill.backgroundColor = theme.accentKey.fill.uiColor
        let target = slots[index].frame
        pill.layer.cornerRadius = target.height / 2
        let slide = animated && previous != nil
        if slide, let previous {
            pill.frame = previous
        }
        let move = {
            self.pill.frame = target
            self.pill.alpha = 1
        }
        if slide {
            UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: move) { _ in
                self.pillFollowsLayout = true
            }
        } else {
            move()
            pillFollowsLayout = true
        }
    }

    private static func title(for candidate: Candidate, quoted: Bool) -> String {
        candidate.role == .typed && quoted ? "“\(candidate.text)”" : candidate.text
    }
}

/// One tappable suggestion.
private final class SuggestionSlot: UIControl {
    private let label = UILabel()
    private let icon = UIImageView()

    var labelText: String? { label.text }

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        label.lineBreakMode = .byTruncatingMiddle
        icon.contentMode = .center
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        addSubview(label)
        addSubview(icon)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.55 : 1 }
    }

    func configure(text: String, symbol: String?, isHighlighted emphasized: Bool, theme: Theme) {
        label.text = text
        label.font = Typography.rounded(size: 16, weight: emphasized ? .semibold : .regular)
        label.textColor = emphasized ? theme.accentKey.label.uiColor : theme.letterKey.label.uiColor
        icon.image = symbol.flatMap { UIImage(systemName: $0) }
        icon.tintColor = theme.secondaryLabel.uiColor
        icon.isHidden = symbol == nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let iconWidth: CGFloat = icon.isHidden ? 0 : 16
        let textWidth = min(label.intrinsicContentSize.width, bounds.width - 12 - iconWidth)
        let start = (bounds.width - textWidth - iconWidth) / 2
        icon.frame = CGRect(x: start, y: 0, width: iconWidth, height: bounds.height)
        label.frame = CGRect(x: start + iconWidth, y: 0, width: textWidth, height: bounds.height)
    }
}
