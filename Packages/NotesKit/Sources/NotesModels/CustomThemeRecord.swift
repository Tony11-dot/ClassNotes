import Foundation
import SwiftData

/// A user-built theme (premium). The full `ThemeSpec` is stored as JSON so the
/// record survives token additions without lockstep migrations.
@Model
public final class CustomThemeRecord {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var specJSON: Data
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, specJSON: Data, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.specJSON = specJSON
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}
