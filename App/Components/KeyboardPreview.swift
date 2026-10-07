import LeanTypeCore
import LeanTypeDesign
import LeanTypeKeyboardUI
import Observation
import SwiftUI

/// Drives the real keyboard engine against an in-memory document, so the app can show (and
/// let people try) the exact keyboard they'll get, in any theme.
@MainActor
@Observable
final class PreviewKeyboardModel {
    private(set) var textBeforeCursor = ""
    private(set) var textAfterCursor = ""

    @ObservationIgnored let engine: KeyboardEngine
    @ObservationIgnored private let document: InMemoryTextDocument

    init(settings: KeyboardSettings, placeholder: String = "") {
        let document = InMemoryTextDocument(text: placeholder)
        self.document = document
        engine = KeyboardEngine(document: document, settings: settings, showsNextKeyboardKey: false)
        textBeforeCursor = document.before
        document.onChange = { [weak self] document in
            self?.textBeforeCursor = document.before
            self?.textAfterCursor = document.after
        }
    }

    var isEmpty: Bool {
        textBeforeCursor.isEmpty && textAfterCursor.isEmpty
    }

    func update(settings: KeyboardSettings) {
        engine.update(settings: settings)
    }

    func clear() {
        document.replaceAll(with: "")
        engine.reset()
    }
}

/// Hosts a live `KeyboardView` in SwiftUI at its natural height.
struct KeyboardPreview: UIViewRepresentable {
    let model: PreviewKeyboardModel
    let theme: Theme
    var hapticsEnabled = true

    func makeUIView(context _: Context) -> KeyboardView {
        let view = KeyboardView(
            engine: model.engine,
            theme: theme,
            feedback: FeedbackCoordinator(hapticsEnabled: hapticsEnabled, clicksEnabled: false)
        )
        view.metricsOverride = .portrait
        view.feedback.prepare()
        return view
    }

    func updateUIView(_ view: KeyboardView, context _: Context) {
        view.theme = theme
        view.feedback.hapticsEnabled = hapticsEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: KeyboardView, context _: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 390, height: uiView.preferredHeight)
    }
}

/// The preview keyboard inside a rounded frame, with the typed text above it and a caret.
struct KeyboardPlayground: View {
    @Environment(\.pebbleTheme) private var theme
    @Environment(SettingsModel.self) private var settings

    let model: PreviewKeyboardModel
    var prompt = "Try typing here"

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                typedText
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
                if !model.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { model.clear() }
                        .labelStyle(.iconOnly)
                        .font(.system(size: 18))
                        .foregroundStyle(theme.subtleInk.opacity(0.6))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            KeyboardPreview(model: model, theme: theme, hapticsEnabled: settings.settings.hapticsEnabled)
        }
        .background(theme.surface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(theme.surfaceRim, lineWidth: 1)
        }
        .shadow(color: theme.shadow.opacity(0.7), radius: 18, y: 8)
        .onChange(of: settings.settings) { _, new in model.update(settings: new) }
    }

    private var typedText: some View {
        let caret = Text("|").foregroundStyle(theme.accent).fontWeight(.bold)
        return Group {
            if model.isEmpty {
                Text("\(caret)\(Text(prompt).foregroundStyle(theme.subtleInk.opacity(0.7)))")
            } else {
                let before = Text(model.textBeforeCursor).foregroundStyle(theme.ink)
                let after = Text(model.textAfterCursor).foregroundStyle(theme.ink)
                Text("\(before)\(caret)\(after)")
            }
        }
        .font(.pebble(.title3))
        .lineLimit(3)
        .accessibilityLabel(model.isEmpty ? prompt : model.textBeforeCursor + model.textAfterCursor)
    }
}
