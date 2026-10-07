import CoreGraphics

/// One step of a gesture demo: where each finger is, whether it's touching, and how long it
/// takes to get there. `step` keeps otherwise-identical poses distinct for the phase animator.
struct FingerPose: Hashable {
    struct Finger: Hashable {
        var x: CGFloat
        var y: CGFloat = 0
        var isDown: Bool
    }

    let step: Int
    /// Every pose in a tip has the same number of fingers, so each one animates smoothly.
    let fingers: [Finger]
    let duration: Double

    var isDown: Bool { fingers.contains(where: \.isDown) }
}

/// A gesture worth teaching, with a tiny looping demo.
struct GestureTip: Identifiable {
    let id: String
    let title: String
    let detail: String
    let keyLabel: String
    let keySymbol: String?
    let keyWidth: CGFloat
    /// A small corner label on the keycap, like the digit a flick types.
    var keyHint: String?
    let poses: [FingerPose]

    /// A one-finger demo moving only sideways.
    static func poses(_ moves: [(x: CGFloat, isDown: Bool, duration: Double)]) -> [FingerPose] {
        moves.enumerated().map { step, move in
            FingerPose(step: step, fingers: [.init(x: move.x, isDown: move.isDown)], duration: move.duration)
        }
    }

    /// A demo with any number of fingers moving freely.
    static func poses(fingers moves: [(fingers: [FingerPose.Finger], duration: Double)]) -> [FingerPose] {
        moves.enumerated().map { step, move in
            FingerPose(step: step, fingers: move.fingers, duration: move.duration)
        }
    }

