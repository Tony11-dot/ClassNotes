import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI
import UniformTypeIdentifiers

/// Drag and drop onto a page: a PDF from Files, a photo from Photos, a link
/// from Safari, words from another app, any other file. Each lands on the page
/// it was dropped on, where it was dropped (`NotebookEditorModel.drop`).
extension EditorScreen {

    /// The drop target for one page in the stack. `size` is the page as laid
    /// out on screen; the drop point is converted into the page's own space.
    func pageDropTarget(_ page: PageRecord, size: CGSize) -> some ViewModifier {
        PageDropTarget(
            isTargeted: Binding(
                get: { dropTargetPageID == page.id },
                set: { targeted in
                    if targeted {
                        dropTargetPageID = page.id
                    } else if dropTargetPageID == page.id {
                        dropTargetPageID = nil
                    }
                }
            ),
            perform: { providers, location in
                handleDrop(providers, on: page, at: location, displaySize: size)
            }
        )
    }

    func handleDrop(
        _ providers: [NSItemProvider], on page: PageRecord, at location: CGPoint, displaySize: CGSize
    ) -> Bool {
        guard !providers.isEmpty, displaySize.width > 0, page.logicalSize.width > 0 else { return false }
        let scale = page.logicalSize.width / displaySize.width
        let point = CGPoint(x: location.x * scale, y: location.y * scale)
        let fontName = FontLibrary.byNameOrID(toolState.textFontID).fontName
        let colorHex = toolState.textColorHex ?? theme.ink.hexString
        Task {
            var unreadable = 0
            for (offset, provider) in providers.enumerated() {
                guard let item = await DropLoader.load(provider) else {
                    unreadable += 1
                    continue
                }
                // Several things dropped at once fan out a little, so they
                // don't land exactly on top of one another.
                let step = CGFloat(offset) * 28
                let outcome = await model.drop(
                    item, on: page.id, at: CGPoint(x: point.x + step, y: point.y + step),
                    fontName: fontName, colorHex: colorHex
                )
                if case .pdf = item {
                    editorNotice = Self.importNotice(outcome, source: "PDF")
                } else if outcome == nil {
                    unreadable += 1
                }
            }
            if let notice = Self.dropNotice(unreadable: unreadable, of: providers.count) {
                editorNotice = notice
            }
        }
        return true
    }

    /// What to say when some or all of a drop couldn't be read.
    static func dropNotice(unreadable: Int, of total: Int) -> String? {
        guard unreadable > 0 else { return nil }
        if unreadable == total {
            return "Couldn't read what was dropped. Nothing on this page was changed."
        }
        return "\(unreadable) of the \(total) things dropped couldn't be read and were left out."
    }
}

/// Accepts drops and shows the page as a target while something hovers over it.
struct PageDropTarget: ViewModifier {
    @Environment(\.theme) private var theme
    @Binding var isTargeted: Bool
    let perform: ([NSItemProvider], CGPoint) -> Bool

    func body(content: Content) -> some View {
        content
            .onDrop(of: DropRouting.pageTypes, isTargeted: $isTargeted, perform: perform)
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.accent.color, lineWidth: 3)
                        .background(theme.accent.withAlpha(0.06).color, in: RoundedRectangle(cornerRadius: 8))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}
