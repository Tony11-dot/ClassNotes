import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import PencilKit
import SwiftUI
import UIKit

/// Tracks which page's canvas last received ink so undo/redo and the page tools
/// target the right canvas.
@MainActor
@Observable
public final class ActiveCanvasTracker {
    public weak var activeCanvas: PKCanvasView?
    /// Live canvases by page, so tools (OCR, beautify, circle-to-explain) can read
    /// a page's current ink without waiting for the debounced save.
    private var canvases: [UUID: Weak] = [:]
    /// Bumped whenever anything lands on (or comes off) an undo stack, so the
    /// rail's Undo/Redo buttons can re-read `canUndo` / `canRedo`. `UndoManager`
    /// is not observable, so without a nudge the buttons would stay greyed out
    /// through the whole session.
    private var undoRevision = 0

    public init() {}

    struct Weak { weak var view: PKCanvasView? }

    /// The undo stack of the page last drawn on.
    public var activeUndoManager: UndoManager? {
        (activeCanvas as? PageCanvasView)?.pageUndoManager ?? activeCanvas?.undoManager
    }

    public var canUndo: Bool {
        _ = undoRevision
        return activeUndoManager?.canUndo ?? false
    }

    public var canRedo: Bool {
        _ = undoRevision
        return activeUndoManager?.canRedo ?? false
    }

    public func undo() {
        activeUndoManager?.undo()
        undoRevision &+= 1
    }

    public func redo() {
        activeUndoManager?.redo()
        undoRevision &+= 1
    }

    /// Something changed on an undo stack — re-read `canUndo` / `canRedo`.
    func undoStackChanged() {
        undoRevision &+= 1
    }

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

    /// The page's OWN undo stack — the one the rail's buttons drive.
    ///
    /// The page used to hand this manager to PencilKit as well, on the theory
    /// that PencilKit would register its stroke undos into it. It does not
    /// reliably: `UIResponder.undoManager` walks the responder chain, a
    /// `PKCanvasView` inside a SwiftUI hierarchy is never first responder, and
    /// whatever PencilKit resolved to was not this. Undo and Redo were dead
    /// buttons for the entire life of the editor.
    ///
    /// So the page keeps its own history instead of hoping for someone else's:
    /// the coordinator snapshots the drawing after every change that settles and
    /// pushes the step here. Deterministic, and it covers the things PencilKit
    /// never knew about anyway — shape snapping, scribble-erase, beautification,
    /// a lasso move.
    let pageUndoManager = UndoManager()

    /// Where PencilKit's own registrations go to be ignored. Handing it a real
    /// manager keeps it on its documented path; nothing ever drives this one, so
    /// its entries can't fight the page's history or double up with it.
    private let inkSink: UndoManager = {
        let manager = UndoManager()
        manager.levelsOfUndo = 1
        return manager
    }()

    override var undoManager: UndoManager? { inkSink }

    /// Something landed on (or came off) the page's stack.
    var onUndoStackChanged: (() -> Void)?

