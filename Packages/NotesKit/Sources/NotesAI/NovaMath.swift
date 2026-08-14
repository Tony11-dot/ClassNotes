import Foundation

/// Turns the LaTeX a model writes maths in into something a person can read.
///
/// Every model trained on textbooks answers a maths question in LaTeX, so a reply
/// arrives full of `$x^2$`, `\frac{a}{b}` and `\sqrt{2}`. Printed verbatim that is
/// worse than useless — it's the answer, obfuscated, with dollar signs around it.
///
/// There is no LaTeX engine here and there does not need to be one: what students
/// read on a page is `x² + √2` and `(a + b)/2`, and Unicode has all of it. So the
/// markup is parsed properly — braces matched, fractions and roots read as the
/// groups they are, scripts raised and lowered — and rendered as text that sets in
/// the app's own face alongside the rest of the answer.
///
/// Pure, so what each construct comes out as is pinned by tests rather than
/// eyeballed in a chat window.
public enum NovaMath {
    /// One piece of LaTeX, rendered.
    public static func render(_ latex: String) -> String {
        var renderer = Renderer(Array(latex))
        let out = renderer.render()
        return out
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A line of prose with its inline maths rendered in place.
    ///
    /// Both spellings are handled: `$…$`, which is what models overwhelmingly
    /// emit, and `\(…\)`, which is the form LaTeX itself prefers. A lone `$` is
    /// left alone — a price is not an equation.
    public static func renderInline(_ text: String) -> String {
        renderDelimited(renderDelimited(text, open: "\\(", close: "\\)"), open: "$", close: "$")
    }

    /// Display maths on its own line, if this whole block is one equation.
    /// Returns nil when it isn't, so ordinary prose is never mangled.
    public static func displayMath(in trimmed: String) -> String? {
        for (open, close) in [("$$", "$$"), ("\\[", "\\]")] {
            guard trimmed.hasPrefix(open), trimmed.hasSuffix(close),
                  trimmed.count > open.count + close.count else { continue }
            let body = trimmed.dropFirst(open.count).dropLast(close.count)
            return render(String(body))
        }
        return nil
    }

    /// Whether a line opens display maths that runs on past it.
    public static func opensDisplayMath(_ trimmed: String) -> String? {
        for open in ["$$", "\\["] where trimmed.hasPrefix(open) {
            return open
        }
        return nil
    }

    public static func closesDisplayMath(_ trimmed: String, opener: String) -> Bool {
        let close = opener == "$$" ? "$$" : "\\]"
        return trimmed.hasSuffix(close)
    }

    // MARK: - Inline scanning

    private static func renderDelimited(_ text: String, open: String, close: String) -> String {
        let chars = Array(text)
        let openChars = Array(open), closeChars = Array(close)
        var out = ""
        var index = 0

        while index < chars.count {
            guard matches(chars, at: index, openChars),
                  let end = closing(chars, from: index + openChars.count, closeChars),
                  end > index + openChars.count else {
                out.append(chars[index])
                index += 1
                continue
            }
            let body = String(chars[(index + openChars.count)..<end])
            // `$100 and $50` is money, not two equations: real maths never opens
            // with a space, and it never runs for a paragraph.
            guard isPlausibleMath(body) else {
                out.append(chars[index])
                index += 1
                continue
            }
            out += render(body)
            index = end + closeChars.count
        }
        return out
    }

    private static func matches(_ chars: [Character], at index: Int, _ token: [Character]) -> Bool {
        guard index + token.count <= chars.count else { return false }
        for offset in 0..<token.count where chars[index + offset] != token[offset] { return false }
        return true
    }

    private static func closing(_ chars: [Character], from: Int, _ token: [Character]) -> Int? {
        var index = from
        while index < chars.count {
            if matches(chars, at: index, token) { return index }
            index += 1
        }
        return nil
    }

    /// The longest run we'll accept between two dollar signs. Beyond this the
    /// pairing is almost certainly two separate prices.
    static let maximumInlineLength = 220

    static func isPlausibleMath(_ body: String) -> Bool {
        guard !body.isEmpty, body.count <= maximumInlineLength else { return false }
        guard let first = body.first, !first.isWhitespace else { return false }
        guard let last = body.last, !last.isWhitespace else { return false }
        return !body.contains("\n")
    }

    // MARK: - The parser

    private struct Renderer {
        let chars: [Character]
        var index = 0

        init(_ chars: [Character]) { self.chars = chars }

        mutating func render(until stop: Character? = nil) -> String {
            var out = ""
            while index < chars.count {
                let character = chars[index]
                if let stop, character == stop { break }
                switch character {
                case "\\":
                    out += command()
                case "^":
                    index += 1
                    out += script(raised: true)
                case "_":
                    index += 1
                    out += script(raised: false)
                case "{":
                    index += 1
                    out += render(until: "}")
                    if index < chars.count { index += 1 }
                case "}":
                    index += 1
                case "&":
                    index += 1
                    out += " "
                default:
                    out.append(character)
                    index += 1
                }
            }
            return out
        }

        /// The contents of the next `{…}`, or the single token after it.
        mutating func group() -> String {
            skipSpaces()
            guard index < chars.count else { return "" }
            if chars[index] == "{" {
                index += 1
                let body = render(until: "}")
                if index < chars.count { index += 1 }
                return body
            }
            if chars[index] == "\\" { return command() }
            let single = String(chars[index])
            index += 1
            return single
        }

        mutating func skipSpaces() {
            while index < chars.count, chars[index] == " " { index += 1 }
        }

        mutating func command() -> String {
            index += 1  // the backslash
            guard index < chars.count else { return "" }
            guard chars[index].isLetter else {
                let symbol = chars[index]
                index += 1
                switch symbol {
                case "\\": return "\n"
                case ",", ";", ":", "!", " ": return " "
                default: return String(symbol)
                }
            }
            var name = ""
            while index < chars.count, chars[index].isLetter {
                name.append(chars[index])
                index += 1
            }
            return expand(name)
        }

        mutating func expand(_ name: String) -> String {
            switch name {
            case "frac", "dfrac", "tfrac", "cfrac":
                let numerator = group()
                let denominator = group()
                return "\(wrap(numerator))/\(wrap(denominator))"
            case "sqrt":
                var degree: String?
                skipSpaces()
                if index < chars.count, chars[index] == "[" {
                    index += 1
                    degree = render(until: "]")
                    if index < chars.count { index += 1 }
                }
                let body = group()
                let root = degree.flatMap { NovaMath.raise($0) }.map { "\($0)√" } ?? "√"
                return "\(root)\(wrap(body))"
            case "text", "textrm", "textbf", "textit", "mathrm", "mathbf", "mathit",
                 "mathsf", "mathbb", "mathcal", "operatorname", "boxed", "displaystyle":
                return group()
            case "left", "right":
                skipSpaces()
                guard index < chars.count else { return "" }
                let delimiter = chars[index]
                index += 1
                if delimiter == "\\" {
                    // `\left\{` and friends.
                    guard index < chars.count else { return "" }
                    let escaped = chars[index]
                    index += 1
                    return String(escaped)
                }
                return delimiter == "." ? "" : String(delimiter)
            case "quad", "qquad": return "  "
            case "begin", "end":
                _ = group()  // the environment's name; the rows render on their own
                return "\n"
            default:
                return NovaMath.symbols[name] ?? name
            }
        }

        /// Parentheses only where they change the reading: `a/b` and `-b/2a` need
        /// none, `(x + 1)/2` very much does. A leading sign is part of the term,
        /// not an operation inside it — bracketing for it would put half the
        /// answers in a maths lesson inside redundant parentheses.
        func wrap(_ body: String) -> String {
            var inner = body
            if inner.hasPrefix("-") || inner.hasPrefix("+") || inner.hasPrefix("−") {
                inner.removeFirst()
            }
            let needsBrackets = inner.contains(where: { " +-±×÷/".contains($0) })
            guard needsBrackets, !(body.hasPrefix("(") && body.hasSuffix(")")) else { return body }
            return "(\(body))"
        }

        mutating func script(raised: Bool) -> String {
            let body = group()
            if let mapped = raised ? NovaMath.raise(body) : NovaMath.lower(body) { return mapped }
            // No Unicode for it — say what it is rather than silently flattening
            // `x^{n+1}` into `xn+1`.
            return raised ? "^(\(body))" : "_(\(body))"
        }
    }

    // MARK: - Unicode tables

    static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶",
        "7": "⁷", "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼",
        "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "a": "ᵃ", "b": "ᵇ", "c": "ᶜ",
        "d": "ᵈ", "e": "ᵉ", "k": "ᵏ", "m": "ᵐ", "x": "ˣ", "y": "ʸ", "T": "ᵀ"
    ]

