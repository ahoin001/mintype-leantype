import Foundation

/// What one finger just did. The session does not see coordinates; the segmenter already
/// decided tap versus stroke.
enum SessionSignal: Equatable, Sendable {
    case fingerDown
    /// `letter` is set when the finger lifted without becoming a stroke.
    /// `wasStroke` frees that thumb's chain so it can draw again after a handoff.
    case fingerUp(letter: String?, time: Double, wasStroke: Bool)
    case strokeStarted(ThumbSide)
    case delimiter(WordDelimiter)
}

enum SessionPhase: Equatable, Sendable {
    case idle
    case contact
    case tapOpen
    case swipeOpen
}

enum SessionEffect: Equatable, Sendable {
    case stayOpen
    case preview
    case commit(Timeline, trailing: WordDelimiter?)
    case hapticTap
    case hapticStroke
    case hapticCommit
}

/// When a word is open, and what closes it.
///
/// A contact span runs from the first finger down until none remain. If that span never
/// stroked, the word stays tap-open across later pauses. If it stroked before any tap-open
/// latch, the word commits the moment the last finger lifts. A tap that lands while another
/// finger is still down does not latch the phase by itself.
struct WordSession: Equatable, Sendable {
    private(set) var phase: SessionPhase = .idle
    private(set) var timeline = Timeline()
    /// Fingers still on the glass.
    private var fingers = 0
    /// Strokes currently drawing. A third finger cannot open another one.
    private var strokes = 0

    mutating func reduce(_ signal: SessionSignal) -> [SessionEffect] {
        switch signal {
        case .fingerDown:
            if phase == .idle {
                timeline = Timeline()
                strokes = 0
                phase = .contact
            }
            fingers += 1
            return []

        case let .fingerUp(letter, time, wasStroke):
            if let letter {
                timeline.items.append(.tap(letter: letter, time: time))
            }
            if wasStroke {
                strokes = max(0, strokes - 1)
            }
            fingers = max(0, fingers - 1)
            if fingers > 0 {
                return letter == nil ? [] : [.hapticTap, .preview]
            }
            var effects: [SessionEffect] = letter == nil ? [] : [.hapticTap]
            effects.append(contentsOf: release())
            return effects

        case let .strokeStarted(thumb):
            guard strokes < 2 else { return [] }
            strokes += 1
            timeline.items.append(.stroke(thumb: thumb))
            if phase != .tapOpen {
                phase = .swipeOpen
            }
            return [.hapticStroke, .preview]

        case let .delimiter(mark):
            guard phase != .idle || !timeline.items.isEmpty else { return [] }
            let draft = timeline
            seal()
            return [.commit(draft, trailing: mark), .hapticCommit]
        }
    }

    /// Drops strokes after an undo, leaving any taps as an open word.
    mutating func dropStrokes() {
        timeline.items.removeAll { item in
            if case .stroke = item { true } else { false }
        }
        strokes = 0
        if phase == .swipeOpen {
            phase = timeline.items.isEmpty ? .idle : .tapOpen
        }
    }

    /// Closes the word without forgetting fingers that are still down.
    mutating func closeWord() {
        phase = .idle
        timeline = Timeline()
        strokes = 0
    }

    /// The word has been committed or abandoned. The next finger starts a new one.
    mutating func seal() {
        closeWord()
        fingers = 0
    }

    private mutating func release() -> [SessionEffect] {
        strokes = 0
        switch phase {
        case .swipeOpen:
            let draft = timeline
            seal()
            return [.commit(draft, trailing: nil), .hapticCommit]
        case .contact:
            phase = .tapOpen
            return [.stayOpen]
        case .tapOpen:
            return [.stayOpen, .preview]
        case .idle:
            return []
        }
    }
}
