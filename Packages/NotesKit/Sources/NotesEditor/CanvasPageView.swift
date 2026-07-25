import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import PencilKit
import SwiftUI

/// Tracks which page's canvas last received ink so palette undo/redo targets
/// the right undo stack.
@MainActor
@Observable
public final class ActiveCanvasTracker {
    public weak var activeCanvas: PKCanvasView?
    /// Live canvases by page, so tools (OCR, circle-to-explain) can read a
    /// page's current ink without waiting for the debounced save.
    private var canvases: [UUID: Weak] = [:]

    public init() {}

    struct Weak { weak var view: PKCanvasView? }

    func register(_ canvas: PKCanvasView, for pageID: UUID) {
        canvases[pageID] = Weak(view: canvas)
    }

    public func drawing(for pageID: UUID) -> PKDrawing? {
        canvases[pageID]?.view?.drawing
    }
}

/// `PKCanvasView` pinned to the fixed logical page space (768×1024): ink
/// coordinates are device-independent, and the scroll view zoom keeps strokes
/// vector-crisp at any on-screen size.
final class PageCanvasView: PKCanvasView {
    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = bounds.width / PageGeometry.size.width
        guard scale > 0 else { return }
        if abs(zoomScale - scale) > 0.0001 {
            minimumZoomScale = scale
            maximumZoomScale = scale
            zoomScale = scale
        }
        contentSize = CGSize(
            width: PageGeometry.size.width * scale,
            height: PageGeometry.size.height * scale
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
    var onFocus: (UUID) -> Void = { _ in }

    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme

    func makeUIView(context: Context) -> PageCanvasView {
        let canvas = PageCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
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
        canvas.tool = toolState.pkTool(theme: theme)
        // Hand (object) mode: stop the canvas from capturing the pencil so the
        // element layer's move/resize gestures win. Any other tool draws.
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
            store: services.documentStore,
            toolState: toolState,
            tracker: tracker,
            onFocus: onFocus
        )
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
        weak var canvas: PKCanvasView?
        var toolState: ToolState

        private let notebookID: UUID
        private let pageID: UUID
        private let store: DocumentStore
        private let tracker: ActiveCanvasTracker
        private let onFocus: (UUID) -> Void
        private var saveTask: Task<Void, Never>?
        private var loaded = false

        init(
            notebookID: UUID,
            pageID: UUID,
            store: DocumentStore,
            toolState: ToolState,
            tracker: ActiveCanvasTracker,
            onFocus: @escaping (UUID) -> Void
        ) {
            self.notebookID = notebookID
            self.pageID = pageID
            self.store = store
            self.toolState = toolState
            self.tracker = tracker
            self.onFocus = onFocus
        }

        func loadDrawing() {
            Task {
                if let data = await store.pageData(notebook: notebookID, page: pageID),
                   let drawing = try? PKDrawing(data: data) {
                    canvas?.drawing = drawing
                }
                loaded = true
            }
        }

        // MARK: PKCanvasViewDelegate

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard loaded else { return }
            tracker.activeCanvas = canvasView
            onFocus(pageID)
            scheduleSave(canvasView.drawing)
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
