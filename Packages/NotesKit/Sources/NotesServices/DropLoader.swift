import Foundation
import NotesModels
import UniformTypeIdentifiers

/// Reads what a drag carries into a `DroppedItem`, choosing what it becomes
/// by `DropRouting` so a page, the library and the tests agree.
///
/// On the main actor because the providers come from a drop session there
/// and aren't `Sendable`; the reading itself happens in the providers' own
/// handlers, off the main thread.
@MainActor
public enum DropLoader {

    /// Biggest file a drop will read. A drop is read whole into memory before
    /// it is stored; a file far past this is a video or an archive nobody
    /// meant to put on a page, and reading it would cost the editor its memory.
    public nonisolated static let maximumBytes = 200 * 1024 * 1024

    /// What the drag offers, as an item; nil when it offers nothing usable or
    /// the read failed. Never throws: a drop that can't be read is reported by
    /// the caller as "couldn't read that", and nothing on the page changes.
    public static func load(_ provider: NSItemProvider) async -> DroppedItem? {
        let identifiers = provider.registeredTypeIdentifiers
        guard let kind = DropRouting.kind(for: identifiers) else { return nil }
        let name = provider.suggestedName
        switch kind {
        case .link:
            guard let url = await object(URL.self, from: provider), url.scheme?.hasPrefix("http") == true
            else { return await text(from: provider) }
            return .link(url)
        case .text:
            return await text(from: provider)
        case .pdf, .image, .file:
            let identifier = DropRouting.identifier(for: kind, in: identifiers) ?? UTType.item.identifier
            guard let data = await fileData(identifier, from: provider) else { return nil }
            let ext = DropRouting.fileExtension(suggestedName: name, identifier: identifier)
            let title = name.map { ($0 as NSString).deletingPathExtension } ?? ""
            switch kind {
            case .pdf: return .pdf(data, name: title)
            case .image: return .image(data, name: title, fileExtension: ext)
            default: return .file(data, name: name ?? "File.\(ext)", fileExtension: ext)
            }
        }
    }

    private static func text(from provider: NSItemProvider) async -> DroppedItem? {
        guard let string = await object(String.self, from: provider),
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .text(string)
    }

    private static func object<T: _ObjectiveCBridgeable & Sendable>(
        _ type: T.Type, from provider: NSItemProvider
    ) async -> T? where T._ObjectiveCType: NSItemProviderReading {
        guard provider.canLoadObject(ofClass: type) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { value, _ in
                continuation.resume(returning: value)
            }
        }
    }

    /// The bytes, read inside the handler: the file it hands over is deleted
    /// the moment the handler returns.
    private static func fileData(_ identifier: String, from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                guard let url,
                      let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= maximumBytes
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: try? Data(contentsOf: url))
            }
        }
    }
}
