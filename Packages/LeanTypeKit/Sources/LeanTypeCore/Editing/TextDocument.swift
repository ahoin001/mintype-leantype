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

    /// Letters typed but not yet committed. They belong to the open word.
    var typedComposing: String { get }
    /// The swipe's current reading, shown until the finger lifts. It is not part of the word.
    var previewComposing: String { get }
    /// How many characters of the active mark sit before the caret. The end, until a trackpad step moves in.
    var markCaret: Int { get }
    func setTypedComposing(_ text: String, caret: Int)
    func setPreviewComposing(_ text: String, caret: Int)
    func setMarkCaret(_ index: Int)
    /// Moves the held letters into the document.
    func flushTypedComposing()
}

public extension TextDocument {
    /// The marked string on screen: held letters, or the swipe ghost when nothing is held.
    var activeMark: String {
        typedComposing.isEmpty ? previewComposing : typedComposing
    }

    func setTypedComposing(_ text: String) {
        setTypedComposing(text, caret: text.count)
    }

    func setPreviewComposing(_ text: String) {
        setPreviewComposing(text, caret: text.count)
    }
}

/// A complete in-memory document used by tests and the companion app's live preview.
@MainActor
public final class InMemoryTextDocument: TextDocument {
    public private(set) var before: String
    public private(set) var after: String
    public private(set) var typedComposing = ""
    public private(set) var previewComposing = ""
    public private(set) var markCaret = 0
    public var onChange: ((InMemoryTextDocument) -> Void)?

    public var text: String {
        let ghost = typedComposing.isEmpty ? previewComposing : typedComposing
        return before + ghost + after
    }
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
        if !typedComposing.isEmpty, markCaret > 0 {
            var characters = Array(typedComposing)
            characters.remove(at: markCaret - 1)
            setTypedComposing(String(characters), caret: markCaret - 1)
            return
        }
        guard !before.isEmpty else { return }
        before.removeLast()
        onChange?(self)
    }

    public func adjustCursor(byUTF16Offset offset: Int) {
        flushTypedComposing()
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

    public func setTypedComposing(_ text: String, caret: Int) {
        let next = min(max(0, caret), text.count)
        guard typedComposing != text || markCaret != next else { return }
        typedComposing = text
        markCaret = next
        onChange?(self)
    }

    public func setPreviewComposing(_ text: String, caret: Int) {
        let next = min(max(0, caret), text.count)
        guard previewComposing != text || markCaret != next else { return }
        previewComposing = text
        markCaret = next
        onChange?(self)
    }

    public func setMarkCaret(_ index: Int) {
        let next = min(max(0, index), activeMark.count)
        guard markCaret != next else { return }
        markCaret = next
        onChange?(self)
    }

    public func flushTypedComposing() {
        let text = typedComposing
        guard !text.isEmpty else { return }
        typedComposing = ""
        markCaret = previewComposing.count
        before += text
        onChange?(self)
    }

    public func replaceAll(with text: String) {
        typedComposing = ""
        previewComposing = ""
        markCaret = 0
        before = text
        after = ""
        onChange?(self)
    }
}
