import Foundation

/// What the user picked in Settings. `system` follows the OS between the plain
/// Light and Dark presets — same behavior as ClassMate.
public enum ThemeSelection: Hashable, Sendable {
    case system
    case preset(ThemePreset)
    case custom(UUID)

    public var rawValue: String {
        switch self {
        case .system: "system"
        case .preset(let preset): "preset:\(preset.rawValue)"
        case .custom(let id): "custom:\(id.uuidString)"
        }
    }

    public init?(rawValue: String) {
        if rawValue == "system" {
            self = .system
        } else if let presetID = rawValue.removingPrefix("preset:"),
                  let preset = ThemePreset(rawValue: presetID) {
            self = .preset(preset)
        } else if let uuidText = rawValue.removingPrefix("custom:"),
                  let uuid = UUID(uuidString: uuidText) {
            self = .custom(uuid)
        } else {
            return nil
        }
    }

    /// The spec for `system`, given the OS appearance.
    public static func systemSpec(prefersDark: Bool) -> ThemeSpec {
        (prefersDark ? ThemePreset.dark : ThemePreset.light).spec
    }
}

extension ThemeSelection: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let selection = ThemeSelection(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid theme selection: \(raw)"
            )
        }
        self = selection
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension String {
    fileprivate func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
