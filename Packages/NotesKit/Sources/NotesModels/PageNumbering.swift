import Foundation

/// How the app numbers pages: the cover is the cover, and page 1 is the first
/// page after it. The page manager, bookmarks and NOVA's page citations all
/// count this way, so "p. 3" in an answer opens the page labelled 3.
public enum PageNumbering {
    /// Each page's number, in page order: 0 for the cover.
    public static func numbers(of pages: [PageRecord]) -> [Int] {
        var count = 0
        return pages.map { page in
            guard !page.isCover else { return 0 }
            count += 1
            return count
        }
    }

    /// The page shown as `number` (0: the cover), if there is one.
    public static func page(numbered number: Int, in pages: [PageRecord]) -> PageRecord? {
        zip(pages, numbers(of: pages)).first { $0.1 == number }?.0
    }
}
