/// Remembers recently deleted characters so a backspace scrub can be reversed one character
/// at a time, or a whole deleted word restored at once.
///
/// Deletions are grouped: a word delete is one group, and a run of single-character deletes
/// extends the latest group. Capacity is bounded so a long hold-to-delete can't grow memory.
struct DeletionBuffer {
    static let capacity = 512

    /// Each group stores characters in deletion order (the character nearest the cursor last).
    private var groups: [[Character]] = []
    private var characterCount = 0

    var isEmpty: Bool { groups.isEmpty }

    mutating func record(_ deleted: [Character], extendingLastGroup: Bool) {
        guard !deleted.isEmpty else { return }
        if extendingLastGroup, !groups.isEmpty {
            groups[groups.count - 1].append(contentsOf: deleted)
        } else {
            groups.append(deleted)
        }
        characterCount += deleted.count
        trimToCapacity()
    }

    /// Removes and returns the most recently deleted character.
    mutating func popCharacter() -> Character? {
        guard var last = groups.popLast(), let character = last.popLast() else { return nil }
        if !last.isEmpty {
            groups.append(last)
        }
        characterCount -= 1
        return character
    }

    /// Removes and returns the most recent group as text in reading order.
    mutating func popGroup() -> String? {
        guard let last = groups.popLast() else { return nil }
        characterCount -= last.count
        return String(last.reversed())
    }

    mutating func removeAll() {
        groups.removeAll(keepingCapacity: false)
        characterCount = 0
    }

    private mutating func trimToCapacity() {
        while characterCount > Self.capacity, !groups.isEmpty {
            let overflow = characterCount - Self.capacity
            if groups[0].count <= overflow {
                characterCount -= groups.removeFirst().count
            } else {
                groups[0].removeFirst(overflow)
                characterCount -= overflow
            }
        }
    }
}
