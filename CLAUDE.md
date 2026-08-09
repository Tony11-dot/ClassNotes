# ClassMate Notes

Native note-taking app. iPadOS 26+ full PencilKit editor; iOS 26+ read-only viewer.
Universal app, Swift 6 (strict concurrency), SwiftUI-first, Liquid Glass design language.

## Testing & security rules (non-negotiable)

- **Swift Testing framework only** (`@Test` / `#expect`) — never XCTest.
- Every service and model gets tests. DesignSystem has render tests across ALL themes.
- Run `xcodebuild test` before declaring any task done. Nothing "works" until it
  compiles and tests pass:
  - Theme package: `cd Packages/ClassMateTheme && swift test`
  - NotesKit: `cd Packages/NotesKit && xcodebuild test -scheme NotesKit-Package -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)'`
  - App: `xcodebuild build -project ClassNotes.xcodeproj -scheme ClassNotes -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' CODE_SIGNING_ALLOWED=NO`
- No secrets in source. Keychain for anything sensitive.
- Never trust client-only entitlement state as final — `EntitlementService` is
  architected so server-side receipt validation can be added behind it later.
- Document packages must survive corrupt or partial files without data loss —
  `DocumentStore` recovery rules are tested; keep them tested when the format grows.

## Architecture invariants

- All entitlement checks go through `EntitlementService` via `.premiumGated()` —
  never scatter `if isPremium` through views. Locked features stay VISIBLE and
  show the upsell sheet on tap; never hide, never nag.
- ALL styling comes from `NotesDesignSystem` + `ClassMateTheme`. Zero raw hex
  outside theme definitions (SwiftLint enforces this).
- `NotesEditor` (iPad editing) is imported ONLY by `App/Routing` (SwiftLint
  enforces this). iPhone never routes to it — read-only viewer, no PKCanvasView.
- Glass belongs to the FUNCTIONAL layer only (toolbars, palette, popovers,
  sidebar). The canvas/paper is ALWAYS opaque. Use `dsGlass*` helpers, which
  respect Reduce Transparency.
- Theme presets in `ClassMateTheme` are exact values extracted from the
  ClassMate app (Flutter repo at `~/Dev/classmate`,
  `apps/classmate_mobile/lib/core/theme/theme_controller.dart`). Do NOT edit
  preset color values by hand — `themes.json` is the canonical fixture and a
  parity test pins the Swift code to it.
- Documents are packages on disk (`<uuid>.cmnote/` with `manifest.json` +
  `pages/*.drawing`); SwiftData holds metadata + settings + custom themes only.
  Designed for iCloud sync later; don't build sync yet.
- Whoever creates a `ModelContainer` must RETAIN it — `ModelContext` does not,
  and a deallocated container traps on the next store operation. `AppServices`
  owns the app's; tests hold theirs in a harness. Never write
  `Factory.make().mainContext` as a one-liner.
- Ink coordinates live in the page's OWN logical space (`PageRecord.logicalSize`,
  from `PageSize` × `PageOrientation`); `PageCanvasView` pins the PKCanvasView
  zoom so drawings are device-independent. Don't size canvases in raw view
  points, and never read `PageGeometry.size` for a page you have a record for —
  it's only the `classic` 768×1024 default, kept so pre-v6 documents keep their
  exact geometry.

## Architecture invariants (added features)

- Sign-in reuses ClassMate's REAL backend accounts. `ClassMateAPIClient` +
  `AuthService` hit `POST /auth/login` (`{identifier,password}`→`{token}`),
  `GET /auth/me`, base URL `pacific-enchantment-production-7a80.up.railway.app`
  (override via `CM_API_BASE_URL` env or `CMApiBaseURL` Info.plist key). The app
  gates the library behind `AuthService.state == .authenticated`.
