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
  Grotesk in NotesDesignSystem (registered at launch via `CMFonts`). The library's
  navigation title is the LOCKUP, not the word "Library" — `BrandTitle`, a
  `ToolbarContent` so a screen drops it beside the buttons it already has, on both
  the iPad grid and the iPhone list.
- The launch animation is the DESIGNED Lottie scene itself —
  `NotesDesignSystem/Resources/LaunchScene.json`, played by `LaunchSceneView`.
  Replacing that file replaces the launch. `lottie-ios` is the app's one
  third-party dependency, added deliberately: the launch used to be a SwiftUI
  rebuild of the artwork, which drifted from the artwork every time it changed.
  `LaunchView` still falls back to a bundled video and then to the native
  animation if the scene is missing. It is staged exactly the way ClassMate stages
  its splash: theme surface, `AmbientBackground` fading in over 1.1 s behind it,
  and the scene centred and aspect-fitted across the FULL width (its own
  `LaunchScene.aspectRatio`, not a hardcoded cap) — which needs
  `LaunchSceneView.sizeThatFits`, because a `LottieAnimationView`'s intrinsic size
  is the composition's own 1280×720 and a representable that never answers the
  proposal is laid out at that size whatever it was offered, i.e. off both edges
  of a phone. The scene is RECOLOURED to the theme exactly the way ClassMate
  recolours its own splash (`splash_screen.dart`): everything the artwork DRAWS —
  `LaunchScene.lettering` (white), `LaunchScene.navy`, and the CN monogram, an
  embedded PNG that vector recolouring can't reach, whose pixels are retinted with
  the alpha preserved — becomes `theme.accent`, and `LaunchScene.plate`, the
  near-black slab the lockup sits on, becomes `theme.surface` so the lockup melts
  into the background. Which baked colour plays which ROLE is a property of the
  artwork, not a constant: the previous scene was a navy mark on a white canvas,
  so white meant background and was painted the surface — and when the artwork
  became white lettering on a dark plate, that same rule painted the words the
  colour of the field behind them and left the plate matching no rule at all.
  `canBuildThemedScene` exists because `animation(surface:accent:)` falls back to
  the untouched artwork, and a fallback still plays, still lasts the right length
  and is still non-nil — indistinguishable, on screen and to a test, from a theme
  being ignored. Recoloured scenes are cached per theme; `updateUIView` swaps in a
  scene rebuilt for a new theme, since `makeUIView` runs once.
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
- The pen tray is data, not code: `PenLibrary` lists a couple of FIXED
  instruments (Pen, Marker, Highlighter), each with a `PenSettings` — just
  Thickness, Concentration and Colour, the only things a user can still tune.
  There is no Stability/Tip/Sensitivity anymore, and nothing rebuilds a
  finished stroke's geometry at all. It used to: those three sliders were
  applied by `PenShaper`, which rebuilt every stroke's control points once it
  lifted (smoothing = averaging neighbours, Tip = tapering the ends, Sensitivity
  = blending point size toward the stroke's average). It read PencilKit's OWN
  fitted spline to do that — control points whose count tracks how fast the
  pencil moved, not the stroke's length — so the exact same setting barely
  touched a slow letter and crushed a fast one: round after round of chasing
  writing that "shrank" or "lost edges" always led back to that rebuild, no
  matter how the speed-dependence itself was patched. Removing the sliders
  and the rebuild entirely was the actual fix: what PencilKit hands back for
  ordinary handwriting is exactly what gets recorded, full stop. Pure math for
  what's left lives in `NotesModels.InkGeometry` (`StrokeSmoothing`,
  `ScribbleDetector`, `LineGrouper`, `BeautifyLayout`) so it's testable without
  a canvas — keep it there. `StrokeSmoothing` itself is NOT dead: shape
  snapping and the ruler's live fit still use it directly by window, because
  those are deliberate, WATCHED actions (the user sees the fit happen under
  the held pencil) rather than a silent rewrite of what they just wrote.
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
- Real-time beautification is `LiveBeautifier`: a settle timer, ONE Vision pass
  over the whole region of fresh ink, then `plan(...)` (pure, in
  `LiveBeautifierLayout.swift`) deciding inserts vs. appends to a line already
  typeset. Vision does its OWN line segmentation and the boxes it returns are
  matched back to the strokes underneath (`pageRect(forVisionBox:in:)` +
  `strokes(_:inside:excluding:)`). Do NOT go back to cutting the ink into lines
  and sending one crop each: a crop of a single word is a picture with no context
  — the hardest thing there is to read — and the width-over-height test that
  guarded it discarded every one-word line before Vision ever saw it, which is why
  roughly one line in ten was ever beautified. Diagrams are ruled out by height
  (`maximumLineHeight`) AFTER recognition, not by shape before it. Vision gets the
  ink re-inked BLACK on an OPAQUE WHITE crop (`recognitionImage`) — the raw
  `PKDrawing.image` is the pen's own colour on transparency, which recognized
  nothing — at a minimum ink width, retried at a much larger scale when the crop
  reads back empty, and capped at `maximumCropSide`. `apply` returns Bool so a
  refused pass doesn't advance the run list.
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
- The page OWNS its history; it does not borrow PencilKit's.
  `PageCanvasView.pageUndoManager` is the stack the rail drives, and the
  coordinator pushes a whole-drawing snapshot step whenever a change settles
  (`commitUndoStep`). PencilKit is handed a separate `inkSink` manager that
  nothing ever drives. Handing PencilKit the real manager and hoping it would
  register there is what made Undo and Redo dead buttons for the editor's whole
  life: `UIResponder.undoManager` walks the responder chain, a PKCanvasView
  inside SwiftUI is never first responder, and whatever it resolved to was not
  ours. Snapshots (not deltas) because a page of ink is tens of kilobytes and a
  step happens when the hand rests — and because "Undo puts the page back the way
  it was" is then exactly true. A rewrite (`replace`) never opens its own step, so
  refining the stroke just drawn — pen shaping, the ruler, a shape snap — is one
  press to take back; beautification pushes a step carrying the ink AND the
  elements in both directions (`apply(plan:)` returns `BeautifyElements`).
