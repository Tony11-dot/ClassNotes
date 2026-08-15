import SwiftUI
import UIKit

/// A file on disk, wrapped so it can drive `.sheet(item:)`.
///
/// Exported PDFs are shared as FILES, not as `Data`: a share sheet handed raw
/// data gives the other end a nameless blob, and the whole point of exporting a
/// notebook is that it arrives called what the notebook is called.
public struct SharedFile: Identifiable, Equatable {
    public var id: URL { url }
    public let url: URL

    public init(url: URL) {
        self.url = url
    }
}

/// The system share sheet. SwiftUI's `ShareLink` needs its item up front, which
/// an export can't provide — the PDF doesn't exist until it has been rendered.
public struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    public init(items: [Any]) {
        self.items = items
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    public func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
