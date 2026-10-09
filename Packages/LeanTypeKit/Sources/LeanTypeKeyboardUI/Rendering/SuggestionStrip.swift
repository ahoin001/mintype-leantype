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
    var onBan: ((String) -> Void)?
    var onMoreOften: ((String) -> Void)?
    var onLessOften: ((String) -> Void)?
    var useCount: ((String) -> Int)?
    var historyChoices: ((String) -> [String])?
    var onReplaceHistory: ((Int, String) -> Void)?

    private let scroller = UIScrollView()
    private var slots: [SuggestionSlot] = []
    private var contentWidth: CGFloat = 0
    private var separators: [UIView] = []
    /// One pill for the highlighted word, so it can slide between slots instead of popping.
    private let pill = UIView()
    private(set) var state = CandidateState.empty
    private var theme: Theme?
    private var pillFollowsLayout = true
    /// Set by a commit or a correction, then consumed by the next pill placement.
    private var emphasis = PillEmphasis.travel

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        scroller.showsHorizontalScrollIndicator = false
        scroller.alwaysBounceHorizontal = false
        scroller.clipsToBounds = true
        addSubview(scroller)
        pill.isUserInteractionEnabled = false
        pill.layer.cornerCurve = .continuous
        pill.alpha = 0
        scroller.addSubview(pill)
        addInteraction(UIContextMenuInteraction(delegate: self))
        for index in 0..<CandidateState.historyLimit {
            let slot = SuggestionSlot()
            slot.addAction(UIAction { [weak self] _ in
                guard self?.state.isHistory != true else { return }
                self?.onSelect?(index)
            }, for: .touchUpInside)
            slots.append(slot)
            scroller.addSubview(slot)
        }
        for _ in 1..<CandidateState.historyLimit {
            let separator = UIView()
            separator.isUserInteractionEnabled = false
            separators.append(separator)
            scroller.addSubview(separator)
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
        placePill(animated: false)
    }

    /// A commit or a correction the next placement should picture. Ignored once the bar updates.
    func note(_ event: KeyboardEvent) {
        switch event {
        case .wordCommitted(.swipe), .wordCommitted(.suggestion):
            emphasis = .land
        case .correctionApplied, .correctionReverted:
            emphasis = .correct
        default:
            break
        }
    }

    /// The event arrived but the bar did not change, so the emphasis must not leak onto a later move.
    func cancelEmphasis() {
        emphasis = .travel
    }

    func show(_ newState: CandidateState) {
        guard newState != state else {
            cancelEmphasis()
            return
        }
        state = newState
        let animated = !UIAccessibility.isReduceMotionEnabled && window != nil
        render(animated: animated)
        pillFollowsLayout = false
        setNeedsLayout()
        layoutIfNeeded()
        placePill(animated: animated)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        positionSlots()
        if pillFollowsLayout {
            placePill(animated: false)
        }
    }

    private func positionSlots() {
        scroller.frame = bounds
        let count = max(state.candidates.count, 1)
        if state.isHistory {
            var x: CGFloat = 0
            for (index, slot) in slots.enumerated() {
                let visible = index < state.candidates.count
                slot.isHidden = !visible
                let letters = visible ? CGFloat(state.candidates[index].text.count) : 0
                let width = visible ? max(76, letters * 11 + 28) : 0
                slot.frame = CGRect(x: x, y: 0, width: width, height: bounds.height).insetBy(dx: 3, dy: 4)
                if visible { x += width }
            }
            for separator in separators { separator.isHidden = true }
            contentWidth = max(x, bounds.width)
        } else {
            contentWidth = bounds.width
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
        scroller.isScrollEnabled = state.isHistory && contentWidth > bounds.width + 1
        scroller.contentSize = CGSize(width: contentWidth, height: bounds.height)
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
            if state.isHistory {
                slot.menu = historyMenu(for: candidate.text, index: index)
                slot.showsMenuAsPrimaryAction = true
            } else {
                slot.menu = nil
                slot.showsMenuAsPrimaryAction = false
            }
        }
    }

    func contextMenuInteraction(
        _: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !state.isHistory, let word = word(at: location) else { return nil }
        let memory = memoryOf?(word) ?? .unavailable
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.menu(for: word, memory: memory)
        }
    }

    private func word(at location: CGPoint) -> String? {
        guard let index = slots.firstIndex(where: { !$0.isHidden && $0.frame.contains(scroller.convert(location, from: self)) }),
              index < state.candidates.count
        else { return nil }
        return state.candidates[index].text
    }

    private func menu(for word: String, memory: WordMemory) -> UIMenu? {
        switch memory {
        case .unavailable:
            return UIMenu(children: [banAction(word)])
        case .fresh:
            return UIMenu(children: [rememberAction(word, strengthens: false), banAction(word)])
        case .learning:
            return UIMenu(children: [rememberAction(word, strengthens: false)] + scoreActions(word) + [forgetAction(word), banAction(word)])
        case .remembered:
            return UIMenu(children: scoreActions(word) + [forgetAction(word), banAction(word)])
        case .blocked:
            return UIMenu(children: [rememberAction(word, strengthens: false)])
        }
    }

    private func historyMenu(for word: String, index: Int) -> UIMenu {
        let choices = (historyChoices?(word) ?? []).map { choice in
            UIAction(title: choice, image: UIImage(systemName: "text.cursor")) { [weak self] _ in
                self?.onReplaceHistory?(index, choice)
            }
        }
        let memory = memoryOf?(word) ?? .unavailable
        let rank = scoreActions(word)
        let tail: [UIMenuElement]
        switch memory {
        case .fresh:
            tail = [rememberAction(word, strengthens: false), banAction(word)]
        case .learning:
            tail = rank + [forgetAction(word), banAction(word)]
        case .remembered:
            tail = rank + [forgetAction(word), banAction(word)]
        case .blocked:
            tail = [rememberAction(word, strengthens: false)]
        case .unavailable:
            tail = rank + [banAction(word)]
        }
        return UIMenu(children: choices + tail)
    }

    private func scoreActions(_ word: String) -> [UIAction] {
        let count = useCount?(word) ?? 0
        let detail = count == 1 ? "Used 1 time" : "Used \(count) times"
        let more = UIAction(title: "More often", subtitle: detail, image: UIImage(systemName: "arrow.up")) { [weak self] _ in
            self?.onMoreOften?(word)
        }
        let less = UIAction(title: "Less often", subtitle: detail, image: UIImage(systemName: "arrow.down")) { [weak self] _ in
            self?.onLessOften?(word)
        }
        return [more, less]
    }

    private func banAction(_ word: String) -> UIAction {
        UIAction(title: "Never suggest", subtitle: "Keep this spelling off the keyboard", image: UIImage(systemName: "nosign"), attributes: .destructive) { [weak self] _ in
            self?.onBan?(word)
        }
    }

    private func rememberAction(_ word: String, strengthens: Bool) -> UIAction {
        let subtitle = strengthens
            ? "Count it again, so it ranks higher"
            : "Keep this spelling, and suggest it"
        return UIAction(title: "Remember", subtitle: subtitle, image: UIImage(systemName: "brain")) { [weak self] _ in
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
            return [UIAccessibilityCustomAction(name: "Never suggest \(word)") { [weak self] _ in
                self?.onBan?(word)
                return true
            }]
        case .fresh:
            return [
                UIAccessibilityCustomAction(name: "Remember \(word)") { [weak self] _ in
                    self?.onRemember?(word)
                    return true
                },
                UIAccessibilityCustomAction(name: "Never suggest \(word)") { [weak self] _ in
                    self?.onBan?(word)
                    return true
                },
            ]
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
                UIAccessibilityCustomAction(name: "Never suggest \(word)") { [weak self] _ in
                    self?.onBan?(word)
                    return true
                },
            ]
        case .remembered:
            return [
                UIAccessibilityCustomAction(name: "Remember \(word)") { [weak self] _ in
                    self?.onRemember?(word)
                    return true
                },
                UIAccessibilityCustomAction(name: "Forget \(word)") { [weak self] _ in
                    self?.onForget?(word)
                    return true
                },
                UIAccessibilityCustomAction(name: "Never suggest \(word)") { [weak self] _ in
                    self?.onBan?(word)
                    return true
                },
            ]
        case .blocked:
            return [UIAccessibilityCustomAction(name: "Remember \(word)") { [weak self] _ in
                self?.onRemember?(word)
                return true
            }]
        }
    }

    /// Stretches the accent pill between slots. A landing or a correction squeezes through
    /// the middle instead. The first appearance is in place.
    private func placePill(animated: Bool) {
        let emphasis = self.emphasis
        self.emphasis = .travel
        guard let theme, let index = state.highlightedIndex, slots.indices.contains(index), !slots[index].isHidden else {
            if emphasis == .land, animated, pill.alpha > 0.5 {
                MorphDriver.move(pill, to: pill.frame, kind: .settle, duration: Motion.pillSettle, travels: true) { [weak self] in
                    self?.pillFollowsLayout = true
                }
                UIView.animate(withDuration: Motion.pillSettle, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                    self.pill.alpha = 0
                }
            } else {
                pill.alpha = 0
                pillFollowsLayout = true
            }
            return
        }
        pill.backgroundColor = theme.accentKey.fill.uiColor
        let target = slots[index].frame
        pill.layer.cornerRadius = target.height / 2
        let visible = pill.alpha > 0.5 && pill.frame.width > 1
        guard animated, visible else {
            pill.frame = target
            pill.alpha = 1
            pillFollowsLayout = true
            return
        }
        let kind: Morph = emphasis == .travel ? .stretch : .settle
        let duration = emphasis == .travel ? Motion.pillTravel : Motion.pillSettle
        pill.alpha = 1
        MorphDriver.move(pill, to: target, kind: kind, duration: duration, travels: true) { [weak self] in
            self?.pillFollowsLayout = true
        }
    }

    private static func title(for candidate: Candidate, quoted: Bool) -> String {
        candidate.role == .typed && quoted ? "“\(candidate.text)”" : candidate.text
    }
}

/// What the next pill placement is answering.
private enum PillEmphasis {
    case travel
    case land
    case correct
}

/// One tappable suggestion.
private final class SuggestionSlot: UIButton {
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
