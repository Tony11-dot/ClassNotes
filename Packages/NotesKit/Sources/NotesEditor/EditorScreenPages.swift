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
            .simultaneousGesture(zoomGesture(containerWidth: containerWidth))
            // A two-finger touch is ALSO exactly what `ScrollView`'s own native
            // pan gesture reads as "scroll by the average of both fingers" — it
            // was recognizing right alongside `zoomGesture` the whole time, so
            // every pinch had two independent drivers fighting over the same
            // content offset: the native pan applying the raw touch delta, and
            // `applyPinchAnchor`'s own `scrollTo` applying the anchor math, one
            // frame apart. That fight IS "it keeps jumping" and "I can't move
            // freely while pinching" — not a tuning problem, a second hand on
            // the same wheel. Disabling native scrolling for exactly the
            // window a pinch is open leaves `applyPinchAnchor` the only writer.
            .scrollDisabled(pinchZoomAnchor != nil)
            // Bound so `zoomGesture` can drive the scroll position programmatically
            // (`ScrollPosition.scrollTo(x:y:)`) to keep the pinch anchor under the
            // fingers. Reading is done separately, below, via
            // `onScrollGeometryChange` — that path is already proven live in this
            // view (the overscroll tracker next to it) where `ScrollPosition`'s own
            // read side is not. Keeping read and write on two different channels
            // also avoids a feedback loop: the zoom gesture never reads
            // `pageScrollGeo` mid-gesture (only once, when the pinch begins), so
            // writing to `pageScrollPosition` cannot trigger another write.
            .scrollPosition($pageScrollPosition)
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
            .onScrollGeometryChange(for: PageScrollGeometry.self) { geo in
                PageScrollGeometry(
                    contentOffset: geo.contentOffset,
                    contentSize: geo.contentSize,
                    containerSize: geo.containerSize
                )
            } action: { _, geo in
                pageScrollGeo = geo
            }
            // Jumping to a page is a SCROLL, not a highlight. Setting
            // `focusedPageID` alone is what "Go to page" used to do: the thumbnail
            // lit up in the page manager and the page stack stayed exactly where
            // it was, which reads as a button that does nothing.
            .onChange(of: pageJumpTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(target, anchor: .top)
                }
                pageJumpTarget = nil
            }
        }
    }

    /// Focuses a page AND brings it on screen.
    func jump(to pageID: UUID) {
        model.focusedPageID = pageID
        pageJumpTarget = pageID
    }

    /// Pinch-to-zoom over the page stack. Clamped so a stray pinch can't leave
    /// the user on a page too small to find or too large to navigate, and
    /// anchored to where the pinch actually landed — like Photos, the point
    /// under the fingers stays under them instead of the page jumping while the
    /// scroll offset sits still. See `PinchZoomAnchor` for the anchor math and
    /// its one deliberate approximation (the vertical axis).
    func zoomGesture(containerWidth: CGFloat) -> some Gesture {
        // 0.01 fired a re-layout of every visible page's canvas AND a manual
        // scroll re-center on every ~1% of magnification — at pinch speed that's
        // easily 100+ of both a second, each one a real `PKCanvasView` zoomScale
        // re-pin plus a `ScrollPosition` write racing the SwiftUI re-layout from
        // `pageZoom` changing underneath it, which is what a coarse pinch felt
        // like a stutter/blink instead of a continuous scale. 0.04 fixed the
        // stutter but over-corrected into visibly steppy zoom on the hardware
        // this actually ships to (iPad Pro, M-series) — plenty of headroom for
        // a finer step. 0.015 is still well clear of the stutter this was tuned
        // against while reading as continuous to a finger.
        let magnify = MagnifyGesture(minimumScaleDelta: 0.015)
            .onChanged { value in
                let anchor = pinchZoomAnchor ?? {
                    let captured = capturePinchAnchor(at: value.startLocation, containerWidth: containerWidth)
                    pinchZoomAnchor = captured
                    return captured
                }()
                pageZoom = Self.clampZoom(anchor.startZoom * value.magnification)
                applyPinchAnchor(anchor, containerWidth: containerWidth)
            }
            .onEnded { _ in
                zoomAnchor = pageZoom
                pinchZoomAnchor = nil
                pinchPanTranslation = .zero
            }
        // A pinch's two fingers don't just change distance apart — together
        // they drift across the page too, and Photos follows both: the page
        // zooms under the pinch AND slides with it. `MagnifyGesture` only ever
        // reports the distance change, never where the pinch itself has moved
        // to, so without this the anchor was locked to wherever the pinch
        // STARTED — the page couldn't be panned at all while a pinch was live,
        // which is exactly "I can't move freely while pinching." This rides
        // alongside the magnify gesture purely to read that drift; it writes
        // nothing for an ordinary one-finger touch, since every handler below
        // is gated on a pinch already being open.
        let pan = DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let anchor = pinchZoomAnchor else { return }
                pinchPanTranslation = value.translation
                applyPinchAnchor(anchor, containerWidth: containerWidth)
            }
            .onEnded { _ in
                // Unconditional: harmless to zero an already-zero value for an
                // ordinary one-finger touch that was never a pinch at all.
                pinchPanTranslation = .zero
            }
        return SimultaneousGesture(magnify, pan)
    }

    /// Snapshots where a pinch that just started sits over the page stack, in
    /// terms that survive a zoom change: a fraction across the page's own width,
    /// and a fraction of the whole content's height. Captured once, from
    /// `pageScrollGeo` as it stood the instant the pinch began — never re-read
    /// mid-gesture, which is what keeps this a one-way write and not a loop.
    func capturePinchAnchor(at viewportPoint: CGPoint, containerWidth: CGFloat) -> PinchZoomAnchor {
        let zoom = pageZoom
        let width = Self.pageWidth(in: containerWidth, zoom: zoom)
        let contentWidth = max(containerWidth, width + Self.pageGutter * 2)
        let marginX = (contentWidth - width) / 2
        let contentX = pageScrollGeo.contentOffset.x + viewportPoint.x
        let pageFraction = width > 0 ? min(max((contentX - marginX) / width, 0), 1) : 0.5

        let contentY = pageScrollGeo.contentOffset.y + viewportPoint.y
        let totalHeight = max(pageScrollGeo.contentSize.height, 1)
        let heightFraction = min(max(contentY / totalHeight, 0), 1)

        return PinchZoomAnchor(
            viewportPoint: viewportPoint,
            startZoom: zoom,
            pageFraction: pageFraction,
            totalHeightFraction: heightFraction,
            startContentHeight: pageScrollGeo.contentSize.height
        )
    }

    /// Reapplies a captured anchor at the CURRENT `pageZoom`: works out where
    /// that same page-relative point now sits in content space, and scrolls so
    /// it lands back under `anchor.viewportPoint`.
    func applyPinchAnchor(_ anchor: PinchZoomAnchor, containerWidth: CGFloat) {
        let zoom = pageZoom
        let width = Self.pageWidth(in: containerWidth, zoom: zoom)
        let contentWidth = max(containerWidth, width + Self.pageGutter * 2)
        let marginX = (contentWidth - width) / 2
        let targetContentX = marginX + anchor.pageFraction * width

        // Every page's height scales by the same width ratio (height = width /
        // that page's own fixed aspect ratio), and the constant 32pt gaps and
        // 28pt top/bottom padding between pages don't scale at all — so the
        // total content height can be reconstructed exactly from the ratio
        // without re-summing every page.
        let startWidth = Self.pageWidth(in: containerWidth, zoom: anchor.startZoom)
        let widthRatio = startWidth > 0 ? width / startWidth : 1
        let verticalConstant = 56 + CGFloat(max(model.pages.count - 1, 0)) * 32
        let pagesHeightAtStart = max(anchor.startContentHeight - verticalConstant, 0)
        let projectedContentHeight = pagesHeightAtStart * widthRatio + verticalConstant
        let targetContentY = anchor.totalHeightFraction * projectedContentHeight

        // The pinch's own drift since it began — see `pinchPanTranslation` —
        // added to where it started, so the anchor tracks where the fingers
        // ACTUALLY are right now rather than only where they first touched
        // down.
        let viewportPoint = CGPoint(
            x: anchor.viewportPoint.x + pinchPanTranslation.width,
            y: anchor.viewportPoint.y + pinchPanTranslation.height
        )
        let maxOffsetX = max(0, contentWidth - pageScrollGeo.containerSize.width)
        let maxOffsetY = max(0, projectedContentHeight - pageScrollGeo.containerSize.height)
        let newOffsetX = min(max(targetContentX - viewportPoint.x, 0), maxOffsetX)
        let newOffsetY = min(max(targetContentY - viewportPoint.y, 0), maxOffsetY)

        pageScrollPosition.scrollTo(x: newOffsetX, y: newOffsetY)
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
        // A pinch programmatically re-centers the scroll position on every
        // step (`applyPinchAnchor`) to keep the anchor point under the
        // fingers — zooming OUT shrinks the content and can transiently push
        // that offset near an edge purely as a side effect of the zoom, not
        // because the user scrolled there. Reading that as a real overscroll
        // and inserting a page mid-pinch is exactly the "it keeps jumping
        // pages" report: a new page appears and the scroll re-centers around
        // it, which looks like the page you were zooming on jumped away.
        guard pinchZoomAnchor == nil else { return }
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
        .onTapGesture {
            model.focusedPageID = page.id
            selectedElementID = nil
        }
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
        // Images/files/text/audio/links sit BELOW the ink, so a stroke drawn
        // over one of them paints on top of it — you can annotate a photo or
        // circle something in a scan. Tape is the one exception: it renders
        // in its own instance below, ABOVE the ink, because hiding what's
        // underneath it is the entire point of tape.
        PageElementsLayer(
            pageID: page.id,
            elements: page.elements,
            model: model,
            toolState: toolState,
            displaySize: displaySize,
            logicalSize: page.logicalSize,
            allowsEditing: !toolState.isDrawingEnabled,
            editingTextID: $editingTextID,
            selectedElementID: $selectedElementID,
            layer: .belowInk,
            tracker: tracker
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
            editingTextID: $editingTextID,
            selectedElementID: $selectedElementID,
            layer: .aboveInk,
            tracker: tracker
        )
        EraseCatcherLayer(
            pageID: page.id,
            elements: page.elements,
            model: model,
            toolState: toolState,
            displaySize: displaySize,
            logicalSize: page.logicalSize,
            tracker: tracker
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
            TapPlacementLayer(displaySize: displaySize, logicalSize: page.logicalSize) { point in
                Task { await floodFill(at: point, on: page) }
            }
        }
        if toolState.tool == .horizontalLine || toolState.tool == .verticalLine {
            let axis: LineAxis = toolState.tool == .horizontalLine ? .horizontal : .vertical
            TapPlacementLayer(displaySize: displaySize, logicalSize: page.logicalSize) { point in
                Task { await drawStraightLine(through: point, axis: axis, on: page) }
            }
        }
        if let snip = copiedSnip, snip.pageID == page.id, page.logicalSize.width > 0 {
            let scale = displaySize.width / page.logicalSize.width
            let displayFrame = CGRect(
                x: snip.frame.minX * scale, y: snip.frame.minY * scale,
                width: snip.frame.width * scale, height: snip.frame.height * scale
            )
            pasteChip(near: displayFrame, in: displaySize)
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
                    onResize: { bounds in Task { await resizeSelection(to: bounds) } },
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
        if toolState.tool == .codeBlock, editingTextID == nil {
            TextPlacementLayer(displaySize: displaySize, logicalSize: page.logicalSize) { point in
                Task {
                    editingTextID = await model.insertCodeBlock(
                        at: point, on: page.id,
                        fontName: FontLibrary.byNameOrID(toolState.codeBlockFontID).fontName,
                        fontSize: toolState.codeBlockFontSize,
                        textColorHex: toolState.codeBlockTextColorHex ?? CodeBlockSettings.defaultTextHex,
                        backgroundColorHex: toolState.codeBlockBackgroundColorHex ?? CodeBlockSettings.defaultBackgroundHex,
                        cornerRadius: toolState.codeBlockCornerRadius,
                        language: toolState.codeBlockLanguage.rawValue,
                        transparentBackground: toolState.codeBlockTransparentBackground
                    )
                }
            }
        }
        // Function plots no longer place-on-tap: picking the tool opens a big
        // settings sheet (`FunctionPlotSettingsSheet`, from `ToolRailView`)
        // with a Create button, and the block is dropped already fully
        // configured, centred on the page — see `insertFunctionPlot(draft:)`.
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