    static let all: [GestureTip] = [
        GestureTip(
            id: "swipe",
            title: "Swipe a word",
            detail: "Slide one finger through the letters of a word and lift. A trail follows you, and the word lands with a space.",
            keyLabel: "h  e  l  l  o",
            keySymbol: nil,
            keyWidth: 220,
            poses: poses(fingers: [
                ([.init(x: -80, y: 0, isDown: false)], 0.4),
                ([.init(x: -80, y: 0, isDown: true)], 0.12),
                ([.init(x: -30, y: -10, isDown: true)], 0.25),
                ([.init(x: 25, y: 8, isDown: true)], 0.3),
                ([.init(x: 80, y: -6, isDown: true)], 0.25),
                ([.init(x: 80, y: -6, isDown: false)], 0.3),
            ])
        ),
        GestureTip(
            id: "twoThumbs",
            title: "Two thumbs, one word",
            detail: "Slide with both thumbs at once, Nintype style. Letters join in the order you reach them; the word ends when both lift.",
            keyLabel: "t  h  e",
            keySymbol: nil,
            keyWidth: 220,
            poses: poses(fingers: [
                ([.init(x: -70, isDown: false), .init(x: 60, isDown: false)], 0.4),
                ([.init(x: -70, isDown: true), .init(x: 60, isDown: false)], 0.12),
                ([.init(x: -10, isDown: true), .init(x: 60, isDown: false)], 0.35),
                ([.init(x: -10, isDown: true), .init(x: 60, isDown: true)], 0.12),
                ([.init(x: -10, isDown: false), .init(x: 60, isDown: false)], 0.4),
            ])
        ),
        GestureTip(
            id: "flick",
            title: "Flick for numbers",
            detail: "Flick down on a letter to type the little character in its corner: digits on the top row, symbols below.",
            keyLabel: "q",
            keySymbol: nil,
            keyWidth: 52,
            keyHint: "1",
            poses: poses(fingers: [
                ([.init(x: 0, y: -6, isDown: false)], 0.4),
                ([.init(x: 0, y: -6, isDown: true)], 0.1),
                ([.init(x: 0, y: 22, isDown: true)], 0.14),
                ([.init(x: 0, y: 22, isDown: false)], 0.5),
            ])
        ),
        GestureTip(
            id: "trackpad",
            title: "Glide the cursor",
            detail: "Slide along the space bar to move the cursor. Fling it to jump word by word, or hold at the edge to keep going.",
            keyLabel: "space",
            keySymbol: nil,
            keyWidth: 180,
            poses: poses([(0, false, 0.4), (0, true, 0.15), (-60, true, 0.7), (50, true, 0.9), (50, false, 0.2)])
        ),
        GestureTip(
            id: "wordJump",
            title: "Jump by word",
            detail: "Rest a second finger on the space bar while gliding and every step jumps a whole word.",
            keyLabel: "space",
            keySymbol: nil,
            keyWidth: 180,
            poses: poses(fingers: [
                ([.init(x: -40, isDown: false), .init(x: 40, isDown: false)], 0.4),
                ([.init(x: -40, isDown: true), .init(x: 40, isDown: false)], 0.12),
                ([.init(x: -40, isDown: true), .init(x: 40, isDown: true)], 0.15),
                ([.init(x: -40, isDown: true), .init(x: 75, isDown: true)], 0.45),
                ([.init(x: -40, isDown: false), .init(x: 75, isDown: false)], 0.3),
            ])
        ),
        GestureTip(
            id: "deleteWord",
            title: "Delete a word",
            detail: "One tap on delete removes the whole previous word, and it blows away like a gust of wind.",
            keyLabel: "delete",
            keySymbol: "delete.left",
            keyWidth: 72,
            poses: poses([(0, false, 0.5), (0, true, 0.12), (0, false, 0.18), (0, true, 0.12), (0, false, 0.5)])
        ),
        GestureTip(
            id: "deleteHold",
            title: "Hold to clear faster",
            detail: "Keep holding delete: it starts with letters, moves up to words, then whole sentences. Each step gets a little tap.",
            keyLabel: "delete",
            keySymbol: "delete.left",
            keyWidth: 72,
            poses: poses([(0, false, 0.4), (0, true, 0.15), (0, true, 1.6), (0, false, 0.4)])
        ),
        GestureTip(
            id: "scrub",
            title: "Erase letter by letter",
            detail: "Slide left from delete to erase one letter at a time. Slide back right to bring them back.",
            keyLabel: "delete",
            keySymbol: "delete.left",
            keyWidth: 72,
            poses: poses([(0, false, 0.4), (0, true, 0.15), (-70, true, 0.8), (-20, true, 0.6), (-20, false, 0.2)])
        ),
        GestureTip(
            id: "undo",
            title: "Undo a delete",
            detail: "Just deleted a word by mistake? Swipe right on delete and it breezes right back.",
            keyLabel: "delete",
            keySymbol: "delete.left",
            keyWidth: 72,
            poses: poses([(0, false, 0.4), (0, true, 0.15), (60, true, 0.45), (60, false, 0.25)])
        ),
        GestureTip(
            id: "revert",
            title: "Keep what you typed",
            detail: "Autocorrect only steps in when it's sure. If it guessed wrong, tap delete once to get your word back. Hold a suggestion to remember that spelling, or to forget a word it learned.",
            keyLabel: "delete",
            keySymbol: "delete.left",
            keyWidth: 72,
            poses: poses([(0, false, 0.5), (0, true, 0.12), (0, false, 0.6)])
        ),
        GestureTip(
            id: "shift",
            title: "Quick capitals",
            detail: "Slide from shift onto a letter for a single capital. Double-tap shift for caps lock.",
            keyLabel: "shift",
            keySymbol: "shift",
            keyWidth: 72,
            poses: poses([(0, false, 0.4), (0, true, 0.15), (70, true, 0.5), (70, false, 0.25)])
        ),
        GestureTip(
            id: "symbols",
            title: "Symbols in one move",
            detail: "Slide from 123 to any number or symbol and let go. You land right back on letters.",
            keyLabel: "123",
            keySymbol: nil,
            keyWidth: 72,
            poses: poses([(0, false, 0.4), (0, true, 0.15), (80, true, 0.5), (80, false, 0.25)])
        ),
        GestureTip(
            id: "accents",
            title: "Accents and extras",
            detail: "Hold a letter like e or n to pick é, ñ, or a shortcut you added, such as an email. Slide to choose, lift to type.",
            keyLabel: "e",
            keySymbol: nil,
            keyWidth: 52,
            poses: poses([(0, false, 0.4), (0, true, 0.6), (40, true, 0.4), (40, false, 0.25)])
        ),
        GestureTip(
            id: "period",
            title: "End a sentence",
            detail: "Tap space twice to add a period, and the next word starts with a capital.",
            keyLabel: "space",
            keySymbol: nil,
            keyWidth: 180,
            poses: poses([(0, false, 0.5), (0, true, 0.1), (0, false, 0.12), (0, true, 0.1), (0, false, 0.6)])
        ),
    ]
}
