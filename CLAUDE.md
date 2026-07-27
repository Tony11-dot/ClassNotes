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
- AI is `AIProvider` (Groq streaming today) behind `NovaConversation`; the Groq
  key is user-entered in Settings → Keychain. Circle-to-explain OCRs the focused
  page and seeds NOVA. Keep AI provider-swappable for a future backend proxy.
- `NotesAI` is the only module that owns NOVA UI; `NotesEditor` and `NotesLibrary`
  depend on it. Editor-only code still lives behind the `App/Routing` import rule.
- Brand parity: reuse ClassMate's single blue CM mark + wordmark as TEMPLATE
  images tinted to the theme accent (BrandMark/BrandWordmark), and bundle Cabinet
  Grotesk in NotesDesignSystem (registered at launch via `CMFonts`). Do not add a
  Lottie dependency — the launch animation is native (`LaunchView`).
- Page content beyond ink is `PageElement` (image/file/audio/text/link/tape)
  stored in the manifest (v6; every older version loads loss-free) with payloads
  under the package's `media/`. Tape is an element above the ink: tapping toggles
  `isHidden`, which lifts the strip and reveals what it covers.
- The pen tray is data, not code: `PenLibrary` lists the instruments, each with a
  `PenSettings` the user tunes. PencilKit has no API for smoothing or pressure
  response, so those sliders are applied in `PenShaper`, which rebuilds a stroke
  once it's finished. Pure math lives in `NotesModels.InkGeometry`
  (`StrokeSmoothing`, `ScribbleDetector`, `LineGrouper`, `BeautifyLayout`) so it's
  testable without a canvas — keep it there.
- Real-time beautification is `LiveBeautifier`: a settle timer, per-LINE Vision
  recognition on a tight upscaled crop, then `plan(...)` (pure) deciding inserts
  vs. appends to a line already typeset. Only line-shaped ink is touched
  (`looksLikeWriting`), so diagrams and doodles are never eaten.
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
