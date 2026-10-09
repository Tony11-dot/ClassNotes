import CoreGraphics
@testable import NotesModels
import Testing

/// Reading a page back off a picture of it (`PagePictureFit`), for "Edit on
/// this iPad".
@Suite("Page picture fit")
struct PagePictureFitTests {
    @Test("A picture is read back to the page it was rendered from")
    func pictureFit() {
        let fallback = PageStyle(template: .ruled, pageSize: .letter, orientation: .portrait)
        let scale = PagePictureFit.renderScale
        // Exactly the size, at the render scale — A4 rounds to whole pixels.
        let a4 = PagePictureFit.style(
            forPixelSize: CGSize(width: (842 * scale).rounded(), height: (595 * scale).rounded()), fallback: fallback
        )
        #expect(a4.pageSize == .a4 && a4.orientation == .landscape)
        #expect(a4.template == PageStyle.imported(size: .a4, orientation: .landscape).template)
        // Another scale, same shape: the shape decides.
        let classic = PagePictureFit.style(forPixelSize: CGSize(width: 1536, height: 2048), fallback: fallback)
        #expect(classic.pageSize == .classic && classic.orientation == .portrait)
        // Nothing like any page: the notebook's own size.
        let odd = PagePictureFit.style(forPixelSize: CGSize(width: 1000, height: 300), fallback: fallback)
        #expect(odd.pageSize == .letter && odd.orientation == .portrait)
        #expect(PagePictureFit.style(forPixelSize: .zero, fallback: fallback).pageSize == .letter)
    }

    @Test("A page's voice notes, files and links stack up from the corner without overlapping")
    func attachmentFrames() {
        let page = CGSize(width: 768, height: 1024)
        let frames = PagePictureFit.attachmentFrames(for: [.audio, .file, .link], pageSize: page)
        #expect(frames.count == 3)
        for (index, frame) in frames.enumerated() {
            #expect(CGRect(origin: .zero, size: page).contains(frame))
            for other in frames[(index + 1)...] { #expect(frame.intersects(other) == false) }
        }
        #expect(frames[0].maxY == page.height - 24)
    }
}
