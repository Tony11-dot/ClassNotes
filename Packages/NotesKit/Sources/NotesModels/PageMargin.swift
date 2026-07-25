import Foundation

/// The notebook margin line — the vertical rule down one side of a page. Default
/// is a leading (left) line whose color is derived from the paper unless the
/// user overrides it. Lives per-page in the manifest (v3; older manifests load
/// with the default leading margin).
public struct PageMargin: Codable, Sendable, Equatable {
    public enum Position: String, Codable, Sendable, CaseIterable, Identifiable {
        case none
        case leading
        case trailing

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .none: "None"
            case .leading: "Left"
            case .trailing: "Right"
            }
        }
    }

    public var position: Position
    /// `nil` = auto (derived from the paper by the renderer).
    public var colorHex: String?
    /// Distance of the line from the page edge, in logical page points.
    public var offset: Double

    public init(position: Position = .leading, colorHex: String? = nil, offset: Double = 72) {
        self.position = position
        self.colorHex = colorHex
        self.offset = offset
    }

    /// The default a fresh page gets: a left margin, auto-colored.
    public static let `default` = PageMargin()
}
