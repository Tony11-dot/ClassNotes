import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import PencilKit
import SwiftUI

/// Tracks which page's canvas last received ink so undo/redo and the page tools
/// target the right canvas.
@MainActor
@Observable
public final class ActiveCanvasTracker {
    public weak var activeCanvas: PKCanvasView?
    /// Live canvases by page, so tools (OCR, beautify, circle-to-explain) can read
    /// a page's current ink without waiting for the debounced save.
    private var canvases: [UUID: Weak] = [:]

    public init() {}

    struct Weak { weak var view: PKCanvasView? }

    func register(_ canvas: PKCanvasView, for pageID: UUID) {
        canvases[pageID] = Weak(view: canvas)
    }

    public func drawing(for pageID: UUID) -> PKDrawing? {
        canvases[pageID]?.view?.drawing
    }

    /// Best-effort live drawing for beautify/OCR: the requested page if it has a
    /// live canvas, otherwise the most-recently-active canvas — so tapping
    /// Beautify works even when the target page's canvas is offscreen/deallocated
    /// in the lazy page list.
    public func bestDrawing(preferring pageID: UUID?) -> (pageID: UUID, drawing: PKDrawing)? {
        if let pageID, let drawing = canvases[pageID]?.view?.drawing, !drawing.strokes.isEmpty {
            return (pageID, drawing)
        }
        for (id, weak) in canvases {
            if let drawing = weak.view?.drawing, !drawing.strokes.isEmpty {
                return (id, drawing)
            }
        }
        return nil
    }

    /// Replace a page's live drawing (used by shape-snapping, beautify and clear).
    public func setDrawing(_ drawing: PKDrawing, for pageID: UUID) {
        canvases[pageID]?.view?.drawing = drawing
    }

    public func canvas(for pageID: UUID) -> PKCanvasView? {
        canvases[pageID]?.view
    }

    /// The bounding box of a page's ink in logical page space, or nil if empty.
    public func inkBounds(for pageID: UUID) -> CGRect? {
        guard let bounds = canvases[pageID]?.view?.drawing.bounds,
              !bounds.isNull, !bounds.isEmpty else { return nil }
        return bounds
    }

    /// Wipe a page's ink. Setting `.drawing` fires the canvas delegate, which
    /// persists it.
    public func clearDrawing(for pageID: UUID) {
        canvases[pageID]?.view?.drawing = PKDrawing()
    }
}

/// `PKCanvasView` pinned to the page's logical space: ink coordinates are
/// device-independent, and the scroll view zoom keeps strokes vector-crisp at any
/// on-screen size. Boards (`allowsZoom`) start fitted and pinch to zoom in.
final class PageCanvasView: PKCanvasView {
    var logicalSize: CGSize = PageGeometry.size
    var allowsZoom = false
    private var didFit = false

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, logicalSize.width > 0, logicalSize.height > 0 else { return }
        if allowsZoom {
            let fit = min(bounds.width / logicalSize.width, bounds.height / logicalSize.height)
            guard fit > 0 else { return }
            minimumZoomScale = fit
            maximumZoomScale = fit * 8
            isScrollEnabled = true
            if !didFit {
                zoomScale = fit
                didFit = true
            }
        } else {
            let fit = bounds.width / logicalSize.width
            guard fit > 0 else { return }
            if abs(zoomScale - fit) > 0.0001 {
                minimumZoomScale = fit
                maximumZoomScale = fit
                zoomScale = fit
            }
        }
        syncContentSize()
    }

    func syncContentSize() {
        contentSize = CGSize(
            width: logicalSize.width * zoomScale,
            height: logicalSize.height * zoomScale
        )
    }
}

