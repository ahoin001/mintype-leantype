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
    public let placement: KeyboardPlacement
    public let rows: [[KeyFrame]]
    private let rowBands: [ClosedRange<CGFloat>]
    private let framesByID: [KeyID: KeyFrame]

    public var keys: [KeyFrame] { rows.flatMap { $0 } }

    public init(layout: KeyboardLayout, size: CGSize, metrics: KeyboardMetrics) {
        self.layout = layout
        self.size = size
        self.metrics = metrics
        placement = .docked

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
        lhs.layout == rhs.layout && lhs.size == rhs.size && lhs.metrics == rhs.metrics && lhs.placement == rhs.placement
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(layout)
        hasher.combine(size.width)
        hasher.combine(size.height)
        hasher.combine(metrics)
        hasher.combine(placement)
    }

    /// Frames for a floating keyboard, or two clusters with a center gap. Docked is unchanged.
    /// The thumb split follows Q and P after they move, so it stays the middle of the keys.
    public func applying(_ placement: KeyboardPlacement) -> KeyboardGeometry {
        guard placement != .docked else { return self }
        let mapped = rows.map { row in row.map { placed($0, as: placement) } }
        return KeyboardGeometry(
            layout: layout,
            size: size,
            metrics: metrics,
            rows: mapped,
            placement: placement
        )
    }

    private init(
        layout: KeyboardLayout,
        size: CGSize,
        metrics: KeyboardMetrics,
        rows: [[KeyFrame]],
        placement: KeyboardPlacement
    ) {
        self.layout = layout
        self.size = size
        self.metrics = metrics
        self.placement = placement
        self.rows = rows
        var bands: [ClosedRange<CGFloat>] = []
        for row in rows {
            let top = row.map(\.hitFrame.minY).min() ?? 0
            let bottom = row.map(\.hitFrame.maxY).max() ?? top
            bands.append(top...max(top, bottom))
        }
        rowBands = bands
        framesByID = Dictionary(rows.flatMap { $0 }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func placed(_ frame: KeyFrame, as placement: KeyboardPlacement) -> KeyFrame {
        let width = size.width
        switch placement {
        case .docked:
            return frame
        case .floating:
            let inset = width * 0.11
            return shifted(frame, from: 0...width, to: inset...(width - inset))
        case .split:
            let gap: CGFloat = 28
            let mid = width / 2
            if frame.visualFrame.midX < mid {
                return shifted(frame, from: 0...mid, to: 0...(mid - gap / 2))
            }
            return shifted(frame, from: mid...width, to: (mid + gap / 2)...width)
        }
    }

    private func shifted(_ frame: KeyFrame, from: ClosedRange<CGFloat>, to: ClosedRange<CGFloat>) -> KeyFrame {
        func map(_ x: CGFloat) -> CGFloat {
            let span = from.upperBound - from.lowerBound
            guard span > 0 else { return to.lowerBound }
            let clamped = min(max(x, from.lowerBound), from.upperBound)
            let t = (clamped - from.lowerBound) / span
            return to.lowerBound + t * (to.upperBound - to.lowerBound)
        }
        return KeyFrame(
            key: frame.key,
            visualFrame: remapX(frame.visualFrame, map),
            hitFrame: remapX(frame.hitFrame, map),
            row: frame.row
        )
    }

    private func remapX(_ rect: CGRect, _ map: (CGFloat) -> CGFloat) -> CGRect {
        let minX = map(rect.minX)
        let maxX = map(rect.maxX)
        return CGRect(x: minX, y: rect.minY, width: max(maxX - minX, 0), height: rect.height)
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
        // Floating margins and the split gap are not keys.
        if placement != .docked { return nil }
        return row.min { abs($0.visualFrame.midX - point.x) < abs($1.visualFrame.midX - point.x) }
    }

    private func rowIndex(forY y: CGFloat) -> Int {
        if let index = rowBands.firstIndex(where: { $0.contains(y) }) {
            return index
        }
        return y < 0 ? 0 : rows.count - 1
    }
}
