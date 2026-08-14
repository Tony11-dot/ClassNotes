import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI

/// How the editor lays pages out: the scrolling stack of pages for a notebook, the
/// single pannable board for a whiteboard, and the stack of surfaces over each
/// page's paper — ink canvas, elements, tape being laid down, text placement.
extension EditorScreen {

    /// A whiteboard: one big page filling the screen, panned and zoomed rather
    /// than paged.
    @ViewBuilder
    var boardSurface: some View {
        if let page = model.pages.first {
            GeometryReader { geo in
                ZStack {
                    pagePaper(page)
                    canvasStack(page, displaySize: page.logicalSize, allowsZoom: true)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .onAppear { model.focusedPageID = page.id }
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: - Focus mode

    /// Focus mode: the page you're on, as large as it fits, and an Exit button.
    /// No rail, no bubble, no navigation bar, no neighbouring pages — the pencil
    /// still draws, so you can read and highlight without anything in the way.
    @ViewBuilder
    var focusSurface: some View {
        let page = model.page(model.focusedPageID) ?? model.pages.first
        ZStack {
            theme.surface.color.ignoresSafeArea()
            if let page {
                GeometryReader { geo in
                    let size = focusPageSize(for: page, in: geo.size)
                    ZStack {
                        pagePaper(page)
                        if let bg = backgroundImage(for: page) {
                            Image(uiImage: bg).resizable().scaledToFit()
                        }
                        canvasStack(page, displaySize: size, allowsZoom: false)
                    }
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 22, y: 10)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            } else {
                BrandLoader(size: 56)
            }
        }
        .overlay(alignment: .topTrailing) { exitFocusButton }
        .overlay(alignment: .top) { noticeBanner }
        .ignoresSafeArea(edges: .bottom)
    }

    /// The largest the page fits in `available`, keeping its own aspect ratio.
    func focusPageSize(for page: PageRecord, in available: CGSize) -> CGSize {
        let logical = page.logicalSize
        guard logical.width > 0, logical.height > 0 else { return available }
        let inset: CGFloat = 24
        let box = CGSize(
            width: max(available.width - inset * 2, 1),
            height: max(available.height - inset * 2, 1)
        )
        let scale = min(box.width / logical.width, box.height / logical.height)
        return CGSize(width: logical.width * scale, height: logical.height * scale)
    }

    var exitFocusButton: some View {
        Button {
            toolState.focusMode = false
        } label: {
            Label("Exit", systemImage: "arrow.down.right.and.arrow.up.left")
                .font(.dsSubheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(height: 40)
                .foregroundStyle(theme.ink.color)
        }
        .buttonStyle(.plain)
        .dsGlass(in: Capsule(), interactive: true)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .padding(.trailing, 18)
        .padding(.top, 12)
        .accessibilityLabel("Exit focus mode")
    }

    // MARK: - Pages

    var pageScroll: some View {
        // The page width is resolved HERE, from the container, and handed down.
        // A ScrollView that scrolls horizontally offers its content unbounded
        // width, so `.frame(maxWidth:)` inside it never resolves to anything and
        // an aspect-ratio'd page collapses to a dot — which is exactly what a
        // page looked like once zooming was added. The stack is then given an
        // explicit width so the horizontal axis has something real to scroll.
        GeometryReader { outer in
            let width = pageWidth(in: outer.size.width)
            pageStack(width: width, containerWidth: outer.size.width)
        }
    }

    /// How wide a page is drawn: as wide as the window allows up to `maximumPageWidth`,
    /// times the zoom. Zoom past the fit and the stack scrolls sideways.
    func pageWidth(in container: CGFloat) -> CGFloat {
        Self.pageWidth(in: container, zoom: pageZoom)
    }

    static func pageWidth(in container: CGFloat, zoom: CGFloat) -> CGFloat {
        let fit = min(maximumPageWidth, max(container - pageGutter * 2, minimumPageWidth))
        return fit * clampZoom(zoom)
    }

    /// A page drawn `width` wide, given its own aspect ratio.
    func pageSize(for page: PageRecord, width: CGFloat) -> CGSize {
        Self.pageSize(aspectRatio: PageTemplateView.aspectRatio(of: page.style), width: width)
    }

    static func pageSize(aspectRatio: CGFloat, width: CGFloat) -> CGSize {
        let ratio = aspectRatio > 0 ? aspectRatio : 0.75
        return CGSize(width: width, height: width / ratio)
    }

    static let maximumPageWidth: CGFloat = 840
    static let minimumPageWidth: CGFloat = 240
    static let pageGutter: CGFloat = 40

    func pageStack(width: CGFloat, containerWidth: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(spacing: 32) {
                    ForEach(model.pages) { page in
                        pageView(page, width: width).id(page.id)
                    }
                }
                .padding(.vertical, 28)
                .frame(width: max(containerWidth, width + Self.pageGutter * 2))
            }
            // Pinch zooms the page by making it LAY OUT bigger, not by scaling a
            // rendered picture of it: `PageCanvasView` re-pins its zoom to the new
            // width, so the ink is re-rasterized at the new size and stays vector
            // crisp — and it stays in the page's own logical coordinates, which is
            // what keeps a drawing device-independent.
            .simultaneousGesture(zoomGesture)
            .onScrollGeometryChange(for: Overscroll.self) { geo in
                let topRest = -geo.contentInsets.top
                let bottomRest = geo.contentSize.height - geo.containerSize.height + geo.contentInsets.bottom
                return Overscroll(
                    top: topRest - geo.contentOffset.y,
                    bottom: geo.contentOffset.y - bottomRest,
                    scrollable: geo.contentSize.height > geo.containerSize.height
                )
            } action: { _, over in
                handleOverscroll(over, proxy: proxy)
            }
        }
    }

    /// Pinch-to-zoom over the page stack. Clamped so a stray pinch can't leave
    /// the user on a page too small to find or too large to navigate.
    var zoomGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                pageZoom = Self.clampZoom(zoomAnchor * value.magnification)
            }
            .onEnded { _ in zoomAnchor = pageZoom }
    }

    static let zoomRange: ClosedRange<CGFloat> = 0.5...4

    static func clampZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, zoomRange.lowerBound), zoomRange.upperBound)
    }

    /// The zoom readout, with a tap back to 100%. Only on screen while the page
    /// is not at its natural size — otherwise it's a permanent badge for a
    /// setting nobody changed.
    @ViewBuilder
    var zoomIndicator: some View {
        if abs(pageZoom - 1) > 0.01 {
            Button {
                withAnimation(.spring(duration: 0.28)) {
                    pageZoom = 1
                    zoomAnchor = 1
                }
            } label: {
                Label("\(Int((pageZoom * 100).rounded()))%", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.dsCaption.weight(.semibold))
                    .foregroundStyle(theme.ink.color)
                    .padding(.horizontal, 12).padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .dsGlass(in: Capsule(), interactive: true)
            .padding(.bottom, 18)
            .accessibilityLabel("Zoom \(Int((pageZoom * 100).rounded())) percent. Tap to reset.")
            .transition(.scale.combined(with: .opacity))
        }
    }

    /// Over-scroll past either end grows the notebook: keep dragging past the
    /// last page (or above the first) and a new page — inheriting that page's
    /// style — slides in.
    func handleOverscroll(_ over: Overscroll, proxy: ScrollViewProxy) {
        guard over.scrollable else { return }
        let threshold: CGFloat = 120
        if over.bottom > threshold, !addingBottom {
            addingBottom = true
            Task {
                _ = await model.appendInheritingLast()
                addingBottom = false
            }
        }
        if over.top > threshold, !addingTop {
            addingTop = true
            let anchor = model.pages.first?.id
            Task {
                _ = await model.prependInheritingFirst()
                // Keep the viewport steady: the new page grew above, so pin the
                // page that used to be first back to the top.
                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                addingTop = false
            }
        }
    }

    func edgeLoader(top: Bool) -> some View {
        VStack {
            if !top { Spacer() }
            ZStack {
                Circle().stroke(theme.separator.color, lineWidth: 2).frame(width: 40, height: 40)
                ProgressView().tint(theme.accent.color)
                Image(systemName: "plus").font(.dsCaption.weight(.bold)).foregroundStyle(theme.accent.color)
                    .offset(y: 14)
            }
            .padding(16)
            if top { Spacer() }
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }

    /// One page's paper. The cover is a page like any other; its paper is the
    /// notebook's cover artwork instead of a printed template, so the pencil draws
    /// straight onto the cover.
    func pagePaper(_ page: PageRecord) -> some View {
        PagePaperView(page: page, cover: notebook.usesCoverPage ? notebook.coverPaper : nil)
    }

    func pageView(_ page: PageRecord, width: CGFloat) -> some View {
        // Both dimensions are concrete: the page's own aspect ratio turns the
        // resolved width into a height, so nothing downstream has to guess.
        let size = pageSize(for: page, width: width)
        return ZStack {
            pagePaper(page)
            if let bg = backgroundImage(for: page) {
                Image(uiImage: bg).resizable().scaledToFit()
            }
            canvasStack(page, displaySize: size, allowsZoom: false)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.focusedPageID = page.id }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    model.focusedPageID == page.id ? theme.accent.color.opacity(0.5) : theme.separator.color,
                    lineWidth: model.focusedPageID == page.id ? 1.5 : 0.5
                )
        )
        .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("editor"))
        } action: { frame in
            pageFrames[page.id] = frame
        }
    }

    /// The ink canvas plus everything layered over it: elements, tape being laid,
    /// and the text-placement surface.
    @ViewBuilder
    func canvasStack(
        _ page: PageRecord, displaySize: CGSize, allowsZoom: Bool
    ) -> some View {
        // The bucket's colour goes UNDER the ink, so a fill can reach as far as
        // the paint does without burying the writing on top of it.
        PageFillLayer(
            elements: page.elements,
            displaySize: displaySize,
            logicalSize: page.logicalSize
        )
        CanvasPageView(
            notebookID: notebook.id,
            page: page,
            toolState: toolState,
            tracker: tracker,
            beautifier: beautifier,
            beautifyFontName: beautifyFontName,
            allowsZoom: allowsZoom,
            rulerGuide: rulerGuide(for: page, displaySize: displaySize),
            onFocus: { model.focusedPageID = $0 },
            onBeautified: { plan in await model.apply(plan: plan, to: page.id) },
            onReverted: { elements in await model.restoreElements(elements, on: page.id) }
        )
        PageElementsLayer(
            pageID: page.id,
            elements: page.elements,
            model: model,
            toolState: toolState,
            displaySize: displaySize,
            logicalSize: page.logicalSize,
            allowsEditing: !toolState.isDrawingEnabled,
            editingTextID: $editingTextID
        )
        if toolState.tool == .tape {
            TapeDrawingLayer(
                toolState: toolState,
                displaySize: displaySize,
                logicalSize: page.logicalSize
            ) { points in
                Task {
                    await model.insertTape(
                        points: points, on: page.id,
                        shape: toolState.tapeShape, pattern: toolState.tapePattern,
                        colorHex: toolState.tapeColor(theme: theme).hexString,
                        thickness: toolState.tapeThickness
                    )
                }
            }
        }
        if toolState.tool == .fill {
            FillPlacementLayer(displaySize: displaySize, logicalSize: page.logicalSize) { point in
                Task { await floodFill(at: point, on: page) }
            }
        }
        if toolState.tool == .lasso {
            if let selection = lassoSelection, selection.pageID == page.id {
                LassoSelectionView(
                    selection: selection.caught,
                    displaySize: displaySize,
                    logicalSize: page.logicalSize,
                    onDelete: { Task { await deleteSelection() } },
                    onDuplicate: { Task { await duplicateSelection() } },
                    onCopy: { copySelection() },
                    onMove: { offset in Task { await moveSelection(by: offset) } },
                    onDismiss: { lassoSelection = nil }
                )
            } else {
                LassoOverlay(
                    displaySize: displaySize,
                    logicalSize: page.logicalSize,
                    resolve: { loop in resolveLasso(loop, on: page) },
                    onSelected: { caught in
                        lassoSelection = PageSelection(pageID: page.id, caught: caught)
                    }
                )
            }
        }
        if toolState.tool == .text, editingTextID == nil {
            TextPlacementLayer(displaySize: displaySize, logicalSize: page.logicalSize) { point in
                Task {
                    editingTextID = await model.insertTextBox(
                        at: point, on: page.id,
                        fontName: FontLibrary.byNameOrID(toolState.textFontID).fontName,
                        fontSize: toolState.textSize,
                        colorHex: toolState.textColorHex ?? theme.ink.hexString
                    )
                }
            }
        }
    }

    /// Where the straight-edge lies on this page, in the page's own logical
    /// points — so ink drawn along it can be ruled straight.
    ///
    /// The ruler floats over the whole editor and the page scrolls underneath it,
    /// so the conversion is through the page's own frame in the editor's
    /// coordinate space. No frame, no guide: a page that hasn't been laid out yet
    /// can't say where the ruler is sitting on it.
    func rulerGuide(for page: PageRecord, displaySize: CGSize) -> RulerGuide? {
        guard rulerVisible, let line = rulerLine, let frame = pageFrames[page.id],
              frame.width > 1, page.logicalSize.width > 0 else { return nil }
        let scale = frame.width / page.logicalSize.width
        guard scale > 0 else { return nil }
        func onPage(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - frame.minX) / scale, y: (point.y - frame.minY) / scale)
        }
        return RulerGuide(
            start: onPage(line.start),
            end: onPage(line.end),
            halfWidth: RulerOverlay.thickness / 2 / scale
        )
    }

    /// The PostScript name of the beautification font, custom uploads included.
    var beautifyFontName: String {
        let font = services.fontStore.resolve(id: toolState.beautify.fontID)
            ?? FontLibrary.font(id: toolState.beautify.fontID)
        return font.fontName
    }

}
