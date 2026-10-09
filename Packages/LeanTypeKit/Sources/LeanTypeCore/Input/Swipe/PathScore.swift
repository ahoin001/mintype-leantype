import CoreGraphics

/// Shape, location, and endpoint match of one polyline against a word's key centers.
///
/// Scratch buffers are reused. `PathDecoder` uses the length gate. The alignment decoder
/// turns the same mismatch into a cost, including when several strokes add up to the word.
struct PathScore: Sendable {
    static let sampleCount = 32
    static let locationSigma: CGFloat = 0.42
    static let shapeSigma: CGFloat = 0.3
    static let endpointSigma: CGFloat = 0.55
    static let locationCutoff: CGFloat = 1.6

    /// How far a sample may slide along the curve and still match. Wide enough for a small
    /// corner cut, narrow enough that a longer word cannot hide inside a short stroke.
    static let warpRadius = 2

    private var gesturePoints: [CGPoint]
    private var gestureShape: [CGPoint]
    private var idealPath: [CGPoint]
    private var idealPoints: [CGPoint]
    private var idealShape: [CGPoint]
    private var warpPrevious: [CGFloat]
    private var warpCurrent: [CGFloat]
    private(set) var gestureLength: CGFloat = 0

    init() {
        gesturePoints = Array(repeating: .zero, count: Self.sampleCount)
        gestureShape = Array(repeating: .zero, count: Self.sampleCount)
        idealPath = []
        idealPath.reserveCapacity(32)
        idealPoints = Array(repeating: .zero, count: Self.sampleCount)
        idealShape = Array(repeating: .zero, count: Self.sampleCount)
        warpPrevious = Array(repeating: 0, count: Self.sampleCount)
        warpCurrent = Array(repeating: 0, count: Self.sampleCount)
    }

    /// Resamples `path` once. Returns false when there is nothing to score.
    @discardableResult
    mutating func prepare(_ path: [CGPoint], layout: LetterLayout) -> Bool {
        guard path.count >= 2 else { return false }
        path.withUnsafeBufferPointer { source in
            gesturePoints.withUnsafeMutableBufferPointer { StrokeAnalyzer.resample(source, into: $0) }
        }
        normalize(gesturePoints, into: &gestureShape, layout: layout)
        gestureLength = StrokeAnalyzer.length(of: path) / layout.keyWidth
        return true
    }

    var start: CGPoint { gesturePoints[0] }
    var end: CGPoint { gesturePoints[Self.sampleCount - 1] }

    /// Log-likelihood of the prepared gesture given `key`. `location` is reported even when
    /// the path is too far to score. `gateLength` rejects a single stroke whose length is
    /// nowhere near the word. The alignment decoder passes false and applies `lengthCost`.
    /// `warp` lets a sample slide a short way along the curve, for the lead comparison only.
    mutating func measure(
        _ key: UnsafeRawBufferPointer,
        mustExceed floor: Double,
        gateLength: Bool,
        layout: LetterLayout,
        warp: Bool = false
    ) -> (score: Double?, location: CGFloat?) {
        guard key.count >= 2 else { return (nil, nil) }

        let startMiss = layout.normalizedDistance(gesturePoints[0], layout.center(of: key[0]))
        let endMiss = layout.normalizedDistance(gesturePoints[Self.sampleCount - 1], layout.center(of: key[key.count - 1]))
        let endpointTerm = Double((startMiss * startMiss + endMiss * endMiss) / (2 * Self.endpointSigma * Self.endpointSigma))
        guard -endpointTerm > floor else { return (nil, nil) }

        idealPath.removeAll(keepingCapacity: true)
        for letter in key {
            let center = layout.center(of: letter)
            if idealPath.last != center {
                idealPath.append(center)
            }
        }
        guard idealPath.count >= 2 else { return (nil, nil) }

        if gateLength {
            let ideal = StrokeAnalyzer.length(of: idealPath) / layout.keyWidth
            let ratio = (gestureLength + 0.5) / (ideal + 0.5)
            guard ratio > 0.45, ratio < 2.2 else { return (nil, nil) }
        }

        idealPath.withUnsafeBufferPointer { source in
            idealPoints.withUnsafeMutableBufferPointer { StrokeAnalyzer.resample(source, into: $0) }
        }

        var paired: CGFloat = 0
        for index in 0..<Self.sampleCount {
            paired += layout.normalizedDistance(gesturePoints[index], idealPoints[index])
        }
        paired /= CGFloat(Self.sampleCount)
        let location = warp ? min(paired, warpedLocation(layout: layout)) : paired
        guard location < Self.locationCutoff else { return (nil, location) }
        let locationTerm = Double(location * location / (2 * Self.locationSigma * Self.locationSigma))
        guard -(endpointTerm + locationTerm) > floor else { return (nil, location) }

        normalize(idealPoints, into: &idealShape, layout: layout)
        var shape: CGFloat = 0
        for index in 0..<Self.sampleCount {
            let dx = gestureShape[index].x - idealShape[index].x
            let dy = gestureShape[index].y - idealShape[index].y
            shape += (dx * dx + dy * dy).squareRoot()
        }
        shape /= CGFloat(Self.sampleCount)

        let shapeTerm = Double(shape * shape / (2 * Self.shapeSigma * Self.shapeSigma))
        return (-(endpointTerm + locationTerm + shapeTerm), location)
    }