/// One page's drawing surface. The template underneath is SwiftUI; the canvas
/// itself is transparent. Saving is debounced and atomic via `DocumentStore`.
struct CanvasPageView: UIViewRepresentable {
    let notebookID: UUID
    let page: PageRecord
    let toolState: ToolState
    let tracker: ActiveCanvasTracker
    let beautifier: LiveBeautifier
    /// The resolved PostScript name for the beautification font (custom faces
    /// included) — the editor owns the font store, so it resolves this.
    let beautifyFontName: String
    /// A board pans and zooms instead of being pinned to a fit scale.
    var allowsZoom = false
    var onFocus: (UUID) -> Void = { _ in }
    /// Applies a finished beautification pass to the manifest.
    var onBeautified: (BeautifyPlan) async -> Void = { _ in }

    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme

    func makeUIView(context: Context) -> PageCanvasView {
        let canvas = PageCanvasView()
        canvas.logicalSize = page.logicalSize
        canvas.allowsZoom = allowsZoom
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = allowsZoom
        canvas.bouncesZoom = false
        canvas.showsVerticalScrollIndicator = allowsZoom
        canvas.showsHorizontalScrollIndicator = allowsZoom
        // Pencil-only drawing = system-grade palm rejection; fingers scroll
        // the page list instead of leaving marks.
        canvas.drawingPolicy = .pencilOnly
        canvas.delegate = context.coordinator
        canvas.overrideUserInterfaceStyle = theme.isDark ? .dark : .light

        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = context.coordinator
        canvas.addInteraction(pencilInteraction)

        context.coordinator.canvas = canvas
        tracker.register(canvas, for: page.id)
        context.coordinator.loadDrawing()
        return canvas
    }

    func updateUIView(_ canvas: PageCanvasView, context: Context) {
        context.coordinator.toolState = toolState
        context.coordinator.beautifyFontName = beautifyFontName
        context.coordinator.onBeautified = onBeautified
        context.coordinator.pageSize = page.logicalSize
        canvas.logicalSize = page.logicalSize
        canvas.tool = toolState.pkTool(theme: theme)
        // Tape / text / move modes: stop the canvas from capturing the pencil so
        // the overlay's gestures win. Any writing tool draws.
        canvas.drawingGestureRecognizer.isEnabled = toolState.isDrawingEnabled
        canvas.overrideUserInterfaceStyle = theme.isDark ? .dark : .light
    }

    static func dismantleUIView(_ canvas: PageCanvasView, coordinator: Coordinator) {
        coordinator.flushPendingSave()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            notebookID: notebookID,
            pageID: page.id,
            pageSize: page.logicalSize,
            store: services.documentStore,
            toolState: toolState,
            tracker: tracker,
            beautifier: beautifier,
            beautifyFontName: beautifyFontName,
            onFocus: onFocus
        )
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
        weak var canvas: PageCanvasView?
        var toolState: ToolState
        var beautifyFontName: String
        var pageSize: CGSize
        var onBeautified: (BeautifyPlan) async -> Void = { _ in }

        private let notebookID: UUID
        private let pageID: UUID
        private let store: DocumentStore
        private let tracker: ActiveCanvasTracker
        private let beautifier: LiveBeautifier
        private let onFocus: (UUID) -> Void
        private var saveTask: Task<Void, Never>?
        private var loaded = false
        /// Stroke count after the last change, so we can tell an ADDED stroke
        /// (candidate for shaping / snapping / scribble-erase) from an erase or a
        /// replacement we made ourselves.
        private var lastStrokeCount = 0
        /// Guards the reentrant `drawing` assignments we make while reshaping.
        private var isRewriting = false

        init(
            notebookID: UUID,
            pageID: UUID,
            pageSize: CGSize,
            store: DocumentStore,
            toolState: ToolState,
            tracker: ActiveCanvasTracker,
            beautifier: LiveBeautifier,
            beautifyFontName: String,
            onFocus: @escaping (UUID) -> Void
        ) {
            self.notebookID = notebookID
            self.pageID = pageID
            self.pageSize = pageSize
            self.store = store
            self.toolState = toolState
            self.tracker = tracker
            self.beautifier = beautifier
            self.beautifyFontName = beautifyFontName
            self.onFocus = onFocus
        }

