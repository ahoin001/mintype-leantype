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
    public private(set) var markCaret = 0
    private var marked = ""
    private var markedCaret = 0

    public var contextBefore: String? {
        guard var before = proxy.documentContextBeforeInput else { return nil }
        let mark = typedComposing.isEmpty ? previewComposing : typedComposing
        guard !mark.isEmpty else { return before }
        var prefix = Substring(mark)
        while !prefix.isEmpty {
            if before.hasSuffix(prefix) {
                before.removeLast(prefix.count)
                break
            }
            prefix.removeLast()
        }
        return before
    }

    public var contextAfter: String? { proxy.documentContextAfterInput }
    public var selectedText: String? { proxy.selectedText }

    public func insert(_ text: String) {
        proxy.insertText(text)
    }

    public func deleteBackward() {
        if !typedComposing.isEmpty, markCaret > 0 {
            var characters = Array(typedComposing)
            characters.remove(at: markCaret - 1)
            setTypedComposing(String(characters), caret: markCaret - 1)
            return
        }
        proxy.deleteBackward()
    }

    public func adjustCursor(byUTF16Offset offset: Int) {
        flushTypedComposing()
        proxy.adjustTextPosition(byCharacterOffset: offset)
    }

    public func setTypedComposing(_ text: String, caret: Int) {
        typedComposing = text
        markCaret = min(max(0, caret), text.count)
        publishMark()
    }

    public func setPreviewComposing(_ text: String, caret: Int) {
        previewComposing = text
        markCaret = min(max(0, caret), text.count)
        publishMark()
    }

    public func setMarkCaret(_ index: Int) {
        markCaret = min(max(0, index), activeMark.count)
        publishMark()
    }

    public func flushTypedComposing() {
        let text = typedComposing
        guard !text.isEmpty else { return }
        typedComposing = ""
        markCaret = previewComposing.count
        publishMark()
        proxy.insertText(text)
    }

    /// An empty string clears a swipe ghost. `unmarkText` would commit it.
    private func publishMark() {
        let shown = typedComposing.isEmpty ? previewComposing : typedComposing
        let caret = min(markCaret, shown.count)
        let utf16 = shown.prefix(caret).utf16.count
        guard shown != marked || utf16 != markedCaret else { return }
        marked = shown
        markedCaret = utf16
        proxy.setMarkedText(shown, selectedRange: NSRange(location: utf16, length: 0))
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
