import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI
import UIKit

/// The bar across the top of the grid: All, Favourites, the top-level shelves
/// and the tags, then a second row inside the chosen shelf (where it sits, and
/// the shelves inside it). Every chip is also a drop target: drag a cover onto
/// a shelf to file it, onto a tag to tag it, onto All to take it off its shelf.
extension LibraryGridScreen {

    var shelfTree: ShelfTree { ShelfTree(shelves.map { ($0.id, $0.parentID) }) }
    private var shelfOrder: [UUID] { shelves.map(\.id) }
    var allTags: [String] { NotebookTags.all(in: liveNotebooks.map(\.tags)) }

    private func shelf(_ id: UUID) -> Shelf? { shelves.first { $0.id == id } }

    /// "Biology › Cells": a shelf named with the shelves it sits inside.
    func shelfPathName(_ id: UUID) -> String {
        (shelfTree.ancestors(of: id).reversed() + [id])
            .compactMap { shelf($0)?.name }
            .joined(separator: " › ")
    }

    private var selectedShelfID: UUID? {
        if case .shelf(let id) = selectedShelf { return id }
        return nil
    }

    /// The top-level shelf the current one is in (or is).
    private var selectedRootID: UUID? {
        selectedShelfID.map { shelfTree.ancestors(of: $0).last ?? $0 }
    }

    var shelfBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            topRow
            if let id = selectedShelfID,
               shelfTree.parent(of: id) != nil || !shelfTree.children(of: id, in: shelfOrder).isEmpty {
                innerRow(id)
            }
        }
    }

    private var topRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                dropChip("all", ChipLabel(title: "All", symbol: "square.grid.2x2", color: theme.accent),
                         isSelected: selectedShelf == .all,
                         action: { selectedShelf = .all },
                         onDrop: { file($0, onto: nil) })
                if favoritesCount > 0 {
                    shelfChip(
                        title: "Favourites", symbol: "star.fill", color: theme.accent,
                        isSelected: selectedShelf == .favorites
                    ) {
                        selectedShelf = .favorites
                    }
                }
                ForEach(shelfTree.children(of: nil, in: shelfOrder), id: \.self) { id in
                    if let shelf = shelf(id) { shelfDropChip(shelf, isSelected: selectedRootID == id) }
                }
                ForEach(allTags, id: \.self) { tag in
                    dropChip("tag:" + tag.lowercased(), ChipLabel(title: tag, symbol: "number", color: theme.accent),
                             isSelected: selectedShelf == .tag(tag),
                             action: { selectedShelf = .tag(tag) },
                             onDrop: { self.tag($0, with: tag) })
                    .contextMenu {
                        Button(role: .destructive) {
                            if selectedShelf == .tag(tag) { selectedShelf = .all }
                            services.repository.removeTagEverywhere(tag)
                        } label: {
                            Label("Remove from every notebook", systemImage: "tag.slash")
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
        }
    }

    /// Inside a shelf: a way back up, where you are, and what's inside.
    private func innerRow(_ id: UUID) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let parent = shelfTree.parent(of: id) {
                    Button {
                        selectedShelf = .shelf(parent)
                    } label: {
                        Label(shelf(parent)?.name ?? "Back", systemImage: "chevron.backward")
                            .font(.dsSubheadline.weight(.medium))
                            .frame(minHeight: 36)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent.color)
                    .accessibilityLabel("Back to \(shelf(parent)?.name ?? "the shelf above")")
                }
                Text(shelfPathName(id))
                    .font(.dsCaption.weight(.semibold))
                    .foregroundStyle(theme.inkSecondary.color)
                    .padding(.horizontal, 4)
                ForEach(shelfTree.children(of: id, in: shelfOrder), id: \.self) { child in
                    if let shelf = shelf(child) { shelfDropChip(shelf, isSelected: false) }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 10)
        }
    }

    private func shelfDropChip(_ shelf: Shelf, isSelected: Bool) -> some View {
        dropChip(
            shelf.id.uuidString,
            ChipLabel(title: shelf.name, symbol: shelf.symbolName, color: ThemeColor(hex: shelf.colorHex) ?? theme.accent),
            isSelected: isSelected,
            action: { selectedShelf = .shelf(shelf.id) },
            onDrop: { file($0, onto: shelf.id) }
        )
        .contextMenu { shelfMenu(shelf) }
    }

    @ViewBuilder
    private func shelfMenu(_ shelf: Shelf) -> some View {
        Button {
            newShelfParent = shelf
        } label: {
            Label("New shelf inside", systemImage: "folder.badge.plus")
        }
        let targets = shelves.filter {
            $0.id != shelf.parentID && shelfTree.canMove(shelf.id, under: $0.id)
        }
        if shelf.parentID != nil || !targets.isEmpty {
            Menu {
                if shelf.parentID != nil {
                    Button("Top of the library") { services.repository.moveShelf(shelf, under: nil) }
                }
                ForEach(targets) { target in
                    Button(shelfPathName(target.id)) { services.repository.moveShelf(shelf, under: target.id) }
                }
            } label: {
                Label("Move into", systemImage: "folder")
            }
        }
        Button(role: .destructive) {
            if let selected = selectedShelfID, shelfTree.subtree(of: shelf.id).contains(selected) {
                selectedShelf = shelfTree.parent(of: shelf.id).map(ShelfFilter.shelf) ?? .all
            }
            try? services.repository.deleteShelf(shelf)
        } label: {
            Label("Delete shelf (keeps what's in it)", systemImage: "trash")
        }
    }

    /// What a chip shows.
    struct ChipLabel {
        let title: String
        let symbol: String
        let color: ThemeColor
    }

    /// A chip that takes dropped covers, and lights up while one is over it.
    private func dropChip(
        _ key: String, _ label: ChipLabel, isSelected: Bool,
        action: @escaping () -> Void, onDrop: @escaping ([String]) -> Bool
    ) -> some View {
        shelfChip(
            title: label.title, symbol: label.symbol, color: label.color,
            isSelected: isSelected || dropTarget == key, action: action
        )
            .scaleEffect(dropTarget == key ? 1.08 : 1)
            .animation(.spring(duration: 0.2), value: dropTarget == key)
            .dropDestination(for: String.self) { ids, _ in
                onDrop(ids)
            } isTargeted: { over in
                if over {
                    dropTarget = key
                } else if dropTarget == key {
                    dropTarget = nil
                }
            }
    }

    func shelfChip(
        title: String,
        symbol: String,
        color: ThemeColor,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.dsSubheadline.weight(.medium))
                .foregroundStyle(isSelected ? theme.contrastingInk(on: color).color : theme.ink.color)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    isSelected ? color.color : theme.surfaceRaised.color,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Drops

    private func dropped(_ ids: [String]) -> [Notebook] {
        let wanted = Set(ids.compactMap(UUID.init(uuidString:)))
        return liveNotebooks.filter { wanted.contains($0.id) }
    }

    private func file(_ ids: [String], onto shelfID: UUID?) -> Bool {
        let notebooks = dropped(ids)
        guard !notebooks.isEmpty else { return false }
        try? services.repository.setShelf(shelfID, for: notebooks)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return true
    }

    private func tag(_ ids: [String], with tag: String) -> Bool {
        let notebooks = dropped(ids)
        guard !notebooks.isEmpty else { return false }
        services.repository.addTag(tag, to: notebooks)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return true
    }
}
