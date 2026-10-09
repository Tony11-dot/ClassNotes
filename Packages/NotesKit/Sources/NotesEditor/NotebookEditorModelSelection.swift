import CoreGraphics
import Foundation
import NotesModels

/// Edits that act on a WHOLE lasso selection at once.
///
/// Separate from `NotebookEditorModel` itself for the same reason
/// `NotebookEditorModelInsertions` is: the model's own body is already at
/// SwiftLint's size limit, and these are one self-contained concern.
///
/// Every single-element mutator on the model ends in
/// `DocumentStore.setElements`, which re-reads the manifest, re-encodes ALL of
/// it and writes it atomically. Called in a loop — which is what the lasso used
/// to do — moving a selection of a dozen photos was a dozen sequential
/// whole-manifest rewrites on the release of one drag, and the intermediate
/// eleven were thrown away. These do the same edits in memory and hit the disk
/// ONCE, which is the same bargain `NotebookRepository` already makes for a
/// batch delete in the library.
extension NotebookEditorModel {
    /// Removes every named element in one write.
    public func deleteElements(_ ids: [UUID], on pageID: UUID) async {
        guard !ids.isEmpty else { return }
        let doomed = Set(ids)
        await editElements(on: pageID) { elements in
            elements.removeAll { doomed.contains($0.id) }
        }
    }

    /// Shifts every named element, and any path it carries, in one write.
    public func moveElements(_ ids: [UUID], on pageID: UUID, by offset: CGSize) async {
        guard !ids.isEmpty, offset != .zero else { return }
        let moving = Set(ids)
        await editElements(on: pageID) { elements in
            for index in elements.indices where moving.contains(elements[index].id) {
                elements[index] = elements[index].moved(by: offset)
            }
        }
    }

    /// Applies one affine transform to every named element in one write.
    public func transformElements(
        _ ids: [UUID], on pageID: UUID, by transform: CGAffineTransform
    ) async {
        guard !ids.isEmpty else { return }
        let changing = Set(ids)
        await editElements(on: pageID) { elements in
            for index in elements.indices where changing.contains(elements[index].id) {
                elements[index] = elements[index].transformed(by: transform)
            }
        }
    }

    /// Turns every named element by `radians` about `pivot`, in one write
    /// (`PageElement.rotated`).
    public func rotateElements(
        _ ids: [UUID], on pageID: UUID, by radians: CGFloat, about pivot: CGPoint
    ) async {
        guard !ids.isEmpty, radians != 0 else { return }
        let turning = Set(ids)
        await editElements(on: pageID) { elements in
            for index in elements.indices where turning.contains(elements[index].id) {
                elements[index] = elements[index].rotated(by: radians, about: pivot)
            }
        }
    }

    /// Recolours every named element that has a colour of its own, in one
    /// write. Photos, files and the like are left as they are.
    public func recolorElements(_ ids: [UUID], on pageID: UUID, hex: String) async {
        guard !ids.isEmpty else { return }
        let changing = Set(ids)
        await editElements(on: pageID) { elements in
            for index in elements.indices where changing.contains(elements[index].id) {
                if let recoloured = elements[index].recoloured(hex) { elements[index] = recoloured }
            }
        }
    }

    /// Copies every named element, offset, in one write. Returns the new ids in
    /// the same order as the sources it could copy, so the caller can select
    /// exactly what it just made rather than diffing the page to find out.
    @discardableResult
    public func duplicateElements(
        _ ids: [UUID], on pageID: UUID, offset: CGSize
    ) async -> [UUID] {
        guard !ids.isEmpty else { return [] }
        var created: [UUID] = []
        await editElements(on: pageID) { elements in
            // `ids` order, not page order, so the returned ids line up with what
            // the caller asked for.
            for id in ids {
                guard let source = elements.first(where: { $0.id == id }) else { continue }
                var copy = source.moved(by: offset)
                copy.id = UUID()
                created.append(copy.id)
                elements.append(copy)
            }
        }
        return created
    }

    /// The one place a whole-selection edit touches the page: mutate the list in
    /// memory, publish it, write it once.
    private func editElements(
        on pageID: UUID, _ edit: (inout [PageElement]) -> Void
    ) async {
        guard var current = manifest,
              let pageIndex = current.pages.firstIndex(where: { $0.id == pageID })
        else { return }
        var elements = current.pages[pageIndex].elements
        edit(&elements)
        current.pages[pageIndex].elements = elements
        manifest = current
        await saveElements(elements, notebook: notebookID, page: pageID)
    }
}
