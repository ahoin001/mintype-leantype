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

    /// Lays out a callout for `anchor` (a key's visual frame) with `optionCount` cells, kept
    /// horizontally inside `bounds` and allowed to rise into the dock (negative y).
    public static func layout(
        anchor: CGRect,
        optionCount: Int,
        metrics: KeyboardMetrics,
        bounds: CGRect
    ) -> CalloutLayout {
        let count = max(optionCount, 1)
        let bubbleHeight = metrics.keyHeight
        let bubbleY = max(anchor.minY - neckGap - bubbleHeight, bounds.minY)

        let cellWidth: CGFloat
        let bubbleWidth: CGFloat
        if count == 1 {
            bubbleWidth = anchor.width + previewWidening
            cellWidth = bubbleWidth
        } else {
            cellWidth = anchor.width
            bubbleWidth = CGFloat(count) * cellWidth + 2 * bubblePadding
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
        var options = (0..<count).map { index in
            CGRect(
                x: bubble.minX + inset + CGFloat(index) * cellWidth,
                y: bubble.minY,
                width: cellWidth,
                height: bubbleHeight
            )
        }
        // Order so index 0 is always the cell nearest the key.
        if count > 1, anchor.midX >= bounds.midX {
            options.reverse()
        }
        return CalloutLayout(bubbleFrame: bubble, anchorFrame: anchor, optionFrames: options)
    }
}
