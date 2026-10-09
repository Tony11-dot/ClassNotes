import ClassMateTheme
import NotesDesignSystem
import NotesServices
import SwiftUI

/// Settings → iCloud: keep notebooks the same on every device (D-003).
struct CloudSyncSection: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme

    var body: some View {
        let sync = services.cloudSync
        Section {
            Toggle(isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync notebooks with iCloud")
                        .font(.dsBody)
                        .foregroundStyle(theme.ink.color)
                    Text(statusText(sync.status))
                        .font(.dsCaption)
                        .foregroundStyle(theme.inkSecondary.color)
                }
            }
            .tint(theme.accent.color)
            if sync.isEnabled {
                Button {
                    Task { await sync.syncNow() }
                } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(sync.status == .syncing)
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text("""
                 Your notebooks stay on this device and a copy goes to your iCloud Drive, so they're the same \
                 on your iPad and iPhone. If a notebook changes on two devices before they sync, you keep both \
                 versions. Notebooks sync when you close them, never while you're writing.
                 """)
        }
        .listRowBackground(theme.surfaceRaised.color)
    }

    private func statusText(_ status: CloudSyncController.Status) -> String {
        switch status {
        case .off: "Off"
        case .unavailable: "Sign in to iCloud and turn on iCloud Drive to sync."
        case .syncing: "Syncing…"
        case .upToDate(let date): "Up to date · " + date.formatted(date: .omitted, time: .shortened)
        case .partly(let failed, _):
            "\(failed) notebook\(failed == 1 ? "" : "s") couldn't sync yet. ClassNotes will try again."
        }
    }
}
