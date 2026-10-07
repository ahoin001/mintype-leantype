import UIKit

/// A fixed budget of reusable layers for effects.
///
/// Effects borrow a layer, animate it, and hand it back when the animation ends. When the
/// budget is spent, `shape()` and `text()` return `nil` and the effect simply skips that
/// flourish: a burst of fast typing can never pile up layers or memory.
@MainActor
final class LayerPool {
    static let shapeCapacity = 24
    static let textCapacity = 24

    private var freeShapes: [CAShapeLayer] = []
    private var freeTexts: [CATextLayer] = []
    private var shapesCreated = 0
    private var textsCreated = 0
    private let scale: CGFloat

    init(scale: CGFloat) {
        self.scale = scale
    }

    /// Creates a handful of layers up front so the first effects don't allocate mid-frame.
    func prewarm() {
        while shapesCreated < 8 { freeShapes.append(makeShape()) }
        while textsCreated < 8 { freeTexts.append(makeText()) }
    }

    func shape() -> CAShapeLayer? {
        if let layer = freeShapes.popLast() { return layer }
        guard shapesCreated < Self.shapeCapacity else { return nil }
        return makeShape()
    }

    func text() -> CATextLayer? {
        if let layer = freeTexts.popLast() { return layer }
        guard textsCreated < Self.textCapacity else { return nil }
        return makeText()
    }

    func recycle(_ layer: CALayer) {
        layer.removeAllAnimations()
        layer.removeFromSuperlayer()
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        layer.mask = nil
        if let shape = layer as? CAShapeLayer {
            shape.path = nil
            shape.lineWidth = 0
            shape.strokeColor = nil
            shape.shadowOpacity = 0
            shape.shadowRadius = 0
            shape.shadowPath = nil
            freeShapes.append(shape)
        } else if let text = layer as? CATextLayer {
            text.string = nil
            freeTexts.append(text)
        }
    }

    /// Releases idle layers (memory warning or effects turned off).
    func drain() {
        shapesCreated -= freeShapes.count
        textsCreated -= freeTexts.count
        freeShapes.removeAll()
        freeTexts.removeAll()
    }

    private func makeShape() -> CAShapeLayer {
        shapesCreated += 1
        let layer = CAShapeLayer()
        layer.contentsScale = scale
        layer.actions = Self.noActions
        return layer
    }

    private func makeText() -> CATextLayer {
        textsCreated += 1
        let layer = CATextLayer()
        layer.contentsScale = scale
        layer.alignmentMode = .center
        layer.actions = Self.noActions
        return layer
    }

    /// Effects animate explicitly; implicit animations on pooled layers would only add work.
    static let noActions: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "path": NSNull(), "opacity": NSNull(),
        "transform": NSNull(), "contents": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(),
        "foregroundColor": NSNull(), "string": NSNull(), "hidden": NSNull(),
    ]
}
