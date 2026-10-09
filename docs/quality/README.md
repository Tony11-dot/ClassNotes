# ClassNotes quality programme: scope report and plan

This is the scope and dependency report the quality mandate asks for before
any large change (§53.22). It records:

- what the app is built on;
- where it falls short of the bar;
- what is being fixed, in what order.

Registers (dependencies, decisions, risks, permissions, network use, change
control) are in [registers.md](registers.md). Measured numbers are in
[measurements.md](measurements.md).

Last updated: 2026-10-09. Phase 1 is complete; see "Phase 1 outcome" below. Rounds 2, 3 and 4 are below it. Round 4 settled every open decision (section 6). Round 5 closed the remaining code gaps in phases 2, 3, 7, 8 and 9.

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
| PDF | The imported PDF is kept once in the package and each page is drawn **live** from it (tiled, `CATiledLayer`, Core Graphics), sharp at any zoom; search reads its text layer; export writes the original vector page. A 2× PNG per page stays as the thumbnail and for older builds (manifest v9) |
| Search | `SearchIndexer` (actor): Vision `VNRecognizeTextRequest` over rendered ink, plus element text, cached per package in `search.json` |
| Handwriting recognition | Apple Vision, on device and offline |
| AI (NOVA) | `NovaBackendProvider` → ClassMate API `POST /classnotes/ai` (model key held on the server; the server calls Groq). Asks before sending anything (`NovaConsent`). Groq direct is a fallback only |
| Auth | ClassNotes' own accounts (`/classnotes/auth/*`), token in the Keychain. **Optional**: the library opens without one (D-001) |
| Sync | The ClassMate mirror (metadata and page renders up; renames and deletes down). **iCloud notebook sync** (`NotebookSync`, D-003) is on from 1.5 (81): the container exists and the entitlements are wired (R-25) |
| Settings sync | `PUT/GET /classnotes/settings`; the higher revision wins (no wall clock) |
| Payments | StoreKit 2: a lifetime unlock plus an optional subscription (`EntitlementService`) |
| Tests | Swift Testing only: see measurements.md for the current count. Includes a 3,000-step crash/damage torture test, a two-device sync torture test, benchmarks, and the NOVA evaluation set |
| CI/CD | fastlane run locally (`beta`, `check`, `listing`, `submit`). There is no hosted CI |
| Crash reporting and analytics | MetricKit, **on the device** (D-004): crash, hang, launch and memory reports kept locally, summarised in Support, sent only when the user shares them. No analytics, no third party |

## 2. Existing dependencies

There is one third-party package: `lottie-ios` (Apache-2.0), used only for the
launch animation. Everything else is an Apple framework: PencilKit, PDFKit,
Vision, SwiftData, StoreKit, AVFoundation, VisionKit (document scanner),
PhotosUI and os.

## 3. Required new dependencies

None. Every round so far uses Apple frameworks only. Telemetry (D-004) and
the live PDF engine (D-006) were both built on Apple frameworks (MetricKit,
Core Graphics) rather than adding a dependency.

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
- **End-to-end latency (ms), FPS and battery** need a physical iPad with
  Instruments. Nothing in the simulator measures them. The benchmarks here
  measure the parts the app controls: storage, search and rendering on the
  CPU. Launch time and library memory have been measured on the iPad Air (M4)
  (measurements.md §9).
- **Hover** needs Apple Pencil 2 or Pro on an M2-or-later iPad Pro or an M2/M3
  iPad Air. **Squeeze and barrel roll** need Apple Pencil Pro.
- **PDFs imported before 1.6** stay rasterised: the original PDF wasn't kept,
  so there is nothing to draw live. Re-importing the PDF gives the live page.

## 6. Decisions (detail in registers.md)

All eight were decided in round 4, on the recommendations in registers.md.

