import CoreGraphics

/// Where the key area sits. The session is the same in every placement; only frames
/// and the thumb split move.
public enum KeyboardPlacement: String, Codable, Sendable, CaseIterable {
    case docked
    case floating
    case split
}
