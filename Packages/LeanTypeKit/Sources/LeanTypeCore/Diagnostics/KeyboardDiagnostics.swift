import Foundation

/// What the keyboard was doing the last time it opened, plus the latest crash iOS reported.
///
/// Written into the App Group so the companion app can explain a keyboard that flickered
/// and was replaced. Writes are synchronous: a kill after `mark` still leaves the step on disk.
public struct KeyboardReport: Codable, Equatable, Sendable {
    public struct Event: Codable, Equatable, Sendable {
        public var date: Date
        public var step: String

        public init(date: Date, step: String) {
            self.date = date
            self.step = step
        }
    }

    public struct Crash: Codable, Equatable, Sendable {
        public var date: Date
        public var summary: String
        public var detail: String

        public init(date: Date, summary: String, detail: String) {
            self.date = date
            self.summary = summary
            self.detail = detail
        }
    }

    public static let openedStep = "Stayed open"
    /// Steps that mean "still starting". If one of these is the newest line and the keyboard
    /// never got to stay open afterwards, the app treats that launch as a failure.
    public static let inProgressSteps: Set<String> = [
        "Starting",
        "Keyboard built",
        "Opening",
        "Opening with Full Access",
        "Settings loaded",
    ]

    public var events: [Event]
    public var crash: Crash?
    public var lastOpened: Date?

    public init(events: [Event] = [], crash: Crash? = nil, lastOpened: Date? = nil) {
        self.events = events
        self.crash = crash
        self.lastOpened = lastOpened
    }

    /// A launch that died, newer than the last time the keyboard stayed on screen.
    public var hasTrouble: Bool {
        if let crash, isNewerThanLastOpen(crash.date) { return true }
        guard let last = events.last, Self.inProgressSteps.contains(last.step) else { return false }
        return isNewerThanLastOpen(last.date)
    }

    public var headline: String {
        if crash.map({ isNewerThanLastOpen($0.date) }) == true {
            return "LeanType closed unexpectedly"
        }
        return "LeanType didn't stay open"
    }

    public var explanation: String {
        if let crash, isNewerThanLastOpen(crash.date) {
            if crash.summary.localizedCaseInsensitiveContains("jetsam")
                || crash.summary.localizedCaseInsensitiveContains("memory") {
                return "iOS closed it for using too much memory. Copy the details if it happens again."
            }
            return "iOS closed it while it was opening. \(crash.summary)"
        }
        switch events.last?.step {
        case "Starting", "Keyboard built":
            return "It closed while drawing the keys. Copy the details to see the last step it reached."
        default:
            return "It closed while turning on Full Access. Copy the details to see the last step it reached."
        }
    }

    /// Plain text for the Copy button: the story, then the stack if we have one.
    public var copyText: String {
        var lines = events.map { "\(Self.timestamp.string(from: $0.date))  \($0.step)" }
        if let crash {
            lines.append("")
            lines.append(crash.summary)
            if !crash.detail.isEmpty {
                lines.append(crash.detail)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func isNewerThanLastOpen(_ date: Date) -> Bool {
        guard let lastOpened else { return true }
        return date > lastOpened
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

/// Appends startup steps and crash reports to one JSON file in the shared container.
public final class DiagnosticLog: @unchecked Sendable {
    public static let shared = DiagnosticLog { SharedContainer.fileURL(named: "KeyboardDiagnostics.json") }

    static let eventLimit = 30
    static let detailLimit = 4_000

    private let lock = NSLock()
    private let file: CodableFileStore<KeyboardReport>

    init(url: @escaping @Sendable () -> URL?) {
        file = CodableFileStore(url: url)
    }

    public func load() -> KeyboardReport {
        lock.lock()
        defer { lock.unlock() }
        return file.load() ?? KeyboardReport()
    }

    public func mark(_ step: String, at date: Date = .now) {
        update { report in
            report.events.append(KeyboardReport.Event(date: date, step: step))
        }
    }

    /// The keyboard made it on screen. Clears the "didn't stay open" reading for earlier steps.
    public func markOpened(at date: Date = .now) {
        update { report in
            report.lastOpened = date
            report.events.append(KeyboardReport.Event(date: date, step: KeyboardReport.openedStep))
        }
    }

    public func recordCrash(summary: String, detail: String, at date: Date = .now) {
        update { report in
            report.crash = KeyboardReport.Crash(
                date: date,
                summary: String(summary.prefix(500)),
                detail: String(detail.prefix(Self.detailLimit))
            )
        }
    }

    /// Hides the card until the next failed launch.
    public func acknowledge() {
        let now = Date()
        update { report in
            report.crash = nil
            report.lastOpened = now
        }
    }

    private func update(_ change: (inout KeyboardReport) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var report = file.load() ?? KeyboardReport()
        change(&report)
        if report.events.count > Self.eventLimit {
            report.events.removeFirst(report.events.count - Self.eventLimit)
        }
        file.save(report)
    }
}
