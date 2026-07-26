import CoreText
import Foundation
import NotesModels
import Observation

/// Holds the user's uploaded fonts (OTF/TTF) so they can be used to beautify
/// handwriting and style text. Files are copied into Application Support, so
/// they survive relaunch; each is registered with Core Text at launch/import so
/// `Font.custom(postScriptName:)` resolves it. A small JSON registry remembers
/// the display name + PostScript name → file mapping.
@MainActor
@Observable
public final class CustomFontStore {
    public private(set) var fonts: [HandwritingFont] = []

    private let dir: URL
    private let registryURL: URL

    private struct Entry: Codable {
        let id: String
        let displayName: String
        let fontName: String
        let fileName: String
    }

    public init(rootURL: URL? = nil) {
        let base = rootURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        dir = base.appendingPathComponent("Fonts", isDirectory: true)
        registryURL = dir.appendingPathComponent("registry.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        loadAndRegister()
    }

    private func loadAndRegister() {
        guard let data = try? Data(contentsOf: registryURL),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        var loaded: [HandwritingFont] = []
        for entry in entries {
            let url = dir.appendingPathComponent(entry.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            loaded.append(HandwritingFont(
                id: entry.id, displayName: entry.displayName,
                fontName: entry.fontName, category: .custom
            ))
        }
        fonts = loaded
    }

    /// Import an OTF/TTF from `url`: copy it in, register it, read its real
    /// PostScript + family name from the file, and add it to the pack. Returns
    /// the new font (or an existing one if already imported), nil on failure.
    @discardableResult
    public func importFont(from url: URL) -> HandwritingFont? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.isEmpty ? "ttf" : url.pathExtension.lowercased()
        let fileName = "\(UUID().uuidString).\(ext)"
        let dest = dir.appendingPathComponent(fileName)
        guard (try? data.write(to: dest)) != nil else { return nil }

        guard CTFontManagerRegisterFontsForURL(dest as CFURL, .process, nil),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(dest as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first else {
            try? FileManager.default.removeItem(at: dest)
            return nil
        }

        let ctFont = CTFontCreateWithFontDescriptor(descriptor, 0, nil)
        let psName = CTFontCopyPostScriptName(ctFont) as String
        let family = (CTFontCopyName(ctFont, kCTFontFamilyNameKey) as String?)
            ?? url.deletingPathExtension().lastPathComponent

        // Already have this exact face — reuse it and drop the duplicate file.
        if let existing = fonts.first(where: { $0.fontName == psName }) {
            try? FileManager.default.removeItem(at: dest)
            return existing
        }

        let font = HandwritingFont(
            id: "custom-\(psName)", displayName: family, fontName: psName, category: .custom
        )
        fonts.append(font)
        persistAppending(Entry(
            id: font.id, displayName: font.displayName,
            fontName: font.fontName, fileName: fileName
        ))
        return font
    }

    public func resolve(id: String) -> HandwritingFont? {
        fonts.first { $0.id == id }
    }

    private func persistAppending(_ entry: Entry) {
        var entries: [Entry] = []
        if let data = try? Data(contentsOf: registryURL),
           let existing = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = existing
        }
        entries.append(entry)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: registryURL)
        }
    }
}