- Which closed shape the ink meant is decided by FIT RESIDUAL
  (`ShapeSnapper.bestClosedShape`), not by counting corners. A hand-drawn square's
  corners are rounded, its sides bow, and the down-sample that stops sampling
  noise reading as corners lands either side of a real one — the count came out
  three as often as four, so squares snapped to triangles.
- The dwell watcher follows the PENCIL only (`allowedTouchTypes`, matching the
  canvas's `drawingPolicy`) and one touch at a time, and it cleans up in `reset()`
  — UIKit's own last word on a gesture — not only in `touchesEnded`. A recognizer
  another one beats to the touch is reset WITHOUT `touchesCancelled`: a palm
  resting on the page started a "stroke" that never ended, `isTouching` stayed
  true for the rest of the session, and everything that waits for the pencil to
  lift (the ink pass, undo steps, beautification's `apply`) waited forever. If a
  shape happened to be held at the time the canvas stayed muted too — the pencil
  stopped marking the page and started dragging it instead. That one leak is the
  whole of "snapping doesn't work, beautification doesn't work, and sometimes the
  pen behaves like a finger". `finishHeldStroke` re-enables drawing
  unconditionally and `shouldEnableDrawing()` clears a mute whose hold is over,
  because drawing being off is the one state the user cannot get out of.
- Once a dwell is ACCEPTED the watcher claims the touch (`state = .began`).
  Muting PencilKit leaves the touch free for the enclosing scroll view's pan,
  which would drag the page out from under the shape being sized.
- The dwell watcher polls a rest CLOCK (`restSince`) and appends every coalesced
  touch. A one-shot timer armed on the last big move gets one chance per move: a
  pause over ink that isn't a shape yet used it up and nothing re-armed it, so the
  pause after the shape was finished was never examined. A held line clicks onto
  level/upright (`ShapeSnapper.detented`) and taps the hand as it lands.
- Tape is erased by `PageElementsLayer`, not the canvas: tape is an element, so
  the eraser tool gets a high-priority gesture over tape strips only.
- Pages pinch to zoom by LAYING OUT bigger (`pageZoom` scales the page's
  `maxWidth`), never by `scaleEffect` on the canvas — a transform rasterizes the
  PKCanvasView at its old size and the ink goes soft. Re-laying out re-pins
  `PageCanvasView`'s zoom, so strokes stay vector crisp and stay in the page's own
  logical space.
- Nothing that follows a finger may sit under an `.animation(_:value:)` keyed on
  its own position — the rail did, so every drag sample started a fresh spring and
  the rail only caught up on release. Drag updates are applied bare; only the
  release is animated, inside `withAnimation`.
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

## Architecture invariants (tools added round 5)

- The paint bucket is a RASTER question answered as vector. `FillTool` renders
  the page's ink to a boolean mask, `FillGeometry.region` floods out from the tap
  until it hits ink, and the boundary of what it reached is traced
  (`outline`), simplified (Douglas–Peucker) and stored as a `.fill` `PageElement`
  whose `points` are the outline in page space. There is no vector answer to
  "which region did they tap inside?" — hand-drawn outlines overlap, double back
  and rarely close. A fill draws ABOVE the ink and still reads as underneath it,
  because its polygon stops where the ink stopped the flood; that is why no
  under-ink layer was needed. A flood that reaches `maximumCoverage` of the page
  is REFUSED — the shape had a gap, and filling the page buries the notes.
- The lasso's rules are pure (`LassoSelection`): even-odd containment, and a
  stroke is caught when `coverage` of its sampled length is inside. People circle
  generously, so the bar is well under half — and well above nothing, so the word
  beside the loop isn't dragged in. Elements are caught by centre or by three
  corners, because a loop around a big image rarely clears all four.
- Multi-select is one model (`LibrarySelection`) shared by the iPad grid and the
  iPhone list, so "select" means the same thing in both. Emptying the selection
  ENDS the mode — with nothing held every button in the bar is dead, so staying
  in it strands the user behind a bar that can't act; `beginEmpty()` is how the
  "Select" button starts, and starting empty doesn't trip that rule. The bar is
  a `safeAreaInset`, never a bottom `overlay`: iOS 26 puts the search field at
  the bottom edge on iPhone and it landed on top of the bar, which is why its
  buttons did nothing. Every control in it carries its own 44-point box — bare
  `Text` labels in a 56-point bar are a few points tall, and the glass under
  them reacts to the touch, so a miss looked like a press that did nothing.
  Batch delete/shelve save ONCE (`NotebookRepository.delete(_:[Notebook])`,
  `setShelf(_:for:)`) and push each id, so a mass delete clears the ClassNotes
  tab too.
- `SignUpScreen` creates a REAL ClassMate account through `POST /auth/register`,
  not a ClassNotes-only one. Everything the app does — the library mirror, page
  renders, NOVA via `/classnotes/ai` — is authenticated with a ClassMate session;
  a parallel account space would mean rebuilding all of it or silently losing the
  notes made under it. Sign in with Apple and Google are NOT built: they need the
  App ID capability and a Google client ID respectively.

## Architecture invariants (settings + snapshot round)

- Tool settings are DURABLE and per-account. `ToolPreferences` (NotesModels) is
  the Codable value — pens and per-instrument tuning, eraser, tape, text boxes,
  beautification, and the Pencil gestures — owned by `SettingsStore`
  (NotesServices) and saved into `AppPreferences.toolsJSON`. `ToolState` is a
  live VIEW of it: every tunable property is computed over `preferences`, so a
  slider write goes straight to the store. It used to hold all of this in memory
  alone, which meant every adjustment the user made was forgotten the moment the
  editor closed and there was nothing on disk for a second device to be handed.
  Decoding is TOTAL (every field defaults, garbage decodes to the factory setup):
  settings are a convenience and must never cost someone their app.
- Settings travel through the account: `PUT/GET /classnotes/settings`
  (`ClassNotesSettings`, one JSONB row per user, payload OPAQUE to the backend).
  Which copy wins is decided by `revision`, the client's own counter, NEVER by a
  wall clock — devices disagree about the time, and a phone an hour behind would
  quietly write its stale copy over the iPad's on every launch. Both ends enforce
  it: `DeviceSettings.newer` on the client, and the service refuses a lower
  revision instead of overwriting. Launch PULLS before it pushes, same as the
  library, for the same reason.
- What the Apple Pencil's squeeze and double-tap do is the user's choice
  (`PencilAction`, set in Settings, synced with everything else). `ToolState`
  carries out what it can and RETURNS a `PencilOutcome` for what it can't (undo,
  ruler, NOVA, colours), which `EditorScreen` handles — so the mapping stays a
  pure function of the settings and is testable without a canvas.
- The page's width is resolved by `pageScroll` from the container and handed
  DOWN to each page. A `ScrollView` that scrolls horizontally offers its content
  unbounded width, so `.frame(maxWidth:)` inside one never resolves and an
  aspect-ratio'd page collapses to a dot — which is exactly what every page
  became when zooming was added. The stack gets an explicit width so the
  horizontal axis has something real to scroll.
- Nothing in the tool rail may cross the edge of the rail's `glassEffect` while
  animating. A view that leaves the glass's shape is promoted out of the glass
  layer and the promotion lands a frame late — that is the selected pen appearing
  to sit UNDER the rail and then snap above it mid-spring. The rail is ONE piece
  of glass: no `GlassEffectContainer` (that exists to merge several) and not
  `interactive` (that is for a control that reacts to its own touches).
- Lasso Copy puts a PICTURE of the caught region on the pasteboard — ink,
  photos, fills and text boxes, rendered as they look. It used to copy only the
  text of any text boxes caught, so circling a diagram and pressing Copy reported
  there was nothing to copy. Circling is a spatial act: the selection is a region
  of the page, and the honest answer to "copy this" is that region. The snip is
  also kept in hand (`copiedSnip`), so the Paste chip can put it straight back on
  the page as an image element; pasting switches to `.hand` because drag and
  pinch only work when the pencil isn't drawing.

## Architecture invariants (snapping, ruler, fill round)

- A held shape TAKES OVER the pencil. When `previewSnap` accepts a dwell it calls
  `suppressLiveInk`, which disables `drawingGestureRecognizer` — the stroke in
  flight belongs to PencilKit and can only be cancelled, and leaving it meant the
  raw wandering ink kept drawing on top of the clean shape for as long as the hand
  moved. That is why the snap only ever *looked* like it happened on release. The
  shape is committed on the lift by `commitSettledShape`, which replaces the last
  stroke if PencilKit kept it and otherwise inks the shape from the tool in hand
  (`ShapeSnapper.stroke(from:ink:width:)`). `updateUIView` must not re-enable
  drawing while `isSuppressingLiveInk`, and the ink pass and history steps both
  wait on `isPencilDown`.
- The assists have RESISTANCE, not just a click. `ShapeSnapper.detented` eases the
  free end back toward level/upright between `detentAngle` and `detentPull`
  instead of following the pencil exactly, and `squared` pulls a nearly-square box
  square (which is what turns a drawn ellipse into a circle). `resolve` returns
  whether an assist landed so the haptic fires on the way IN only.
- The ruler is a WALL, not a picture of one. `RulerGuide` (pure, in NotesModels)
  projects ink drawn along either long edge onto that edge; `RulerOverlay`
  publishes its endpoints in the editor's coordinate space and each page converts
  them through its own frame. The overlay must NOT `ignoresSafeArea`, or the line
  the ink is ruled against sits a safe area away from the one on screen. Ink drawn
  ACROSS the edge (a crossed t) is left alone by the aspect test.
- The ruler rules the line WHILE it is being drawn (`previewRuled`, driven by the
  dwell watcher's `onProgress`), on the same machinery as a held shape: it takes
  the stroke over the moment `RulerGuide.straightened` accepts it, mutes the live
  ink and previews the projected line under the pencil, and `commitPending` inks
  that same path on the lift. Ruling in the deferred ink pass instead is what put
  the straight line a beat behind the hand — you watched yourself draw a crooked
  line and a straight one turned up afterwards, which is a ruler that corrects
  you, not one you draw against. The deferred `ruled(_:)` stays as the fallback.
  `commitPending` is NOT gated on the shape-snapping switch: the straight-edge
  sets `pendingSnapPath` too and is its own setting.
- The paint bucket fills as far as the paint reaches, and the colour goes UNDER
  the ink (`PageFillLayer`, below `CanvasPageView`). Fills were in
  `PageElementsLayer` before, which was wrong twice: an element is drawn inside a
  frame at its own box but a fill's outline is in absolute page coordinates, so
  the colour landed offset by its own origin; and drawing over the ink is the only
  reason an open shape ever had to be refused. `FillGeometry.freePixel` nudges a
  tap that landed on a line into the space beside it. `PageContentView` (the
  iPhone viewer and the ClassMate render) draws fills the same way.
- Beautification judges a line against the PAGE, never against a fixed number of
  points. `isWritingLine(_:pageSize:)` allows up to `pageSize.height * 0.22` and
  rules out tall ink by shape (writing runs across, a diagram runs down). The old
  flat 130-point ceiling is exactly why it "only worked zoomed in": zooming lays
  the page out bigger without changing its logical size, so the same hand covers
  fewer logical points and only then fitted. The claim band around a Vision box is
  0.45 of the line height, not 0.6 — a wider band reached into the lines above and
  below, leaving them with no ink of their own to typeset. Which strokes belong to
  which line is decided ALL AT ONCE (`LiveBeautifier.assign`): every stroke is
  offered to every recognized line and goes to the one whose middle it sits
  nearest, in that line's own heights. Claiming line by line in whatever order the
  recognizer returned meant the first line to ask took every stroke its band
  touched — a neighbour's descenders and dotted i's included — and the neighbour
  was then dropped for having no ink of its own.
- NOVA renders LaTeX itself (`NovaMath`). Every model answers a maths question in
  LaTeX, and Markdown passes `$x^2$` and `\frac{a}{b}` straight through to the
  screen. There is no LaTeX engine and there doesn't need to be one: the markup is
  parsed with matched braces and rendered to Unicode (`x²`, `√2`, `(x + 1)/2`),
  inline and as display blocks. A lone `$` is left alone — a price is not an
  equation. Fenced code carries its language.

- Page settings never target the COVER. A cover's paper is the notebook's
  artwork, so a template or a rule colour chosen for it changes nothing you can
  see — and the cover is the first page, focused by default, which is why the
  sheet appeared to do nothing at all. `settingsTargetPage` skips it, and the
  sheet says which page it is editing and offers "Apply to every page".

## Architecture invariants (library round: search, export, trash, bookmarks)

- Deleting a notebook does NOT destroy it. `Notebook.deletedAt` is the only thing
  a delete sets; the row and the whole document package stay exactly as they
  were, and `NotebookRepository.purge` is the single step that removes ink.
  `TrashPolicy` (pure, in NotesModels) owns the thirty days, and
  `purgeExpiredTrash(now:)` takes a clock so the rule is testable without waiting
  a month. `deletedAt == nil` means LIVE and must never read as "deleted at the
  epoch" — that reading would purge the entire library on the next launch.
  Re-trashing an already-trashed notebook must not re-stamp the date, or the
  grace period silently restarts every time anything touches the row and nothing
  is ever actually purged. Every list of notebooks filters `isTrashed` — the
  grid, the phone list, "add books to shelf", the untitled-name counter,
  `fullSnapshot` (pushing one would put it straight back in the ClassNotes tab)
  and `searchTargets` (a result you can't open is not a result).
- Search is CACHED RECOGNITION, never live recognition. `SearchIndexer` reads a
  page once — text elements plus Vision over the ink — and stores the result in
  `search.json` inside the package (`SearchIndex`); a page is re-read only when
  its ink is newer than the reading (`needsReindex`). The index is DERIVED data:
  a missing or corrupt one is an empty index, never an error and never a repair,
  because the worst it can cost is a notebook matching on its title until it's
  read again. Typing never blocks on recognition — `search(_:across:)` reads only
  indexes that already exist, and building runs in the background (at launch, and
  when someone first searches). Ink is rasterised for Vision by `InkRasterizer`,
  the SAME code beautification uses: black on opaque white, because
  `PKDrawing.image` is the pen's own colour on transparency and recognises
  nothing. Two readers of the same ink must not disagree about what it looks
  like, which is why `LiveBeautifier.recognitionImage` delegates rather than
  keeping its own copy.
- `NoteSearch` is pure and total. All terms must appear (AND), matching folds
  case and accents (handwriting spells neither reliably), and an EMPTY query
  matches NOTHING — reading "no terms" as "no filter" would make an empty search
  box return the whole library. Snippets are cut around the earliest matching
  term by searching INSIDE the displayed string with `.caseInsensitive,
  .diacriticInsensitive` options: folding to a separate string and re-applying
  the offset slides the window off the match, because folding can change a
  string's length.
- Export renders from DISK, not from the canvas. `NotebookExporter` reads the
  manifest and the ink blobs, so exporting works from the library without opening
  the editor and doesn't depend on which pages happen to be on screen. Every page
  keeps its OWN size in the PDF (`beginPage(withBounds:)`) — a notebook with an
  A4 scan in the middle must not have that page cropped to page one's geometry.
  Exporting from INSIDE the editor flushes the live canvases to disk first, or
  the PDF is missing the last thing the user wrote. `PageCompositeView` is the
  one page-as-it-looks stack (paper, background, ink, elements), shared by the
  viewer and the exporter, so a layer added in one is not missing from the other.
- `NotebookManifest.coverPageVersion` exists because `ensureCoverPage` must key
  off the version covers ARRIVED at, never off `currentVersion`. Those were the
  same number only while v7 was newest; keying off the latter means the first
  time any later field is added (v8: `PageRecord.isBookmarked`), every v7
  notebook reads as "pre-cover" again and is handed a cover back — including
  everyone who deliberately deleted theirs.
- Jumping to a page is a SCROLL, not a highlight. `EditorScreen.jump(to:)` sets
  `focusedPageID` AND `pageJumpTarget`, which the page stack's `ScrollViewReader`
  acts on. Setting the focus alone is what "Go to page" used to do: the thumbnail
  lit up in the page manager and the stack stayed exactly where it was.
  Bookmarks (`PageRecord.isBookmarked`, manifest v8) and search hits both open a
  notebook through this, via `EditorScreen(notebook:openingPage:)` — checked
  after loading, since the id came from an index written earlier and the page it
  names may since have been deleted.
- The Beautify button commits through the page's own history
  (`ActiveCanvasTracker.applyBeautified`), the same step the live pass registers.
  It used to write the result straight onto the canvas with `setDrawing`, which
  changes the page without telling its undo stack anything — so the one action
  most likely to be regretted was the one action that couldn't be taken back.
