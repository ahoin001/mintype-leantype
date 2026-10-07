import CoreGraphics

/// Where a callout's bubble and option cells sit relative to its key.
public struct CalloutLayout: Hashable, Sendable {
    /// The rounded bubble above the key. The renderer joins it to `anchorFrame` with a neck.
    public let bubbleFrame: CGRect
    /// The key the callout grows out of.
    public let anchorFrame: CGRect
    /// One cell per option, left to right, inside the bubble.
    public let optionFrames: [CGRect]

    /// The option under a finger at horizontal position `x`, clamped to the ends so sliding
    /// past the last option keeps it selected.
    public func optionIndex(atX x: CGFloat) -> Int {
        if let index = optionFrames.firstIndex(where: { $0.minX <= x && x < $0.maxX }) {
            return index
        }
        return optionFrames.indices.min {
            abs(optionFrames[$0].midX - x) < abs(optionFrames[$1].midX - x)
        } ?? 0
    }
}

public enum CalloutGeometry {
    static let neckGap: CGFloat = 2
    static let previewWidening: CGFloat = 22
    static let bubblePadding: CGFloat = 6

    /// Width of each hold option. A single character stays one key wide. Longer text grows
    /// with its length, up to about four keys, then the whole row scales to fit `available`
    /// (the widest the bubble may be, including its padding).
    public static func cellWidths(for options: [String], keyWidth: CGFloat, available: CGFloat) -> [CGFloat] {
        let preferred = options.map { preferredWidth(for: $0, keyWidth: keyWidth) }
        let padding: CGFloat = options.count > 1 ? 2 * bubblePadding : 0
        let contentLimit = max(available - padding, keyWidth)
        let sum = preferred.reduce(0, +)
        guard sum > contentLimit, sum > 0 else { return preferred }
        let scale = contentLimit / sum
        return preferred.map { $0 * scale }
    }

    /// Lays out a callout for `anchor` (a key's visual frame) with `optionCount` cells, kept
    /// horizontally inside `bounds` and allowed to rise into the dock (negative y).
    ///
    /// `cellWidths`, when it has one entry per option, sizes the cells. Index 0 stays the cell
    /// nearest the key.
    public static func layout(
        anchor: CGRect,
        optionCount: Int,
        metrics: KeyboardMetrics,
        bounds: CGRect,
        cellWidths: [CGFloat]? = nil
    ) -> CalloutLayout {
        let count = max(optionCount, 1)
        let bubbleHeight = metrics.keyHeight
        let bubbleY = max(anchor.minY - neckGap - bubbleHeight, bounds.minY)

        let widths: [CGFloat]
        let bubbleWidth: CGFloat
        if count == 1 {
            let grown = cellWidths.flatMap { $0.count == 1 ? $0[0] : nil } ?? 0
            bubbleWidth = max(anchor.width + previewWidening, grown)
            widths = [bubbleWidth]
        } else if let cellWidths, cellWidths.count == count {
            widths = cellWidths
            bubbleWidth = widths.reduce(0, +) + 2 * bubblePadding
        } else {
            widths = Array(repeating: anchor.width, count: count)
            bubbleWidth = CGFloat(count) * anchor.width + 2 * bubblePadding
        }

        let centeredX = anchor.midX - bubbleWidth / 2
        let minX = bounds.minX + metrics.sideInset
        let maxX = bounds.maxX - metrics.sideInset - bubbleWidth
        let bubbleX: CGFloat = if count == 1 {
            min(max(centeredX, minX), maxX)
        } else if anchor.midX < bounds.midX {
            // Multi-option rows start over the key and grow toward the keyboard's center.
            min(max(anchor.minX - bubblePadding, minX), maxX)
        } else {
            min(max(anchor.maxX + bubblePadding - bubbleWidth, minX), maxX)
        }

        let bubble = CGRect(x: bubbleX, y: bubbleY, width: bubbleWidth, height: bubbleHeight)
        let inset: CGFloat = count == 1 ? 0 : bubblePadding
        // Index 0 is the cell nearest the key: the left end on the left half, the right end
        // on the right half.
        var options: [CGRect] = []
        options.reserveCapacity(count)
        if count > 1, anchor.midX >= bounds.midX {
            var x = bubble.maxX - inset
            for width in widths {
                x -= width
                options.append(CGRect(x: x, y: bubble.minY, width: width, height: bubbleHeight))
            }
        } else {
            var x = bubble.minX + inset
            for width in widths {
                options.append(CGRect(x: x, y: bubble.minY, width: width, height: bubbleHeight))
                x += width
            }
        }
        return CalloutLayout(bubbleFrame: bubble, anchorFrame: anchor, optionFrames: options)
    }

    private static func preferredWidth(for option: String, keyWidth: CGFloat) -> CGFloat {
        let count = option.count
        guard count > 1 else { return keyWidth }
        let grown = keyWidth * (1 + 0.55 * CGFloat(count - 1))
        return min(max(grown, keyWidth), keyWidth * 4)
    }
}
