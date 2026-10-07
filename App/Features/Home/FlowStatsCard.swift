import LeanTypeCore
import SwiftUI

/// A glance at how typing has gone this week. Counts only; the keyboard never records text.
struct FlowStatsCard: View {
    @Environment(\.pebbleTheme) private var theme

    let stats: FlowStats

    var body: some View {
        PebbleCard(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    PebbleIcon(systemName: "wind", size: 30)
                    Text("Your flow")
                        .font(.pebble(.headline, weight: .bold))
                        .foregroundStyle(theme.ink)
                    Spacer()
                    Label("On this phone only", systemImage: "lock.fill")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.subtleInk.opacity(0.6))
                }

                if stats.isEmpty {
                    Text("Type a little with LeanType and your week shows up here.")
                        .font(.pebble(.subheadline))
                        .foregroundStyle(theme.subtleInk)
                } else {
                    sparkline
                    HStack(alignment: .top, spacing: 8) {
                        stat(stats.wordsThisWeek(), label: "words this week")
                        stat(stats.longestStreak, label: "longest clean streak")
                        stat(stats.wordsRestored, label: "words saved by undo")
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Seven bars, oldest at the left, today at the right. The tallest day fills the row.
    private var sparkline: some View {
        let today = FlowStats.day(of: .now)
        let counts = (0..<7).map { stats.wordsByDay[today - (6 - $0), default: 0] }
        let peak = max(counts.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(counts.enumerated()), id: \.offset) { index, count in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(index == counts.count - 1 ? theme.accent : theme.accent.opacity(0.35))
                    .frame(height: max(4, 36 * CGFloat(count) / CGFloat(peak)))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 36)
        .accessibilityLabel("Words over the last seven days")
    }

    private func stat(_ value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number.notation(.compactName))
                .font(.pebble(.title2, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(theme.accent)
                .contentTransition(.numericText(value: Double(value)))
            Text(label)
                .font(.pebble(.caption, weight: .medium))
                .foregroundStyle(theme.subtleInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
