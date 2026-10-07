import LeanTypeCore
import UIKit

/// Where effects draw: a transparent, touch-transparent overlay covering the whole keyboard
/// (dock included), plus a backdrop layer that sits behind the keys for ambient glows.
///
/// Effects speak in key-area coordinates (what Core events carry); the stage converts them.
@MainActor
final class EffectsStage: UIView {
    let pool: LayerPool
    /// Behind the keys, above the background gradient. The host view inserts it.
    let backdrop = CALayer()

    /// Where the key area's origin sits in the stage.
    private(set) var keyAreaFrame: CGRect = .zero
    private(set) var dockFrame: CGRect = .zero

    init(scale: CGFloat) {
        pool = LayerPool(scale: scale)
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        layer.masksToBounds = true
        backdrop.actions = LayerPool.noActions
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func updateRegions(keyArea: CGRect, dock: CGRect) {
        keyAreaFrame = keyArea
        dockFrame = dock
    }

    func point(fromKeyArea point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + keyAreaFrame.minX, y: point.y + keyAreaFrame.minY)
    }

    func rect(fromKeyArea rect: CGRect) -> CGRect {
        rect.offsetBy(dx: keyAreaFrame.minX, dy: keyAreaFrame.minY)
    }

    /// Adds a pooled layer to the stage.
    func present(_ layer: CALayer) {
        self.layer.addSublayer(layer)
    }
}
