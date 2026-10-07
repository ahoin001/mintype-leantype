import UIKit

/// The extension's root input view. Adopting `UIInputViewAudioFeedback` is what allows
/// `UIDevice.playInputClick()` to play the system key click (when the user has clicks on).
public final class KeyboardInputView: UIInputView, UIInputViewAudioFeedback {
    public var enableInputClicksWhenVisible: Bool { true }
}
