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

        // Watches the pencil rest so a shape can settle WHILE it's still down.
        context.coordinator.attachDwellWatcher(to: canvas)

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
        /// How many strokes have already been through the ink pass, so a pass only
        /// looks at what's new. Reset downwards whenever strokes disappear (erase,
        /// undo, a beautification wipe).
        private var processedStrokeCount = 0
        /// Guards the reentrant `drawing` assignments we make while reshaping.
        private var isRewriting = false
        /// True between `canvasViewDidBeginUsingTool` and `…DidEndUsingTool`, i.e.
        /// the pencil is DOWN. Assigning `PKCanvasView.drawing` in that window
        /// tears down the stroke in flight — which is why letters written straight
        /// after another one "appeared and erased a second later". Every rewrite
        /// (pen shaping, shape snap, scribble-erase, beautification) waits for the
        /// hand to lift.
        private var isUsingTool = false
        private var inkPassTask: Task<Void, Never>?
        /// The shape the live dwell watcher settled on, waiting for the pencil to
        /// lift so it can be committed as ONE canvas rewrite.
        private var pendingSnapPath: [CGPoint]?
        /// Draws that shape under the resting pencil. A layer rather than a stroke
        /// swap: the in-flight stroke belongs to PencilKit, and assigning
        /// `drawing` mid-stroke tears it up.
        private let snapPreviewLayer = CAShapeLayer()
        private weak var dwellWatcher: StrokeDwellRecognizer?

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
                // Ink already on the page was shaped when it was written; a pass
                // over it would only cost time and re-smooth what's settled.
                processedStrokeCount = canvas?.drawing.strokes.count ?? 0
                loaded = true
            }
        }

        // MARK: Live shape snapping

        /// Adds the dwell watcher and the preview layer to a canvas.
        func attachDwellWatcher(to canvas: PageCanvasView) {
            snapPreviewLayer.fillColor = nil
            snapPreviewLayer.lineCap = .round
            snapPreviewLayer.lineJoin = .round
            snapPreviewLayer.opacity = 0
            canvas.layer.addSublayer(snapPreviewLayer)

            let watcher = StrokeDwellRecognizer(target: nil, action: nil)
            watcher.logicalPoint = { [weak canvas] touch in
                guard let canvas, canvas.zoomScale > 0 else { return .zero }
                // A scroll view hands back content coordinates already; the zoom
                // is what stands between those and the page's own space.
                let point = touch.location(in: canvas)
                return CGPoint(x: point.x / canvas.zoomScale, y: point.y / canvas.zoomScale)
            }
            watcher.onDwell = { [weak self] points in self?.previewSnap(points) }
            watcher.onResume = { [weak self] in self?.cancelSnapPreview() }
            watcher.onEnd = { [weak self] held in
                guard let self else { return }
                self.hideSnapPreview()
                if !held { self.pendingSnapPath = nil }
            }
            canvas.addGestureRecognizer(watcher)
            dwellWatcher = watcher
        }

        /// The pencil has come to rest: fit what's been drawn and show it.
        private func previewSnap(_ points: [CGPoint]) {
            guard toolState.snapShapes, toolState.tool == .pen,
                  let canvas, let path = ShapeSnapper.liveFit(points) else { return }
            pendingSnapPath = path

            let scale = canvas.zoomScale
            let bezier = UIBezierPath()
            for (index, point) in path.enumerated() {
                let scaled = CGPoint(x: point.x * scale, y: point.y * scale)
                if index == 0 { bezier.move(to: scaled) } else { bezier.addLine(to: scaled) }
            }
            let settings = toolState.penSettings
            snapPreviewLayer.path = bezier.cgPath
            snapPreviewLayer.lineWidth = max(1, settings.effectiveWidth * scale)
            snapPreviewLayer.strokeColor = (canvas.tool as? PKInkingTool)?.color.cgColor
            snapPreviewLayer.opacity = 1
            // The shape landing under your pencil should feel like it clicked.
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        }

        private func cancelSnapPreview() {
            pendingSnapPath = nil
            hideSnapPreview()
        }

        private func hideSnapPreview() {
            snapPreviewLayer.opacity = 0
            snapPreviewLayer.path = nil
        }

        // MARK: PKCanvasViewDelegate

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            isUsingTool = true
            // Anything queued would land under the moving pencil — hold it.
            inkPassTask?.cancel()
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            isUsingTool = false
            scheduleInkPass()
            // Re-arm beautification on the LIFT, not just on the last drawing
            // change. Rest the tip on the page after a word and the drawing stops
            // changing, so the settle timer fires while the pencil is still down;
            // `apply` refuses to swap ink out from under it, and nothing ever
            // asked again — the pass was simply lost. That is what "I write with
            // it on and nothing happens" looks like from the outside.
            scheduleBeautification()
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard loaded, !isRewriting else { return }
            tracker.activeCanvas = canvasView
            onFocus(pageID)

            // Strokes went away (eraser, undo) — our "already processed" mark has
            // to come back with them or the next pass reads the wrong indices.
            let count = canvasView.drawing.strokes.count
            if count < processedStrokeCount { processedStrokeCount = count }

            scheduleSave()
            scheduleBeautification()
            // A change with the pencil up (undo, paste, an erase) still deserves a
            // pass; one with the pencil down waits for `didEndUsingTool`.
            if !isUsingTool { scheduleInkPass() }
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? PageCanvasView)?.syncContentSize()
        }

        // MARK: Ink pass

        /// Queues the post-stroke pass. Debounced so writing several letters in
        /// quick succession costs ONE canvas rewrite instead of one per stroke —
        /// assigning `.drawing` re-renders the whole page, which is what made a
        /// filling page feel progressively laggier.
        private func scheduleInkPass() {
            inkPassTask?.cancel()
            inkPassTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled, let self, !self.isUsingTool else { return }
                self.runInkPass()
            }
        }

        /// Scribble-to-erase, then shape-snap / pen tuning for every stroke added
        /// since the last pass — all folded into a single `drawing` assignment.
        private func runInkPass() {
            guard loaded, let canvas else { return }
            var drawing = canvas.drawing
            let count = drawing.strokes.count
            guard count > processedStrokeCount else {
                processedStrokeCount = count
                return
            }

            if toolState.scribbleToErase, toolState.tool == .pen,
               let cleaned = ScribbleEraser.applying(to: drawing) {
                processedStrokeCount = cleaned.strokes.count
                replace(cleaned, on: canvas)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                scheduleSave()
                return
            }

            var changed = false
            var snappedAShape = false
            /// Only the fallback taps back — the live preview already did, when the
            /// shape appeared under the pencil.
            var snappedLate = false
            if toolState.tool == .pen {
                // The shape the user already WATCHED settle under the pencil wins:
                // it's the one they accepted by holding still, and committing it
                // verbatim means the preview and the ink can never disagree.
                if toolState.snapShapes, let path = pendingSnapPath, count > 0 {
                    let last = count - 1
                    drawing.strokes[last] = ShapeSnapper.stroke(
                        from: path, like: drawing.strokes[last]
                    )
                    changed = true
                    snappedAShape = true
                    pendingSnapPath = nil
                }
                for index in processedStrokeCount..<count {
                    // Already snapped — don't also re-shape it.
                    if snappedAShape, index == count - 1 { continue }
                    let stroke = drawing.strokes[index]
                    // Fallback for a hold the live watcher missed. Same result,
                    // just a beat later.
                    if toolState.snapShapes, let snapped = ShapeSnapper.snapped(stroke) {
                        drawing.strokes[index] = snapped
                        changed = true
                        snappedAShape = true
                        snappedLate = true
                    } else if let shaped = PenShaper.shaped(stroke, settings: toolState.penSettings) {
                        drawing.strokes[index] = shaped
                        changed = true
                    }
                }
            }
            processedStrokeCount = count
            guard changed else { return }
            if snappedLate { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
            replace(drawing, on: canvas)
            scheduleSave()
        }

        /// Assigns a rewritten drawing without mistaking the resulting delegate
        /// callback for the user's own input. The flag clears on the NEXT main-actor
        /// turn because PKCanvasView reports the change asynchronously — clearing it
        /// on the same line let our own rewrite come back as "new ink".
        private func replace(_ drawing: PKDrawing, on canvas: PKCanvasView) {
            isRewriting = true
            canvas.drawing = drawing
            Task { @MainActor [weak self] in self?.isRewriting = false }
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
                    guard let self, let canvas = self.canvas else { return false }
                    // Never swap the ink out from under a moving pencil. Refusing
                    // here keeps the beautifier's bookkeeping intact, and the pass
                    // re-runs when the hand next rests.
                    guard !self.isUsingTool else { return false }
                    // Typeset text FIRST, then take the ink away. The other order
                    // leaves a frame with neither on the page, which is what made
                    // beautification look like the writing vanished and something
                    // else appeared, instead of the writing turning into type.
                    await self.onBeautified(plan)
                    self.processedStrokeCount = remaining.strokes.count
                    self.replace(remaining, on: canvas)
                    self.scheduleSave()
                    return true
                }
            )
        }

        // MARK: Saving

        /// Debounced page save. The drawing is serialized INSIDE the task, once the
        /// hand has been still for 600 ms — doing it per change meant every stroke
        /// paid `dataRepresentation()` for the whole page on the main thread, so
        /// writing got slower the more there was on the page.
        private func scheduleSave() {
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let self, self.loaded,
                      let data = self.canvas?.drawing.dataRepresentation() else { return }
                try? await self.store.savePageData(
                    data, notebook: self.notebookID, page: self.pageID
                )
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
