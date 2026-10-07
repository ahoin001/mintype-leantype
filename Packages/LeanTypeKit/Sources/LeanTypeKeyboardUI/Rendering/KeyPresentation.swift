import LeanTypeCore
import LeanTypeDesign

/// What a key shows, independent of where it is.
enum KeyLabel: Hashable {
    case text(String, Typography.KeyRole)
    case symbol(String)
}

/// Which color family a key uses.
enum KeyFamily: Hashable {
    case letter
    case function
    case accent
}

struct KeyPresentation: Hashable {
    let label: KeyLabel
    let family: KeyFamily
    let isEnabled: Bool
    let accessibilityLabel: String
    /// The flick-down character, drawn small in the key's corner.
    var hint: String?
}

/// Maps a key and the current keyboard state to its label, color family, and spoken name.
enum KeyPresentationProvider {
    static func presentation(for key: KeySpec, state: KeyboardViewState, showsHints: Bool = false) -> KeyPresentation {
        switch key.kind {
        case let .character(character):
            let shown = state.shift == .off ? character : uppercased(character)
            let role: Typography.KeyRole = character.first?.isLetter == true ? .letter : .symbol
            let hint = showsHints ? key.secondary : nil
            let spoken = key.secondary.map { "\(shown), flick down for \($0)" } ?? shown
            return KeyPresentation(
                label: .text(shown, role),
                family: .letter,
                isEnabled: true,
                accessibilityLabel: showsHints ? spoken : shown,
                hint: hint
            )

        case .shift:
            return switch state.shift {
            case .off:
                KeyPresentation(label: .symbol("shift"), family: .function, isEnabled: true, accessibilityLabel: "shift")
            case .once:
                KeyPresentation(label: .symbol("shift.fill"), family: .letter, isEnabled: true, accessibilityLabel: "shift")
            case .locked:
                KeyPresentation(
                    label: .symbol("capslock.fill"),
                    family: .accent,
                    isEnabled: true,
                    accessibilityLabel: "caps lock"
                )
            }

        case .backspace:
            return KeyPresentation(label: .symbol("delete.left"), family: .function, isEnabled: true, accessibilityLabel: "delete")

        case .space:
            return KeyPresentation(label: .text("space", .function), family: .letter, isEnabled: true, accessibilityLabel: "space")

        case .returnKey:
            let title = state.returnKey.title
            let family: KeyFamily = state.returnKey.isProminent && state.isReturnKeyEnabled ? .accent : .function
            return KeyPresentation(
                label: .text(title, .function),
                family: family,
                isEnabled: state.isReturnKeyEnabled,
                accessibilityLabel: title
            )

        case let .layerSwitch(target):
            let (title, spoken) = switch target {
            case .letters: ("ABC", "letters")
            case .numbers: ("123", "numbers")
            case .symbols: ("#+=", "symbols")
            }
            return KeyPresentation(label: .text(title, .function), family: .function, isEnabled: true, accessibilityLabel: spoken)

        case .nextKeyboard:
            return KeyPresentation(label: .symbol("globe"), family: .function, isEnabled: true, accessibilityLabel: "next keyboard")
        }
    }

    private static func uppercased(_ character: String) -> String {
        let upper = character.uppercased()
        return upper.count == character.count ? upper : character
    }
}

extension Theme {
    func colors(for family: KeyFamily) -> Theme.KeyColors {
        switch family {
        case .letter: letterKey
        case .function: functionKey
        case .accent: accentKey
        }
    }
}
