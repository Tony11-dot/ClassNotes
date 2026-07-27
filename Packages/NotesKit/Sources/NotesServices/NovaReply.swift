import Foundation

/// Cleans a model reply into the answer alone.
///
/// NOVA runs on a reasoning model (Groq's `gpt-oss-120b`), which narrates its
/// chain of thought before answering. The proxy asks for that to be withheld, but
/// a stream is not a promise: models still emit `<think>` blocks, the harmony
/// `<|channel|>analysis` markers, or a "Let me think…" preamble — and while a
/// reply is streaming the OPENING marker arrives long before the closing one, so
/// the thinking would sit in the transcript in plain sight until it finished.
///
/// This runs on the accumulated text every time a token lands, so an unterminated
/// block is treated as "still thinking" and shows nothing rather than half a
/// thought. Pure and `Sendable` so it's pinned by tests.
public enum NovaReply: Sendable {
    /// Marker pairs that wrap reasoning. Order matters only for readability.
    private static let fences: [(open: String, close: String)] = [
        ("<think>", "</think>"),
        ("<thinking>", "</thinking>"),
        ("<reasoning>", "</reasoning>"),
        ("<|channel|>analysis<|message|>", "<|end|>"),
        ("<|start|>assistant<|channel|>analysis<|message|>", "<|end|>")
    ]

    /// Lines that are pure meta-commentary rather than an answer.
    private static let preambles = [
        "let me think", "let's think", "thinking:", "thought:", "thoughts:",
        "analysis:", "reasoning:", "we need to", "the user is asking",
        "the user wants", "i need to figure out"
    ]

    /// What the transcript should show for `raw` — reasoning removed, harmony
    /// scaffolding removed, whitespace tidied.
    public static func display(_ raw: String) -> String {
        var text = stripFences(in: raw)
        text = stripChannelMarkers(in: text)
        text = stripPreambleLines(in: text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes every complete `<think>…</think>` block, and everything from an
    /// UNCLOSED opener to the end — mid-stream, the thinking hasn't finished.
    private static func stripFences(in raw: String) -> String {
        var text = raw
        for fence in fences {
            while let open = text.range(of: fence.open, options: .caseInsensitive) {
                if let close = text.range(
                    of: fence.close, options: .caseInsensitive,
                    range: open.upperBound..<text.endIndex
                ) {
                    text.removeSubrange(open.lowerBound..<close.upperBound)
                } else {
                    text.removeSubrange(open.lowerBound..<text.endIndex)
                    break
                }
            }
        }
        return text
    }

    /// Drops leftover harmony control tokens (`<|start|>`, `<|channel|>final`,
    /// `<|message|>`, `<|end|>`) that some builds emit around the real answer.
    private static func stripChannelMarkers(in raw: String) -> String {
        var text = raw
        // The final-channel header introduces the answer, so cut everything before
        // it rather than just the marker itself.
        if let final = text.range(of: "<|channel|>final<|message|>") {
            text = String(text[final.upperBound...])
        }
        for marker in ["<|start|>assistant", "<|start|>", "<|end|>", "<|message|>", "<|return|>"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        // Any surviving `<|channel|>xyz` header.
        while let header = text.range(of: "<|channel|>") {
            let rest = text[header.upperBound...]
            let end = rest.firstIndex(where: { $0 == "\n" }) ?? rest.endIndex
            text.removeSubrange(header.lowerBound..<end)
        }
        return text
    }

    /// Removes leading lines that are the model talking to itself. Only LEADING
    /// lines, and only before any real content — a sentence like "Let me think
    /// about your question" further down an answer is left alone.
    private static func stripPreambleLines(in raw: String) -> String {
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let first = lines.first {
            let probe = first.trimmingCharacters(in: .whitespaces).lowercased()
            if probe.isEmpty {
                lines.removeFirst()
                continue
            }
            guard preambles.contains(where: { probe.hasPrefix($0) }) else { break }
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }
}
