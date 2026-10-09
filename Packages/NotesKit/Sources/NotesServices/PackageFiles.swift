import CryptoKit
import Foundation

/// Which files of a notebook package travel between devices (D-003), and a
/// fingerprint of the ones that ARE the notebook.
///
/// Three kinds of file live in a package:
/// - content: the manifest, page ink (live and in Recently Deleted), the page
///   trash and media. A change here is a change to the notebook.
/// - description and renders: `info.json` and `cover.png`. They travel, but
///   aren't content: the description is reconciled newest-wins on its own
///   clock, and the cover is redrawn from the content.
/// - this device's own: the search index (derived) and every recovery
///   artefact (the manifest backup, quarantined files, a copy kept for a newer
///   build). They never travel; another device has its own.
public enum PackageFiles {

    public static func isLocalOnly(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix(".")
            || name == "search.json"
            || name == "manifest.backup.json"
            || name.hasPrefix("manifest.unreadable")
            || (name.hasPrefix("manifest.v") && name.hasSuffix(".json"))
            || name.hasSuffix(".unreadable")
    }

    public static func isContent(_ path: String) -> Bool {
        path == "manifest.json" || path == "trash.json"
            || path.hasPrefix("pages/") || path.hasPrefix("media/")
    }

    /// The files that travel, as paths relative to the package, sorted.
    public static func syncedFiles(in package: URL) -> [String] {
        let base = package.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(
            at: package, includingPropertiesForKeys: [.isRegularFileKey], options: []
        ) else { return [] }
        var paths: [String] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base) else { continue }
            let relative = String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !isLocalOnly(relative) { paths.append(relative) }
        }
        return paths.sorted()
    }

    /// SHA-256 over each content file's path and bytes. Equal on two devices
    /// exactly when the notebook's content is equal, whatever the files'
    /// dates.
    public static func fingerprint(of package: URL) -> String {
        var hasher = SHA256()
        for path in syncedFiles(in: package) where isContent(path) {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            if let data = try? Data(contentsOf: package.appendingPathComponent(path)) {
                hasher.update(data: Data(SHA256.hash(data: data)))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A cheap stand-in for "did anything change": every content file's path,
    /// size and modification time. Used to skip re-hashing an untouched
    /// notebook; the fingerprint is what's compared.
    public static func stamp(of package: URL) -> String {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        return syncedFiles(in: package).filter(isContent).map { path in
            let values = try? package.appendingPathComponent(path).resourceValues(forKeys: keys)
            return "\(path):\(values?.fileSize ?? -1):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
    }

    /// Copies the files that travel into a NEW folder at `destination`.
    public static func copySynced(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for path in syncedFiles(in: source) {
            let target = destination.appendingPathComponent(path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source.appendingPathComponent(path), to: target)
        }
    }

    /// Makes `destination`'s travelling files the same as `source`'s, writing
    /// only what differs: a page drawn on is one file uploaded, not the
    /// notebook. Files that are this device's own are left alone.
    ///
    /// `leaving`: paths not touched either way (the description, which is
    /// reconciled newest-wins on its own).
    public static func mirror(from source: URL, to destination: URL, leaving: Set<String> = []) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let wanted = syncedFiles(in: source).filter { !leaving.contains($0) }
        let wantedSet = Set(wanted)
        for path in syncedFiles(in: destination) where !wantedSet.contains(path) && !leaving.contains(path) {
            try fm.removeItem(at: destination.appendingPathComponent(path))
        }
        for path in wanted {
            let from = source.appendingPathComponent(path)
            let to = destination.appendingPathComponent(path)
            if fm.fileExists(atPath: to.path),
               (try? Data(contentsOf: to)) == (try? Data(contentsOf: from)) { continue }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staged = to.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).part")
            try fm.copyItem(at: from, to: staged)
            if fm.fileExists(atPath: to.path) {
                _ = try fm.replaceItemAt(to, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: to)
            }
        }
    }

    /// Notebook ids with a package in `folder`.
    public static func packageIDs(in folder: URL) -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name in
            // An iCloud placeholder for a package not yet on this device is
            // ".<id>.cmnote.icloud".
            var trimmed = name
            if trimmed.hasPrefix("."), trimmed.hasSuffix(".icloud") {
                trimmed = String(trimmed.dropFirst().dropLast(".icloud".count))
            }
            guard trimmed.hasSuffix("." + DocumentStore.fileExtension) else { return nil }
            return UUID(uuidString: String(trimmed.dropLast(DocumentStore.fileExtension.count + 1)))
        }
    }
}
