import Foundation

/// A language a code block can be labelled and coloured as. Deliberately a
/// short, curated list — not every language anyone might write, just enough
/// that a note reads as the language it actually is.
public enum CodeLanguage: String, Sendable, CaseIterable, Identifiable, Codable {
    case swift, python, javascript, typescript, java, c, cpp, html, json, plaintext

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .swift: "Swift"
        case .python: "Python"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .java: "Java"
        case .c: "C"
        case .cpp: "C++"
        case .html: "HTML"
        case .json: "JSON"
        case .plaintext: "Plain text"
        }
    }

    fileprivate var keywords: Set<String> {
        switch self {
        case .swift:
            [
                "func", "var", "let", "if", "else", "guard", "return", "struct", "class", "enum",
                "case", "for", "while", "in", "import", "public", "private", "internal", "static",
                "extension", "protocol", "init", "self", "Self", "nil", "true", "false", "switch",
                "default", "break", "continue", "throw", "throws", "try", "catch", "async", "await",
                "where", "as", "is", "override", "final", "mutating", "typealias", "some", "any"
            ]
        case .python:
            [
                "def", "class", "if", "elif", "else", "for", "while", "in", "import", "from", "as",
                "return", "yield", "try", "except", "finally", "with", "lambda", "None", "True",
                "False", "and", "or", "not", "is", "pass", "break", "continue", "global",
                "nonlocal", "raise", "async", "await", "self"
            ]
        case .javascript, .typescript:
            [
                "function", "var", "let", "const", "if", "else", "for", "while", "in", "of",
                "return", "class", "extends", "new", "this", "import", "export", "from", "as",
                "try", "catch", "finally", "throw", "async", "await", "typeof", "instanceof",
                "null", "undefined", "true", "false", "switch", "case", "default", "break",
                "continue", "interface", "type", "implements", "public", "private"
            ]
        case .java, .c, .cpp:
            [
                "int", "float", "double", "char", "void", "if", "else", "for", "while", "return",
                "class", "public", "private", "protected", "static", "final", "new", "this",
                "import", "package", "try", "catch", "finally", "throw", "throws", "switch",
                "case", "default", "break", "continue", "struct", "enum", "namespace", "template",
                "typename", "const", "null", "true", "false", "include", "define", "using",
                "bool", "long", "short", "unsigned", "auto"
            ]
        case .html, .json, .plaintext:
            []
        }
    }

    fileprivate var lineCommentPrefixes: [String] {
        switch self {
        case .swift, .javascript, .typescript, .java, .c, .cpp: ["//"]
        case .python: ["#"]
        case .html, .json, .plaintext: []
        }
    }

    fileprivate var blockComment: (open: String, close: String)? {
        switch self {
        case .swift, .javascript, .typescript, .java, .c, .cpp: ("/*", "*/")
        case .html: ("<!--", "-->")
        case .python, .json, .plaintext: nil
        }
    }

    /// Whether bare `"..."` / `'...'` runs should read as string literals.
    fileprivate var hasStringLiterals: Bool { self != .plaintext && self != .html }
}

/// What a stretch of source reads as, for colouring.
public enum CodeTokenKind: Sendable, Equatable {
    case keyword
    case string
    case comment
    case number
    case plain
}

public struct CodeToken: Sendable, Equatable {
    public let range: Range<String.Index>
    public let kind: CodeTokenKind
}

/// Lightweight, dependency-free syntax colouring.
///
/// Not a real parser — a single left-to-right scan that recognizes comments,
/// string literals, numbers and a per-language keyword list, in that priority
/// order. A handwritten note's few lines of code don't need a real compiler
/// front-end to read as code rather than a wall of plain text, and this needs
/// no third-party package to keep working with no network at all.
public enum CodeSyntaxHighlighter {
    /// Tokenizes `text` for `language`. The returned tokens cover the WHOLE
    /// string with no gaps — anything not otherwise classified is `.plain`.
    public static func tokens(for text: String, language: CodeLanguage) -> [CodeToken] {
        guard !text.isEmpty else { return [] }
        guard language != .plaintext else {
            return [CodeToken(range: text.startIndex..<text.endIndex, kind: .plain)]
        }
        var tokens: [CodeToken] = []
        var index = text.startIndex
        var plainStart = index

        func flushPlain(upTo end: String.Index) {
            guard plainStart < end else { return }
            tokens.append(CodeToken(range: plainStart..<end, kind: .plain))
        }

        while index < text.endIndex {
            // Line comment.
            if let prefix = language.lineCommentPrefixes.first(where: { text[index...].hasPrefix($0) }) {
                flushPlain(upTo: index)
                let end = text[index...].firstIndex(of: "\n") ?? text.endIndex
                tokens.append(CodeToken(range: index..<end, kind: .comment))
                index = end
                plainStart = index
                _ = prefix
                continue
            }
            // Block comment.
            if let block = language.blockComment, text[index...].hasPrefix(block.open) {
                flushPlain(upTo: index)
                let searchStart = text.index(index, offsetBy: block.open.count, limitedBy: text.endIndex) ?? text.endIndex
                let closeRange = text.range(of: block.close, range: searchStart..<text.endIndex)
                let end = closeRange?.upperBound ?? text.endIndex
                tokens.append(CodeToken(range: index..<end, kind: .comment))
                index = end
                plainStart = index
                continue
            }
            // String literal.
            if language.hasStringLiterals, "\"'`".contains(text[index]) {
                let quote = text[index]
                flushPlain(upTo: index)
                var end = text.index(after: index)
                while end < text.endIndex {
                    let c = text[end]
                    if c == "\\" {
                        end = text.index(end, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                        continue
                    }
                    if c == quote {
                        end = text.index(after: end)
                        break
                    }
                    if c == "\n" { break } // an unterminated string ends at the line
                    end = text.index(after: end)
                }
                tokens.append(CodeToken(range: index..<end, kind: .string))
                index = end
                plainStart = index
                continue
            }
            // Number.
            if text[index].isNumber, isWordBoundary(text, before: index) {
                flushPlain(upTo: index)
                var end = index
                while end < text.endIndex, text[end].isNumber || text[end] == "." || text[end] == "_" {
                    end = text.index(after: end)
                }
                tokens.append(CodeToken(range: index..<end, kind: .number))
                index = end
                plainStart = index
                continue
            }
            // Identifier / keyword.
            if text[index].isLetter || text[index] == "_" {
                var end = index
                while end < text.endIndex, text[end].isLetter || text[end].isNumber || text[end] == "_" {
                    end = text.index(after: end)
                }
                let word = String(text[index..<end])
                if language.keywords.contains(word) {
                    flushPlain(upTo: index)
                    tokens.append(CodeToken(range: index..<end, kind: .keyword))
                    plainStart = end
                }
                index = end
                continue
            }
            index = text.index(after: index)
        }
        flushPlain(upTo: text.endIndex)
        return tokens
    }

    private static func isWordBoundary(_ text: String, before index: String.Index) -> Bool {
        guard index > text.startIndex else { return true }
        let previous = text[text.index(before: index)]
        return !(previous.isLetter || previous.isNumber || previous == "_")
    }
}
