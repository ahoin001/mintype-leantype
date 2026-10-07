import CoreGraphics
import Foundation
@testable import LeanTypeCore

/// Deterministic clock for gesture timers: time only moves when a test advances it.
@MainActor
final class ManualScheduler: Scheduler {
    private struct Task {
        let id: Int
        let due: TimeInterval
        let action: @MainActor @Sendable () -> Void
    }

    private final class Token: Cancellable {
        let cancelHandler: () -> Void
        init(_ cancelHandler: @escaping () -> Void) { self.cancelHandler = cancelHandler }
        func cancel() { cancelHandler() }
    }

    private(set) var now: TimeInterval = 1000
    private var tasks: [Task] = []
    private var nextID = 0

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> any Cancellable {
        let id = nextID
        nextID += 1
        tasks.append(Task(id: id, due: now + delay, action: action))
        return Token { [weak self] in
            MainActor.assumeIsolated { self?.tasks.removeAll { $0.id == id } }
        }
    }

    /// Advances time, running due tasks in order (including ones they schedule).
    func advance(by interval: TimeInterval) {
        let target = now + interval
        while let next = tasks.filter({ $0.due <= target }).min(by: { $0.due < $1.due }) {
            tasks.removeAll { $0.id == next.id }
            now = next.due
            next.action()
        }
        now = target
    }
}

/// Records everything the engine publishes.
@MainActor
final class EngineRecorder: KeyboardEngineDelegate {
    var feedback: [FeedbackEvent] = []
    var geometryUpdates = 0
    var nextKeyboardRequests = 0

    func keyboardEngine(_: KeyboardEngine, didUpdateGeometry _: KeyboardGeometry) { geometryUpdates += 1 }
    func keyboardEngine(_: KeyboardEngine, didUpdateState _: KeyboardViewState) {}
    func keyboardEngine(_: KeyboardEngine, didEmit feedback: FeedbackEvent) { self.feedback.append(feedback) }
    func keyboardEngineDidRequestNextKeyboard(_: KeyboardEngine) { nextKeyboardRequests += 1 }
}

/// Drives a real `KeyboardEngine` with synthetic touches against an in-memory document.
@MainActor
final class EngineHarness {
    static let width: CGFloat = 390

    let document: InMemoryTextDocument
    let scheduler = ManualScheduler()
    let recorder = EngineRecorder()
    let engine: KeyboardEngine
    private var nextTouch = 0
    private var positions: [TouchID: CGPoint] = [:]

    init(
        text: String = "",
        settings: KeyboardSettings = .default,
        traits: InputTraits = .default
    ) {
        document = InMemoryTextDocument(text: text)
        engine = KeyboardEngine(document: document, settings: settings, traits: traits, scheduler: scheduler)
        engine.delegate = recorder
        let metrics = KeyboardMetrics.portrait
        engine.updateLayout(
            size: CGSize(width: Self.width, height: metrics.keyAreaHeight(rowCount: 4)),
            metrics: metrics
        )
    }

    var text: String { document.text }
    var state: KeyboardViewState { engine.state }

    func point(for kind: KeyKind) -> CGPoint {
        guard let frame = engine.geometry.keys.first(where: { $0.key.kind == kind }) else {
            preconditionFailure("No \(kind) key on \(engine.geometry.layout.layer)")
        }
        return CGPoint(x: frame.visualFrame.midX, y: frame.visualFrame.midY)
    }

    func point(for character: String) -> CGPoint {
        point(for: .character(character))
    }

    @discardableResult
    func down(at location: CGPoint) -> TouchID {
        let id = TouchID(rawValue: nextTouch)
        nextTouch += 1
        positions[id] = location
        send(id, location, .began)
        return id
    }

    func move(_ id: TouchID, by delta: CGVector, over duration: TimeInterval = 0.05, steps: Int = 1) {
        guard let start = positions[id] else { return }
        for step in 1...steps {
            scheduler.advance(by: duration / Double(steps))
            let fraction = CGFloat(step) / CGFloat(steps)
            let location = CGPoint(x: start.x + delta.dx * fraction, y: start.y + delta.dy * fraction)
            positions[id] = location
            send(id, location, .moved)
        }
    }

    func move(_ id: TouchID, to location: CGPoint, over duration: TimeInterval = 0.05) {
        guard let start = positions[id] else { return }
        move(id, by: CGVector(dx: location.x - start.x, dy: location.y - start.y), over: duration)
    }

    func up(_ id: TouchID) {
        guard let location = positions.removeValue(forKey: id) else { return }
        send(id, location, .ended)
    }

    func tap(_ kind: KeyKind, gap: TimeInterval = 0.12) {
        let id = down(at: point(for: kind))
        scheduler.advance(by: 0.05)
        up(id)
        scheduler.advance(by: gap)
    }

    func type(_ text: String) {
        for character in text {
            tap(character == " " ? .space : .character(String(character).lowercased()))
        }
    }

    func wait(_ interval: TimeInterval) {
        scheduler.advance(by: interval)
    }

    private func send(_ id: TouchID, _ location: CGPoint, _ phase: TouchPhase) {
        engine.handle([TouchSample(id: id, location: location, timestamp: scheduler.now, phase: phase)])
    }
}