    /// Shake-to-undo and the hardware-keyboard ⌘Z both need this.
    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(undoPage)),
            UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(redoPage))
        ]
    }

    @objc private func undoPage() {
        pageUndoManager.undo()
        onUndoStackChanged?()
    }

    @objc private func redoPage() {
        pageUndoManager.redo()
        onUndoStackChanged?()
    }

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
    /// Where the straight-edge lies on THIS page, when it is out. Ink drawn along
    /// it is ruled straight.
    var rulerGuide: RulerGuide?
    var onFocus: (UUID) -> Void = { _ in }
    /// Applies a finished beautification pass to the manifest, handing back the
    /// page's elements as they were before it and as they are after it — Undo
    /// needs the first, Redo the second.
    var onBeautified: (BeautifyPlan) async -> BeautifyElements = { _ in BeautifyElements() }
    /// Puts a set of elements back, so a beautification is a single step either way.
    var onReverted: ([PageElement]) async -> Void = { _ in }

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
        canvas.onUndoStackChanged = { [weak tracker] in tracker?.undoStackChanged() }
        tracker.register(canvas, for: page.id)
        if tracker.activeCanvas == nil { tracker.activeCanvas = canvas }
        context.coordinator.loadDrawing()
        return canvas
    }

    func updateUIView(_ canvas: PageCanvasView, context: Context) {
        context.coordinator.toolState = toolState
        context.coordinator.beautifyFontName = beautifyFontName
        context.coordinator.onBeautified = onBeautified
        context.coordinator.onReverted = onReverted
        context.coordinator.pageSize = page.logicalSize
        context.coordinator.rulerGuide = rulerGuide
        canvas.logicalSize = page.logicalSize
        canvas.tool = toolState.pkTool(theme: theme)
        // Tape / text / move modes: stop the canvas from capturing the pencil so
        // the overlay's gestures win. Any writing tool draws.
        //
        // While a shape is settled under a live pencil the canvas is deliberately
        // muted (see `suppressLiveInk`), and a SwiftUI update landing mid-gesture
        // must not undo that — turning drawing back on halfway through would put
        // the wandering ink back under the shape.
        canvas.drawingGestureRecognizer.isEnabled =
            context.coordinator.isSuppressingLiveInk ? false : toolState.isDrawingEnabled
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
        /// The straight-edge on this page, when it is out.
        var rulerGuide: RulerGuide?
        var onBeautified: (BeautifyPlan) async -> BeautifyElements = { _ in BeautifyElements() }
        /// Puts a set of page elements back — the manifest half of an undo or redo.
        var onReverted: ([PageElement]) async -> Void = { _ in }

        private let notebookID: UUID
        let pageID: UUID
        private let store: DocumentStore
        let tracker: ActiveCanvasTracker
        let beautifier: LiveBeautifier
        private let onFocus: (UUID) -> Void
        private var saveTask: Task<Void, Never>?
        private var loaded = false
        /// How many strokes have already been through the ink pass, so a pass only
        /// looks at what's new. Reset downwards whenever strokes disappear (erase,
        /// undo, a beautification wipe).
        var processedStrokeCount = 0
        /// Guards the reentrant `drawing` assignments we make while reshaping.
        var isRewriting = false
        /// True between `canvasViewDidBeginUsingTool` and `…DidEndUsingTool`, i.e.
        /// the pencil is DOWN. Assigning `PKCanvasView.drawing` in that window
        /// tears down the stroke in flight — which is why letters written straight
        /// after another one "appeared and erased a second later". Every rewrite
        /// (pen shaping, shape snap, scribble-erase, beautification) waits for the
        /// hand to lift.
        var isUsingTool = false
        private var inkPassTask: Task<Void, Never>?
        /// The page as of the last committed history step. Every step is the pair
        /// (this, what the page became) — which is why Redo works as well as Undo.
        var undoBaseline = PKDrawing()
        /// Something has changed since `undoBaseline` and is not on the stack yet.
        var hasUncommittedChange = false
        var commitTask: Task<Void, Never>?
        /// The shape the live dwell watcher settled on, waiting for the pencil to
        /// lift so it can be committed as ONE canvas rewrite.
        var pendingSnapPath: [CGPoint]?
        /// How many strokes were on the page when the shape settled, so the commit
        /// knows whether PencilKit ended up keeping the ink it was drawing.
        var strokeCountAtSnap: Int?
        /// True while the canvas is deliberately not drawing, because a settled
        /// shape has taken over the pencil.
        private(set) var isSuppressingLiveInk = false
        /// The settled shape while the pencil still holds it, so moving the pencil
        /// resizes THAT shape instead of refitting the wandering ink.
        var liveSnap: ShapeSnapper.LiveSnap?
        /// Whether the held line is currently sitting on the level/upright detent,
        /// so the haptic fires as it clicks in and not for every sample after.
        var isOnDetent = false
        /// Draws that shape under the resting pencil. A layer rather than a stroke
        /// swap: the in-flight stroke belongs to PencilKit, and assigning
        /// `drawing` mid-stroke tears it up.
        let snapPreviewLayer = CAShapeLayer()
        weak var dwellWatcher: StrokeDwellRecognizer?

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
                var stored = PKDrawing()
                if let data = await store.pageData(notebook: notebookID, page: pageID),
                   let drawing = try? PKDrawing(data: data) {
                    stored = drawing
                }
                isRewriting = true
                canvas?.drawing = stored
                // Ink already on the page was shaped when it was written; a pass
                // over it would only cost time and re-smooth what's settled.
                processedStrokeCount = stored.strokes.count
                undoBaseline = stored
                hasUncommittedChange = false
                // `loaded` waits a turn with `isRewriting`, so the delegate
                // callback for OUR assignment can't be mistaken for the user's
                // first stroke and pushed onto the history as "they drew a page".
                Task { @MainActor [weak self] in
                    self?.isRewriting = false
                    self?.loaded = true
                }
            }
        }

        // MARK: PKCanvasViewDelegate

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            isUsingTool = true
            tracker.activeCanvas = canvasView
            // Anything queued would land under the moving pencil — hold it.
            inkPassTask?.cancel()
            commitTask?.cancel()
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
            // The page has moved off its last history step.
            hasUncommittedChange = true

            // Strokes went away (eraser, undo) — our "already processed" mark has
            // to come back with them or the next pass reads the wrong indices.
            let count = canvasView.drawing.strokes.count
            if count < processedStrokeCount { processedStrokeCount = count }

            scheduleSave()
            scheduleBeautification()
            // A change with the pencil up (a lasso move, an erase, a paste) still
            // deserves a pass and a history step; one with the pencil down waits
            // for `didEndUsingTool`.
            if !isUsingTool {
                scheduleInkPass()
                scheduleUndoCommit()
            }
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

        /// Scribble-to-erase, then shape-snap / ruler / pen tuning for every stroke
        /// added since the last pass — all folded into a single `drawing`
        /// assignment, and finished as ONE step on the page's history.
        private func runInkPass() {
            guard loaded, let canvas else { return }
            // A settled shape is still being held: the pencil is down and the
            // committed ink is not what it will be. Wait for the lift.
            guard !isPencilDown else { return }
            var drawing = canvas.drawing
            var count = drawing.strokes.count

            // The shape the user already WATCHED settle under the pencil wins:
            // it's the one they accepted by holding still, and committing it
            // verbatim means the preview and the ink can never disagree.
            if toolState.snapShapes, toolState.tool == .pen, let path = pendingSnapPath {
                commitSettledShape(path, into: &drawing, on: canvas)
                count = drawing.strokes.count
                pendingSnapPath = nil
                strokeCountAtSnap = nil
                processedStrokeCount = count
                replace(drawing, on: canvas)
                commitUndoStep(named: "Shape")
                scheduleSave()
                return
            }

            guard count > processedStrokeCount else {
                processedStrokeCount = count
                commitUndoStep()
                return
            }

            if toolState.scribbleToErase, toolState.tool == .pen,
               let cleaned = ScribbleEraser.applying(to: drawing) {
                processedStrokeCount = cleaned.strokes.count
                replace(cleaned, on: canvas)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                commitUndoStep(named: "Scribble Erase")
                scheduleSave()
                return
            }

            var changed = false
            /// Only the fallback taps back — the live preview already did, when the
            /// shape appeared under the pencil.
            var snappedLate = false
            if toolState.tool == .pen {
                for index in processedStrokeCount..<count {
                    let stroke = drawing.strokes[index]
                    // Fallback for a hold the live watcher missed. Same result,
                    // just a beat later.
                    if toolState.snapShapes, let snapped = ShapeSnapper.snapped(stroke) {
                        drawing.strokes[index] = snapped
                        changed = true
                        snappedLate = true
                    } else if let ruled = ruled(stroke) {
                        // Drawn against the straight-edge: the ruler's job is to
                        // make the line straight whatever the hand did.
                        drawing.strokes[index] = ruled
                        changed = true
                    } else if let shaped = PenShaper.shaped(stroke, settings: toolState.penSettings) {
                        drawing.strokes[index] = shaped
                        changed = true
                    }
                }
            }
            processedStrokeCount = count
            if changed {
                if snappedLate { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
                replace(drawing, on: canvas)
                scheduleSave()
            }
            // Even an untouched stroke is a step: the history is the page's, not
            // the ink pass's.
            commitUndoStep()
        }

        /// Puts the settled shape on the page. Normally it replaces the stroke
        /// PencilKit was drawing — but the live preview mutes the canvas while the
        /// shape is held, so PencilKit may have discarded that stroke entirely, and
        /// then the shape has to be inked from the tool in hand instead.
        private func commitSettledShape(
            _ path: [CGPoint], into drawing: inout PKDrawing, on canvas: PKCanvasView
        ) {
            let baseline = strokeCountAtSnap ?? max(drawing.strokes.count - 1, 0)
            if drawing.strokes.count > baseline, let template = drawing.strokes.last {
                drawing.strokes[drawing.strokes.count - 1] =
                    ShapeSnapper.stroke(from: path, like: template)
            } else {
                let tool = canvas.tool as? PKInkingTool
                drawing.strokes.append(ShapeSnapper.stroke(
                    from: path,
                    ink: tool.map { PKInk($0.inkType, color: $0.color) } ?? PKInk(.pen, color: .black),
                    width: tool?.width ?? CGFloat(toolState.penSettings.effectiveWidth)
                ))
            }
        }

        /// A stroke ruled straight against the straight-edge, or nil when it wasn't
        /// drawn along it.
        private func ruled(_ stroke: PKStroke) -> PKStroke? {
            guard let guide = rulerGuide,
                  let straight = guide.straightened(ShapeSnapper.densePoints(stroke))
            else { return nil }
            return ShapeSnapper.stroke(from: straight, like: stroke)
        }

        /// Assigns a rewritten drawing without mistaking the resulting delegate
        /// callback for the user's own input. The flag clears on the NEXT main-actor
        /// turn because PKCanvasView reports the change asynchronously — clearing it
        /// on the same line let our own rewrite come back as "new ink".
        ///
        /// A rewrite never pushes its own history step: refining the stroke just
        /// drawn (pen shaping, the ruler, a shape snap) is part of drawing it, and
        /// a second entry would mean two presses of Undo to take one line back.
        /// `commitUndoStep` closes the step once the pass is finished.
        func replace(_ drawing: PKDrawing, on canvas: PKCanvasView) {
            isRewriting = true
            canvas.drawing = drawing
            Task { @MainActor [weak self] in self?.isRewriting = false }
        }

        // MARK: - Live ink while a shape is held

        /// Whether the pencil is still on the glass, according to the dwell watcher.
        var isPencilDown: Bool { dwellWatcher?.isTouching ?? false }

        /// Mutes the canvas so the settled shape is the only thing under the pencil.
        ///
        /// The stroke in flight belongs to PencilKit and cannot be edited, only
        /// cancelled. Leaving it meant the raw, wandering ink kept drawing on top
        /// of the clean shape for as long as the hand kept moving — so the snap
        /// only ever LOOKED like it happened on release, which is exactly how it
        /// was reported.
        func suppressLiveInk() {
            guard let canvas, !isSuppressingLiveInk else { return }
            isSuppressingLiveInk = true
            strokeCountAtSnap = canvas.drawing.strokes.count
            canvas.drawingGestureRecognizer.isEnabled = false
        }

        /// The pencil has lifted off a held shape: give the canvas back and run the
        /// pass that puts the shape on the page.
        ///
        /// The pass has to be asked for here. Muting the canvas already fired
        /// `canvasViewDidEndUsingTool`, back when the pencil was still down and the
        /// shape was still being sized — nothing else is coming.
        func finishHeldStroke() {
            let wasSuppressed = isSuppressingLiveInk
            isSuppressingLiveInk = false
            if wasSuppressed {
                canvas?.drawingGestureRecognizer.isEnabled = toolState.isDrawingEnabled
            }
            scheduleInkPass()
        }

        // MARK: Saving

        /// Debounced page save. The drawing is serialized INSIDE the task, once the
        /// hand has been still for 600 ms — doing it per change meant every stroke
        /// paid `dataRepresentation()` for the whole page on the main thread, so
        /// writing got slower the more there was on the page.
        func scheduleSave() {
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
            toolState.handlePencilTap()
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
