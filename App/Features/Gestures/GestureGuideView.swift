import SwiftUI

struct GestureGuideView: View {
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(GestureTip.all) { tip in
                    GestureCard(tip: tip)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .pebbleScreen()
        .navigationTitle("Gestures")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct GestureCard: View {
    @Environment(\.pebbleTheme) private var theme

    let tip: GestureTip

    var body: some View {
        PebbleCard {
            VStack(alignment: .leading, spacing: 16) {
                GestureDemo(tip: tip)
                    .frame(maxWidth: .infinity)
                    .frame(height: 74)
                    .background(theme.backgroundGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(tip.title)
                        .font(.pebble(.headline, weight: .bold))
                        .foregroundStyle(theme.ink)
                    Text(tip.detail)
                        .font(.pebble(.subheadline))
                        .foregroundStyle(theme.subtleInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A keycap with a translucent fingertip acting out the gesture on a loop. With Reduce Motion
/// on, it shows a single still pose instead.
private struct GestureDemo: View {
    @Environment(\.pebbleTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let tip: GestureTip

    var body: some View {
        ZStack {
            keycap
            if reduceMotion {
                finger(for: tip.poses.first { $0.isDown } ?? tip.poses[0])
            } else {
                PhaseAnimator(tip.poses) { pose in
                    finger(for: pose)
                } animation: { pose in
                    .smooth(duration: pose.duration)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var keycap: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(theme.surface)
            .frame(width: tip.keyWidth, height: 44)
            .overlay {
                Group {
                    if let symbol = tip.keySymbol {
                        Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                    } else {
                        Text(tip.keyLabel).font(.pebble(.callout, weight: .medium))
                    }
                }
                .foregroundStyle(theme.ink)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(theme.surfaceRim, lineWidth: 1)
            }
            .shadow(color: theme.shadow, radius: 1.5, y: 1.5)
    }

    private func finger(for pose: FingerPose) -> some View {
        Circle()
            .fill(theme.accent.opacity(0.35))
            .overlay { Circle().strokeBorder(theme.accent.opacity(0.7), lineWidth: 2) }
            .frame(width: 30, height: 30)
            .scaleEffect(pose.isDown ? 0.85 : 1.15)
            .opacity(pose.isDown ? 1 : 0)
            .offset(x: pose.x, y: 4)
    }
}
