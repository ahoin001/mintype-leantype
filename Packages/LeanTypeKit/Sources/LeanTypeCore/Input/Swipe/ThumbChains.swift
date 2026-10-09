import CoreGraphics

/// One chain per stroke. Order inside a chain is the order that thumb drew.
/// Two strokes are never the same chain, including two touches that are down together.
struct ThumbChains: Sendable {
    var chains: [[StrokeChannel.Step]]

    var eventCount: Int { chains.reduce(0) { $0 + $1.count } }

    static func make(_ steps: [StrokeChannel.Step]) -> ThumbChains {
        var grouped: [Int: [StrokeChannel.Step]] = [:]
        var order: [Int] = []
        for step in steps {
            if grouped[step.strokeIndex] == nil {
                order.append(step.strokeIndex)
            }
            grouped[step.strokeIndex, default: []].append(step)
        }
        let chains = order.map { index in
            (grouped[index] ?? []).sorted { $0.time < $1.time }
        }
        return ThumbChains(chains: chains)
    }
}
