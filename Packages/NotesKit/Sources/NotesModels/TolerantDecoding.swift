import Foundation

// A manifest is decoded as ONE value, so a single field this build doesn't
// recognise used to fail the whole document: a template, paper size or tape
// pattern added in a later build read as "this notebook is unreadable", and the
// store then rebuilt the notebook from its ink blobs, dropping every image, text
// box, fill, bookmark and page setting it held. Every enum the manifest stores
// therefore decodes an unknown raw value to a safe display fallback instead of
// throwing. The original bytes survive regardless: `DocumentStore` keeps a copy
// of any manifest stamped newer than this build before it first rewrites it.

extension RawRepresentable where RawValue == String {
    static func decodeTolerantly(from decoder: Decoder, fallback: Self) throws -> Self {
        let raw = try decoder.singleValueContainer().decode(String.self)
        return Self(rawValue: raw) ?? fallback
    }
}

extension PageTemplate {
    /// An unknown template shows as plain paper; the ink is untouched.
    public init(from decoder: Decoder) throws {
        self = try .decodeTolerantly(from: decoder, fallback: .blank)
    }
}

extension PageSize {
    public init(from decoder: Decoder) throws {
        self = try .decodeTolerantly(from: decoder, fallback: .classic)
    }
}

extension PageOrientation {
    public init(from decoder: Decoder) throws {
        self = try .decodeTolerantly(from: decoder, fallback: .portrait)
    }
}

extension PageMargin.Position {
    public init(from decoder: Decoder) throws {
        self = try .decodeTolerantly(from: decoder, fallback: .leading)
    }
}

extension TapeShape {
    public init(from decoder: Decoder) throws {
        self = try .decodeTolerantly(from: decoder, fallback: .draw)
    }
}

extension TapePattern {
    public init(from decoder: Decoder) throws {
        self = try .decodeTolerantly(from: decoder, fallback: .solid)
    }
}

extension CodingUserInfoKey {
    /// Set to `true` to decode a damaged manifest entry by entry: a page or an
    /// element that won't decode is skipped instead of failing the document.
    /// Only `DocumentStore`'s recovery path uses it — what it skips is lost from
    /// THAT copy, which is why the store keeps the original bytes first.
    public static let manifestSalvage = CodingUserInfoKey(rawValue: "classnotes.manifestSalvage")!
}

extension Decoder {
    var isSalvaging: Bool { userInfo[.manifestSalvage] as? Bool == true }
}

/// An array that drops the entries it can't decode rather than failing.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                decoded.append(element)
            } else {
                // Step past the entry: a decode that reads nothing still advances.
                _ = try? container.decode(Skip.self)
            }
        }
        elements = decoded
    }

    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }
}
