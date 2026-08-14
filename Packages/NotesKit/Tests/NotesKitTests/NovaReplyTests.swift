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
            .code(language: nil, "E = mc^2"),
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
            NovaMarkdownBlock.parse("```\nlet x = 1") == [.code(language: nil, "let x = 1")]
        )
    }

    @Test("A fence's language travels with the code")
    func keepsCodeLanguage() {
        #expect(
            NovaMarkdownBlock.parse("```swift\nlet x = 1\n```")
                == [.code(language: "swift", "let x = 1")]
        )
    }
}

/// The maths half of a reply. Every model answers a maths question in LaTeX, so
/// this is the difference between an answer and a page of `$` signs.
@Suite("NOVA renders maths")
struct NovaMathTests {
    @Test("Powers and indices become real superscripts and subscripts")
    func scripts() {
        #expect(NovaMath.render("x^2") == "x²")
        #expect(NovaMath.render("x^{10}") == "x¹⁰")
        #expect(NovaMath.render("a_1 + a_2") == "a₁ + a₂")
        // Nothing in Unicode for it, so it SAYS it's a power rather than
        // flattening x^{n+1} into "xn+1".
        #expect(NovaMath.render("x^{q+1}") == "x^(q+1)")
    }

    @Test("Fractions read as divisions, bracketed only where it matters")
    func fractions() {
        #expect(NovaMath.render("\\frac{a}{b}") == "a/b")
        #expect(NovaMath.render("\\frac{x + 1}{2}") == "(x + 1)/2")
        #expect(NovaMath.render("\\dfrac{1}{2}") == "1/2")
    }

    @Test("Roots, Greek letters and operators come out as themselves")
    func symbols() {
        #expect(NovaMath.render("\\sqrt{2}") == "√2")
        #expect(NovaMath.render("\\sqrt{x + 1}") == "√(x + 1)")
        #expect(NovaMath.render("\\pi r^2") == "π r²")
        #expect(NovaMath.render("a \\times b \\leq c") == "a × b ≤ c")
        #expect(NovaMath.render("\\left( x \\right)") == "( x )")
        #expect(NovaMath.render("\\text{speed} = \\frac{d}{t}") == "speed = d/t")
    }

    @Test("Inline maths is rendered inside a sentence, and prices are left alone")
    func inlineMath() {
        #expect(
            NovaMath.renderInline("The area is $\\pi r^2$ exactly.")
                == "The area is π r² exactly."
        )
        #expect(
            NovaMath.renderInline("It cost $5 and then $7 more.")
                == "It cost $5 and then $7 more.",
            "a price is not an equation"
        )
        #expect(NovaMath.renderInline("Let \\(x = 2\\).") == "Let x = 2.")
    }

    @Test("Display maths is its own block, with no dollar signs left")
    func displayMath() {
        #expect(
            NovaMarkdownBlock.parse("Here it is:\n\n$$x = \\frac{-b}{2a}$$")
                == [.paragraph("Here it is:"), .math("x = -b/2a")]
        )
        // The one that actually needs the brackets keeps them.
        #expect(
            NovaMath.render("\\frac{-b \\pm \\sqrt{d}}{2a}") == "(-b ± √d)/2a"
        )
        #expect(NovaMarkdownBlock.parse("\\[E = mc^2\\]") == [.math("E = mc²")])
    }

    @Test("Display maths spread over several lines is still one block")
    func multiLineDisplayMath() {
        let blocks = NovaMarkdownBlock.parse("$$\na^2 + b^2 = c^2\n$$")
        #expect(blocks.count == 1)
        if case .math(let body) = blocks[0] {
            #expect(body.contains("a² + b² = c²"))
        } else {
            Issue.record("a multi-line $$ block should be one equation")
        }
    }
}
