import CoreGraphics

/// Shape and depth tokens for keys and callouts. Geometry (positions and hit areas) lives in
/// `LeanTypeCore.KeyboardMetrics`; this type only describes how a key looks.
public struct KeyStyle: Hashable, Sendable {
    public let cornerRadius: CGFloat
    public let calloutCornerRadius: CGFloat
    public let shadowOffset: CGSize
    public let shadowRadius: CGFloat
    public let rimWidth: CGFloat
    /// Scale applied while a function key is held; letters show a callout instead.
    public let pressedScale: CGFloat

    public init(
        cornerRadius: CGFloat,
        calloutCornerRadius: CGFloat,
        shadowOffset: CGSize,
        shadowRadius: CGFloat,
        rimWidth: CGFloat,
        pressedScale: CGFloat
    ) {
        self.cornerRadius = cornerRadius
        self.calloutCornerRadius = calloutCornerRadius
        self.shadowOffset = shadowOffset
        self.shadowRadius = shadowRadius
        self.rimWidth = rimWidth
        self.pressedScale = pressedScale
    }

    public static let pebble = KeyStyle(
        cornerRadius: 12,
        calloutCornerRadius: 16,
        shadowOffset: CGSize(width: 0, height: 1.5),
        shadowRadius: 1.5,
        rimWidth: 0.75,
        pressedScale: 0.95
    )

    public static let compactPebble = KeyStyle(
        cornerRadius: 10,
        calloutCornerRadius: 14,
        shadowOffset: CGSize(width: 0, height: 1),
        shadowRadius: 1,
        rimWidth: 0.75,
        pressedScale: 0.95
    )
}
