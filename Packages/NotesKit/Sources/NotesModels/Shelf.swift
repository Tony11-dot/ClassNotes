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

    public var systemName: String { rawValue }
}
