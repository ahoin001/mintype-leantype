import CoreGraphics
import Testing
@testable import LeanTypeCore

@Suite("Layouts")
struct LayoutTests {
    @Test("Every row of every layer fills exactly ten units", arguments: KeyboardLayer.allCases)
    func rowsFillTenUnits(layer: KeyboardLayer) {
        for variant in [KeyboardVariant.standard, .email, .url] {
            for showsGlobe in [true, false] {
                let layout = LayoutProvider.layout(
                    for: layer,
                    context: LayoutContext(variant: variant, showsNextKeyboardKey: showsGlobe)
                )
                for row in layout.rows {
                    #expect(abs(row.totalUnits - 10) < 0.001, "\(layer) \(variant) row sums to \(row.totalUnits)")
                }
            }
        }
    }

    @Test func letterRowFlanksSpaceWithApostropheAndPeriod() throws {
        let layout = LayoutProvider.layout(for: .letters, context: LayoutContext())
        let keys = layout.rows[3].keys
        let space = try #require(keys.firstIndex { $0.kind == .space })
        #expect(keys[space - 1].kind == .character("'"))
        #expect(keys[space + 1].kind == .character("."))
        #expect(keys.contains { $0.kind == .emoji })
        #expect(keys[space - 1].widthUnits == 0.85)
        #expect(keys[space + 1].widthUnits == 0.85)

        let email = LayoutProvider.layout(for: .letters, context: LayoutContext(variant: .email))
        #expect(email.rows[3].keys.compactMap(\.kind.character) == ["@", "."])
        let url = LayoutProvider.layout(for: .letters, context: LayoutContext(variant: .url))
        let urlMarks = url.rows[3].keys.compactMap(\.kind.character)
        #expect(urlMarks == ["/", "."])
        #expect(urlMarks.filter { $0 == "." }.count == 1)
    }

    @Test func emailLayoutAddsAtAndDot() {
        let layout = LayoutProvider.layout(for: .letters, context: LayoutContext(variant: .email))
        let bottom = layout.rows[3].keys.compactMap(\.kind.character)
        #expect(bottom == ["@", "."])
    }

    @Test func globeKeyFollowsContext() {
        let withGlobe = LayoutProvider.layout(for: .letters, context: LayoutContext(showsNextKeyboardKey: true))
        let without = LayoutProvider.layout(for: .letters, context: LayoutContext(showsNextKeyboardKey: false))
        #expect(withGlobe.rows[3].keys.contains { $0.kind == .nextKeyboard })
        #expect(!without.rows[3].keys.contains { $0.kind == .nextKeyboard })
    }

    @Test func keyIDsAreUniqueWithinALayout() {
        for layer in KeyboardLayer.allCases {
            let ids = LayoutProvider.layout(for: layer, context: LayoutContext()).rows.flatMap(\.keys).map(\.id)
            #expect(Set(ids).count == ids.count)
        }
    }
}

@Suite("Geometry")
struct GeometryTests {
    let metrics = KeyboardMetrics.portrait
    let size = CGSize(width: 390, height: KeyboardMetrics.portrait.keyAreaHeight(rowCount: 4))

    func geometry(_ layer: KeyboardLayer = .letters) -> KeyboardGeometry {
        KeyboardGeometry(layout: LayoutProvider.layout(for: layer, context: LayoutContext()), size: size, metrics: metrics)
    }

    @Test func centerOfEveryKeyHitsThatKey() {
        let geometry = geometry()
        for frame in geometry.keys {
            let center = CGPoint(x: frame.visualFrame.midX, y: frame.visualFrame.midY)
            #expect(geometry.key(at: center)?.id == frame.id)
        }
    }

    @Test func gapsResolveToAKey() throws {
        let geometry = geometry()
        let q = try #require(geometry.keys.first { $0.key.kind == .character("q") })
        let w = try #require(geometry.keys.first { $0.key.kind == .character("w") })
        let gap = CGPoint(x: (q.visualFrame.maxX + w.visualFrame.minX) / 2, y: q.visualFrame.midY)
        let hit = geometry.key(at: gap)
        #expect(hit?.id == q.id || hit?.id == w.id)
    }

    @Test func edgeKeysExtendToKeyboardEdges() throws {
        let geometry = geometry()
        let a = try #require(geometry.keys.first { $0.key.kind == .character("a") })
        #expect(geometry.key(at: CGPoint(x: 1, y: a.visualFrame.midY))?.id == a.id)
        let space = try #require(geometry.keys.first { $0.key.kind == .space })
        #expect(geometry.key(at: CGPoint(x: space.visualFrame.midX, y: size.height - 0.5))?.id == space.id)
    }

    @Test func pointsFarOutsideMissTheKeyboard() {
        #expect(geometry().key(at: CGPoint(x: 100, y: -200)) == nil)
    }

    @Test func calloutsStayInsideBoundsAndOrderNearestFirst() throws {
        let geometry = geometry()
        let bounds = CGRect(x: 0, y: -metrics.dockHeight, width: size.width, height: size.height + metrics.dockHeight)
        let p = try #require(geometry.keys.first { $0.key.kind == .character("p") })
        let layout = CalloutGeometry.layout(anchor: p.visualFrame, optionCount: 5, metrics: metrics, bounds: bounds)

        #expect(layout.bubbleFrame.maxX <= bounds.maxX)
        #expect(layout.bubbleFrame.minY >= bounds.minY)
        let first = try #require(layout.optionFrames.first)
        let last = try #require(layout.optionFrames.last)
        #expect(first.midX > last.midX, "Right-side keys grow leftward, nearest option first")
        #expect(layout.optionIndex(atX: first.midX) == 0)
        #expect(layout.optionIndex(atX: -500) == layout.optionFrames.count - 1)
    }

    @Test func splitLeavesAGapAndFloatingMovesTheThumbsInward() throws {
        let docked = geometry()
        let split = docked.applying(.split)
        let mid = CGPoint(x: size.width / 2, y: size.height / 2)
        #expect(split.key(at: mid) == nil)
        let q = try #require(split.keys.first { $0.key.kind == .character("q") })
        let p = try #require(split.keys.first { $0.key.kind == .character("p") })
        #expect(q.visualFrame.midX < size.width / 2)
        #expect(p.visualFrame.midX > size.width / 2)
        #expect(split.key(at: CGPoint(x: q.visualFrame.midX, y: q.visualFrame.midY))?.id == q.id)

        let floating = docked.applying(.floating)
        let dockedQ = try #require(docked.keys.first { $0.key.kind == .character("q") })
        let floatingQ = try #require(floating.keys.first { $0.key.kind == .character("q") })
        #expect(floatingQ.visualFrame.midX > dockedQ.visualFrame.midX)
        let margin = CGPoint(x: 2, y: floatingQ.visualFrame.midY)
        #expect(floating.key(at: margin) == nil)
    }
}
