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
  - App: `xcodebuild build -project ClassMateNotes.xcodeproj -scheme ClassMateNotes -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' CODE_SIGNING_ALLOWED=NO`
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
- Ink coordinates live in the fixed 768×1024 logical page space
  (`PageGeometry`); `PageCanvasView` pins the PKCanvasView zoom so drawings are
  device-independent. Don't size canvases in raw view points.

## Milestones

Milestone 1 (current): library, multi-page PencilKit canvas, floating tool
palette, page templates, persistence, Pencil double-tap/squeeze, Settings with
themes + paper tone + custom theme editor; iPhone read-only viewer; paywall
scaffold with debug entitlement toggle. Do not build ahead of the milestone.
Handwriting-to-font is Milestone 3 — entitlement stub only.
