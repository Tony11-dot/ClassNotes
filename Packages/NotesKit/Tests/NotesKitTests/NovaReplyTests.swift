import Foundation
import Testing
@testable import NotesAI
@testable import NotesServices

/// NOVA runs on a reasoning model. What the student reads must be the ANSWER —
/// never the model thinking out loud, and never raw Markdown syntax.
@Suite("NOVA reply cleaning")
struct NovaReplyTests {
    @Test("A complete think block is removed, the answer is kept")
    func stripsCompleteThinkBlock() {
        let raw = """
        <think>The user asks about photosynthesis. I should keep it short.</think>
        Plants turn light into sugar. 🌱
        """
        #expect(NovaReply.display(raw) == "Plants turn light into sugar. 🌱")
    }

    @Test("An unfinished think block shows nothing, not half a thought")
    func hidesStreamingThoughts() {
        // Mid-stream: the opener has arrived, the closer hasn't. This is the case
        // that put NOVA's reasoning in the transcript for seconds at a time.
        let raw = "<think>Okay so they want the definition of a mole, let me"
        #expect(NovaReply.display(raw).isEmpty)
    }

    @Test("Harmony channel markers are stripped and the final channel wins")
    func stripsHarmonyChannels() {
        let raw = "<|channel|>analysis<|message|>weighing options<|end|>"
            + "<|start|>assistant<|channel|>final<|message|>Use the quadratic formula."
        #expect(NovaReply.display(raw) == "Use the quadratic formula.")
    }

    @Test("A self-narrating preamble line is dropped")
    func stripsPreamble() {
        let raw = """
        Let me think about what they're asking.
        The mitochondrion makes ATP.
        """
        #expect(NovaReply.display(raw) == "The mitochondrion makes ATP.")
    }

    @Test("An ordinary answer is passed through untouched")
    func leavesRealAnswersAlone() {
        let raw = """
        **Osmosis** is water moving across a membrane. 💡

        - From low to high solute
        - No energy needed
        """
        #expect(NovaReply.display(raw) == raw)
    }

    @Test("A sentence about thinking further down the answer survives")
    func onlyStripsLeadingPreamble() {
        let raw = "Here's the trick. Let me think of it as a ratio — that's all it is."
        #expect(NovaReply.display(raw) == raw)
    }
}

@Suite("NOVA markdown layout")
struct NovaMarkdownTests {
    @Test("Headings, bullets, steps, quotes and code each become their own block")
    func parsesBlocks() {
        let blocks = NovaMarkdownBlock.parse("""
        ## Key idea
        Energy is conserved.

        - stays constant
          - even in collisions
        1. write the equation
        > worth remembering
        ```
        E = mc^2
        ```
        ---
        """)
        #expect(blocks == [
            .heading(level: 2, "Key idea"),
            .paragraph("Energy is conserved."),
            .bullet(depth: 0, "stays constant"),
            .bullet(depth: 1, "even in collisions"),
            .numbered(1, "write the equation"),
            .quote("worth remembering"),
            .code("E = mc^2"),
            .rule
        ])
    }

    @Test("Inline emphasis is left for AttributedString, not shown as syntax")
    func keepsInlineMarkers() {
        // The block parser must NOT eat inline syntax — the renderer resolves it, so
        // the student sees bold text rather than asterisks.
        #expect(
            NovaMarkdownBlock.parse("A **mole** is `6.02e23` things.")
                == [.paragraph("A **mole** is `6.02e23` things.")]
        )
    }

    @Test("Wrapped lines join into one paragraph")
    func joinsWrappedLines() {
        #expect(
            NovaMarkdownBlock.parse("one line\nand its continuation\n\nnew paragraph")
                == [.paragraph("one line and its continuation"), .paragraph("new paragraph")]
        )
    }

    @Test("A hashtag is not a heading and a lone dash is not a bullet")
    func doesNotOverReach() {
        #expect(NovaMarkdownBlock.parse("#revision") == [.paragraph("#revision")])
        #expect(NovaMarkdownBlock.parse("-5 degrees") == [.paragraph("-5 degrees")])
        #expect(NovaMarkdownBlock.parse("1.5 litres") == [.paragraph("1.5 litres")])
    }

    @Test("A code fence still streaming renders what has arrived")
    func handlesUnterminatedFence() {
        #expect(
            NovaMarkdownBlock.parse("```\nlet x = 1") == [.code("let x = 1")]
        )
    }
}
