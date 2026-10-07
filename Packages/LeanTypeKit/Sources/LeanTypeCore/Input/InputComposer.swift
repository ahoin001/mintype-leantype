/// Orders text-producing commits across simultaneous fingers.
///
/// Each text-producing session reserves a ticket when its finger lands. Commits are released
/// strictly in touch-down order: a finger that lifts early waits for any earlier finger that is
/// still undecided (for example, one holding a long-press alternates menu). This is the
/// ordering guarantee two-thumb typing depends on, and it keeps fast tap rollover correct.
@MainActor
public final class InputComposer {
    public struct Ticket: Hashable, Sendable {
        fileprivate let sequence: UInt64
    }

    private enum Resolution {
        case pending
        case commit([KeyboardIntent])
        case cancelled
    }

    private var slots: [(sequence: UInt64, resolution: Resolution)] = []
    private var nextSequence: UInt64 = 0
    private let sink: @MainActor ([KeyboardIntent]) -> Void

    public init(sink: @escaping @MainActor ([KeyboardIntent]) -> Void) {
        self.sink = sink
    }

    public var hasPendingCommits: Bool {
        !slots.isEmpty
    }

    public func reserve() -> Ticket {
        defer { nextSequence &+= 1 }
        slots.append((nextSequence, .pending))
        return Ticket(sequence: nextSequence)
    }

    public func commit(_ ticket: Ticket, _ intents: [KeyboardIntent]) {
        resolve(ticket, as: .commit(intents))
    }

    public func cancel(_ ticket: Ticket) {
        resolve(ticket, as: .cancelled)
    }

    public func reset() {
        slots.removeAll()
    }

    private func resolve(_ ticket: Ticket, as resolution: Resolution) {
        guard let index = slots.firstIndex(where: { $0.sequence == ticket.sequence }),
              case .pending = slots[index].resolution
        else { return }
        slots[index].resolution = resolution
        flush()
    }

    private func flush() {
        while let first = slots.first {
            switch first.resolution {
            case .pending:
                return
            case let .commit(intents):
                slots.removeFirst()
                sink(intents)
            case .cancelled:
                slots.removeFirst()
            }
        }
    }
}
