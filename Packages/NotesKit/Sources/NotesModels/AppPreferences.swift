import Foundation
import SwiftData

/// Singleton preferences row — theme selection, paper tone and the encoded
/// `ToolPreferences` blob live in SwiftData per spec (and ride along when iCloud
/// sync arrives).
///
/// The tools are stored as encoded JSON rather than as columns on purpose: they
/// are a value the app already has to serialise to send between a user's devices,
/// and one blob means adding a slider does not migrate the store.
@Model
public final class AppPreferences {
    @Attribute(.unique) public var key: String
    public var themeSelectionRaw: String
    public var paperToneRaw: String
    /// JSON-encoded `ToolPreferences`. `nil` on a store written before tools were
    /// remembered at all, which decodes to the factory setup.
    public var toolsJSON: Data?
    /// Bumped on every change, so the newer of two devices' copies can be told
    /// apart without trusting either one's clock.
    ///
    /// The inline `= 0`/`= .distantPast` defaults aren't decorative — they're
    /// what SwiftData's lightweight migration reads to backfill this column on
    /// an existing row. Both fields shipped as plain non-optional properties
    /// with a default only in the memberwise `init` below, which the migrator
    /// never sees; every store created before these fields existed failed to
    /// migrate on launch (`NSCocoaErrorDomain 134110`,
    /// "missing attribute values on mandatory destination attribute"),
    /// silently falling back to an in-memory container per launch —
    /// `ModelContainerFactory.make` — so no notebook/theme/settings state
    /// written to this store ever actually persisted.
    public var settingsRevision: Int = 0
    public var settingsUpdatedAt: Date = Date.distantPast

    public static let singletonKey = "app-preferences"

    public init(
        themeSelectionRaw: String = "system",
        paperToneRaw: String = "neutral",
        toolsJSON: Data? = nil,
        settingsRevision: Int = 0,
        settingsUpdatedAt: Date = .now
    ) {
        self.key = Self.singletonKey
        self.themeSelectionRaw = themeSelectionRaw
        self.paperToneRaw = paperToneRaw
        self.toolsJSON = toolsJSON
        self.settingsRevision = settingsRevision
        self.settingsUpdatedAt = settingsUpdatedAt
    }
}
