import ClassMateTheme
import NotesDesignSystem
import NotesModels
import SwiftUI

/// What the library's `+` offers. Six ways into a document, from "just start
/// writing" to "annotate this scan".
public enum AddContentChoice: String, CaseIterable, Identifiable, Sendable {
    /// A cover and two blank white pages, created instantly with no questions.
    case quickNote
    /// The full New Notebook sheet — covers, paper, size, colors.
    case notebook
    /// One big board with pan and zoom instead of pages.
    case whiteboard
    /// A photo turned into an annotatable page.
    case image
    /// A PDF or file turned into annotatable pages.
    case file
    /// A camera scan turned into annotatable pages.
    case scan

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .quickNote: "Quick Note"
        case .notebook: "Notebook"
        case .whiteboard: "Whiteboard"
        case .image: "Image"
        case .file: "Import from Files"
        case .scan: "Scan Document"
        }
    }

    public var subtitle: String {
        switch self {
        case .quickNote: "A cover and two blank pages, right now"
        case .notebook: "Choose a cover, paper, size and colors"
        case .whiteboard: "One endless board — pan and zoom, no pages"
        case .image: "Pick a photo and draw on it"
        case .file: "A PDF or document you can annotate"
        case .scan: "Scan pages with the camera, then annotate"
        }
    }

    public var symbolName: String {
        switch self {
        case .quickNote: "bolt.fill"
        case .notebook: "book.closed.fill"
        case .whiteboard: "rectangle.on.rectangle"
        case .image: "photo.fill"
        case .file: "folder.fill"
        case .scan: "doc.viewfinder.fill"
        }
    }
}
