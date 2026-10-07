/// The minimal text surface the keyboard edits. In the extension this wraps
/// `UITextDocumentProxy`; in tests and the companion app's preview it's `InMemoryTextDocument`.
@MainActor
public protocol TextDocument: AnyObject {
    /// Text before the cursor. The system proxy only exposes a limited window, and may return
    /// `nil` when the host provides no context.
    var contextBefore: String? { get }
    var contextAfter: String? { get }
    var selectedText: String? { get }

    func insert(_ text: String)
    /// Deletes one character (grapheme cluster) before the cursor, or the selection.
    func deleteBackward()
    /// Moves the cursor by `offset` UTF-16 code units, matching
    /// `UITextDocumentProxy.adjustTextPosition(byCharacterOffset:)`.
    func adjustCursor(byUTF16Offset offset: Int)
}

/// A complete in-memory document used by tests and the companion app's live preview.
@MainActor
public final class InMemoryTextDocument: TextDocument {
    public private(set) var before: String
    public private(set) var after: String
    public var onChange: ((InMemoryTextDocument) -> Void)?

    public var text: String { before + after }
    public var contextBefore: String? { before }
    public var contextAfter: String? { after }
    public var selectedText: String? { nil }

    public init(text: String = "", cursorAtEnd: Bool = true) {
        before = cursorAtEnd ? text : ""
        after = cursorAtEnd ? "" : text
    }

    public init(before: String, after: String) {
        self.before = before
        self.after = after
    }

    public func insert(_ text: String) {
        before += text
        onChange?(self)
    }

    public func deleteBackward() {
        guard !before.isEmpty else { return }
        before.removeLast()
        onChange?(self)
    }

    public func adjustCursor(byUTF16Offset offset: Int) {
        var remaining = abs(offset)
        while remaining > 0 {
            if offset < 0 {
                guard let character = before.popLast() else { break }
                after.insert(character, at: after.startIndex)
                remaining -= character.utf16.count
            } else {
                guard let character = after.first else { break }
                after.removeFirst()
                before.append(character)
                remaining -= character.utf16.count
            }
        }
        onChange?(self)
    }

    public func replaceAll(with text: String) {
        before = text
        after = ""
        onChange?(self)
    }
}
