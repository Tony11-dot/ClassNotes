import Foundation
import SwiftData

/// A "shelf" (a.k.a. a bag / collection) groups notebooks in the library —
/// e.g. "Biology", "Journal", "Sketchbook". A notebook may sit on one shelf or
/// none (the default "All" view). Cover color comes from the theme palette.
@Model
public final class Shelf {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var colorHex: String
    public var symbolName: String
    public var sortIndex: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        colorHex: String,
        symbolName: String = "bag",
        sortIndex: Int = 0,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}

/// SF Symbols offered when creating a shelf — the "books, bags, folders" idea.
public enum ShelfSymbol: String, CaseIterable, Sendable {
    case bag
    case book = "books.vertical"
    case backpack = "backpack"
    case folder
    case graduationcap
    case pencilAndRuler = "pencil.and.ruler"
    case flask = "flask"
    case paintpalette
    // More choices so shelves can match any subject or mood.
    case star
    case heart
    case bookmark
    case tray = "tray.full"
    case calendar
    case function
    case atom
    case globe
    case leaf
    case musicNote = "music.note"
    case sparkles
    case lightbulb
    case briefcase
    case cameraShutter = "camera"
    case gameController = "gamecontroller"
    case sportscourt

    public var systemName: String { rawValue }

    /// What VoiceOver calls the icon. An SF Symbol's own name is not a word
    /// ("tray.full", "gamecontroller").
    public var spokenName: String {
        switch self {
        case .bag: "Bag"
        case .book: "Books"
        case .backpack: "Backpack"
        case .folder: "Folder"
        case .graduationcap: "Graduation cap"
        case .pencilAndRuler: "Pencil and ruler"
        case .flask: "Flask"
        case .paintpalette: "Paint palette"
        case .star: "Star"
        case .heart: "Heart"
        case .bookmark: "Bookmark"
        case .tray: "Tray"
        case .calendar: "Calendar"
        case .function: "Function"
        case .atom: "Atom"
        case .globe: "Globe"
        case .leaf: "Leaf"
        case .musicNote: "Music note"
        case .sparkles: "Sparkles"
        case .lightbulb: "Light bulb"
        case .briefcase: "Briefcase"
        case .cameraShutter: "Camera"
        case .gameController: "Game controller"
        case .sportscourt: "Sports court"
        }
    }
}
