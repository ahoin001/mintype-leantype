import CoreGraphics

/// One step of a demo finger: where it is, whether it's touching, and how long it takes to
/// get there. `step` keeps otherwise-identical poses distinct for the phase animator.
struct FingerPose: Hashable {
    let step: Int
    let x: CGFloat
    let isDown: Bool
    let duration: Double
}

/// A gesture worth teaching, with a tiny looping demo.
struct GestureTip: Identifiable {
    let id: String
    let title: String
    let detail: String
    let keyLabel: String
    let keySymbol: String?
    let keyWidth: CGFloat
    let poses: [FingerPose]

    static func poses(_ moves: [(x: CGFloat, isDown: Bool, duration: Double)]) -> [FingerPose] {
        moves.enumerated().map { FingerPose(step: $0.offset, x: $0.element.x, isDown: $0.element.isDown, duration: $0.element.duration) }
    }

    static let all: [GestureTip] = [
        GestureTip(
            id: "trackpad",
            title: "Glide the cursor",
            detail: "Slide along the space bar to move the cursor. Swipe faster to travel further.",
            keyLabel: "space",
            keySymbol: nil,
            keyWidth: 180,
            poses: poses([(0, false, 0.4), (0, true, 0.15), (-60, true, 0.7), (50, true, 0.9), (50, false, 0.2)])
        ),
        GestureTip(
            id: "deleteWord",
            title: "Delete a word",
            detail: "One tap on delete removes the whole previous word. Hold it to keep going.",
            keyLabel: "delete",
            keySymbol: "delete.left",
            keyWidth: 72,
            poses: poses([(0, false, 0.5), (0, true, 0.12), (0, false, 0.18), (0, true, 0.12), (0, false, 0.5)])
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
            detail: "Just deleted a word by mistake? Swipe right on delete and it comes right back.",
            keyLabel: "delete",
            keySymbol: "delete.left",
            keyWidth: 72,
            poses: poses([(0, false, 0.4), (0, true, 0.15), (60, true, 0.45), (60, false, 0.25)])
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
            detail: "Hold a letter like e or n to pick é, ñ and friends. Slide to choose, lift to type.",
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
