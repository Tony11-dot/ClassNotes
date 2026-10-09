import CoreGraphics

/// Rebuilding pages from PICTURES of them — what a notebook written on another
/// device is on this one, until its ink arrives: the renders the server keeps
/// for the ClassNotes tab (`NotebookRepository.adoptRemote`).
public enum PagePictureFit {
    /// The scale the editor renders a page at for the server
    /// (`EditorScreen.syncPageContent`). Kept here so the size a page was
    /// pictured at can be read back off the picture.
    public static let renderScale: CGFloat = 1.5

    /// The page a picture was taken of: the size and direction whose logical
    /// size, at `renderScale`, is the picture's pixel size; failing that, one of
    /// the same shape (an older build may have rendered at another scale); and
    /// failing that, `fallback`. Either of the first two means the picture fills
    /// the page edge to edge instead of sitting letterboxed on it. Nothing is
    /// printed under the picture — it already shows the paper it was drawn on.
    public static func style(forPixelSize pixels: CGSize, fallback: PageStyle) -> PageStyle {
        let candidates = [(fallback.pageSize, fallback.orientation)]
            + PageSize.allCases.flatMap { size in PageOrientation.allCases.map { (size, $0) } }
        guard pixels.width > 0, pixels.height > 0 else {
            return .imported(size: fallback.pageSize, orientation: fallback.orientation)
        }
        let logical = CGSize(width: pixels.width / renderScale, height: pixels.height / renderScale)
        // A couple of points either way: the render rounds to whole pixels.
        if let exact = candidates.first(where: { size, orientation in
            let page = size.size(orientation: orientation)
            return abs(page.width - logical.width) <= 2 && abs(page.height - logical.height) <= 2
        }) {
            return .imported(size: exact.0, orientation: exact.1)
        }
        let aspect = pixels.width / pixels.height
        if let shaped = candidates.first(where: { size, orientation in
            let page = size.size(orientation: orientation)
            return abs(page.width / page.height - aspect) <= aspect * 0.01
        }) {
            return .imported(size: shaped.0, orientation: shaped.1)
        }
        return .imported(size: fallback.pageSize, orientation: fallback.orientation)
    }

    /// Where a pictured page's voice notes, files and links go as working
    /// elements: stacked up from the bottom-right corner, each at the size the
    /// editor gives a new one. The picture already shows where each one was;
    /// these are the ones that play and open — and the ones the next push
    /// carries, so the server doesn't lose them either.
    public static func attachmentFrames(for kinds: [PageElement.Kind], pageSize: CGSize) -> [CGRect] {
        let inset: CGFloat = 24
        let gap: CGFloat = 12
        var bottom = pageSize.height - inset
        return kinds.map { kind in
            let size = chipSize(kind)
            bottom -= size.height
            let frame = CGRect(
                x: max(0, pageSize.width - inset - size.width), y: max(0, bottom),
                width: size.width, height: size.height
            )
            bottom -= gap
            return frame
        }
    }

    /// The editor's own sizes for a new voice note, file and link
    /// (`NotebookEditorModelInsertions`).
    static func chipSize(_ kind: PageElement.Kind) -> CGSize {
        switch kind {
        case .audio: CGSize(width: 240, height: 52)
        case .link: CGSize(width: 280, height: 60)
        default: CGSize(width: 260, height: 68)
        }
    }
}
