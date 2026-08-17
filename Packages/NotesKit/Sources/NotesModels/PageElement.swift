import CoreGraphics
import Foundation

/// A point in logical page space, Codable so freeform tape paths survive in the
/// manifest.
public struct PagePoint: Codable, Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(_ point: CGPoint) {
        self.x = point.x
        self.y = point.y
    }

    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

/// Non-ink content placed on a page: an image/file/link, a voice note, a block of
/// text (a typeset text box, or handwriting beautified into a chosen font), or a
/// strip of sticky tape that masks whatever is underneath. Positioned in the
/// page's logical space (`PageRecord.logicalSize`). Binary payloads live beside
/// the manifest in the document package; this record just references them.
public struct PageElement: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case image
        case file
        case audio
        case text
        /// Sticky tape: covers the content under it until tapped.
        case tape
        /// A tappable web link.
        case link
        /// A closed region of the page flooded with colour. Its `points` are the
        /// region's outline in page space, traced from where the ink bounded it,
        /// so it stops exactly where the drawing does.
        case fill
        /// A typeset block of source code: monospaced, coloured, on its own
        /// background — reuses the same text/font/colour fields `.text` does.
        case codeBlock
        /// An element kind this build doesn't recognise. Decoding to this
        /// instead of throwing is what keeps a page's OTHER elements intact
        /// when an older binary opens a document a newer one wrote to.
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    public var id: UUID
    public var kind: Kind
    /// Frame in the page's logical points.
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
    /// For text/codeBlock: the content and the font family to typeset it in.
    public var text: String?
    public var fontName: String?
    public var textColorHex: String?
    /// For codeBlock: `CodeLanguage.rawValue` — both the label shown and what
    /// `CodeSyntaxHighlighter` colours the text as. `nil`/unrecognized reads
    /// as `.plaintext` (uncoloured), never a throw.
    public var codeLanguage: String?
    /// For codeBlock: the background box's corner radius in logical points
    /// (nil = `CodeBlockSettings.defaultCornerRadius`).
    public var codeCornerRadius: Double?
    /// For text: the type size in logical page points (nil = the legacy 20 pt).
    public var fontSize: Double?
    /// For text: the line-height MULTIPLE the run was laid out at (nil = 1.0).
    /// Beautification sizes its box from this, so the box and the drawn text have
    /// to agree — leaving it out is how a run laid out at 2.4× got drawn at 1×
    /// inside a box three lines tall.
    public var lineSpacing: Double?
    /// For text: draw with a heavier weight (beautification's "Dynamic Bold").
    public var isBold: Bool
    /// For link: the destination.
    public var urlString: String?

    // MARK: Tape

    /// For tape: how the strip was laid down (freeform / straight / rectangle).
    public var tapeShape: TapeShape?
    /// For tape: the printed pattern.
    public var tapePattern: TapePattern?
    /// For tape: the strip's colour (`nil` = the theme's muted accent). For
    /// codeBlock: the background box's colour (`nil` = `CodeBlockSettings.defaultBackgroundHex`).
    public var colorHex: String?
    /// For tape: the freeform / line path in logical page points, relative to the
    /// page (not the element frame). Empty for rectangles.
    public var points: [PagePoint]
    /// For tape: the strip's thickness in logical points.
    public var strokeWidth: Double?
    /// For tape: `true` = the strip is lifted, so what's underneath shows through
    /// and only the outline remains. Tapping toggles it.
    public var isHidden: Bool

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
        textColorHex: String? = nil,
        codeLanguage: String? = nil,
        codeCornerRadius: Double? = nil,
        fontSize: Double? = nil,
        lineSpacing: Double? = nil,
        isBold: Bool = false,
        urlString: String? = nil,
        tapeShape: TapeShape? = nil,
        tapePattern: TapePattern? = nil,
        colorHex: String? = nil,
        points: [PagePoint] = [],
        strokeWidth: Double? = nil,
        isHidden: Bool = false
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
        self.codeLanguage = codeLanguage
        self.codeCornerRadius = codeCornerRadius
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.isBold = isBold
        self.urlString = urlString
        self.tapeShape = tapeShape
        self.tapePattern = tapePattern
        self.colorHex = colorHex
        self.points = points
        self.strokeWidth = strokeWidth
        self.isHidden = isHidden
    }

    public var frame: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// Text elements render at this size; older elements had a fixed 20 pt.
    public static let legacyTextSize: Double = 20

    public var resolvedFontSize: Double { fontSize ?? Self.legacyTextSize }

    /// The line-height multiple to draw the run at. Single-spaced unless the run
    /// was laid out otherwise.
    public var resolvedLineSpacing: Double { max(lineSpacing ?? 1, 0.5) }

    /// Extra leading, in points, to hand SwiftUI's `.lineSpacing` — which takes the
    /// gap BETWEEN lines, not a multiple of the line height.
    public var extraLeading: Double {
        max(0, (resolvedLineSpacing - 1) * resolvedFontSize)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, x, y, width, height, rotation
        case payloadFilename, displayName, durationSeconds
        case text, fontName, textColorHex, fontSize, lineSpacing, isBold, urlString
        case codeLanguage, codeCornerRadius
        case tapeShape, tapePattern, colorHex, points, strokeWidth, isHidden
    }

    /// Custom decode so v2–v5 elements (which had none of the tape / text-size /
    /// link fields) load without loss.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        payloadFilename = try c.decodeIfPresent(String.self, forKey: .payloadFilename)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName)
        textColorHex = try c.decodeIfPresent(String.self, forKey: .textColorHex)
        codeLanguage = try c.decodeIfPresent(String.self, forKey: .codeLanguage)
        codeCornerRadius = try c.decodeIfPresent(Double.self, forKey: .codeCornerRadius)
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize)
        lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing)
        isBold = try c.decodeIfPresent(Bool.self, forKey: .isBold) ?? false
        urlString = try c.decodeIfPresent(String.self, forKey: .urlString)
        tapeShape = try c.decodeIfPresent(TapeShape.self, forKey: .tapeShape)
        tapePattern = try c.decodeIfPresent(TapePattern.self, forKey: .tapePattern)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        points = try c.decodeIfPresent([PagePoint].self, forKey: .points) ?? []
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth)
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
    }
}
