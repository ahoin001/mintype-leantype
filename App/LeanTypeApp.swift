import LeanTypeCore
import LeanTypeDesign
import SwiftUI

@main
struct LeanTypeApp: App {
    @State private var settings = SettingsModel()
    @State private var setup = SetupStatusModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(setup)
        }
    }
}

struct RootView: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(SetupStatusModel.self) private var setup
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        let selection = settings.settings.theme
        let theme = ThemeCatalog.theme(for: selection, prefersDark: colorScheme == .dark)

        NavigationStack {
            HomeView()
        }
        .tint(theme.accent)
        .environment(\.pebbleTheme, theme)
        .preferredColorScheme(selection == .automatic ? nil : theme.colorScheme)
        .fullScreenCover(isPresented: showsOnboarding) {
            OnboardingView { hasCompletedOnboarding = true }
                .environment(\.pebbleTheme, theme)
                .tint(theme.accent)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { setup.refresh() }
        }
    }

    private var showsOnboarding: Binding<Bool> {
        Binding(
            get: { !hasCompletedOnboarding },
            set: { hasCompletedOnboarding = !$0 }
        )
    }
}
