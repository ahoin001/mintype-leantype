import LeanTypeCore
import UIKit

/// Adapts the system's `UITextDocumentProxy` to Core's `TextDocument`.
@MainActor
public final class TextDocumentProxyAdapter: TextDocument {
    private let proxy: any UITextDocumentProxy

    public init(proxy: any UITextDocumentProxy) {
        self.proxy = proxy
    }

    public private(set) var typedComposing = ""
    public private(set) var previewComposing = ""
    private var marked = ""

    public var contextBefore: String? {
        guard var before = proxy.documentContextBeforeInput else { return nil }
        let mark = typedComposing.isEmpty ? previewComposing : typedComposing
        if !mark.isEmpty, before.hasSuffix(mark) {
            before.removeLast(mark.count)
        }
        return before
    }

    public var contextAfter: String? { proxy.documentContextAfterInput }
    public var selectedText: String? { proxy.selectedText }

    public func insert(_ text: String) {
        proxy.insertText(text)
    }

    public func deleteBackward() {
        guard typedComposing.isEmpty else {
            typedComposing.removeLast()
            publishMark()
            return
        }
        proxy.deleteBackward()
    }

    public func adjustCursor(byUTF16Offset offset: Int) {
        flushTypedComposing()
        proxy.adjustTextPosition(byCharacterOffset: offset)
    }

    public func setTypedComposing(_ text: String) {
        typedComposing = text
        publishMark()
    }

    public func setPreviewComposing(_ text: String) {
        previewComposing = text
        publishMark()
    }

    public func flushTypedComposing() {
        let text = typedComposing
        typedComposing = ""
        publishMark()
        if !text.isEmpty { proxy.insertText(text) }
    }

    private func publishMark() {
        let shown = typedComposing.isEmpty ? previewComposing : typedComposing
        guard shown != marked else { return }
        marked = shown
        let end = shown.utf16.count
        proxy.setMarkedText(shown, selectedRange: NSRange(location: end, length: 0))
    }
}

public extension InputTraits {
    /// Snapshot of the host field's traits.
    @MainActor
    init(proxy: any UITextDocumentProxy) {
        self.init(
            variant: KeyboardVariant(proxy.keyboardType ?? .default),
            autocapitalization: AutocapitalizationMode(proxy.autocapitalizationType ?? .sentences),
            returnKey: ReturnKeyKind(proxy.returnKeyType ?? .default),
            enablesReturnKeyAutomatically: proxy.enablesReturnKeyAutomatically ?? false,
            allowsAutocorrection: proxy.autocorrectionType != .no,
            blocksLexicalEntry: proxy.isSecureTextEntry == true
                || proxy.textContentType.map(Self.isExactEntry) == true
        )
    }

    /// Usernames, passwords, and one-time codes must reach the field exactly as typed.
    private static func isExactEntry(_ type: UITextContentType) -> Bool {
        [.username, .password, .newPassword, .oneTimeCode].contains(type)
    }
}

extension KeyboardVariant {
    init(_ type: UIKeyboardType) {
        switch type {
        case .emailAddress: self = .email
        case .URL, .webSearch: self = .url
        case .numberPad, .phonePad, .decimalPad, .numbersAndPunctuation, .asciiCapableNumberPad: self = .numeric
        default: self = .standard
        }
    }
}

extension AutocapitalizationMode {
    init(_ type: UITextAutocapitalizationType) {
        switch type {
        case .none: self = .none
        case .words: self = .words
        case .allCharacters: self = .allCharacters
        default: self = .sentences
        }
    }
}

extension ReturnKeyKind {
    init(_ type: UIReturnKeyType) {
        switch type {
        case .go: self = .go
        case .google, .yahoo, .search: self = .search
        case .join: self = .join
        case .next: self = .next
        case .route: self = .route
        case .send: self = .send
        case .done: self = .done
        case .emergencyCall: self = .emergencyCall
        case .continue: self = .continue
        default: self = .default
        }
    }
}