    mutating func measure(
        _ key: [UInt8],
        mustExceed floor: Double,
        gateLength: Bool,
        layout: LetterLayout,
        warp: Bool = false
    ) -> (score: Double?, location: CGFloat?) {
        key.withUnsafeBytes { measure($0, mustExceed: floor, gateLength: gateLength, layout: layout, warp: warp) }
    }

    /// How far the drawn length sits outside the band a single stroke used to hard-reject.
    /// Zero inside the band. The alignment decoder adds this instead of dropping the word.
    static func lengthCost(gestureLength: CGFloat, key: [UInt8], layout: LetterLayout, weight: Double) -> Double {
        guard key.count >= 2, weight > 0 else { return 0 }
        var ideal: CGFloat = 0
        var previous: CGPoint?
        for letter in key {
            let center = layout.center(of: letter)
            if let previous, previous != center {
                ideal += hypot(center.x - previous.x, center.y - previous.y)
            }
            previous = center
        }
        ideal /= layout.keyWidth
        let ratio = (gestureLength + 0.5) / (ideal + 0.5)
        let outside = max(0, 0.45 - ratio) + max(0, ratio - 2.2)
        guard outside > 0 else { return 0 }
        return weight * Double(outside * outside)
    }

    /// Mean distance along a monotonic alignment. Samples may drift by `warpRadius`, so a
    /// finger that cuts a corner is not charged at every later point.
    private mutating func warpedLocation(layout: LetterLayout) -> CGFloat {
        let count = Self.sampleCount
        let huge = CGFloat.greatestFiniteMagnitude / 4
        for index in 0..<count { warpPrevious[index] = huge }
        warpPrevious[0] = layout.normalizedDistance(gesturePoints[0], idealPoints[0])
        guard count > 1 else { return warpPrevious[0] }
        for row in 1..<count {
            for index in 0..<count { warpCurrent[index] = huge }
            let lower = max(0, row - Self.warpRadius)
            let upper = min(count - 1, row + Self.warpRadius)
            var rowBest = huge
            for column in lower...upper {
                let step = layout.normalizedDistance(gesturePoints[row], idealPoints[column])
                var best = warpPrevious[column]
                if column > 0 {
                    best = min(best, warpPrevious[column - 1])
                    best = min(best, warpCurrent[column - 1])
                }
                let cost = best + step
                warpCurrent[column] = cost
                rowBest = min(rowBest, cost)
            }
            if rowBest / CGFloat(count) >= Self.locationCutoff { return Self.locationCutoff }
            swap(&warpPrevious, &warpCurrent)
        }
        return warpPrevious[count - 1] / CGFloat(count)
    }

    private func normalize(_ points: [CGPoint], into output: inout [CGPoint], layout: LetterLayout) {
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        var sumX: CGFloat = 0, sumY: CGFloat = 0
        for point in points {
            let x = point.x / layout.keyWidth
            let y = point.y / layout.keyHeight
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            sumX += x; sumY += y
        }
        let count = CGFloat(points.count)
        let scale = max(maxX - minX, maxY - minY, 1)
        let centerX = sumX / count
        let centerY = sumY / count
        for (index, point) in points.enumerated() {
            output[index] = CGPoint(
                x: (point.x / layout.keyWidth - centerX) / scale,
                y: (point.y / layout.keyHeight - centerY) / scale
            )
        }
    }
}
