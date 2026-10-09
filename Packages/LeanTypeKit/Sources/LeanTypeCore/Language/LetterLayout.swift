import CoreGraphics

/// Where each letter key sits, in key-area coordinates. The spatial model shared by tap
/// autocorrect and swipe decoding.
public struct LetterLayout: Hashable, Sendable {
    /// Centers indexed by `LexiconKey.index(of:)`.
    public let centers: [CGPoint]
    public let keyWidth: CGFloat
    public let keyHeight: CGFloat

    /// The split between the two thumbs: halfway from Q to P.
    public var handMidline: CGFloat {
        let left = center(of: UInt8(ascii: "q")).x
        let right = center(of: UInt8(ascii: "p")).x
        return (left + right) / 2
    }

    /// Builds the layout from a letters-layer geometry; `nil` if any letter key is missing.
    public init?(geometry: KeyboardGeometry) {
        var centers = [CGPoint?](repeating: nil, count: LexiconKey.letterCount)
        for frame in geometry.keys {
            guard let character = frame.key.kind.character, character.count == 1,
                  let byte = character.utf8.first, (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            else { continue }
            centers[LexiconKey.index(of: byte)] = CGPoint(x: frame.visualFrame.midX, y: frame.visualFrame.midY)
        }
        let resolved = centers.compactMap { $0 }
        guard resolved.count == LexiconKey.letterCount else { return nil }
        // The pitch between neighbors, not a hit frame: edge keys' hit areas stretch to the
        // screen edge and would make every distance look shorter than it is.
        let pitch = resolved[LexiconKey.index(of: UInt8(ascii: "w"))].x - resolved[LexiconKey.index(of: UInt8(ascii: "q"))].x
        guard pitch > 0 else { return nil }
        self.centers = resolved
        keyWidth = pitch
        keyHeight = geometry.metrics.keyHeight + geometry.metrics.rowSpacing
    }

    @inline(__always)
    public func center(of letter: UInt8) -> CGPoint {
        centers[LexiconKey.index(of: letter)]
    }

    /// Letters whose keys are within `radius` key widths of `point`, nearest first.
    public func letters(near point: CGPoint, within radius: CGFloat, limit: Int) -> [UInt8] {
        var found: [(letter: UInt8, distance: CGFloat)] = []
        for (index, center) in centers.enumerated() {
            let distance = normalizedDistance(point, center)
            if distance <= radius {
                found.append((LexiconKey.firstLetter + UInt8(index), distance))
            }
        }
        found.sort { $0.distance < $1.distance }
        return found.prefix(limit).map(\.letter)
    }

    /// Distance in key widths, with vertical travel scaled so a row counts as one key.
    @inline(__always)
    public func normalizedDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = (a.x - b.x) / keyWidth
        let dy = (a.y - b.y) / keyHeight
        return (dx * dx + dy * dy).squareRoot()
    }
}
