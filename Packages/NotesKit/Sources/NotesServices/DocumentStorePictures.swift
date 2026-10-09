import Foundation
import NotesModels

/// A notebook rebuilt from PICTURES of its pages — the renders the server keeps
/// of a notebook written on another device (`NotebookRepository.adoptRemote`).
/// Each picture becomes its page's background, so the whole tool set works over
/// it: what was there can't be erased or moved, but it can be written on.
extension DocumentStore {

    /// One pictured page.
    public struct PicturePage: Sendable {
        public var picture: Data
        /// The picture's own type (`jpg`, `png`): the bytes are kept as they came.
        public var pictureExtension: String
        public var style: PageStyle
        /// The notebook's cover: its artwork stays the paper, under the picture.
        public var isCover: Bool
        public var attachments: [PictureAttachment]

        public init(
            picture: Data, pictureExtension: String, style: PageStyle,
            isCover: Bool = false, attachments: [PictureAttachment] = []
        ) {
            self.picture = picture
            self.pictureExtension = pictureExtension
            self.style = style
            self.isCover = isCover
            self.attachments = attachments
        }
    }

    /// A voice note, file or link that was on a pictured page.
    public struct PictureAttachment: Sendable {
        /// `.audio`, `.file` or `.link`.
        public var kind: PageElement.Kind
        public var name: String
        public var durationSeconds: Double?
        /// The recording or file; nil for a link.
        public var payload: Data?
        public var payloadExtension: String
        public var url: String?

        public init(
            kind: PageElement.Kind, name: String, durationSeconds: Double? = nil,
            payload: Data? = nil, payloadExtension: String = "bin", url: String? = nil
        ) {
            self.kind = kind
            self.name = name
            self.durationSeconds = durationSeconds
            self.payload = payload
            self.payloadExtension = payloadExtension
            self.url = url
        }
    }

    /// Writes a new package whose pages are these pictures, in order, with
    /// their voice notes, files and links as working elements, and `coverRender`
    /// as the library tile until the editor renders its own.
    ///
    /// The package appears whole or not at all: it is put together in a
    /// temporary folder and moved into place in one step, so a failure part-way
    /// can't leave a half-written notebook for the library to find. Never over
    /// a package that is already here (`alreadyExists`).
    @discardableResult
    public func createDocument(
        id: UUID, fromPictures pages: [PicturePage], coverRender: Data? = nil
    ) throws -> NotebookManifest {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: documentURL(for: id).path) else { throw DocumentError.alreadyExists }
        let staging = fm.temporaryDirectory
            .appendingPathComponent("cmnote-pictures-\(UUID().uuidString)", isDirectory: true)
        let media = staging.appendingPathComponent("media", isDirectory: true)
        do {
            try fm.createDirectory(at: staging.appendingPathComponent("pages", isDirectory: true),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: media, withIntermediateDirectories: true)
            func keep(_ data: Data, as fileExtension: String) throws -> String {
                let filename = "\(UUID().uuidString).\(fileExtension)"
                try data.write(to: media.appendingPathComponent(filename), options: .atomic)
                return filename
            }
            var records: [PageRecord] = []
            for page in pages {
                var record = page.isCover ? page.style.makeCoverPage() : page.style.makePage()
                record.backgroundPayloadFilename = try keep(page.picture, as: page.pictureExtension)
                let frames = PagePictureFit.attachmentFrames(
                    for: page.attachments.map(\.kind), pageSize: record.logicalSize
                )
                for (attachment, frame) in zip(page.attachments, frames) {
                    let filename = try attachment.payload.map { try keep($0, as: attachment.payloadExtension) }
                    guard filename != nil || attachment.url != nil else { continue }
                    record.elements.append(PageElement(
                        kind: attachment.kind,
                        x: frame.minX, y: frame.minY, width: frame.width, height: frame.height,
                        payloadFilename: filename, displayName: attachment.name,
                        durationSeconds: attachment.durationSeconds, urlString: attachment.url
                    ))
                }
                records.append(record)
            }
            if let coverRender {
                try coverRender.write(to: staging.appendingPathComponent("cover.png"), options: .atomic)
            }
            let manifest = NotebookManifest(pages: records)
            try encoder.encode(manifest).write(
                to: staging.appendingPathComponent("manifest.json"), options: .atomic
            )
            try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try fm.moveItem(at: staging, to: documentURL(for: id))
            forgetCaches(for: id)
            return manifest
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }
}
