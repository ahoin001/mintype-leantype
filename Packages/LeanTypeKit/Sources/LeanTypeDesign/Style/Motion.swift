import CoreGraphics
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
    /// A digit or hold row growing out of its key. Letter previews do not use this.
    public static let calloutPresent: TimeInterval = 0.16
    /// Entering or leaving space-bar trackpad mode, switching layers, status pill changes.
    public static let modeChange: TimeInterval = 0.2
    /// A pill moving to another slot. The leading edge arrives inside this budget.
    public static let pillTravel: TimeInterval = 0.12
    /// A pill landing on a committed word, or squeezing through a correction.
    public static let pillSettle: TimeInterval = 0.16
    /// How long a shape leads before its label appears.
    public static let contentDelay: TimeInterval = 0.12
    /// Delay between rows when a new layer's labels arrive.
    public static let rowStagger: TimeInterval = 0.02
    /// Labels of a new layer start at this scale. The keys themselves do not.
    public static let rowArrivalScale: CGFloat = 0.96
    /// How long one row's labels take to settle after a layer change.
    public static let rowArrival: TimeInterval = 0.16
    /// One pop when backspace steps up a gear.
    public static let gearPop: TimeInterval = 0.32
    /// A copy of the return glyph lifting off its key.
    public static let returnLift: TimeInterval = 0.18
    /// How far that copy travels, in points.
    public static let returnLiftDistance: CGFloat = 22
}
