import CoreGraphics
import Testing
@testable import LeanTypeCore

/// Seeded mixed-input choreography. Invariants fail the suite. Accuracy is reported on the same runs.
@MainActor
@Suite("Choreography fuzzer")
struct ChoreographyFuzzerTests {
    private let words = [
        "the", "and", "you", "that", "have", "with", "this", "from", "they", "hello",
        "world", "friend", "pill", "live", "wait", "time", "good", "just", "like", "make",
    ]

    @Test func seededChoreographyKeepsItsInvariants() {
        let layout = layoutFromHarness()
        var cleanHits = 0
        var cleanRuns = 0
        var jitterHits = 0
        var jitterRuns = 0
        var misses: [String] = []

        for (index, word) in words.enumerated() {
            for jitter in [0.0, 0.06, 0.15, 0.30] {
                for noise in [0.0, 0.3, 0.6] {
                    let seed = UInt64(index &* 1000) &+ UInt64(jitter * 1000) &+ UInt64(noise * 10)
                    guard let gesture = ChoreographyFuzzer.gesture(
                        word: word,
                        layout: layout,
                        jitter: jitter,
                        noise: noise,
                        seed: seed
                    ) else { continue }
                    let letters = gesture.evidence.aimedLetters.filter(\.isLetter)
                    #expect(letters == word, "\(word) lost or duplicated letters: \(letters)")
                    let first = decode(gesture, layout: layout)
                    let second = decode(gesture, layout: layout)
                    #expect(first.words.first == second.words.first)
                    #expect(Set(first.words) == Set(second.words))
                    let hit = first.words.prefix(jitter == 0 && noise == 0 ? 1 : 3).contains(word)
                    if jitter == 0, noise == 0 {
                        cleanRuns += 1
                        if first.words.first == word { cleanHits += 1 }
                        else { misses.append("\(word) → \(first.words.prefix(3))") }
                    }
                    let thumbs = Set(gesture.evidence.events.map(\.strokeIndex).filter { $0 >= 0 })
                    if jitter == 0.15, noise == 0, thumbs.count >= 2 {
                        jitterRuns += 1
                        if hit {
                            jitterHits += 1
                        } else {
                            misses.append("150ms \(word) → \(first.words.prefix(3).joined(separator: ", "))")
                        }
                    }
                }
            }
        }

        let clean = cleanRuns == 0 ? 0 : Double(cleanHits) / Double(cleanRuns)
        let jittered = jitterRuns == 0 ? 0 : Double(jitterHits) / Double(jitterRuns)
        #expect(clean >= 0.90, "clean top-1 \(clean) misses \(misses)")
        #expect(jittered >= 0.97, "150 ms top-3 \(jittered) \(misses.joined(separator: "; "))")
    }

    @Test func aFingerDownDoesNotCloseTheLeashAndACancelKeepsTheOtherThumb() {
        var generator = SplitMix64(seed: 7)
        for _ in 0..<4 {
            let harness = EngineHarness(
                traits: InputTraits(autocapitalization: .none),
                language: LanguageModel(lexicon: TestLexicon.shared)
            )
            let left = String(UnicodeScalar(UInt8(ascii: "a") + UInt8(generator.next() % 13)))
            let right = String(UnicodeScalar(UInt8(ascii: "n") + UInt8(generator.next() % 13)))
            let held = harness.down(at: harness.point(for: left))
            let partner = harness.down(at: harness.point(for: right))
            harness.wait(0.2)
            #expect(!harness.text.contains(left))
            harness.cancel(partner)
            #expect(harness.text.isEmpty)
            harness.up(held)
            #expect(harness.text == left)
        }
    }

    private func layoutFromHarness() -> LetterLayout {
        let harness = EngineHarness(language: LanguageModel(lexicon: TestLexicon.shared))
        guard let layout = LetterLayout(geometry: harness.engine.geometry) else {
            preconditionFailure("No letter layout")
        }
        return layout
    }

    private func decode(_ gesture: SwipeGesture, layout: LetterLayout) -> DecodeResult {
        var score = PathScore()
        return AlignmentSearch.decode(
            gesture,
            layout: layout,
            lexicon: TestLexicon.shared,
            personal: [],
            bigram: LetterBigram(lexicon: TestLexicon.shared),
            costs: .standard,
            pathScore: &score
        )
    }
}

enum ChoreographyFuzzer {
    static func gesture(
        word: String,
        layout: LetterLayout,
        jitter: Double,
        noise: Double,
        seed: UInt64
    ) -> SwipeGesture? {
        var generator = SplitMix64(seed: seed)
        let letters = word.map(String.init)
        var thumb = Int(generator.next() % 2)
        var thumbs: [Int] = []
        for _ in letters {
            if generator.unit() < 0.72 { thumb = 1 - thumb }
            thumbs.append(thumb)
        }
        let realization = Int(generator.next() % 3)
        var time = 1.0
        var strokes: [StrokeBuffer] = []
        var taps: [StrokeObservation] = []
        var open: (thumb: Int, buffer: StrokeBuffer)?
        for (index, letter) in letters.enumerated() {
            let step = 0.08 + (thumbs[index] == 1 ? jitter : 0)
            time += step
            var point = layout.center(of: letter.utf8.first ?? UInt8(ascii: "a"))
            if noise > 0 {
                let angle = generator.unit() * 2 * .pi
                point.x += CGFloat(cos(angle) * noise) * layout.keyWidth
                point.y += CGFloat(sin(angle) * noise) * layout.keyWidth
            }
            let repeated = index > 0 && letter == letters[index - 1]
            let useStroke = realization != 0 && !repeated && !(realization == 2 && index == 0)
            if useStroke {
                if var current = open, current.thumb == thumbs[index] {
                    current.buffer.append(StrokePoint(location: point, time: time))
                    current.buffer.arrive(letter, at: point, touch: point, time: time)
                    open = current
                } else {
                    if let finished = open {
                        var buffer = finished.buffer
                        buffer.finish(at: buffer.end)
                        strokes.append(buffer)
                    }
                    var buffer = StrokeBuffer(
                        start: StrokePoint(location: point, time: time),
                        thumb: thumbs[index]
                    )
                    buffer.arrive(letter, at: point, touch: point, time: time)
                    open = (thumbs[index], buffer)
                }
            } else {
                if let finished = open {
                    var buffer = finished.buffer
                    buffer.finish(at: buffer.end)
                    strokes.append(buffer)
                    open = nil
                }
                taps.append(StrokeObservation(
                    time: time,
                    point: point,
                    directionX: 0,
                    directionY: 0,
                    letter: letter,
                    isTap: true,
                    strokeIndex: thumbs[index],
                    mark: realization == 2 && index == 0 ? .pin : .tap
                ))
            }
        }
        if let finished = open {
            var buffer = finished.buffer
            buffer.finish(at: buffer.end)
            strokes.append(buffer)
        }
        return GestureComposer.compose(strokes, taps: taps)
    }
}

struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58476D1CE4E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB
        return mixed ^ (mixed >> 31)
    }

    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
