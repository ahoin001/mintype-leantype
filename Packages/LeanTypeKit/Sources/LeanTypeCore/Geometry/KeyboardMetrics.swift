import CoreGraphics

/// Spacing and sizing for the key area. These numbers drive both rendering and hit-testing, so
/// they live in Core rather than in the visual design module.
public struct KeyboardMetrics: Hashable, Sendable {
    public let keyHeight: CGFloat
    public let rowSpacing: CGFloat
    public let keySpacing: CGFloat
    public let sideInset: CGFloat
    public let topInset: CGFloat
    public let bottomInset: CGFloat
    /// Height of the dock strip above the keys. It holds status messages and gives callouts
    /// for the top row room to draw, since extensions can't draw outside their own bounds.
    public let dockHeight: CGFloat
    public let isCompact: Bool

    public init(
        keyHeight: CGFloat,
        rowSpacing: CGFloat,
        keySpacing: CGFloat,
        sideInset: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        dockHeight: CGFloat,
        isCompact: Bool
    ) {
        self.keyHeight = keyHeight
        self.rowSpacing = rowSpacing
        self.keySpacing = keySpacing
        self.sideInset = sideInset
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.dockHeight = dockHeight
        self.isCompact = isCompact
    }

    public static let portrait = KeyboardMetrics(
        keyHeight: 43,
        rowSpacing: 11,
        keySpacing: 6,
        sideInset: 3,
        topInset: 8,
        bottomInset: 4,
        dockHeight: 38,
        isCompact: false
    )

    public static let landscape = KeyboardMetrics(
        keyHeight: 33,
        rowSpacing: 6,
        keySpacing: 6,
        sideInset: 3,
        topInset: 6,
        bottomInset: 3,
        dockHeight: 30,
        isCompact: true
    )

    /// Height of the key area alone (excluding the dock).
    public func keyAreaHeight(rowCount: Int) -> CGFloat {
        let rows = CGFloat(rowCount)
        return topInset + bottomInset + rows * keyHeight + max(rows - 1, 0) * rowSpacing
    }

    /// Full keyboard height including the dock.
    public func totalHeight(rowCount: Int) -> CGFloat {
        dockHeight + keyAreaHeight(rowCount: rowCount)
    }
}