| ID | Question | Decided |
|---|---|---|
| D-001 | Should core note taking require an account? | **No.** The library opens without one; an account adds sync and NOVA |
| D-002 | Reference iPads for the performance gates | iPad Air 11-inch (M4) measured; low end A16 iPad still to borrow |
| D-003 | Real content sync and its conflict model | **iCloud Drive as transport, local packages stay the store, keep both on conflict.** Built; on once the iCloud container exists |
| D-004 | Crash and performance telemetry | **MetricKit, on device**; shared by the user, no third party |
| D-005 | Free-tier limits | **Uncapped.** Any future cap limits creating, never opening (pinned by tests) |
| D-006 | PDF engine | **Live** from the stored PDF (manifest v9), PNG kept as fallback |
| D-007 | Folders and tags | **Shelves inside shelves** (one parent) and **tags**; drag a cover onto either |
| D-008 | Lasso rotate and recolour | **Both.** Ink and fills turn exactly; boxes turn about their centre |

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
| Launch time, memory (§52) | **measured** on the iPad Air (M4) | 162 ms to first frame and 319 ms to active (median of 5); 52 MB with a 1,260-page library; a 300-page notebook scrolled fast holds 313–377 MB (peak 571 MB on opening). The designed 2.6 s launch scene comes on top (measurements.md §9). Low-end A16 still to borrow |
| Crash on device: long-press a library cover and move (1.5 (80)–(82)) | **fixed** in 1.5 (83) | Found by the device lab. The drag preview read `AppServices` from an environment a drag preview never has; `DragPreviewTests` guards it |
| Crash on launch on every device (1.5 (81)–(83)) | **fixed** in 1.5 (84) | Found on the iPad with TestFlight 83. The iCloud entitlement made SwiftData turn on CloudKit by default, and CloudKit refuses the schema's unique ids, so no database opened. Tests, simulator and device lab were all signed without the entitlement. Every configuration is now `cloudKitDatabase: .none`, pinned by a test; reproduced and verified on a simulator signed with the real entitlements |
| Crash-free ≥ 99.8% (A3) | **measurable** | MetricKit reports on each device (D-004) plus App Store Connect's crash counts. Needs time in the field |
| PDF search, vector PDF zoom, PDF export of annotations over the original vector (§16, 66, 67) | **met** for PDFs imported from 1.6 | D-006; earlier imports stay rasterised |
| Sync conflicts (§27, 28, 71, 72) | **met in tests**, on in the build | Keep-both on conflict, never replaced under an open editor, replaced copies kept; two-device and torture tests. Still needs a check on two real iPads |
| Handwriting recognition ≥ 95% CER (§65) | **unmeasured** | Needs a labelled handwriting dataset; Vision is the engine |
| AI context accuracy and hallucination gates (§75, 76) | **measured** | Evaluation set: right page found first 96%; live model cites a right page 23/25, admits 5/5 out-of-notes questions, 0 citations to pages that don't exist (measurements.md §5) |
| Folders/nesting, tags, pinned (§12) | **met** | Nested shelves, tags, favourites, drag to file (D-007) |
| Lasso rotate, recolour, rethicken, cut (§7) | **met** | Rotate and recolour (D-008); thickness and Cut (⌘X) in round 5 |
| Drag and drop (§18, 78) | **met in tests** | PDF → pages, image/text/link/file → where dropped, files → new notebooks in the library; 200 repeated drops all land |
| Multitasking (§19, 79) | **met in tests** | 1,000 background/kill/resize cycles, 0 data-loss events; Split View and Stage Manager keep the editor (routing is by device, not width) |
| Long session (§44) | **met in tests** | Six lectures in one run: nothing lost or corrupt, no slowdown, bounded memory (measurements.md) |
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

### Round 2: Phases 2, 3, 5 and 7 (what can be done and checked without a device)

- [x] **Pencil (2):** main-thread work around each stroke measured
      (measurements.md §2b). Pencil-down no longer reads the whole drawing,
      and stroke end reads it once instead of twice. The "every stroke
      re-renders the editor" suspicion was measured and ruled out: Observation
      does not notify on equal writes.
- [ ] **Pencil (2), device only:** end-to-end latency, frame rate while
      writing, palm-rejection matrix, hover and barrel roll on Pencil Pro.
- [x] **Documents (3):** move or copy pages to another notebook from the
      page manager. The cover stays behind, media travels with the page, and
      a move leaves the originals in Recently Deleted. The destination is
      written in full before the source changes, so a crash duplicates and
      never loses.
- [x] **Search (5):** imported PDF pages, scans and photos are read by Vision,
      so a word printed in a handout is findable. Existing indexes upgrade
      once (`search.json` v2, derived data).
- [x] **iPadOS (7):** hardware-keyboard shortcuts for undo/redo (⌘Z had never
      worked: the canvas is never first responder), tools ⌘1–5, next and
      previous page ⌥⌘↓/↑, new page ⇧⌘N, page manager ⌥⌘P.

### Round 3: Phases 5, 6, 7 and 8 (AI, accessibility, plain language)

- [x] **AI (6): consent.** NOVA sent questions, snips and whole notebooks to
      the AI provider with no permission asked. Every request now waits at
      one gate until the account allows it; the card says what is sent and
      to whom (the ClassNotes server, then Groq), and Settings can withdraw
      it (CC-009, R-18). The unused server "beautify" and "explain" client
      calls are gone, so the gate is the only way out.
- [x] **AI (6): grounded answers.** After "Read this notebook", each question
      carries the pages that best match it (named pages first, then rarer
      shared words) plus a share of every other page, under the server's
      limit. The chat shows "Answering from this notebook" with a Stop, each
      question says which pages went with it, and answers are labelled from
      their own citations: "From your notes" with page links, or "General
      knowledge". Before, the notebook was its first 4,000 characters, sent
      once and cut to 2,000 by the third question.
