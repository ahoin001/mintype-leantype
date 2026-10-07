import LeanTypeCore
import LeanTypeDesign
import LeanTypeKeyboardUI
import Observation
import SwiftUI

/// One dictionary for every preview in the app. It's memory-mapped, so sharing it costs nothing
/// and previews never learn words.
@MainActor
enum PreviewLanguage {
    static let shared = LanguageModel.bundled()
}

/// Drives the real keyboard engine against an in-memory document, so the app can show (and
/// let people try) the exact keyboard they'll get, in any theme. Settings flow in through
/// `KeyboardPreview`, which applies them to the whole keyboard surface.
@MainActor
@Observable
final class PreviewKeyboardModel {
    private(set) var textBeforeCursor = ""
    private(set) var textAfterCursor = ""

    @ObservationIgnored let engine: KeyboardEngine
    @ObservationIgnored private let document: InMemoryTextDocument

    init(placeholder: String = "") {
        let document = InMemoryTextDocument(text: placeholder)
        self.document = document
        engine = KeyboardEngine(document: document, showsNextKeyboardKey: false, language: PreviewLanguage.shared)
        textBeforeCursor = document.before
        document.onChange = { [weak self] document in
            self?.textBeforeCursor = document.before
            self?.textAfterCursor = document.after
        }
    }

    var isEmpty: Bool {
        textBeforeCursor.isEmpty && textAfterCursor.isEmpty
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
    let settings: KeyboardSettings

    func makeUIView(context _: Context) -> KeyboardView {
        let view = KeyboardView(
            engine: model.engine,
            theme: theme,
            feedback: FeedbackCoordinator(hapticsEnabled: settings.hapticsEnabled, clicksEnabled: false)
        )
        view.metricsOverride = .portrait
        view.update(settings: settings)
        view.feedback.prepare()
        view.keyboardWillAppear()
        return view
    }

    func updateUIView(_ view: KeyboardView, context _: Context) {
        view.theme = theme
        view.feedback.hapticsEnabled = settings.hapticsEnabled
        if view.engine.settings != settings {
            view.update(settings: settings)
            view.invalidateIntrinsicContentSize()
        }
    }

    static func dismantleUIView(_ view: KeyboardView, coordinator _: ()) {
        view.keyboardDidDisappear()
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

            KeyboardPreview(model: model, theme: theme, settings: settings.settings)
        }
        .background(theme.surface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(theme.surfaceRim, lineWidth: 1)
        }
        .shadow(color: theme.shadow.opacity(0.7), radius: 18, y: 8)
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