    static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆",
        "7": "₇", "8": "₈", "9": "₉", "+": "₊", "-": "₋", "−": "₋", "=": "₌",
        "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ",
        "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ",
        "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ"
    ]

    static func raise(_ body: String) -> String? { map(body, through: superscripts) }
    static func lower(_ body: String) -> String? { map(body, through: subscripts) }

    private static func map(_ body: String, through table: [Character: Character]) -> String? {
        guard !body.isEmpty else { return nil }
        var out = ""
        for character in body {
            guard let mapped = table[character] else { return nil }
            out.append(mapped)
        }
        return out
    }

    /// The commands worth knowing by name. Anything missing falls through as its
    /// own name, which reads badly but never loses the answer.
    static let symbols: [String: String] = [
        // Greek
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
        "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ",
        "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
        "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ",
        "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
        "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        // Operators and relations
        "times": "×", "div": "÷", "cdot": "·", "pm": "±", "mp": "∓",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
        "approx": "≈", "equiv": "≡", "sim": "∼", "propto": "∝",
        "ll": "≪", "gg": "≫", "cong": "≅",
        // Big operators and calculus
        "sum": "∑", "prod": "∏", "int": "∫", "iint": "∬", "oint": "∮",
        "partial": "∂", "nabla": "∇", "infty": "∞", "lim": "lim",
        "sqrtsign": "√", "degree": "°",
        // Sets and logic
        "in": "∈", "notin": "∉", "subset": "⊂", "subseteq": "⊆",
        "supset": "⊃", "supseteq": "⊇", "cup": "∪", "cap": "∩",
        "emptyset": "∅", "varnothing": "∅", "forall": "∀", "exists": "∃",
        "neg": "¬", "land": "∧", "lor": "∨", "therefore": "∴", "because": "∵",
        "mathbbR": "ℝ", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ",
        // Arrows
        "to": "→", "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔",
        "mapsto": "↦", "implies": "⇒", "iff": "⇔",
        // Geometry
        "angle": "∠", "perp": "⊥", "parallel": "∥", "triangle": "△",
        "circ": "∘", "prime": "′", "cdots": "⋯", "ldots": "…", "dots": "…",
        "vdots": "⋮", "ddots": "⋱"
    ]
}
