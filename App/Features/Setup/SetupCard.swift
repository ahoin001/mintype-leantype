import SwiftUI

/// Guides the two steps iOS requires before LeanType can be used: adding the keyboard and
/// allowing Full Access. Both live behind the app's page in the Settings app.
struct SetupCard: View {
    @Environment(\.pebbleTheme) private var theme
    @Environment(SetupStatusModel.self) private var setup
    @Environment(\.openURL) private var openURL

    var showsTitle = true

    var body: some View {
        PebbleCard {
            VStack(alignment: .leading, spacing: 16) {
                if showsTitle {
                    Text("Finish setting up")
                        .font(.pebble(.title3, weight: .bold))
                        .foregroundStyle(theme.ink)
                }

                SetupStep(number: 1, title: "Open Settings, then tap Keyboards", isDone: setup.hasSeenFullAccess)
                SetupStep(number: 2, title: "Turn on LeanType", isDone: setup.hasSeenFullAccess)
                SetupStep(number: 3, title: "Turn on Allow Full Access", isDone: setup.hasSeenFullAccess)

                Label {
                    Text("Full Access lets LeanType use haptics, sync your settings, and remember your words. "
                        + "LeanType has no network code: what you type never leaves your iPhone.")
                } icon: {
                    Image(systemName: "lock.shield")
                }
                .font(.pebble(.footnote))
                .foregroundStyle(theme.subtleInk)

                Button("Open Settings", action: openSettings)
                    .buttonStyle(.pebble)
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

private struct SetupStep: View {
    @Environment(\.pebbleTheme) private var theme

    let number: Int
    let title: String
    let isDone: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isDone ? theme.accent : theme.chip)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(theme.onAccent)
                } else {
                    Text("\(number)")
                        .font(.pebble(.footnote, weight: .bold))
                        .foregroundStyle(theme.chipInk)
                }
            }
            .frame(width: 26, height: 26)

            Text(title)
                .font(.pebble(.body, weight: .medium))
                .foregroundStyle(theme.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isDone ? "Done" : "Not done")
    }
}
