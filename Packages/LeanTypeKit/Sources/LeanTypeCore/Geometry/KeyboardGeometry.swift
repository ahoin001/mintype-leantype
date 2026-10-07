import CoreGraphics

/// A key placed on screen.
public struct KeyFrame: Hashable, Sendable {
    public let key: KeySpec
    /// The drawn key, inset by spacing.
    public let visualFrame: CGRect
    /// The touch target: the full cell including gaps, extended to the keyboard edges for edge
    /// keys so touches never land in a dead zone.
    public let hitFrame: CGRect
    public let row: Int

    public var id: KeyID { key.id }
}

/// Resolved frames for a layout at a specific size. Coordinates are relative to the key area
/// (the dock sits above it, at negative y).
public struct KeyboardGeometry: Hashable, Sendable {
    public let layout: KeyboardLayout
    public let size: CGSize
    public let metrics: KeyboardMetrics
    public let rows: [[KeyFrame]]
    private let rowBands: [ClosedRange<CGFloat>]
    private let framesByID: [KeyID: KeyFrame]

    public var keys: [KeyFrame] { rows.flatMap { $0 } }

    public init(layout: KeyboardLayout, size: CGSize, metrics: KeyboardMetrics) {
        self.layout = layout
        self.size = size
        self.metrics = metrics

        var rows: [[KeyFrame]] = []
        var bands: [ClosedRange<CGFloat>] = []
        let rowCount = layout.rows.count
        let usableWidth = max(size.width - 2 * metrics.sideInset, 0)

        for (rowIndex, row) in layout.rows.enumerated() {
            let rowTop = metrics.topInset + CGFloat(rowIndex) * (metrics.keyHeight + metrics.rowSpacing)
            let bandTop = rowIndex == 0 ? 0 : rowTop - metrics.rowSpacing / 2
            let bandBottom = rowIndex == rowCount - 1
                ? size.height
                : rowTop + metrics.keyHeight + metrics.rowSpacing / 2
            bands.append(bandTop...max(bandTop, bandBottom))

            let unitWidth = row.totalUnits > 0 ? usableWidth / row.totalUnits : 0
            var cursor = metrics.sideInset + row.insetUnits / 2 * unitWidth
            var frames: [KeyFrame] = []

            for (keyIndex, key) in row.keys.enumerated() {
                let cellWidth = key.widthUnits * unitWidth
                let cell = CGRect(x: cursor, y: rowTop, width: cellWidth, height: metrics.keyHeight)
                let visual = cell.insetBy(dx: metrics.keySpacing / 2, dy: 0)

                let hitMinX = keyIndex == 0 ? 0 : cell.minX
                let hitMaxX = keyIndex == row.keys.count - 1 ? size.width : cell.maxX
                let hit = CGRect(x: hitMinX, y: bandTop, width: hitMaxX - hitMinX, height: bandBottom - bandTop)

                frames.append(KeyFrame(key: key, visualFrame: visual, hitFrame: hit, row: rowIndex))
                cursor += cellWidth
            }
            rows.append(frames)
        }

        self.rows = rows
        rowBands = bands
        framesByID = Dictionary(rows.flatMap { $0 }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public static func == (lhs: KeyboardGeometry, rhs: KeyboardGeometry) -> Bool {
        lhs.layout == rhs.layout && lhs.size == rhs.size && lhs.metrics == rhs.metrics
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(layout)
        hasher.combine(size.width)
        hasher.combine(size.height)
        hasher.combine(metrics)
    }

    public func frame(for id: KeyID) -> KeyFrame? {
        framesByID[id]
    }

    /// The key a touch at `point` should hit. Points inside the keyboard always resolve to the
    /// nearest key; points that wander slightly outside (common mid-slide) still resolve within
    /// `tolerance`, beyond which the touch is considered off the keyboard.
    public func key(at point: CGPoint, tolerance: CGFloat = 24) -> KeyFrame? {
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -tolerance, dy: -tolerance)
        guard bounds.contains(point), !rows.isEmpty else { return nil }

        let rowIndex = rowIndex(forY: point.y)
        let row = rows[rowIndex]
        if let hit = row.first(where: { $0.hitFrame.minX <= point.x && point.x < $0.hitFrame.maxX }) {
            return hit
        }
        return row.min { abs($0.visualFrame.midX - point.x) < abs($1.visualFrame.midX - point.x) }
    }

    private func rowIndex(forY y: CGFloat) -> Int {
        if let index = rowBands.firstIndex(where: { $0.contains(y) }) {
            return index
        }
        return y < 0 ? 0 : rows.count - 1
    }
}
