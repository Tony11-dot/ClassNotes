import Foundation
import ImageIO
import NotesModels
import SwiftData

/// Notebooks that live on another device (`Notebook.isRemoteOnly`).
extension NotebookRepository {

    /// Makes a notebook written on another device editable HERE, from the
    /// server's pictures of its pages — "Edit on this iPad".
    ///
    /// Its ink is on the device that wrote it, and the server keeps only
    /// pictures, so each page becomes its picture as a background
    /// (`DocumentStore.createDocument(id:fromPictures:)`): written over, never
    /// erased or moved. Every page comes, in order — the cover as the cover
    /// when the server has a cover render — and so does every voice note, file
    /// and link, as working elements: leaving the editor pushes this device's
    /// pages, and a page pushed without them would delete them from the server.
    /// So `pages` must be a COMPLETE fresh fetch (`RemoteNotebookCache.freshPages`),
    /// never the offline cache, which keeps only the pictures.
    ///
    /// Same id: the notebook stops being remote-only and opens in the editor.
    /// If the real ink ever arrives through iCloud, sync keeps both.
    public func adoptRemote(
        _ notebook: Notebook, pages: [RemoteNotebookCache.Page], coverRender: Data?
    ) async throws {
        guard notebook.isRemoteOnly else { return }
        let hasCover = coverRender != nil && notebook.usesCoverPage
        var pictured: [DocumentStore.PicturePage] = []
        for (index, page) in pages.enumerated() {
            let picture = try Data(contentsOf: page.imageURL)
            pictured.append(DocumentStore.PicturePage(
                picture: picture,
                pictureExtension: Self.imageExtension(of: picture),
                style: PagePictureFit.style(forPixelSize: Self.pixelSize(of: picture), fallback: notebook.pageStyle),
                isCover: hasCover && index == 0,
                attachments: try page.attachments.compactMap(Self.pictureAttachment)
            ))
        }
        if pictured.isEmpty {
            // The server has no pictures of it at all: nothing to carry over.
            try await store.createDocument(id: notebook.id, style: notebook.pageStyle, includesCover: notebook.usesCoverPage)
        } else {
            try await store.createDocument(id: notebook.id, fromPictures: pictured, coverRender: hasCover ? coverRender : nil)
            // New pages match the ones that came over.
            if let page = pictured.first(where: { !$0.isCover }) ?? pictured.first {
                notebook.pageSizeRaw = page.style.pageSize.rawValue
                notebook.orientationRaw = page.style.orientation.rawValue
            }
        }
        notebook.isRemoteOnly = false
        notebook.updatedAt = .now
        revise([notebook])
        try? context.save()
        await mirrorInfo([notebook])
        sync?.pushNotebook(snapshot(notebook))
    }

    /// A voice note, file or link from the server, with its bytes read in.
    /// A recording or file whose bytes didn't come down throws: carrying the
    /// rest over without it would push its absence to the server.
    private static func pictureAttachment(
        _ attachment: RemoteNotebookCache.Attachment
    ) throws -> DocumentStore.PictureAttachment? {
        switch attachment.kind {
        case "link":
            guard let url = attachment.linkURL else { return nil }
            return DocumentStore.PictureAttachment(kind: .link, name: attachment.name, url: url)
        case "audio", "file":
            guard let fileURL = attachment.fileURL else { throw RemoteNotebookCache.FetchError.incomplete }
            return DocumentStore.PictureAttachment(
                kind: attachment.kind == "audio" ? .audio : .file,
                name: attachment.name,
                durationSeconds: attachment.durationSeconds,
                payload: try Data(contentsOf: fileURL),
                payloadExtension: fileURL.pathExtension.isEmpty ? "bin" : fileURL.pathExtension
            )
        default:
            return nil
        }
    }

    /// A picture's size in pixels, read from its header without decoding it.
    static func pixelSize(of data: Data) -> CGSize {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        else { return .zero }
        return CGSize(width: width, height: height)
    }

    /// The server sends JPEG renders now and sent PNGs before; the cache
    /// names both `.png`, so the type is read from the bytes.
    static func imageExtension(of data: Data) -> String {
        data.starts(with: [0xFF, 0xD8, 0xFF]) ? "jpg" : "png"
    }
}