        func loadDrawing() {
            Task {
                if let data = await store.pageData(notebook: notebookID, page: pageID),
                   let drawing = try? PKDrawing(data: data) {
                    canvas?.drawing = drawing
                }
                lastStrokeCount = canvas?.drawing.strokes.count ?? 0
                loaded = true
            }
        }

        // MARK: PKCanvasViewDelegate

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard loaded, !isRewriting else { return }
            tracker.activeCanvas = canvasView
            onFocus(pageID)

            let added = canvasView.drawing.strokes.count == lastStrokeCount + 1
            if added, handleScribbleErase(on: canvasView) {
                lastStrokeCount = canvasView.drawing.strokes.count
                scheduleSave(canvasView.drawing)
                return
            }
            if added {
                reshapeLastStroke(on: canvasView)
            }
            lastStrokeCount = canvasView.drawing.strokes.count
            scheduleSave(canvasView.drawing)
            scheduleBeautification()
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? PageCanvasView)?.syncContentSize()
        }

        /// Scribble-to-erase: a quick back-and-forth scrub deletes what it crosses.
        /// Returns true when the gesture was consumed as an erase.
        private func handleScribbleErase(on canvasView: PKCanvasView) -> Bool {
            guard toolState.scribbleToErase, toolState.tool == .pen,
                  let cleaned = ScribbleEraser.applying(to: canvasView.drawing) else { return false }
            isRewriting = true
            canvasView.drawing = cleaned
            isRewriting = false
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return true
        }

        /// Snap a held stroke to a clean shape, otherwise apply the pen's own
        /// stability / sensitivity tuning to it.
        private func reshapeLastStroke(on canvasView: PKCanvasView) {
            var drawing = canvasView.drawing
            guard let last = drawing.strokes.last else { return }
            let replacement: PKStroke?
            if toolState.snapShapes, let snapped = ShapeSnapper.snapped(last) {
                replacement = snapped
            } else if toolState.tool == .pen {
                replacement = PenShaper.shaped(last, settings: toolState.penSettings)
            } else {
                replacement = nil
            }
            guard let replacement else { return }
            isRewriting = true
            drawing.strokes[drawing.strokes.count - 1] = replacement
            canvasView.drawing = drawing
            isRewriting = false
        }

        /// Hand the page to the live beautifier; it debounces and only fires once
        /// the pencil rests.
        private func scheduleBeautification() {
            guard toolState.beautify.isEnabled else { return }
            beautifier.inkChanged(
                pageID: pageID,
                settings: toolState.beautify,
                fontName: beautifyFontName,
                pageSize: pageSize,
                drawing: { [weak self] in self?.canvas?.drawing },
                apply: { [weak self] plan, remaining in
                    guard let self else { return }
                    self.isRewriting = true
                    self.canvas?.drawing = remaining
                    self.lastStrokeCount = remaining.strokes.count
                    self.isRewriting = false
                    await self.onBeautified(plan)
                    self.scheduleSave(remaining)
                }
            )
        }

        // MARK: Saving

        private func scheduleSave(_ drawing: PKDrawing) {
            saveTask?.cancel()
            let data = drawing.dataRepresentation()
            saveTask = Task { [store, notebookID, pageID] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                try? await store.savePageData(data, notebook: notebookID, page: pageID)
            }
        }

        func flushPendingSave() {
            saveTask?.cancel()
            guard loaded, let drawing = canvas?.drawing else { return }
            let data = drawing.dataRepresentation()
            Task { [store, notebookID, pageID] in
                try? await store.savePageData(data, notebook: notebookID, page: pageID)
            }
        }

        // MARK: UIPencilInteractionDelegate

        func pencilInteraction(
            _ interaction: UIPencilInteraction,
            didReceiveTap tap: UIPencilInteraction.Tap
        ) {
            toolState.handlePencilTap(preferred: UIPencilInteraction.preferredTapAction)
        }

        func pencilInteraction(
            _ interaction: UIPencilInteraction,
            didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
        ) {
            if squeeze.phase == .ended {
                toolState.handlePencilSqueeze()
            }
        }
    }
}
