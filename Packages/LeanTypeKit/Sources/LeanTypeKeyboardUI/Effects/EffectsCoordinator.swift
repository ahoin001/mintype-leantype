import LeanTypeCore
import LeanTypeDesign
import UIKit

/// Routes keyboard events to the effects the current level allows, and keeps their shared
/// context (theme, flow, layout, intensity) up to date.
@MainActor
final class EffectsCoordinator: KeyboardEventObserver {
    let stage: EffectsStage
    let trails: TrailRenderer
    let jewel: GestureJewelRenderer
    /// Called when flow moves a step, for chrome outside the stage (the dock wordmark).
    var onFlowChange: ((FlowLevel) -> Void)?

    private let governor: EffectsGovernor
    private let halo = CapsHaloEffect()
    private let effects: [any KeyboardEffect]
    private var context: EffectContext

    init(stage: EffectsStage, theme: Theme, settings: EffectsSettings) {
        self.stage = stage
        governor = EffectsGovernor(intensity: settings.intensity)
        effects = [
            RippleEffect(), GustEffect(), SparkleEffect(), FlowGlowEffect(),
            HoldWindupEffect(), GearMarkEffect(), ReturnLiftEffect(), halo,
        ]
        context = EffectContext(
            stage: stage,
            palette: EffectPalette(theme: theme),
            level: governor.level,
            intensity: CGFloat(settings.intensity.scale),
            flow: .zero,
            trailStyle: settings.trailStyle,
            geometry: nil
        )
        trails = TrailRenderer(stage: stage, palette: context.palette)
        jewel = GestureJewelRenderer(stage: stage, palette: context.palette)
        syncTrails()
        governor.onChange = { [weak self] level in self?.levelDidChange(level) }
        if context.level > .off {
            stage.pool.prewarm()
        }
    }

    var level: EffectsLevel { context.level }

    func handle(_ event: KeyboardEvent) {
        if case let .flowChanged(flow) = event {
            context.flow = flow
            onFlowChange?(context.level > .off ? flow : .zero)
        }
        guard context.level > .off else { return }
        jewel.handle(event)
        let interval = Signposts.effects.beginInterval("Effect")
        for effect in effects where context.level >= type(of: effect).minimumLevel {
            effect.handle(event, in: context)
        }
        Signposts.effects.endInterval("Effect", interval)
    }

    // MARK: - Context updates

    func apply(theme: Theme) {
        context.palette = EffectPalette(theme: theme)
        contextDidChange()
    }

    func apply(settings: EffectsSettings) {
        context.intensity = CGFloat(settings.intensity.scale)
        context.trailStyle = settings.trailStyle
        governor.setIntensity(settings.intensity)
        contextDidChange()
    }

    func apply(geometry: KeyboardGeometry) {
        context.geometry = geometry
        contextDidChange()
    }

    func shiftDidChange(_ shift: ShiftState) {
        if shift != .locked {
            halo.capsLockEnded(in: context)
        }
    }

    func layoutDidChange() {
        contextDidChange()
    }

    func keyboardWillAppear() {
        governor.keyboardWillAppear()
    }

    /// Stops everything and frees idle layers until the keyboard next appears.
    func handleMemoryWarning() {
        governor.noteMemoryPressure()
        stage.pool.drain()
    }

    func stopAll() {
        effects.forEach { $0.stop(in: context) }
        trails.endAll(animated: false)
        jewel.end(animated: false)
    }

    // MARK: - Private

    private func contextDidChange() {
        syncTrails()
        guard context.level > .off else { return }
        effects.forEach { $0.contextDidChange(context) }
    }

    private func syncTrails() {
        trails.level = context.level
        trails.palette = context.palette
        trails.style = context.trailStyle
        trails.intensity = context.intensity
        jewel.level = context.level
        jewel.palette = context.palette
        jewel.intensity = context.intensity
    }

    private func levelDidChange(_ level: EffectsLevel) {
        let previous = context.level
        context.level = level
        for effect in effects where level < type(of: effect).minimumLevel && previous >= type(of: effect).minimumLevel {
            effect.stop(in: context)
        }
        if level == .off {
            onFlowChange?(.zero)
            trails.level = .off
            jewel.level = .off
            stage.pool.drain()
        } else {
            stage.pool.prewarm()
            contextDidChange()
        }
    }
}
