import Foundation

/// Import/export of theme specs as JSON — used for the custom-theme
/// share format and for the preset parity fixture.
public enum ThemeJSON {
    public struct File: Codable, Sendable {
        public var version: Int
        public var themes: [ThemeSpec]

        public init(version: Int = 1, themes: [ThemeSpec]) {
            self.version = version
            self.themes = themes
        }
    }

    public static func encode(_ themes: [ThemeSpec]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(File(themes: themes))
    }

    public static func decode(_ data: Data) throws -> [ThemeSpec] {
        try JSONDecoder().decode(File.self, from: data).themes
    }
}

/// The pinned preset fixture bundled with the package (`themes.json`).
/// `PresetParityTests` asserts the Swift presets never drift from it.
public enum ThemeFixture {
    public struct Entry: Codable, Sendable {
        public let id: String
        public let displayName: String
        public let isDark: Bool
        public let accent: String
        public let accentMuted: String
        public let surface: String
        public let surfaceRaised: String
        public let paper: String
        public let ink: String
        public let inkSecondary: String
        public let separator: String
    }

    struct File: Codable {
        let version: Int
        let source: String
        let themes: [Entry]
    }

    public static func load() throws -> [Entry] {
        guard let url = Bundle.module.url(forResource: "themes", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(File.self, from: data).themes
    }
}
