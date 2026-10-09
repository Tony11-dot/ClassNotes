import ClassMateTheme
import NotesDesignSystem
import NotesServices
import SwiftUI

/// Support's "Diagnostics": what the last 30 days' crash and speed reports
/// say, and a way to send them to us. They never leave the device otherwise.
struct DiagnosticsSection: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme

    @State private var summary: DiagnosticsSummary?
    @State private var shared: SharedFile?

    var body: some View {
        Section {
            if let summary, summary.reportedDays > 0 || summary.crashes > 0 || summary.hangs > 0 {
                row("Crashes", value: "\(summary.crashes)")
                row("Freezes", value: "\(summary.hangs)")
                if let launch = summary.launchSeconds {
                    row("Typical launch", value: launch.formatted(.number.precision(.fractionLength(1))) + " s")
                }
                if let memory = summary.peakMemoryMB {
                    row("Most memory used", value: "\(Int(memory)) MB")
                }
            } else {
                Text("No reports yet. iPadOS delivers them about once a day.")
                    .font(.dsFootnote)
                    .foregroundStyle(theme.inkSecondary.color)
            }
            Button {
                Task { shared = await services.diagnostics.exportFile().map(SharedFile.init(url:)) }
            } label: {
                Label("Share diagnostics", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("Diagnostics, last 30 days")
        } footer: {
            Text("""
                 Crash and speed reports from iPadOS, kept on this device. They hold no notes. \
                 Nothing is sent unless you share it.
                 """)
        }
        .listRowBackground(theme.surfaceRaised.color)
        .task {
            let records = await services.diagnostics.records()
            summary = DiagnosticsSummary.of(records, since: .now.addingTimeInterval(-30 * 24 * 3600))
        }
        .sheet(item: $shared) { file in ShareSheet(items: [file.url]) }
    }

    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(theme.ink.color)
            Spacer()
            Text(value).foregroundStyle(theme.inkSecondary.color).monospacedDigit()
        }
        .font(.dsSubheadline)
        .accessibilityElement(children: .combine)
    }
}
