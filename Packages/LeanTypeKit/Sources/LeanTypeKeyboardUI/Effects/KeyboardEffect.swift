import LeanTypeCore
import UIKit

/// What an effect may use while it plays.
@MainActor
struct EffectContext {
    let stage: EffectsStage
    var palette: EffectPalette
    var level: EffectsLevel
    /// The user's intensity as a multiplier for size, opacity, and particle counts.
    var intensity: CGFloat
    var flow: FlowLevel
    var trailStyle: EffectsSettings.TrailStyle
    var geometry: KeyboardGeometry?

    var pool: LayerPool { stage.pool }

    /// Typical key size, for sizing flourishes to the keyboard.
    var keySize: CGSize {
        guard let metrics = geometry?.metrics, let width = geometry?.keys.first?.visualFrame.width else {
            return CGSize(width: 32, height: 43)
        }
        return CGSize(width: width, height: metrics.keyHeight)
    }

    func stageFrame(of kind: KeyKind) -> CGRect? {
        guard let frame = geometry?.keys.first(where: { $0.key.kind == kind }) else { return nil }
        return stage.rect(fromKeyArea: frame.visualFrame)
    }
}

/// One visual flourish, reacting to keyboard events.
///
/// Effects own no long-lived layers beyond what they borrow from the pool, finish within a
/// second, and must tolerate `stop()` at any moment (effects turned off, keyboard hidden).
@MainActor
protocol KeyboardEffect: AnyObject {
    /// The lowest effects level this effect runs at. Effects that move things across the
    /// screen or emit particles need `.full`; gentle fades can run at `.reduced`.
    static var minimumLevel: EffectsLevel { get }

    func handle(_ event: KeyboardEvent, in context: EffectContext)
    /// The theme, flow, or layout changed.
    func contextDidChange(_ context: EffectContext)
    /// Ends everything immediately and returns borrowed layers.
    func stop(in context: EffectContext)
}

extension KeyboardEffect {
    func contextDidChange(_: EffectContext) {}
}
