import Foundation
import Testing
@testable import LeanTypeCore

@Suite("Keyboard diagnostics")
struct DiagnosticsTests {
    private func makeLog() -> DiagnosticLog {
        let url = FileManager.default.temporaryDirectory.appending(path: "Diagnostics-\(UUID().uuidString).json")
        return DiagnosticLog { url }
    }

    @Test func anUnfinishedLaunchIsTroubleUntilTheKeyboardStaysOpen() {
        let log = makeLog()
        let earlier = Date(timeIntervalSince1970: 1_000)
        log.mark("Opening with Full Access", at: earlier)
        #expect(log.load().hasTrouble)
        #expect(log.load().explanation.contains("Full Access"))

        log.markOpened(at: earlier.addingTimeInterval(1))
        #expect(!log.load().hasTrouble)
    }

    @Test func loadingContactsAfterOpenIsTroubleUntilItFinishes() {
        let log = makeLog()
        let opened = Date(timeIntervalSince1970: 2_000)
        log.markOpened(at: opened)
        log.mark("Loading contacts", at: opened.addingTimeInterval(1))
        let report = log.load()
        #expect(report.hasTrouble)
        #expect(report.explanation.contains("contacts"))

        log.mark("Contacts ready (12)", at: opened.addingTimeInterval(2))
        #expect(!log.load().hasTrouble)
    }

    @Test func aCrashNewerThanTheLastOpenIsShownAndCanBeDismissed() {
        let log = makeLog()
        let opened = Date(timeIntervalSince1970: 3_000)
        log.markOpened(at: opened)
        log.recordCrash(summary: "jetsam", detail: "memory limit", at: opened.addingTimeInterval(5))
        let report = log.load()
        #expect(report.hasTrouble)
        #expect(report.explanation.contains("memory"))
        #expect(report.copyText.contains("jetsam"))

        log.acknowledge()
        #expect(!log.load().hasTrouble)
        #expect(log.load().crash == nil)
    }
}
