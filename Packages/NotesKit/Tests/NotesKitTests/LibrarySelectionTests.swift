import Foundation
import Testing
@testable import NotesLibrary

@MainActor
@Suite("Selecting several notebooks at once")
struct LibrarySelectionTests {
    @Test("A long press picks one up and turns selection on")
    func beginsWithOne() {
        let selection = LibrarySelection()
        #expect(!selection.isActive)
        let first = UUID()
        selection.begin(with: first)
        #expect(selection.isActive)
        #expect(selection.contains(first))
        #expect(selection.count == 1)
    }

    @Test("Tapping picks up and puts down")
    func togglesMembers() {
        let selection = LibrarySelection()
        let a = UUID(), b = UUID()
        selection.begin(with: a)
        selection.toggle(b)
        #expect(selection.count == 2)
        selection.toggle(a)
        #expect(selection.count == 1)
        #expect(!selection.contains(a))
    }

    @Test("Putting the last one down leaves selection mode")
    func endsWhenEmptied() {
        // Nothing selected means every button in the bar is dead, so staying in
        // the mode strands the user behind a bar that can't do anything.
        let selection = LibrarySelection()
        let only = UUID()
        selection.begin(with: only)
        selection.toggle(only)
        #expect(selection.isEmpty)
        #expect(!selection.isActive)
    }

    @Test("Deselecting all from the bar leaves the mode too")
    func selectingNoneEnds() {
        let selection = LibrarySelection()
        selection.selectAll([UUID(), UUID()])
        selection.selectAll([])
        #expect(selection.isEmpty)
        #expect(!selection.isActive)
    }

    @Test("Select all takes everything; Done clears both the set and the mode")
    func selectAllAndEnd() {
        let selection = LibrarySelection()
        let all = [UUID(), UUID(), UUID()]
        selection.selectAll(all)
        #expect(selection.count == 3)
        #expect(selection.isActive)

        selection.end()
        #expect(selection.isEmpty)
        #expect(!selection.isActive)
    }

    @Test("Select starts the mode holding nothing, so the bar can appear")
    func beginsEmpty() {
        // This is how the iPhone's "Select" button starts: mode on, nothing held.
        // Starting empty is a beginning, so it must not trip the exit rule.
        let selection = LibrarySelection()
        selection.beginEmpty()
        #expect(selection.isActive)
        #expect(selection.isEmpty)
    }
}

@MainActor
@Suite("Sign-up form")
struct SignUpValidationTests {
    /// The screen validates before it sends, so a typo costs nothing.
    private func form(
        name: String = "Tony", email: String = "t@example.com",
        password: String = "hunter2hunter2", confirmation: String? = nil
    ) -> SignUpScreen {
        var screen = SignUpScreen()
        screen.setForTesting(
            name: name, email: email,
            password: password, confirmation: confirmation ?? password
        )
        return screen
    }

    @Test("A complete, consistent form is ready to send")
    func acceptsAGoodForm() {
        #expect(form().validationError == nil)
    }

    @Test("Each missing or mismatched piece says which one it is")
    func rejectsBadForms() {
        #expect(form(name: "  ").validationError == "Enter your name.")
        #expect(form(email: "not-an-email").validationError == "Enter a valid email.")
        #expect(form(email: "missing@dot").validationError == "Enter a valid email.")
        #expect(form(password: "short").validationError == "Use at least 8 characters.")
        #expect(
            form(password: "hunter2hunter2", confirmation: "hunter2hunter3").validationError
                == "Those passwords don't match."
        )
    }
}
