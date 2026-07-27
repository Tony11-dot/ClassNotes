import ClassMateTheme
import SwiftUI

/// Renders NOVA's reply as formatted text.
///
/// Answers come back as Markdown. Dropping that into a `Text` printed the syntax
/// — `**like this**` — so replies looked like source code. This lays the reply out
/// block by block (headings, bullets, numbered steps, quotes, code, rules) and
/// resolves inline `**bold**`, `*italic*`, `` `code` `` and links through
/// `AttributedString`, so nothing is left showing its markers.
public struct NovaMarkdownText: View {
    @Environment(\.theme) private var theme

    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(NovaMarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: NovaMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let body):
            inline(body)
        case .heading(let level, let body):
            inline(body)
                .font(level <= 1 ? .headline : .subheadline)
                .fontWeight(.bold)
                .padding(.top, 2)
        case .bullet(let depth, let body):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(depth > 0 ? "◦" : "•")
                    .foregroundStyle(theme.accent.color)
                inline(body)
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .numbered(let number, let body):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.accent.color)
                    .monospacedDigit()
                inline(body)
            }
        case .quote(let body):
            HStack(alignment: .top, spacing: 10) {
                Capsule().fill(theme.accent.color).frame(width: 3)
                inline(body).foregroundStyle(theme.inkSecondary.color)
            }
        case .code(let body):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(body)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(10)
            }
            .background(
                theme.surfaceRaised.color,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        case .rule:
            Divider().overlay(theme.separator.color)
        }
    }

    /// One run of inline Markdown. `AttributedString` handles emphasis, code spans
    /// and links; if the line isn't valid Markdown it renders verbatim rather than
    /// disappearing.
    private func inline(_ body: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: body,
            options: AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            return Text(attributed)
        }
        return Text(body)
    }
}

/// One laid-out piece of a Markdown reply. Parsing is pure so the block rules are
/// pinned by tests rather than eyeballed in a chat.
public enum NovaMarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, String)
    case bullet(depth: Int, String)
    case numbered(Int, String)
    case quote(String)
    case code(String)
    case rule

    public static func parse(_ text: String) -> [NovaMarkdownBlock] {
        var blocks: [NovaMarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String]?

        func flushParagraph() {
            let joined = paragraph.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code: everything between ``` markers is kept verbatim.
            if trimmed.hasPrefix("```") {
                if let open = codeLines {
                    blocks.append(.code(open.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    flushParagraph()
                    codeLines = []
                }
                continue
            }
            if codeLines != nil {
                codeLines?.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                continue
            }
            if let heading = headingLevel(of: trimmed) {
                flushParagraph()
                let body = trimmed.dropFirst(heading)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " #"))
                blocks.append(.heading(level: heading, body))
                continue
            }
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if let bullet = bulletBody(of: trimmed) {
                flushParagraph()
                // Indentation nests the list one level; two spaces is enough.
                let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
                blocks.append(.bullet(depth: indent >= 2 ? 1 : 0, bullet))
                continue
            }
            if let (number, body) = numberedBody(of: trimmed) {
                flushParagraph()
                blocks.append(.numbered(number, body))
                continue
            }
            paragraph.append(trimmed)
        }

        // An unterminated fence (still streaming) still shows what's arrived.
        if let open = codeLines, !open.isEmpty {
            blocks.append(.code(open.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    /// `#`…`######` → 1…6, or nil when the line isn't a heading. A `#` with no
    /// space after it is a hashtag, not a heading.
    private static func headingLevel(of line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard hashes >= 1, hashes <= 6 else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return hashes
    }

    /// The text after a `-`, `*`, `+` or `•` bullet marker.
    private static func bulletBody(of line: String) -> String? {
        for marker in ["- ", "* ", "+ ", "• ", "◦ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// `1. step` / `2) step` → (1, "step").
    private static func numberedBody(of line: String) -> (Int, String)? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 2, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let separator = rest.first, separator == "." || separator == ")" else { return nil }
        let body = rest.dropFirst()
        guard body.first == " " else { return nil }
        return (number, String(body).trimmingCharacters(in: .whitespaces))
    }
}
