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
    var menuRows: ((Int) -> [HistoryMenuRow])?
    var onMenuAction: ((Candidate.StripAction) -> Void)?
    var borrowTextLayer: (() -> CATextLayer?)?
    var recycleTextLayer: ((CATextLayer) -> Void)?

    private let scroller = UIScrollView()
    private let edgeMask = CAGradientLayer()
    private let popover = StripPopover()
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
    private var pinNewest = false
    private var userDidScroll = false
    private var pressedChip: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        scroller.showsHorizontalScrollIndicator = false
        scroller.alwaysBounceHorizontal = false
        scroller.clipsToBounds = true
        addSubview(scroller)
        edgeMask.colors = [
            UIColor.clear.cgColor,
            UIColor.black.cgColor,
            UIColor.black.cgColor,
            UIColor.clear.cgColor,
        ]
        edgeMask.locations = [0, 0.06, 0.94, 1]
        edgeMask.startPoint = CGPoint(x: 0, y: 0.5)
        edgeMask.endPoint = CGPoint(x: 1, y: 0.5)
        layer.mask = edgeMask
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(holdChip(_:)))
        hold.minimumPressDuration = 0.35
        addGestureRecognizer(hold)
        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(swipeCase(_:)))
        swipeUp.direction = .up
        addGestureRecognizer(swipeUp)
        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(swipeCase(_:)))
        swipeDown.direction = .down
        addGestureRecognizer(swipeDown)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapGap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        scroller.delegate = self
        pill.isUserInteractionEnabled = false
        pill.layer.cornerCurve = .continuous
        pill.alpha = 0
        scroller.addSubview(pill)
        addInteraction(UIContextMenuInteraction(delegate: self))
        for index in 0..<CandidateState.historyLimit {
            let slot = SuggestionSlot()
            slot.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                if self.state.isHistory || self.state.isDrilled,
                   StripMotion.ignoresHistoryTap(isTentative: self.state.isTentative) {
                    return
                }
                self.onSelect?(index)
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
        let wasLand = emphasis == .land
        state = newState
        pinNewest = newState.isHistory && !newState.isDrilled
        userDidScroll = false
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let animated = !reduceMotion && window != nil
        render(animated: animated)
        pillFollowsLayout = false
        setNeedsLayout()
        layoutIfNeeded()
        placePill(animated: animated)
        if wasLand { flyLatestWord(reduceMotion: reduceMotion) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        edgeMask.frame = bounds
        positionSlots()
        if pillFollowsLayout {
            placePill(animated: false)
        }
    }

    private func positionSlots() {
        scroller.frame = bounds
        let count = max(state.candidates.count, 1)
        if state.isHistory || state.isDrilled {
            var x: CGFloat = 0
            for (index, slot) in slots.enumerated() {
                let visible = index < state.candidates.count
                slot.isHidden = !visible
                let letters = visible ? CGFloat(state.candidates[index].text.count) : 0
                let width = visible ? max(44, letters * 11 + 20) : 0
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
        scroller.isScrollEnabled = (state.isHistory || state.isDrilled) && contentWidth > bounds.width + 1
        scroller.contentSize = CGSize(width: contentWidth, height: bounds.height)
        if pinNewest, !userDidScroll {
            centerNewestWord()
        }
    }

    private func render(animated: Bool) {
        guard let theme else { return }
        for (index, slot) in slots.enumerated() {
            guard index < state.candidates.count else { continue }
            let candidate = state.candidates[index]
            let isHighlighted = state.highlightedIndex == index
            let symbol = Self.symbol(for: candidate)
            let wordChip: Bool = {
                if case .openHistory = candidate.action { return true }
                if case .openDocumentWord = candidate.action { return true }
                return false
            }()
            let apply = {
                slot.configure(
                    text: Self.title(for: candidate, quoted: self.state.highlightedIndex != nil),
                    symbol: symbol,
                    isHighlighted: isHighlighted,
                    unsure: candidate.unsure,
                    glows: wordChip && !candidate.unsure,
                    letterThumbs: candidate.letterThumbs,
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
            slot.menu = nil
            slot.showsMenuAsPrimaryAction = false
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

    private static func symbol(for candidate: Candidate) -> String? {
        switch candidate.action {
        case .closeDrill: "chevron.left"
        case .undoEdit: "arrow.uturn.backward"
        default: candidate.role == .revert ? "arrow.uturn.backward" : nil
        }
    }

    private func centerNewestWord() {
        guard let index = state.candidates.lastIndex(where: { candidate in
            if case .openHistory = candidate.action { return true }
            if case .openDocumentWord = candidate.action { return true }
            return false
        }), slots.indices.contains(index) else { return }
        let frame = slots[index].frame
        let target = frame.midX - bounds.width / 2
        let maxOffset = max(0, contentWidth - bounds.width)
        scroller.contentOffset.x = min(max(0, target), maxOffset)
    }

    private func flyLatestWord(reduceMotion: Bool) {
        guard let index = state.highlightedIndex ?? state.candidates.indices.last,
              slots.indices.contains(index), !slots[index].isHidden else { return }
        let slot = slots[index]
        if StripMotion.fadesInsteadOfTraveling(reduceMotion: reduceMotion) {
            slot.alpha = 0
            UIView.animate(withDuration: Motion.stripFade, delay: 0, options: [.allowUserInteraction]) {
                slot.alpha = 1
            }
            return
        }
        guard let layer = borrowTextLayer?() else { return }
        let text = state.candidates[index].text as NSString
        layer.string = text
        layer.fontSize = 16
        layer.alignmentMode = .center
        layer.foregroundColor = slot.labelColor?.cgColor
        layer.contentsScale = self.layer.contentsScale
        let start = CGRect(x: bounds.midX - 30, y: -18, width: 60, height: 22)
        let end = slot.frame
        layer.frame = start
        scroller.layer.addSublayer(layer)
        let plan = Morph.plan(from: start, to: end, kind: .settle, duration: Motion.wordFlight, travels: true)
        let animation = EffectAnimation.keyframes(
            "position",
            plan.samples.map { NSValue(cgPoint: CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        )
        EffectAnimation.play([animation], on: layer, duration: Motion.wordFlight) { [weak self] in
            self?.recycleTextLayer?(layer)
        }
    }

    private func chipIndex(at point: CGPoint) -> Int? {
        let local = scroller.convert(point, from: self)
        return slots.firstIndex { !$0.isHidden && $0.frame.contains(local) }
    }

    @objc private func holdChip(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            guard let index = chipIndex(at: point), let rows = menuRows?(index), !rows.isEmpty else { return }
            pressedChip = index
            let frame = slots[index].convert(slots[index].bounds, to: self)
            popover.present(
                titles: rows.map(\.title),
                from: frame,
                in: self,
                fades: StripMotion.fadesInsteadOfTraveling(reduceMotion: UIAccessibility.isReduceMotionEnabled)
            )
        case .changed:
            popover.highlight(at: gesture.location(in: popover))
        case .ended:
            if let index = pressedChip, let row = popover.selectedIndex(), let rows = menuRows?(index), rows.indices.contains(row) {
                onMenuAction?(rows[row].action)
            }
            pressedChip = nil
            popover.dismiss()
        default:
            pressedChip = nil
            popover.dismiss()
        }
    }

    @objc private func swipeCase(_ gesture: UISwipeGestureRecognizer) {
        guard let index = chipIndex(at: gesture.location(in: self)),
              state.candidates.indices.contains(index) else { return }
        let action = state.candidates[index].action
        let upper = gesture.direction == .up
        switch action {
        case let .openHistory(entry):
            onMenuAction?(.capitalize(entry: entry, upper: upper))
        case let .openDocumentWord(entry):
            let word = state.candidates[index].text
            let shown = upper ? word.prefix(1).uppercased() + word.dropFirst() : word.lowercased()
            onMenuAction?(.replaceDocumentWord(index: entry, text: shown))
        default:
            break
        }
    }

    @objc private func doubleTapGap(_ gesture: UITapGestureRecognizer) {
        let point = scroller.convert(gesture.location(in: self), from: self)
        let visible = slots.enumerated().filter { !$0.element.isHidden && $0.offset < state.candidates.count }
        guard visible.count >= 2 else { return }
        for pair in zip(visible, visible.dropFirst()) {
            let gap = pair.1.element.frame.minX - pair.0.element.frame.maxX
            let mid = pair.0.element.frame.maxX + gap / 2
            guard abs(point.x - mid) < max(18, gap) else { continue }
            if case let .openHistory(entry) = state.candidates[pair.0.offset].action {
                onMenuAction?(.merge(entry: entry))
            }
            return
        }
    }
}

extension SuggestionStrip: UIScrollViewDelegate {
    func scrollViewWillBeginDragging(_: UIScrollView) {
        userDidScroll = true
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
    private let underline = CAShapeLayer()

    var labelText: String? { label.text }
    var labelColor: UIColor? { label.textColor }

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
        underline.fillColor = nil
        underline.lineWidth = 1
        underline.lineDashPattern = [2, 2]
        underline.isHidden = true
        layer.addSublayer(underline)
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

    func configure(
        text: String,
        symbol: String?,
        isHighlighted emphasized: Bool,
        unsure: Bool,
        glows: Bool,
        letterThumbs: [Int],
        theme: Theme
    ) {
        label.font = Typography.rounded(size: 16, weight: emphasized ? .semibold : .regular)
        let ink = emphasized ? theme.accentKey.label.uiColor : theme.letterKey.label.uiColor
        if letterThumbs.count == text.count, text.count > 1 {
            let other = theme.secondaryLabel.uiColor
            let attributed = NSMutableAttributedString(string: text)
            for (index, character) in text.enumerated() {
                let thumb = letterThumbs.indices.contains(index) ? letterThumbs[index] : 0
                let color = thumb % 2 == 0 ? ink : other
                let range = NSRange(location: index, length: String(character).utf16.count)
                attributed.addAttribute(.foregroundColor, value: color, range: range)
            }
            label.attributedText = attributed
        } else {
            label.attributedText = nil
            label.text = text
            label.textColor = ink
        }
        icon.image = symbol.flatMap { UIImage(systemName: $0) }
        icon.tintColor = theme.secondaryLabel.uiColor
        icon.isHidden = symbol == nil
        underline.isHidden = !unsure
        underline.strokeColor = theme.secondaryLabel.uiColor.cgColor
        layer.shadowColor = theme.accentKey.fill.cgColor
        layer.shadowOpacity = glows ? 0.28 : 0
        layer.shadowRadius = glows ? 6 : 0
        layer.shadowOffset = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let iconWidth: CGFloat = icon.isHidden ? 0 : 16
        let textWidth = min(label.intrinsicContentSize.width, bounds.width - 12 - iconWidth)
        let start = (bounds.width - textWidth - iconWidth) / 2
        icon.frame = CGRect(x: start, y: 0, width: iconWidth, height: bounds.height)
        label.frame = CGRect(x: start + iconWidth, y: 0, width: textWidth, height: bounds.height)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: label.frame.minX, y: label.frame.maxY - 2))
        path.addLine(to: CGPoint(x: label.frame.maxX, y: label.frame.maxY - 2))
        underline.path = path.cgPath
        underline.frame = bounds
    }
}

/// One hold menu for the strip. A finger drags up through the rows and releases to choose.
private final class StripPopover: UIView {
    private var rows: [UILabel] = []
    private var highlighted: Int?

    func present(titles: [String], from frame: CGRect, in host: UIView, fades: Bool) {
        rows.forEach { $0.removeFromSuperview() }
        rows = titles.map { title in
            let label = UILabel()
            label.text = title
            label.font = Typography.rounded(size: 15, weight: .medium)
            label.textAlignment = .center
            label.textColor = .label
            return label
        }
        backgroundColor = UIColor.secondarySystemBackground
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true
        let width = max(frame.width, 120)
        let rowHeight: CGFloat = 36
        let height = rowHeight * CGFloat(rows.count)
        let canvas = host.window ?? host
        let anchor = host.convert(frame, to: canvas)
        self.frame = CGRect(x: anchor.midX - width / 2, y: anchor.minY - height - 6, width: width, height: height)
        for (index, row) in rows.enumerated() {
            row.frame = CGRect(x: 0, y: CGFloat(index) * rowHeight, width: width, height: rowHeight)
            addSubview(row)
        }
        canvas.addSubview(self)
        highlighted = nil
        if fades {
            alpha = 0
            UIView.animate(withDuration: Motion.stripFade) { self.alpha = 1 }
        } else {
            alpha = 0
            transform = CGAffineTransform(translationX: 0, y: 8)
            UIView.animate(withDuration: Motion.stripFade, delay: 0, options: [.curveEaseOut]) {
                self.alpha = 1
                self.transform = .identity
            }
        }
    }

    func highlight(at point: CGPoint) {
        let index = rows.firstIndex { $0.frame.contains(point) }
        guard index != highlighted else { return }
        highlighted = index
        for (rowIndex, row) in rows.enumerated() {
            row.backgroundColor = rowIndex == index ? UIColor.tertiarySystemFill : .clear
        }
    }

    func selectedIndex() -> Int? { highlighted }

    func dismiss() {
        let fades = StripMotion.fadesInsteadOfTraveling(reduceMotion: UIAccessibility.isReduceMotionEnabled)
        UIView.animate(withDuration: Motion.stripFade, animations: {
            self.alpha = 0
            if !fades { self.transform = CGAffineTransform(translationX: 0, y: 6) }
        }, completion: { _ in
            self.removeFromSuperview()
        })
    }
}