- Secrets go through `SecretStore` — `KeychainStore` in the app, `InMemorySecretStore`
  in tests (SPM test hosts can't use the Keychain). The two secrets are the
  ClassMate session token and the user's Groq API key. Never embed keys in source.
- AI is `AIProvider` behind `NovaConversation`, and `NovaProviderRouter` decides
  who answers. DEFAULT is `NovaBackendProvider` — ClassMate's own
  `POST /classnotes/ai`, authenticated with the session the library already needs,
  with the model key server-side — SNIPS INCLUDED. `GroqProvider` (direct, user's
  Keychain key) is a fallback for a session-less device, nothing more. This is not
  belt-and-braces: a key in the binary plus a model string in the binary means a
  revoked key or a retired model silently kills NOVA for everyone until the next
  release — which is exactly what happened when Groq dropped
  `llama-3.3-70b-versatile`. Keep `AIConfig.defaultModel` in step with ClassMate's
  `support.service.ts`.
- The AI snip (`SnipOverlay`) is a RECTANGLE, and it is answered as a PICTURE:
  the crop goes to `/classnotes/ai` as `imageBase64` (task `see`, vision model
  server-side, `SUPPORT_AI_VISION_MODEL`), because a maths or physics snip is
  mostly the part OCR throws away — the diagram, the graph, the working laid out
  in two dimensions. OCR of the crop rides along only as a hint for a model that
  can't see. `NovaBackendProvider.payload` attaches the conversation's most recent
  image to EVERY turn, so a follow-up question is still looking at the snip;
  `NovaSnip` shrinks it first so that stays affordable.
- `NotesAI` is the only module that owns NOVA UI; `NotesEditor` and `NotesLibrary`
  depend on it. Editor-only code still lives behind the `App/Routing` import rule.
- Brand parity: reuse ClassMate's single blue CM mark + wordmark as TEMPLATE
  images tinted to the theme accent (BrandMark/BrandWordmark), and bundle Cabinet
  Grotesk in NotesDesignSystem (registered at launch via `CMFonts`).
- The launch animation is the DESIGNED Lottie scene itself —
  `NotesDesignSystem/Resources/LaunchScene.json`, played by `LaunchSceneView`.
  Replacing that file replaces the launch. `lottie-ios` is the app's one
  third-party dependency, added deliberately: the launch used to be a SwiftUI
  rebuild of the artwork, which drifted from the artwork every time it changed.
  `LaunchView` still falls back to a bundled video and then to the native
  animation if the scene is missing. The scene is RECOLOURED to the theme exactly
  the way ClassMate recolours its own splash (`splash_screen.dart`): the baked
  white canvas becomes `theme.surface` so the animation melts into the background,
  the baked navy becomes `theme.accent`, and the CN monogram — an embedded PNG
  that vector recolouring can't reach — has its pixels retinted with the alpha
  preserved. Recoloured scenes are cached per theme; a recolouring failure costs
  the theme, never the launch.
- The cover is PAGE ONE of the document (`PageRecord.isCover`, manifest v7), drawn
  on with every tool like any other page. Its "paper" is the notebook's artwork
  (`CoverPaper` → `CoverPaperView`, via `PagePaperView`), never a template. Only a
  paged notebook with the cover switch on has one; `DocumentStore.ensureCoverPage`
  gives a pre-v7 notebook its cover exactly once, so a cover the user DELETES stays
  deleted. Leaving the editor renders the cover (artwork + ink) to `cover.png`
  beside the pages BEFORE touching the row — the library tile reloads off
  `updatedAt`, and the same render is pushed to ClassMate as
  `NotebookSyncBody.coverImage`, so the shelf, the iPhone viewer and the ClassNotes
  tab all show the cover as it was actually drawn.
- Page content beyond ink is `PageElement` (image/file/audio/text/link/tape)
  stored in the manifest (v6; every older version loads loss-free) with payloads
  under the package's `media/`. Tape is an element above the ink: tapping toggles
  `isHidden`, which lifts the strip and reveals what it covers.
- The pen tray is data, not code: `PenLibrary` lists the instruments, each with a
  `PenSettings` the user tunes. PencilKit has no API for smoothing, pressure
  response or taper, so those sliders are applied in `PenShaper`, which rebuilds a
  stroke once it's finished.
- EVERY pen setting has to change the ink, and each one owns a different axis:
  Thickness IS the width (nothing else scales it), Tip is how POINTED the tip is
  and tapers the stroke's ends, Sensitivity is pressure response, Stability is
  smoothing, Concentration is alpha, Colour is colour. Tip used to be a second
  multiplier on the width — the same axis as Thickness, wearing a different name,
  and their product could exceed the Thickness slider's own maximum. Sensitivity
  used to no-op inside a ±0.25 deadband, so half its travel did nothing. Preset
  thicknesses are the widths those instruments already drew at, so the arithmetic
  change didn't quietly make every pen thinner. Pure math lives in `NotesModels.InkGeometry`
  (`StrokeSmoothing`, `ScribbleDetector`, `LineGrouper`, `BeautifyLayout`) so it's
  testable without a canvas — keep it there.
- Hold-to-snap settles the shape WHILE the pencil is still down. `StrokeDwellRecognizer`
  watches the live touch (it never recognizes — `cancelsTouchesInView` off, always
  ends `.failed` — so PencilKit's own drawing gesture is untouched), and on a rest
  it draws the fitted shape as a CAShapeLayer preview under the pencil. The ink is
  rewritten ONCE, on lift, from that same fitted path, so the preview and the
  committed stroke can't disagree. A stroke can't report a hold before it ends, so
  reading it from `PKStroke` could only ever snap after the release; that path
  survives as the fallback below.
- A settled shape stays ADJUSTABLE until the pencil lifts. `ShapeSnapper.classify`
  returns a `Shape` (line / angle / ellipse / rectangle / triangle-with-lean /
  polygon) apart from the points it came from, so `path(for:handle:)` can redraw
  that same shape at a new size or angle; the recognizer's `onAdjust` hands over
  each new pencil position, with the far end (or the opposite box corner) pinned as
  the anchor. Movement after a dwell is a HANDLE, not a cancellation — treating it
  as "never mind" meant the only way to resize a snapped circle was to undo it.
- The stroke-timing fallback reads the hold as "how long since
  the pencil was last more than `holdRadius` from where it came to rest" — never as
  the span of points inside a trailing window. `PKStrokePath` is a fitted spline,
  so a pencil held still emits ONE control point covering the whole dwell; a window
  scan measures a zero-length hold and refuses every snap, which is how the feature
  shipped doing nothing. Fitting reads `interpolatedPoints`, not control points (a
  quick line is four of them), and a closed path's corners are counted as a RING or
  a square loses the corner it started on and snaps to a triangle.
- Real-time beautification's recognizer is INJECTED (`LiveBeautifier.LineRecognizer`)
  so the whole pass — grouping, planning, wiping, merging — is testable without
  Vision. A refused `apply` (the pencil is down) re-arms instead of dropping the
  pass, and `canvasViewDidEndUsingTool` re-schedules on the LIFT: resting the tip
  on the page after a word used to lose the pass for good. A pass that reads
  nothing sets `lastPassFoundNothing`, which the editor shows — silence is
  indistinguishable from "the switch does nothing".
- Real-time beautification is `LiveBeautifier`: a settle timer, per-LINE Vision
  recognition on a tight upscaled crop, then `plan(...)` (pure) deciding inserts
  vs. appends to a line already typeset. Only line-shaped ink is touched
  (`looksLikeWriting`), so diagrams and doodles are never eaten. Vision gets the
  line re-inked BLACK on an OPAQUE WHITE crop (`recognitionImage`) — the raw
  `PKDrawing.image` is the pen's own colour on transparency, which recognized
  nothing, and `apply` returns Bool so a refused pass doesn't advance the run list.
  The crop is also re-inked with the PEN at a minimum width and retried at a much
  larger scale when a line reads back empty; low-confidence readings are dropped
  rather than typeset, because Vision always returns its best guess and its best
  guess at a squiggle is a word.
- A beautified run is MEASURED, never estimated. `TextMetrics` (injected, so
  `BeautifyLayout` stays pure) comes from `FontResolver` on the real face, and the
  box carries the settings' `fontSize`, `lineSpacing` (stored on `PageElement` and
  applied when drawing) and the room a wrapped line needs. The old
  `characters × size × 0.58` guess is why the panel looked ignored: the type was
  set correctly and then clipped by a box that didn't fit it. Whether new writing
  CONTINUES a run is judged on the run's INK bounds, not its text box — typeset
  words are much narrower than the hand that wrote them.
- Font names resolve through `FontResolver`, never `Font.custom` directly.
  `Font.custom` / `UIFont(name:)` fail SILENTLY, and Apple's own faces (SF Rounded,
  New York) are unreachable by PostScript name — so half the font picker quietly
  rendered as San Francisco. A catalog entry that stops resolving is a failed test.
