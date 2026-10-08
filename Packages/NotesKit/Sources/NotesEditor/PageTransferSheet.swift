import ClassMateTheme
import NotesDesignSystem
import SwiftUI

/// A notebook pages can be sent to, as the page manager lists it.
struct PageDestination: Identifiable, Equatable {
    let id: UUID
    let title: String
    let colorHex: String
}

/// "Move to…" / "Copy to…": pick the notebook the selected pages go to.
struct PageTransferSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let pageCount: Int
    let isMove: Bool
    let destinations: [PageDestination]
    let onPick: (PageDestination) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if destinations.isEmpty {
                    ContentUnavailableView(
                        "No other notebooks",
                        systemImage: "books.vertical",
                        description: Text("Create another notebook first, then send pages to it.")
                    )
                } else {
                    List(destinations) { destination in
                        Button {
                            onPick(destination)
                            dismiss()
                        } label: {
                            HStack(spacing: 14) {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill((ThemeColor(hex: destination.colorHex) ?? theme.accent).color)
                                    .frame(width: 26, height: 34)
                                Text(destination.title)
                                    .font(.dsBody)
                                    .foregroundStyle(theme.ink.color)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(isMove ? "Moves the pages to this notebook" : "Copies the pages to this notebook")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        let pages = pageCount == 1 ? "1 page" : "\(pageCount) pages"
        return isMove ? "Move \(pages) to…" : "Copy \(pages) to…"
    }
}
