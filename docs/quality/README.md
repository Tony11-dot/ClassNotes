# ClassNotes quality programme: scope report and plan

This is the scope and dependency report the quality mandate asks for before
any large change (§53.22). It records:

- what the app is built on;
- where it falls short of the bar;
- what is being fixed, in what order.

Registers (dependencies, decisions, risks, permissions, network use, change
control) are in [registers.md](registers.md). Measured numbers are in
[measurements.md](measurements.md).

Last updated: 2026-10-09. Phase 1 is complete; see "Phase 1 outcome" below.

---

## 1. Current architecture

| Layer | What it is |
|---|---|
| Language | Swift 6, strict concurrency |
| UI | SwiftUI first; UIKit where SwiftUI can't reach (the canvas, gestures, Pencil interactions) |
| Ink input and rendering | **PencilKit** (`PKCanvasView`), one canvas per visible page in a `LazyVStack`. Rendering and latency are Apple's. Ink is stored as `PKDrawing.dataRepresentation()` |
| Documents | `DocumentStore` (actor). One package per notebook, `<uuid>.cmnote/`, holding `manifest.json`, `pages/<id>.drawing`, `media/*`, `search.json` and `cover.png`. All writes are atomic (temp file + rename) |
| Library metadata | SwiftData (`Notebook`, `Shelf`, `AppPreferences`, `CustomThemeRecord`, `NovaChat`) |
| Write ordering | `PageInkJournal`: page saves are stamped and staged; a stale write is never applied over a newer one |
| PDF | PDFKit **rasterises** every imported page to a 2× PNG page background at import. There is no live PDF engine and no PDF text layer |
| Search | `SearchIndexer` (actor): Vision `VNRecognizeTextRequest` over rendered ink, plus element text, cached per package in `search.json` |
| Handwriting recognition | Apple Vision, on device and offline |
| AI (NOVA) | `NovaBackendProvider` → ClassMate API `POST /classnotes/ai` (model key held on the server). Groq is a direct fallback only |
| Auth | ClassNotes' own accounts (`/classnotes/auth/*`), token in the Keychain |
| Sync | **Mirror only**. Notebook metadata and page *renders* (JPEG) go up to ClassMate's ClassNotes tab. Renames and deletes made in that tab come back down. There is no document content sync and no iCloud |
| Settings sync | `PUT/GET /classnotes/settings`; the higher revision wins (no wall clock) |
| Payments | StoreKit 2: a lifetime unlock plus an optional subscription (`EntitlementService`) |
| Tests | Swift Testing only: 104 suites, 592 tests in NotesKit (including a 3,000-step crash/damage torture test and benchmarks), 21 in ClassMateTheme |
| CI/CD | fastlane run locally (`beta`, `check`, `listing`, `submit`). There is no hosted CI |
| Crash reporting and analytics | **None**. Only Apple's own (Xcode Organizer / App Store Connect crash logs) |

## 2. Existing dependencies

There is one third-party package: `lottie-ios` (Apache-2.0), used only for the
launch animation. Everything else is an Apple framework: PencilKit, PDFKit,
Vision, SwiftData, StoreKit, AVFoundation, VisionKit (document scanner),
PhotosUI and os.

## 3. Required new dependencies

None. Every fix in this round uses Apple frameworks only. Two items need a
product decision before any dependency is added: crash and performance
telemetry (D-004), and a live PDF engine (D-006).

## 4. External services

| Service | Used for | When it's down |
|---|---|---|
| ClassMate API (Railway) | sign-in, library mirror, settings sync, NOVA | Note taking keeps working. See the failure policy in registers.md |
| Groq (direct) | NOVA fallback with the user's own key | NOVA is unavailable; nothing else is affected |
| Apple App Store / StoreKit | purchases | Purchases already made remain available offline (StoreKit caches transactions) |

## 5. Platform limitations (things this app cannot promise)

- **Pencil latency and frame rate belong to PencilKit.** The app can make them
  worse, by blocking the main thread while the hand is down or by assigning the
  drawing mid-stroke. It cannot make them better than PencilKit's own pipeline.
  The work on our side is to keep the main thread free; see measurements.md.
- **Palm rejection** is PencilKit's (`drawingPolicy = .pencilOnly`) plus our
  hit-testing. It can only be verified on a real device with a real hand.
