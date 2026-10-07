import LeanTypeCore
import LeanTypeDesign
import UIKit

/// The strip beside a one-handed keyboard: move the keys to the other side, or go back to
/// full width.
final class OneHandedPanel: UIView {
    var onSwitchSide: (() -> Void)?
    var onExpand: (() -> Void)?

    private let switchButton = UIButton(type: .system)
    private let expandButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        let configuration = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        expandButton.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: configuration), for: .normal)
        expandButton.accessibilityLabel = "Full-width keyboard"
        switchButton.accessibilityLabel = "Move keyboard to the other side"
        switchButton.addAction(UIAction { [weak self] _ in self?.onSwitchSide?() }, for: .touchUpInside)
        expandButton.addAction(UIAction { [weak self] _ in self?.onExpand?() }, for: .touchUpInside)
        addSubview(expandButton)
        addSubview(switchButton)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: Theme) {
        switchButton.tintColor = theme.secondaryLabel.uiColor
        expandButton.tintColor = theme.secondaryLabel.uiColor
    }

    /// Points the switch arrow toward the side the keys would move to.
    func configure(for mode: OneHandedMode) {
        let symbol = mode == .left ? "chevron.right.2" : "chevron.left.2"
        switchButton.setImage(
            UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)),
            for: .normal
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = min(bounds.width, 48)
        let x = (bounds.width - size) / 2
        expandButton.frame = CGRect(x: x, y: bounds.midY - size - 6, width: size, height: size)
        switchButton.frame = CGRect(x: x, y: bounds.midY + 6, width: size, height: size)
    }
}