- [x] **AI (6): two server-contract bugs.** NOVA's own instructions were
      sent as "the page the student is looking at" (R-19); a question or page
      context over 6,000 characters was refused (R-20).
- [x] **Search (5):** measured at 10,000 pages: 67–111 ms per keystroke
      (measurements.md §3), a third of the 1,000-page target.
- [x] **iPadOS (7): VoiceOver.** Every icon-only control has a name; sliders
      say what they set and read out their value; page thumbnails are one
      element each ("Page 3, current page, bookmarked") with the same tap;
      the voice-note bubble says whether it's playing; shelf icons have
      spoken names.
- [x] **Polish (8): words.** The About screen said notebooks "stay on your
      device" (page pictures sync); the FAQ said NOVA tidies handwriting
      (that is on-device) and promised iCloud sync (D-003 is open). Restore
      Purchases showed StoreKit's raw error, and called a cancelled sign-in
      an error.
- [x] **Owner:** the privacy policy now covers ClassNotes and names Groq,
      and the App Store privacy label lists user content (R-21, closed
      2026-10-09).

### Round 4: every open decision

- [x] **D-001, accounts optional.** "Continue without an account" on the
      first screen; a session the server stops honouring, or a deleted
      account, keeps the library open and says why; signing in later syncs at
      once. NOVA without a session says to sign in instead of asking for
      permission it can't use (CC-010).
- [x] **D-008, lasso rotate and recolour.** A turn handle under the
      selection (settles on 15° steps, with a haptic tick), and a Colour
      button. Ink keeps its own ink type and transparency. Found and fixed on
      the way: moving or resizing tape put it twice as far as the finger went
      (R-22).
- [x] **D-007, nested shelves and tags.** Shelves inside shelves, a second
      row inside a shelf, delete moves contents up a level (nothing lost);
      tags with a tidy-as-you-type editor, searched with titles; drag covers
      onto shelves, tags or All (CC-012).
- [x] **D-004, diagnostics on the device.** MetricKit's crash, hang, launch
      and memory reports, kept 90 days, summarised in Support, shared only by
      the user (CC-013).
- [x] **AI (6), the evaluation set.** 30 questions over three notebooks,
      scored offline on every run and live on demand. The live run found that
      the model cites in forms the app didn't read (【p. 1】, "(see p. 3)",
      a "Page 1" heading): fixed, uncited answers went from 5 to 1 in 25
      (R-23).
- [x] **D-006, live PDF.** Manifest v9; the storage torture test now imports
      PDFs and checks the shared file outlives every page that uses it
      (CC-011).
- [x] **D-003, iCloud sync engine.** Built and tested end to end with two
      simulated devices (11 scenario tests, a 3-seed torture test). Off in
      this build until the iCloud container exists (CC-014, R-25).
- [ ] **Device lab (D-002).** A devlab copy (`com.classmate.notes.devlab`,
      its own container, never the installed app) and a 121-notebook,
      1,260-page library are on the iPad Air; the launch and memory traces
      run as soon as the iPad is unlocked.

### Round 5: the remaining gaps in phases 2, 3, 7, 8 and 9

- [x] **Drag and drop (3, 7).** A PDF dropped on a page becomes pages
      after that page; a photo, words, a link or any other file lands where
      it was dropped, on the page it was dropped on. Files dropped on the
      library become notebooks (each PDF its own, the photos together). A
      notebook being dragged to a shelf still reaches the shelf (CC-016).
- [x] **Lasso (2).** Cut (⌘X) and Thickness (thinner/thicker, ink only,
      one undo step per press; the selection holds).
- [x] **Keyboard (7).** Library: ⌘N quick note, ⌥⌘N notebook, ⌘O import,
      ⌘F search (cursor in the field), ⌘, settings. Editor: ⌘= / ⌘- / ⌘0
      zoom on a fixed ladder.
- [x] **Empty states and onboarding (8).** The empty library says what goes
      there and offers "Create your first notebook", "Quick note" and
      "Import a PDF". First-use hints teach the lasso, tape, fill, text,
      ruled lines, the hand, NOVA, the snip and the page manager once each,
      at the moment they're reached; Settings → Show tips again.
- [x] **QA (9).** A long-session test (six lectures over three notebooks,
      then a relaunch) and a 1,000-cycle background/kill/resize test.

### What's left, and who it waits on

- **A hand and a Pencil:** latency, frame rate while writing, palm
  rejection, hover and barrel roll (PencilKit supplies both for ink tools),
  an hour-long session, battery.
- **Two iPads:** the iCloud sync check on real devices.

## 10. Explicitly out of scope

macOS, Windows, Android and web apps; enterprise or classroom administration;
LMS integrations; social, messaging and public sharing; marketplace; real-time
collaboration; web3; advertising. A fix that would depend on any of these is
flagged, not built.
