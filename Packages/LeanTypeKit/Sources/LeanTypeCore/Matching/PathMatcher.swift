import Foundation

/// Turns a swipe timeline into ranked words. The session asks for a match; it does not
/// know which decoder runs.
@MainActor
protocol PathMatcher: AnyObject {
    func match(_ gesture: SwipeGesture) async -> DecodeResult
}

/// The production matcher: the existing alignment search, called from one place.
@MainActor
final class AlignmentPathMatcher: PathMatcher {
    private let decode: @MainActor (SwipeGesture) async -> DecodeResult

    init(_ decode: @escaping @MainActor (SwipeGesture) async -> DecodeResult) {
        self.decode = decode
    }

    func match(_ gesture: SwipeGesture) async -> DecodeResult {
        await decode(gesture)
    }
}