- NEVER assign `PKCanvasView.drawing` while the pencil is down. The coordinator
  gates every rewrite (pen shaping, shape snap, scribble-erase, beautification)
  on `canvasViewDidBeginUsingTool`/`…DidEndUsingTool` and batches them into ONE
  assignment per pause, because assigning re-renders the page and eats the stroke
  in flight. `dataRepresentation()` runs inside the debounced save, never per
  stroke. `PenShaper` no-ops inside a wide sensitivity deadband so the default pen
  never triggers a rewrite at all.
- Tape is erased by `PageElementsLayer`, not the canvas: tape is an element, so
  the eraser tool gets a high-priority gesture over tape strips only.
- Focus mode (`ToolState.focusMode`, entered by picking up the highlighter) is its
  own surface — one page, an Exit chip, no rail/bubble/navigation bar.
- All type comes from `Font.ds*` / `CMType` (Cabinet Grotesk, ClassMate's family).
  Never `.font(.headline)` or `.font(.system(size:))` — the `ds` variants are the
  only way the family applies, and `CMType.applyNavigationBarAppearance()` covers
  UIKit's navigation titles.
- NOVA's transcript shows the ANSWER only: `NovaReply.display` strips `<think>`
  blocks (including unterminated ones mid-stream) and harmony channel markers, and
  `NovaMarkdownText` renders the Markdown so no `**` reaches the screen. The server
  also asks for `reasoning_format: 'hidden'`.
- New documents all go through `NotebookRepository.create(...)`: quick note,
  notebook, whiteboard, image, file and scan differ only by `NotebookKind`,
  `PageStyle` and page count. A whiteboard is ONE page in `PageSize.whiteboard`
  that pans and zooms (`PageCanvasView.allowsZoom`), not a new canvas engine.
- NOVA chats persist in SwiftData (`NovaChat` + `NovaChatStore`), scoped per
  notebook; the editor's floating bubble opens `NovaSidebar`, which saves on
  settle. Circle-to-explain seeds that same sidebar.
- Page content syncs to ClassMate as a render PLUS `NotebookPageAttachment`s
  (audio / file / link) so the ClassNotes tab can zoom, play voice notes and open
  files and links. Backend: `ClassNotesPage.attachments` (JSONB) in the ClassMate
  repo; keep the DTO, the Prisma column and `NotebookPageAttachment` in step.
- The library mirror is push-only EXCEPT one channel back: notebooks the user
  renamed or deleted in the ClassMate ClassNotes tab. `SyncService.pullRemoteChanges`
  runs at launch BEFORE `pushAll` (a push first would send the stale local title
  over the rename), applies them via `NotebookRepository.applyRemoteChanges`, then
  acks so the server can purge its tombstones. Local deletion happens by EXPLICIT
  id only — "absent from the server" must never delete anything.

## Milestones

Milestone 1 shipped (library, canvas, palette, templates, persistence, Pencil
double-tap/squeeze, Settings/themes, iPhone viewer, paywall scaffold).

Milestone 2 (current): ClassMate identity + real auth, profile, About/Support,
privacy link, logout; NOVA AI with circle-to-explain and saved per-notebook
chats in a sidebar; the six creation entries (quick note, notebook, whiteboard,
image, file, scan); the pen tray with per-pen tuning, sticky tape, text boxes,
scribble-to-erase and real-time handwriting beautification; 28 cover designs,
14 paper templates, paper sizes/direction, paper and line colours with a colour
wheel; two-finger ruler, media/file drop, voice-note bubbles;
shelves/collections; page content (renders + attachments) synced to the ClassMate
ClassNotes tab, where pages zoom and their voice notes, files and links work.

Later: iCloud sync; generating a PERSONAL font from handwriting samples (the hard
ML feature — distinct from the shipped handwriting→text) stays a premium stub.
