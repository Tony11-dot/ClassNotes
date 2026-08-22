import Foundation
import NotesModels
import Observation
import SwiftData

/// The one place the app's own settings live: how the tools are tuned, and what
/// the Pencil's gestures do.
///
/// Before this existed, `ToolState` held all of it in memory and nothing else
/// did — so every slider the user moved was forgotten the moment the editor
/// closed, and there was nothing on disk for a second device to be given. The
/// store is the durable copy; `ToolState` is a live view of it.
///
/// Writes are COALESCED. Dragging a thickness slider produces a change per
/// frame, and saving SwiftData sixty times a second while the pencil is in the
/// user's hand is exactly the kind of work that shows up as a stutter in the
/// ink.
@MainActor
@Observable
public final class SettingsStore {
    private let context: ModelContext
    private var saveTask: Task<Void, Never>?
    /// Set while applying a copy that arrived from another device, so the save it
    /// triggers is not treated as a fresh local edit and bumped again.
    private var isApplyingRemote = false

    public private(set) var tools: ToolPreferences
    public private(set) var revision: Int
    public private(set) var updatedAt: Date

    /// Called after a local edit settles, so the sync layer can push it up.
    public var onChange: ((DeviceSettings) -> Void)?

    static let saveDelay: Duration = .milliseconds(400)

    public init(context: ModelContext) {
        self.context = context
        let row = Self.row(in: context)
        self.tools = Self.decode(row.toolsJSON)
        self.revision = row.settingsRevision
        self.updatedAt = row.settingsUpdatedAt

        // See `AppPreferences.snapShapesForcedOff`'s own doc: hold-to-snap was
        // switched off by default after it turned out to be the source of
        // months of "my writing changed on its own" reports, but a changed
        // Swift-side default only reaches a decode-time GAP — a device that
        // used the app before this shipped already has `snapShapes: true`
        // explicitly written into `toolsJSON` (any settings edit re-encodes
        // the whole blob). Marking the row directly and saving it here,
        // outside `update`, guarantees this check never runs twice even if
        // nothing needed to change; the actual flip — only when there's
        // something to flip — goes through `update` so it's a real,
        // revision-bumped edit that wins the next pull-before-push sync
        // instead of losing to the backend's still-stale copy.
        if !row.snapShapesForcedOff {
            row.snapShapesForcedOff = true
            try? context.save()
            if tools.snapShapes {
                update { $0.snapShapes = false }
            }
        }
    }

    // MARK: - Editing

    /// Edits the settings and remembers them. No-ops when nothing actually
    /// changed, so a panel re-rendering can't manufacture a revision that then
    /// wins over another device's real edit.
    public func update(_ mutate: (inout ToolPreferences) -> Void) {
        var edited = tools
        mutate(&edited)
        guard edited != tools else { return }
        tools = edited
        revision += 1
        updatedAt = .now
        scheduleSave()
    }

    /// The whole of this device's setup, for pushing to the account.
    public func snapshot(themeSelection: String, paperTone: String) -> DeviceSettings {
        DeviceSettings(
            revision: revision,
            updatedAt: updatedAt,
            tools: tools,
            themeSelection: themeSelection,
            paperTone: paperTone
        )
    }

    // MARK: - Another device's copy

    /// Takes a copy that arrived from the account, if it is genuinely newer than
    /// what this device holds. Returns true when it was applied, so the caller
    /// knows whether to hand the theme along too.
    @discardableResult
    public func apply(remote: DeviceSettings) -> Bool {
        let local = snapshot(themeSelection: "", paperTone: "")
        guard DeviceSettings.newer(local, remote) == remote, remote != local else { return false }
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        tools = remote.tools
        revision = remote.revision
        updatedAt = remote.updatedAt
        scheduleSave()
        return true
    }

    // MARK: - Persistence

    private func scheduleSave() {
        let notify = !isApplyingRemote
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled, let self else { return }
            self.saveNow(notify: notify)
        }
    }

    /// Writes through immediately — used when the editor is going away and there
    /// may not be another run loop to settle on.
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        saveNow(notify: true)
    }

    private func saveNow(notify: Bool) {
        let row = Self.row(in: context)
        row.toolsJSON = try? JSONEncoder().encode(tools)
        row.settingsRevision = revision
        row.settingsUpdatedAt = updatedAt
        try? context.save()
        if notify {
            onChange?(snapshot(themeSelection: row.themeSelectionRaw, paperTone: row.paperToneRaw))
        }
    }

    // MARK: - Row access

    /// A blob that won't decode is a factory setup, never a crash: settings are
    /// conveniences, and losing them must not cost the user the app.
    nonisolated static func decode(_ data: Data?) -> ToolPreferences {
        guard let data else { return ToolPreferences() }
        return (try? JSONDecoder().decode(ToolPreferences.self, from: data)) ?? ToolPreferences()
    }

    static func row(in context: ModelContext) -> AppPreferences {
        let all = (try? context.fetch(FetchDescriptor<AppPreferences>())) ?? []
        if let existing = all.first(where: { $0.key == AppPreferences.singletonKey }) {
            return existing
        }
        let fresh = AppPreferences()
        context.insert(fresh)
        try? context.save()
        return fresh
    }
}
