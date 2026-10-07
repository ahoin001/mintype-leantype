import os

/// Instruments intervals for the input hot path. Signposts compile to near-nothing when no
/// tool is recording, so they stay on in release builds.
public enum Signposts {
    public static let input = OSSignposter(subsystem: "com.leantype.keyboard", category: .pointsOfInterest)
    public static let layout = OSSignposter(subsystem: "com.leantype.keyboard", category: "Layout")
    /// Swipe decoding, from the last finger lifting to candidates.
    public static let swipe = OSSignposter(subsystem: "com.leantype.keyboard", category: "Swipe")
    /// Setting up effect animations and trail frames on the main thread.
    public static let effects = OSSignposter(subsystem: "com.leantype.keyboard", category: "Effects")
}