- **End-to-end latency (ms), FPS, battery, and launch-to-interactive time**
  need a physical iPad with Instruments. Nothing in the simulator measures
  them. The benchmarks here measure the parts the app controls: storage, search
  and rendering on the CPU.
- **Hover** needs Apple Pencil 2 or Pro on an M2-or-later iPad Pro or an M2/M3
  iPad Air. **Squeeze and barrel roll** need Apple Pencil Pro.
- **PDF text search and vector-sharp PDF zoom** are not possible while PDFs are
  rasterised at import (D-006).

## 6. Open decisions (detail in registers.md)

| ID | Question |
|---|---|
| D-001 | Should core note taking require an account? Today the library is locked behind sign-in |
| D-002 | Reference low-end and high-end iPads for the performance gates |
| D-003 | Real content sync (iCloud vs ClassMate API) and its conflict model |
| D-004 | Crash and performance telemetry provider (MetricKit-only vs a third party) |
| D-005 | Free-tier limits (`freeNotebookLimit` is currently uncapped) |
| D-006 | PDF engine: keep rasterising, or render PDF pages live with PDFKit |
| D-007 | Folder nesting and tags (today: flat shelves plus favourites) |
| D-008 | Rotate for lasso selections (needs a selection-transform model change) |

## 7. Known technical risks (top of the risk register)

1. **A notebook package with no SwiftData row is invisible.** This happens
   after a crash between creating the package and saving the row, or after the
   metadata store fails to open (the app then quietly ran an in-memory library).
   The notes are still on disk, but the user sees an empty library. P0.
2. **A manifest that won't decode is rebuilt from the ink blobs and written
   over the original.** A newer build's unknown template or size makes the whole
   manifest fail. The rebuild drops every image, text box, tape strip, fill,
   template, bookmark, cover and page size. P0.
3. **A notebook deleted in the ClassMate tab is destroyed immediately on the
   iPad**, bypassing the 30-day trash. A server-side mistake would take ink with
   it. P0.
4. **Deleting a page is instant and permanent**: its ink and media are removed
   with no undo. P1.
5. **A failed write blanks the editor.** `manifest = try? await …` sets the
   manifest to nil, so a full disk makes the notebook look empty. Ink save
   failures are swallowed silently. P1.
6. **Memory blow-ups on large notebooks.** The page manager renders every page
   at full resolution up front. Closing the editor re-renders every page on the
   main thread for the mirror. PDF import holds every rendered page in memory
   and blocks the document actor (and so every ink save) until it finishes.
   P0/P1 for large documents.
7. **Writes can be cut off at suspension.** The flush on backgrounding is not
   protected by a background-task assertion. P1.
8. **Autosave can be postponed indefinitely.** The debounce restarts on every
   stroke, so continuous writing postpones the save. P2.
9. **NOVA's direct fallback pins a retired model.** `Info.plist` sets
   `SUPPORT_AI_MODEL = llama-3.3-70b-versatile`, which overrides the code
   default. P2.

## 8. Features that cannot meet the acceptance criteria yet

| Criterion | Status | Why / mitigation |
|---|---|---|
| Pencil latency, FPS, zoom FPS (§55, 56, 63) | **unmeasured** | Needs a device and Instruments. Signposts are added this round so it can be measured |
| Crash-free ≥ 99.8% (A3) | **unmeasurable** | There is no telemetry (D-004). App Store Connect crash counts are the only signal |
| PDF search, vector PDF zoom, PDF export of annotations over the original vector (§16, 66, 67) | **not supported** | PDFs are rasterised (D-006) |
| Sync conflicts (§27, 28, 71, 72) | **not applicable yet** | There is no content sync. The only inbound channel is the rename/delete mirror, which is made non-destructive this round |
| Handwriting recognition ≥ 95% CER (§65) | **unmeasured** | Needs a labelled handwriting dataset; Vision is the engine |
| AI context accuracy and hallucination gates (§75, 76) | **unmeasured** | Needs a curated evaluation set and server-side prompt work |
| Folders/nesting, tags, pinned (§12) | **partial** | Shelves and favourites only (D-007) |
| Lasso rotate, recolour, rethicken (§7) | **partial** | Move, resize, duplicate, copy, delete and Ask NOVA exist |
| 10,000 forced-termination device runs (§61) | **simulated** | A randomised crash-recovery torture test runs against the storage layer in-process; a device kill-loop needs a UI-test host |

