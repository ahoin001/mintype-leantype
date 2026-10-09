import CoreGraphics

/// Which thumb tapped each letter, when no stroke was drawn.
/// Touches under 60 ms apart are different thumbs: one thumb cannot land twice that fast.
/// A slower pair stays with whichever side of the keyboard the key is on.
enum TapThumbs {
    static let differentThumbGap: Double = 0.06

    static func assign(times: [Double], points: [CGPoint], midline: CGFloat) -> [Int] {
        guard times.count == points.count else { return [] }
        var thumbs: [Int] = []
        thumbs.reserveCapacity(times.count)
        var previousTime: Double?
        var previousThumb = 0
        for (time, point) in zip(times, points) {
            let side = point.x < midline ? 0 : 1
            let thumb: Int
            if let previousTime, time - previousTime < differentThumbGap {
                thumb = previousThumb == 0 ? 1 : 0
            } else {
                thumb = side
            }
            thumbs.append(thumb)
            previousTime = time
            previousThumb = thumb
        }
        return thumbs
    }
}
