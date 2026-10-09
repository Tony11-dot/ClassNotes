import SwiftUI

/// Hardware-keyboard commands for the editor, listed in the ⌘-hold overlay.
///
/// They live here, on the editor, and not on the canvas or the rail. The
/// canvas's own ⌘Z (`PageCanvasView.keyCommands`) only fires when the canvas
/// is first responder, and a `PKCanvasView` inside SwiftUI never is — so
/// Undo from the keyboard did nothing. The rail can be collapsed, taking any
/// shortcut on its buttons with it. A text box being edited still gets its own
/// ⌘Z first: it is the first responder, and asks before these do.
extension EditorScreen {

    /// Same order as the rail.
    static let toolShortcuts: [(tool: ToolState.Tool, key: Character)] = [
        (.pen, "1"), (.eraser, "2"), (.lasso, "3"), (.text, "4"), (.hand, "5")
    ]

    var keyboardCommands: some View {
        Group {
            Button("Undo") { tracker.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!tracker.canUndo)
            Button("Redo") { tracker.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!tracker.canRedo)
            ForEach(Self.toolShortcuts, id: \.tool) { entry in
                Button(entry.tool.displayName) { toolState.select(entry.tool) }
                    .keyboardShortcut(KeyEquivalent(entry.key), modifiers: .command)
            }
            Button("Next Page") { stepPage(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Page") { stepPage(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("New Page After This One") {
                Task { await addPageAfterFocused() }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Zoom In") { zoom(to: Self.zoomStep(pageZoom, by: 1)) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { zoom(to: Self.zoomStep(pageZoom, by: -1)) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { zoom(to: 1) }
                .keyboardShortcut("0", modifiers: .command)
            Button(showPages ? "Hide Pages" : "Show Pages") {
                withAnimation(.spring(duration: 0.3)) { showPages.toggle() }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// The zoom levels ⌘= and ⌘- step through, the way every document app on
    /// the platform steps: a fixed ladder, so pressing back lands exactly
    /// where you were.
    nonisolated static let zoomLadder: [CGFloat] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    /// The next rung up (`direction` > 0) or down from `current`; a zoom left
    /// between rungs by a pinch steps to the nearest rung in that direction.
    nonisolated static func zoomStep(_ current: CGFloat, by direction: Int) -> CGFloat {
        let tolerance: CGFloat = 0.01
        if direction > 0 {
            return zoomLadder.first { $0 > current + tolerance } ?? zoomLadder.last ?? current
        }
        return zoomLadder.last { $0 < current - tolerance } ?? zoomLadder.first ?? current
    }

    /// Zooms the page stack the way the 100% chip does. No jump to the top of
    /// the focused page: the keyboard is often used mid-page, and being thrown
    /// back to a page's top edge is the "unexpected page movement" to avoid.
    func zoom(to level: CGFloat) {
        let target = Self.clampZoom(level)
        guard abs(target - pageZoom) > 0.001 else { return }
        withAnimation(.spring(duration: 0.28)) {
            pageZoom = target
            zoomAnchor = target
        }
    }

    /// Moves the focus one page on (or back) and scrolls to it.
    func stepPage(by offset: Int) {
        let pages = model.pages
        let current = pages.firstIndex { $0.id == model.focusedPageID }
        guard let target = Self.steppedPage(from: current, by: offset, count: pages.count) else { return }
        jump(to: pages[target].id)
    }

    /// The page `offset` away from `current`, held to the notebook's ends; nil
    /// when that's where the focus already is. No focus counts as page one.
    static func steppedPage(from current: Int?, by offset: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let start = current ?? 0
        let target = min(max(start + offset, 0), count - 1)
        return target == current ? nil : target
    }

    /// A new page straight after the one in focus, in its style, and onto it.
    func addPageAfterFocused() async {
        let pages = model.pages
        let current = pages.firstIndex { $0.id == model.focusedPageID } ?? (pages.count - 1)
        if let id = await model.insertPage(at: current + 1, inheriting: model.focusedPageID) {
            jump(to: id)
        }
    }
}
