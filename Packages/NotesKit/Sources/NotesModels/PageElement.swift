import CoreGraphics
import Foundation

/// Non-ink content placed on a page: an image/file, a voice note, or a block of
/// text (e.g. handwriting recognized into a chosen font). Positioned in the
/// fixed logical page space (`PageGeometry`). Binary payloads live beside the
/// manifest in the document package; this record just references them.
public struct PageElement: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case image
        case file
        case audio
        case text
    }

    public var id: UUID
    public var kind: Kind
    /// Frame in logical page points (768×1024 space).
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var rotation: Double

    /// For image/file/audio: the payload filename inside the package.
    public var payloadFilename: String?
    /// For file: a human display name; for audio: recorded duration seconds.
    public var displayName: String?
    public var durationSeconds: Double?
    /// For text: the content and the font family to typeset it in.
    public var text: String?
    public var fontName: String?
    public var textColorHex: String?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        rotation: Double = 0,
        payloadFilename: String? = nil,
        displayName: String? = nil,
        durationSeconds: Double? = nil,
        text: String? = nil,
        fontName: String? = nil,
        textColorHex: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.rotation = rotation
        self.payloadFilename = payloadFilename
        self.displayName = displayName
        self.durationSeconds = durationSeconds
        self.text = text
        self.fontName = fontName
        self.textColorHex = textColorHex
    }

    public var frame: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
