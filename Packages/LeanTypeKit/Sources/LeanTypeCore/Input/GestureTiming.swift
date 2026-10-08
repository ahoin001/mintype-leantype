import Foundation

/// Durations shared by a gesture and the motion that pictures it.
/// The keyboard extension and the core have to agree, so the number lives once.
public enum GestureTiming {
    /// How long a finger rests before a hold row opens.
    public static let longPress: TimeInterval = 0.42
}
