import LeanTypeCore
import LeanTypeDesign
import SwiftUI

/// First-run flow: meet LeanType, set it up, then try it with the real engine in-app.
struct OnboardingView: View {
    private enum Page: Int, CaseIterable {
        case welcome
        case setup
        case tryIt
    }

    @Environment(\.pebbleTheme) private var theme
    @State private var page = Page.welcome
    @State private var preview = PreviewKeyboardModel()

    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                WelcomePage().tag(Page.welcome)
                SetupPage().tag(Page.setup)
                TryItPage(preview: preview).tag(Page.tryIt)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            footer
        }
        .pebbleScreen()
    }

    private var footer: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                ForEach(Page.allCases, id: \.self) { item in
                    Capsule()
                        .fill(item == page ? theme.accent : theme.subtleInk.opacity(0.25))
                        .frame(width: item == page ? 22 : 8, height: 8)
                }
            }
            .animation(Motion.playfulSpring, value: page)
            .accessibilityElement()
            .accessibilityLabel("Page \(page.rawValue + 1) of \(Page.allCases.count)")

            Button(page == .tryIt ? "Start typing" : "Continue", action: advance)
                .buttonStyle(.pebble)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private func advance() {
        guard let next = Page(rawValue: page.rawValue + 1) else {
            onFinish()
            return
        }
        withAnimation(Motion.gentleSpring) { page = next }
    }
}

private struct WelcomePage: View {
    @Environment(\.pebbleTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            PebbleMark(size: 96)
                .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.9)
                .opacity(hasAppeared ? 1 : 0)
            VStack(spacing: 12) {
                Text("Meet LeanType")
                    .font(.pebble(.largeTitle, weight: .bold))
                    .foregroundStyle(theme.ink)
                Text("A soft, speedy keyboard built around your thumbs. Glide the cursor, sweep away words, and bring them right back.")
                    .font(.pebble(.title3))
                    .foregroundStyle(theme.subtleInk)
                    .multilineTextAlignment(.center)
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared || reduceMotion ? 0 : 8)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .onAppear {
            withAnimation(Motion.playfulSpring.delay(0.1)) { hasAppeared = true }
        }
    }
}

private struct SetupPage: View {
    @Environment(\.pebbleTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Add it in Settings")
                    .font(.pebble(.largeTitle, weight: .bold))
                    .foregroundStyle(theme.ink)
                    .padding(.top, 40)
                Text("iOS asks you to turn on new keyboards yourself. It takes about ten seconds.")
                    .font(.pebble(.title3))
                    .foregroundStyle(theme.subtleInk)
                SetupCard(showsTitle: false)
            }
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
    }
}

private struct TryItPage: View {
    @Environment(\.pebbleTheme) private var theme

    let preview: PreviewKeyboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Give it a spin")
                .font(.pebble(.largeTitle, weight: .bold))
                .foregroundStyle(theme.ink)
                .padding(.top, 40)
            Text("This is the real LeanType engine. Slide through hello — a trail means you’re swiping a word. Tap delete to remove a whole word, then swipe right on delete to bring it back.")
                .font(.pebble(.body))
                .foregroundStyle(theme.subtleInk)
            Spacer(minLength: 0)
            KeyboardPlayground(model: preview)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
