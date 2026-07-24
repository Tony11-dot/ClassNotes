import Foundation
import SwiftData

/// Singleton preferences row — theme selection and paper tone live in SwiftData
/// per spec (and ride along when iCloud sync arrives).
@Model
public final class AppPreferences {
    @Attribute(.unique) public var key: String
    public var themeSelectionRaw: String
    public var paperToneRaw: String

    public static let singletonKey = "app-preferences"

    public init(themeSelectionRaw: String = "system", paperToneRaw: String = "neutral") {
        self.key = Self.singletonKey
        self.themeSelectionRaw = themeSelectionRaw
        self.paperToneRaw = paperToneRaw
    }
}
