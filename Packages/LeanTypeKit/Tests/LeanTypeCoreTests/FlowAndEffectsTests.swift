import CoreGraphics
import Testing
@testable import LeanTypeCore

@Suite("Flow tracker")
struct FlowTrackerTests {
    @Test func steadyRhythmBuildsFlow() {
        var tracker = FlowTracker()
        var time = 0.0
        for _ in 0..<60 {
            tracker.noteKeystroke(at: time)
            time += 0.15
        }
        #expect(tracker.level.value > 0.8)
    }

    @Test func slowHuntAndPeckStaysCalm() {
        var tracker = FlowTracker()
        var time = 0.0
        for _ in 0..<40 {
            tracker.noteKeystroke(at: time)
            time += 1.2
        }
        #expect(tracker.level == .zero)
    }

    @Test func idleDecaysWithoutTouchingRhythm() {
        var tracker = FlowTracker()
        for index in 0..<40 { tracker.noteKeystroke(at: Double(index) * 0.15) }
        let peak = tracker.level.value
        let settled = tracker.settle(at: 6 + 5)
        #expect(settled.value < peak * 0.2)
        #expect(tracker.level(at: 30).value < 0.01)
    }

    @Test func deletionsCostMomentumAndStreak() {
        var tracker = FlowTracker()
        for index in 0..<30 { tracker.noteKeystroke(at: Double(index) * 0.15) }
        _ = tracker.noteWordCompleted(at: 4.6)
        let before = tracker.level.value
        tracker.noteDeletion(at: 4.7)
        #expect(tracker.level.value < before)
        #expect(tracker.streak == 0)
    }

    @Test func milestonesAreSpacedOut() {
        var tracker = FlowTracker()
        var milestones: [Int] = []
        var time = 0.0
        for _ in 0..<(FlowTracker.milestoneInterval * 2) {
            if let milestone = tracker.noteWordCompleted(at: time) { milestones.append(milestone) }
            time += 0.3
        }
        #expect(milestones == [FlowTracker.milestoneInterval], "The second milestone falls inside the cooldown")

        for _ in 0..<FlowTracker.milestoneInterval {
            time += 1
            if let milestone = tracker.noteWordCompleted(at: time) { milestones.append(milestone) }
        }
        #expect(milestones.last == FlowTracker.milestoneInterval * 3)
    }

    @Test func publishesInSteps() {
        #expect(FlowLevel(0.04).step == 0)
        #expect(FlowLevel(0.46).step == 5)
        #expect(FlowLevel(2).value == 1)
    }
}

@MainActor
@Suite("Flow events")
struct FlowEventTests {
    @Test func typingEmitsFewFlowChangesAndSettlesToZero() {
        let harness = EngineHarness(traits: InputTraits(autocapitalization: .none))
        for _ in 0..<10 { harness.type("asdf ") }
        let changes = harness.recorder.count { if case .flowChanged = $0 { true } else { false } }
        #expect(changes > 0)
        #expect(changes <= FlowLevel.stepCount, "Flow is published per step, not per key")

        harness.wait(30)
        guard case let .flowChanged(last) = harness.recorder.events.last(where: { if case .flowChanged = $0 { true } else { false } }) else {
            Issue.record("Expected a flow change")
            return
        }
        #expect(last.step == 0)
    }

    @Test func wordsAndSentencesEmitEvents() {
        let harness = EngineHarness()
        harness.type("ok  ")
        #expect(harness.recorder.events.contains(.wordCommitted(.tap)))
        #expect(harness.recorder.events.contains { if case .sentenceEnded = $0 { true } else { false } })
    }

    @Test func deletingAWordEmitsItForTheGust() {
        let harness = EngineHarness(text: "hello world")
        harness.tap(.backspace)
        let deleted = harness.recorder.events.compactMap { event -> String? in
            if case let .wordDeleted(word, _) = event { word } else { nil }
        }
        #expect(deleted == ["world"])
    }
}

@Suite("Effects policy")
struct EffectsPolicyTests {
    @Test func defaultsToFull() {
        #expect(EffectsPolicy().level == .full)
    }

    @Test(arguments: [
        (EffectsPolicy(intensity: .off), EffectsLevel.off),
        (EffectsPolicy(isUnderMemoryPressure: true), .off),
        (EffectsPolicy(thermal: .critical), .off),
        (EffectsPolicy(thermal: .serious), .reduced),
        (EffectsPolicy(isLowPowerModeEnabled: true), .reduced),
        (EffectsPolicy(isReduceMotionEnabled: true), .reduced),
        (EffectsPolicy(intensity: .party, thermal: .fair), .full),
    ])
    func resolvesLevel(policy: EffectsPolicy, expected: EffectsLevel) {
        #expect(policy.level == expected)
    }

    @Test func offBeatsReduced() {
        #expect(EffectsPolicy(intensity: .off, isReduceMotionEnabled: true).level == .off)
    }
}
