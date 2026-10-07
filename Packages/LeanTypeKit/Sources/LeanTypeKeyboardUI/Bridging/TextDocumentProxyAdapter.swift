import LeanTypeCore
import UIKit

/// Adapts the system's `UITextDocumentProxy` to Core's `TextDocument`.
@MainActor
public final class TextDocumentProxyAdapter: TextDocument {
    private let proxy: any UITextDocumentProxy

    public init(proxy: any UITextDocumentProxy) {
        self.proxy = proxy
    }

    public var contextBefore: String? { proxy.documentContextBeforeInput }
    public var contextAfter: String? { proxy.documentContextAfterInput }
    public var selectedText: String? { proxy.selectedText }

    public func insert(_ text: String) {
        proxy.insertText(text)
    }

    public func deleteBackward() {
        proxy.deleteBackward()
    }

    public func adjustCursor(byUTF16Offset offset: Int) {
        proxy.adjustTextPosition(byCharacterOffset: offset)
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
            allowsAutocorrection: proxy.autocorrectionType != .no
                && proxy.isSecureTextEntry != true
                && proxy.textContentType.map(Self.isCredential) != true
        )
    }

    /// Usernames, passwords, and one-time codes must reach the field exactly as typed.
    private static func isCredential(_ type: UITextContentType) -> Bool {
        [.username, .password, .newPassword, .oneTimeCode, .emailAddress, .URL].contains(type)
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