## 9. Plan (phases from the mandate, in order; no phase advances past an open P0)

### Phase 1: Reliability (this round)

- [x] Ordered, staged ink saves; quarantine for corrupt pages; ink drawn
      before load is merged (1.4)
- [x] Self-describing packages (`info.json`) plus launch reconciliation:
      every package on disk is in the library
- [x] The metadata store never silently becomes an in-memory library: an
      unopenable store is moved aside and the library is rebuilt from packages
- [x] Remote deletes go to the Trash, never straight to purge
- [x] Manifest last-known-good backup; an undecodable manifest is quarantined
      and restored from the backup, not overwritten; tolerant enum decoding;
      a manifest from a newer build is preserved before it is first written
- [x] Page delete is recoverable: soft delete inside the package, an Undo
      toast, purge after 30 days
- [x] The editor never blanks on a failed write; save failures (disk full)
      are shown in plain language, and staged ink keeps retrying
- [x] Background flush protected by a background-task assertion; autosave
      bounded to at most 2 s behind continuous writing
- [x] Randomised "never lose my notes" torture test (thousands of iterations,
      simulated crashes at every step)

### Phase 1 outcome

Every item above is done and tested. The torture test earned its place on its
first run: it found two real data bugs that hand-written tests had missed, and
the full suite found a third.

1. **A purged page could come back.** Straight after a delete, the manifest
   backup still lists the page. A purge then destroyed the ink and the trash
   entry but left the backup. If the manifest was damaged before the next write,
   recovery restored the backup, and the purged page reappeared blank, its
   elements pointing at swept media. Fix: a purge also removes the page from the
   backup (`forgetInBackup`).
2. **A page restored by recovery opened blank.** If a damaged manifest is
   replaced by its backup straight after a delete, the backup lists the page as
   live, but its ink had already moved to `.drawing.deleted`. In the same
   session its id was also still tombstoned, so every new stroke saved into the
   trash. Fix: every manifest load reconciles live pages against the trash
   (`reviveLivePagesInTrash`).
3. **A deferred `info.json` write could crash the app.** It read the SwiftData
   row when it ran, which could be after the row was purged (trash, then purge
   at once). SwiftData traps on that read. Fix: the description is taken
   synchronously and only the write is deferred.

Also fixed along the way:

- Adopting a stray page blob no longer re-sorts the whole notebook by creation
  date. Pages the user had moved kept being put back in creation order.
- Search per keystroke is 5 to 10 times faster (measurements.md §3).
- NOVA's direct fallback no longer pins a retired model (R-11).

### Phase 4 (pulled forward: these are crash and data-loss risks on large documents)

- [x] PDF import renders outside the document actor, one page at a time in an
      autorelease pool, with a single manifest commit, cleanup on failure, and
      a count of skipped pages
- [x] Page manager and iPhone viewer: lazy, thumbnail-sized renders with a
      bounded cache
- [x] Closing the editor pushes only pages that changed (fingerprinted)

### Instrumentation

- [x] `OSSignposter` intervals for notebook open, page load, page save, page
      render, thumbnails, search and import, so the §52 targets can be measured
      in Instruments on a device
- [x] Benchmarks in the test suite for storage, search and recovery at stress
      sizes; results in measurements.md

### Phases 2, 3 and 5–9 (next rounds)

- Pencil: profile on a device (main-thread stalls during strokes),
  tool-switch latency, palm-rejection matrix.
- Documents: live PDF pages (D-006), folders (D-007), move pages between
  notebooks, page drag and drop.
- Search: PDF text layer, result → exact page (exists). Latency at 1,000
  pages is measured (measurements.md); 10k pages is next.
- AI: "found in your notes vs. general knowledge" labelling, notebook-wide
  questions grounded on `search.json`.
- iPadOS: keyboard shortcuts beyond ⌘Z, drag and drop of pages and
  notebooks, VoiceOver audit.
- Polish and QA: empty states, error copy audit, long-session test on a
  device.

## 10. Explicitly out of scope

macOS, Windows, Android and web apps; enterprise or classroom administration;
LMS integrations; social, messaging and public sharing; marketplace; real-time
collaboration; web3; advertising. A fix that would depend on any of these is
flagged, not built.
