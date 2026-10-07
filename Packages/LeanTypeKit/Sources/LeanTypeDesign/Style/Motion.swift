import Foundation

/// Motion tokens. Keyboard input happens hundreds of times a day, so key presses never animate
/// in; only releases and rare mode changes do.
///
/// This module is UIKit-only so the keyboard extension never loads SwiftUI; the companion
/// app's springs live alongside its SwiftUI bridges.
public enum Motion {
    /// Release fade for a key returning to rest after a press.
    public static let keyRelease: TimeInterval = 0.1
    /// Callout fade-out after a key is committed.
    public static let calloutDismiss: TimeInterval = 0.08
    /// Entering or leaving space-bar trackpad mode, switching layers, status pill changes.
    public static let modeChange: TimeInterval = 0.2
}
