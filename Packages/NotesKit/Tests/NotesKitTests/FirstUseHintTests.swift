import Foundation
import Testing
@testable import NotesEditor
@testable import NotesModels

@MainActor
@Suite("First-use hints")
struct FirstUseHintTests {

    private func fresh() -> FirstUseHints {
        FirstUseHints(defaults: UserDefaults(suiteName: "hints-\(UUID().uuidString)")!)
    }

    @Test("A hint shows once, and never again")
    func once() {
        let hints = fresh()
        #expect(hints.claim(.lasso))
        #expect(!hints.claim(.lasso))
        #expect(hints.claim(.nova), "each hint is its own")
        #expect(hints.seen == [.lasso, .nova])
    }

    @Test("Show tips again brings every hint back")
    func reset() {
        let hints = fresh()
        for hint in FirstUseHint.allCases { _ = hints.claim(hint) }
        hints.reset()
        #expect(hints.seen.isEmpty)
        #expect(hints.claim(.lasso))
    }

    @Test("Seen hints survive a relaunch")
    func persists() {
        let suite = "hints-\(UUID().uuidString)"
        _ = FirstUseHints(defaults: UserDefaults(suiteName: suite)!).claim(.tape)
        #expect(!FirstUseHints(defaults: UserDefaults(suiteName: suite)!).claim(.tape))
    }

    @Test("The lasso and NOVA say what the mandate asks, and every hint is one short line")
    func wording() {
        #expect(FirstUseHint.lasso.message == "Draw around anything to select it.")
        #expect(FirstUseHint.nova.message == "Ask NOVA about anything in your notes.")
        for hint in FirstUseHint.allCases {
            #expect(hint.message.count <= 80, "\(hint) is a line, not a paragraph")
        }
    }

    @Test("Every tool that needs teaching has a hint; pen and eraser don't")
    func tools() {
        #expect(EditorScreen.hint(for: .lasso) == .lasso)
        #expect(EditorScreen.hint(for: .tape) == .tape)
        #expect(EditorScreen.hint(for: .pen) == nil)
        #expect(EditorScreen.hint(for: .eraser) == nil)
    }
}
