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
                    PageTemplateView(style: page.style)
                    canvasStack(page, displaySize: page.logicalSize, allowsZoom: true)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .onAppear { model.focusedPageID = page.id }
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: - Pages

    var pageScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 32) {
                    ForEach(model.pages) { page in
                        pageView(page).id(page.id)
                    }
                }
                .padding(.vertical, 28)
            }
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
                Image(systemName: "plus").font(.caption.weight(.bold)).foregroundStyle(theme.accent.color)
                    .offset(y: 14)
            }
            .padding(16)
            if top { Spacer() }
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }

    func pageView(_ page: PageRecord) -> some View {
        GeometryReader { geo in
            ZStack {
                PageTemplateView(style: page.style)
                if let bg = backgroundImage(for: page) {
                    Image(uiImage: bg).resizable().scaledToFit()
                }
                canvasStack(page, displaySize: geo.size, allowsZoom: false)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.focusedPageID = page.id }
        }
        .aspectRatio(PageTemplateView.aspectRatio(of: page.style), contentMode: .fit)
        .frame(maxWidth: 840)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    model.focusedPageID == page.id ? theme.accent.color.opacity(0.5) : theme.separator.color,
                    lineWidth: model.focusedPageID == page.id ? 1.5 : 0.5
                )
        )
        .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
        .padding(.horizontal, 40)
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
        CanvasPageView(
            notebookID: notebook.id,
            page: page,
            toolState: toolState,
            tracker: tracker,
            beautifier: beautifier,
            beautifyFontName: beautifyFontName,
            allowsZoom: allowsZoom,
            onFocus: { model.focusedPageID = $0 },
            onBeautified: { plan in await model.apply(plan: plan, to: page.id) }
        )
        PageElementsLayer(
            pageID: page.id,
            elements: page.elements,
            model: model,
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

    /// The PostScript name of the beautification font, custom uploads included.
    var beautifyFontName: String {
        let font = services.fontStore.resolve(id: toolState.beautify.fontID)
            ?? FontLibrary.font(id: toolState.beautify.fontID)
        return font.fontName
    }

}
