import ClassMateTheme
import NotesModels
import SwiftUI

/// Turns a code block's plain text into a coloured `AttributedString` — the
/// "colourful code" look every AI assistant's code output already has.
///
/// Built by concatenating one `AttributedString` per token rather than
/// slicing ranges out of a whole-string `AttributedString`: `CodeToken`'s
/// ranges are `String.Index`, not `AttributedString.Index`, and building
/// substring-by-substring sidesteps that conversion entirely. Shared by the
/// editor's own code-block element and the read-only viewer
/// (`PageContentView`) so a note looks the same colours on both.
public enum CodeBlockText {
    public static func attributed(
        _ text: String, language: CodeLanguage, plainColor: ThemeColor, background: ThemeColor
    ) -> AttributedString {
        guard !text.isEmpty else { return AttributedString() }
        guard language != .plaintext else {
            var plain = AttributedString(text)
            plain.foregroundColor = plainColor.color
            return plain
        }
        let palette = Palette.forBackground(background)
        var result = AttributedString()
        for token in CodeSyntaxHighlighter.tokens(for: text, language: language) {
            var piece = AttributedString(String(text[token.range]))
            piece.foregroundColor = palette.color(for: token.kind, plain: plainColor)
            result += piece
        }
        return result
    }

    private struct Palette {
        let keyword: ThemeColor
        let string: ThemeColor
        let comment: ThemeColor
        let number: ThemeColor

        func color(for kind: CodeTokenKind, plain: ThemeColor) -> Color {
            switch kind {
            case .keyword: keyword.color
            case .string: string.color
            case .comment: comment.color
            case .number: number.color
            case .plain: plain.color
            }
        }

        static func forBackground(_ background: ThemeColor) -> Palette {
            background.relativeLuminance < 0.5 ? dark : light
        }

        /// VS Code's own "Dark+" palette — the look an AI assistant's code
        /// block already borrows, so a note's code block reads the same way.
        static let dark = Palette(
            keyword: ThemeColor(hex: "#C586C0") ?? ThemeColor(red: 0.77, green: 0.53, blue: 0.75),
            string: ThemeColor(hex: "#CE9178") ?? ThemeColor(red: 0.81, green: 0.57, blue: 0.47),
            comment: ThemeColor(hex: "#6A9955") ?? ThemeColor(red: 0.42, green: 0.6, blue: 0.33),
            number: ThemeColor(hex: "#B5CEA8") ?? ThemeColor(red: 0.71, green: 0.81, blue: 0.66)
        )
        /// Xcode's light-theme palette, for a code block someone's set to a
        /// light background.
        static let light = Palette(
            keyword: ThemeColor(hex: "#9B2393") ?? ThemeColor(red: 0.61, green: 0.14, blue: 0.58),
            string: ThemeColor(hex: "#C41A16") ?? ThemeColor(red: 0.77, green: 0.1, blue: 0.09),
            comment: ThemeColor(hex: "#5D6C79") ?? ThemeColor(red: 0.36, green: 0.42, blue: 0.47),
            number: ThemeColor(hex: "#1C00CF") ?? ThemeColor(red: 0.11, green: 0, blue: 0.81)
        )
    }
}
