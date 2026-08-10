import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI

/// Selecting several notebooks at once, so they can be shelved or deleted
/// together instead of one long-press at a time.
///
/// Shared by the iPad grid and the iPhone list: the same rules, the same bar, so
/// "select" means one thing across the app.
@MainActor
@Observable
public final class LibrarySelection {
    public private(set) var isActive = false
    public private(set) var ids: Set<UUID> = []

    public init() {}

    public var count: Int { ids.count }
    public var isEmpty: Bool { ids.isEmpty }

    public func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// Enters selection mode holding `id` — what a long press does.
    public func begin(with id: UUID) {
        isActive = true
        ids = [id]
    }

    public func toggle(_ id: UUID) {
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        // Emptying the selection leaves the mode on: taking the last one back is
        // a correction, not a decision to stop selecting.
    }

    public func selectAll(_ all: [UUID]) {
        isActive = true
        ids = Set(all)
    }

    public func end() {
        isActive = false
        ids = []
    }

    /// The notebooks currently held, in the order they appear on screen.
    public func selected(from notebooks: [Notebook]) -> [Notebook] {
        notebooks.filter { ids.contains($0.id) }
    }
}

/// The bar that appears while notebooks are selected: what you have, and what
/// you can do to all of it at once.
public struct LibrarySelectionBar: View {
    @Environment(\.theme) private var theme

    let selection: LibrarySelection
    let shelves: [Shelf]
    let allIDs: [UUID]
    let onDelete: () -> Void
    let onMove: (UUID?) -> Void

    public init(
        selection: LibrarySelection,
        shelves: [Shelf],
        allIDs: [UUID],
        onDelete: @escaping () -> Void,
        onMove: @escaping (UUID?) -> Void
    ) {
        self.selection = selection
        self.shelves = shelves
        self.allIDs = allIDs
        self.onDelete = onDelete
        self.onMove = onMove
    }

    public var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.dsSubheadline.weight(.semibold))
                .foregroundStyle(theme.ink.color)
                .frame(minWidth: 96, alignment: .leading)

            Spacer(minLength: 4)

            Button(selection.count == allIDs.count ? "None" : "All") {
                if selection.count == allIDs.count {
                    selection.selectAll([])
                } else {
                    selection.selectAll(allIDs)
                }
            }
            .font(.dsSubheadline.weight(.medium))

            Menu {
                Button("No shelf") { onMove(nil) }
                if !shelves.isEmpty { Divider() }
                ForEach(shelves) { shelf in
                    Button(shelf.name) { onMove(shelf.id) }
                }
            } label: {
                Image(systemName: "tray.full")
                    .frame(width: 40, height: 36)
                    .contentShape(Rectangle())
            }
            .disabled(selection.isEmpty)
            .accessibilityLabel("Move to shelf")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
                    .frame(width: 40, height: 36)
                    .contentShape(Rectangle())
            }
            .disabled(selection.isEmpty)
            .accessibilityLabel("Delete selected")

            Button("Done") { selection.end() }
                .font(.dsSubheadline.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.ink.color)
        .padding(.horizontal, 16)
        .frame(height: 52)
        .dsGlass(in: Capsule(), interactive: true)
        .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
        .padding(.horizontal, 20)
    }

    private var title: String {
        switch selection.count {
        case 0: "Select notebooks"
        case 1: "1 selected"
        default: "\(selection.count) selected"
        }
    }
}

/// The tick that marks a selected notebook, and the dimming that marks an
/// unselected one while selection is on.
public struct SelectionBadge: ViewModifier {
    @Environment(\.theme) private var theme

    let isActive: Bool
    let isSelected: Bool

    public func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if isActive {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.dsSystem(size: 22, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            isSelected ? theme.contrastingInk(on: theme.accent).color : .white,
                            isSelected ? theme.accent.color : Color.black.opacity(0.28)
                        )
                        .padding(8)
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                }
            }
            .opacity(isActive && !isSelected ? 0.55 : 1)
            .animation(.easeInOut(duration: 0.18), value: isSelected)
            .animation(.easeInOut(duration: 0.18), value: isActive)
    }
}

extension View {
    /// Marks a library cell as selectable, ticked when it's held.
    public func librarySelectable(isActive: Bool, isSelected: Bool) -> some View {
        modifier(SelectionBadge(isActive: isActive, isSelected: isSelected))
    }
}
