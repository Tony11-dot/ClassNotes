import Foundation

/// Shelves inside shelves (D-007). Each shelf has at most one parent; `nil` is
/// the top of the library. Pure over ids, so the rules (no shelf inside
/// itself, what a shelf shows, what deleting one does) are pinned by tests
/// without a database.
public struct ShelfTree: Sendable, Equatable {
    /// Each shelf's parent, by id. A shelf whose parent is missing (deleted
    /// on another path, or a recovered library) counts as top level.
    public private(set) var parents: [UUID: UUID?]

    public init(_ shelves: [(id: UUID, parentID: UUID?)]) {
        var parents: [UUID: UUID?] = [:]
        for shelf in shelves { parents[shelf.id] = shelf.parentID }
        self.parents = parents
    }

    /// The parent that counts: nil when there is none or it no longer exists,
    /// or when following parents loops. A damaged store must neither hang the
    /// library nor hide shelves from it, so a shelf caught in a loop is shown
    /// at the top.
    public func parent(of id: UUID) -> UUID? {
        ancestors(of: id).first
    }

    /// Shelves directly inside `parent` (nil: the top level), in `order`.
    public func children(of parent: UUID?, in order: [UUID]) -> [UUID] {
        order.filter { self.parent(of: $0) == parent }
    }

    /// From the shelf's parent up to the top, nearest first. Empty for a
    /// shelf whose parents loop.
    public func ancestors(of id: UUID) -> [UUID] {
        var chain: [UUID] = []
        var seen: Set<UUID> = [id]
        var current = parents[id] ?? nil
        while let next = current, parents[next] != nil {
            guard seen.insert(next).inserted else { return [] }
            chain.append(next)
            current = parents[next] ?? nil
        }
        return chain
    }

    /// The shelf and every shelf inside it, at any depth.
    public func subtree(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var frontier = [id]
        while let next = frontier.popLast() {
            for child in parents.keys where parent(of: child) == next && !result.contains(child) {
                result.insert(child)
                frontier.append(child)
            }
        }
        return result
    }

    /// Whether `shelf` may go inside `newParent`: never inside itself or
    /// anything inside it, which would take it out of the library entirely.
    public func canMove(_ shelf: UUID, under newParent: UUID?) -> Bool {
        guard let newParent else { return true }
        return !subtree(of: shelf).contains(newParent)
    }
}

/// Tags on a notebook (D-007): free words the user chooses, compared without
/// case, shown as typed the first time.
public enum NotebookTags {
    public static let maximumLength = 32

    /// A tag as stored: trimmed, inner whitespace collapsed, a leading "#"
    /// dropped (people type them), and cut to `maximumLength`. Nil when
    /// nothing is left.
    public static func normalised(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("#") { text.removeFirst() }
        let words = text.split(whereSeparator: \.isWhitespace)
        let joined = words.joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        return String(joined.prefix(maximumLength))
    }

    /// `tags` with `raw` added, unless a tag differing only in case is
    /// already there.
    public static func adding(_ raw: String, to tags: [String]) -> [String] {
        guard let tag = normalised(raw), !contains(tag, in: tags) else { return tags }
        return tags + [tag]
    }

    public static func removing(_ tag: String, from tags: [String]) -> [String] {
        tags.filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
    }

    public static func contains(_ tag: String, in tags: [String]) -> Bool {
        tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    /// Every tag in use across `lists`, once each (first spelling wins),
    /// sorted for display.
    public static func all(in lists: [[String]]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for tag in lists.joined() where seen.insert(tag.lowercased()).inserted {
            result.append(tag)
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
