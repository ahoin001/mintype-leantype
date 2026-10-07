import LeanTypeCore
import SwiftUI

enum HomeDestination: Hashable {
    case themes
    case flair
    case gestures
    case settings
    case playground
}

struct HomeView: View {
    @Environment(\.pebbleTheme) private var theme
    @Environment(SetupStatusModel.self) private var setup
    @Environment(KeyboardDataModel.self) private var data
    @State private var preview = PreviewKeyboardModel()

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header

                if !setup.hasSeenFullAccess {
                    SetupCard()
                }

                VStack(spacing: 10) {
                    PebbleSectionHeader(title: "Try it right here")
                    KeyboardPlayground(model: preview, prompt: "Swipe a word, slide on space")
                }

                if setup.hasSeenFullAccess {
                    FlowStatsCard(stats: data.stats)
                }

                VStack(spacing: 14) {
                    LazyVGrid(columns: columns, spacing: 14) {
                        tile(.themes, icon: "paintpalette", title: "Themes", subtitle: theme.name)
                        tile(.flair, icon: "sparkles", title: "Flair", subtitle: "Trails and bursts")
                        tile(.gestures, icon: "hand.draw", title: "Gestures", subtitle: "The good stuff")
                        tile(.settings, icon: "slider.horizontal.3", title: "Settings", subtitle: "Make it yours")
                    }
                    NavigationLink(value: HomeDestination.playground) {
                        PebbleCard(padding: 16, cornerRadius: 24) {
                            PebbleLinkRow(systemImage: "text.cursor", title: "Playground", detail: "Type for real with LeanType")
                        }
                    }
                    .buttonStyle(PebblePressStyle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .pebbleScreen()
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: HomeDestination.self) { destination in
            switch destination {
            case .themes: ThemePickerView()
            case .flair: FlairView()
            case .gestures: GestureGuideView()
            case .settings: SettingsView()
            case .playground: PlaygroundView()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            PebbleMark(size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("LeanType")
                    .font(.pebble(.largeTitle, weight: .bold))
                    .foregroundStyle(theme.ink)
                Text("Soft keys for quick thumbs")
                    .font(.pebble(.subheadline, weight: .medium))
                    .foregroundStyle(theme.subtleInk)
            }
            Spacer()
        }
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
    }

    private func tile(_ destination: HomeDestination, icon: String, title: String, subtitle: String) -> some View {
        NavigationLink(value: destination) {
            PebbleCard(padding: 16, cornerRadius: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    PebbleIcon(systemName: icon)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.pebble(.headline, weight: .bold))
                            .foregroundStyle(theme.ink)
                        Text(subtitle)
                            .font(.pebble(.footnote, weight: .medium))
                            .foregroundStyle(theme.subtleInk)
                            .lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(PebblePressStyle())
    }
}
