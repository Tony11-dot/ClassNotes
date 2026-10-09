# Registers

This file holds the dependency register, open decisions, risks, permissions,
network classification, external-service failure policy, version
compatibility and change control. Keep it current: a change that touches any
item below updates this file in the same commit.

## Dependency register

| Dependency | Purpose | Required | Version | Licence | Failure behaviour |
|---|---|---|---|---|---|
| PencilKit | ink input, rendering, storage format | yes | iPadOS 26 SDK | Apple | A page blob that fails to decode is quarantined (`.drawing.unreadable`), never overwritten |
| PDFKit | PDF import (rasterised) and PDF export | yes | iPadOS 26 SDK | Apple | Unreadable PDF → plain-language error; nothing in the library changes |
| Vision | handwriting search, beautify, snip OCR | no (degrades) | iPadOS 26 SDK | Apple | No recognition → search matches titles and typed text only |
| SwiftData | library metadata, settings, chats | yes | iPadOS 26 SDK | Apple | An unopenable store is moved aside, kept, and the library is rebuilt from the document packages |
| StoreKit 2 | lifetime and subscription unlocks | no | iPadOS 26 SDK | Apple | Offline → cached transactions; core note taking is never gated |
| lottie-ios | launch animation | no | ≥ 4.5.0 | Apache-2.0 (attribution in NOTICE not required for binary) | A missing scene falls back to video, then to the native animation |
| ClassMate API | auth, mirror, settings, NOVA | no for writing; yes for sign-in | n/a | first-party | See the failure policy below |
| Groq | NOVA fallback with the user's own key | no | n/a | commercial API | NOVA unavailable; nothing else is affected |

**Third-party licence register.** `lottie-ios` is Apache-2.0, which is
compatible with App Store distribution and needs no source disclosure. There
are no other third-party components.

## Decision register

All eight were decided in round 4 (2026-10-09) on the recommendations below;
each records its outcome under **Decided**.

**D-001: Account required for core note taking?**

- Today: the library is behind sign-in (`AuthService.state == .authenticated`).
  A cached session works offline. A token the server rejects (password
  changed, account deleted) signs the device out and locks local notes until
  the user signs in again.
- Options:
  - (a) Keep it as it is.
  - (b) Local-first: notebooks are always reachable, and an account only adds
    the mirror, NOVA and settings sync.
  - (c) Keep the gate, but never lock out a device that already holds local
    notebooks.
- Recommended: **(b)**. The mandate (§53.15) says core note taking should not
  need an account.
- Impact if unresolved: a student whose session is rejected cannot open their
  own lecture notes until they are online and signed in.
- Not changed silently: the gate is a product decision.
- **Decided: (b).** The library opens without an account; a rejected session
  or a deleted account keeps it open (CC-010).

**D-002: Reference hardware for the performance gates.**

- Recommended: low end is iPad (A16) with Apple Pencil (USB-C); high end is
  iPad Pro (M5) with Apple Pencil Pro.
- Impact if unresolved: no §52 number can be claimed as passed.
- **Decided:** the iPad Air 11-inch (M4) the owner develops on is the high
  end measured (measurements.md, "On device"). The A16 low end is still to
  borrow.

**D-003: Content sync.**

- Options:
  - (a) iCloud Drive with a document per package (`NSFileCoordinator`,
    conflict versions).
  - (b) The ClassMate API with per-page revisions.
- Recommended: **(a)** for documents, keeping the API mirror for the
  ClassMate tab. The packages were designed to move into a ubiquity container
  without a format change.
- Required before building it: a stroke-level merge or a "keep both" conflict
  UI. Last-writer-wins is never acceptable for ink.
- Impact: §27, 28, 71 and 72 can't be tested until this exists.
- **Decided: iCloud Drive, as a transport only.** Packages stay on the
  device as the store; a copy travels through the app's iCloud container.
  Changed on both devices → both kept. Built and tested (CC-014); switched off
  in the build until the iCloud container exists (R-25).

**D-004: Telemetry.**

- Options:
  - (a) MetricKit only: on device, no third party; daily hang, crash, launch
    and memory payloads.
  - (b) A third-party SDK such as Sentry.
- Recommended: **(a)** first. It needs no new dependency and no privacy-label
  change if payloads stay on device or go to our own API without note content.
- Impact if unresolved: the crash-free rate (A3) cannot be measured.
- **Decided: (a).** MetricKit, kept on the device, shared by the user
  (CC-013). No privacy-label change: nothing is collected by us.

**D-005: Free-tier limits.**

- `freeNotebookLimit` is nil (uncapped). The mandate requires that no core note
  taking becomes inaccessible when a subscription lapses.
- Recommended: any cap limits *creating* notebooks, never *opening* them. That
  is already how it is wired.
- **Decided:** uncapped; the rule above stands and is pinned by
  `EntitlementTests`.

**D-006: PDF engine.**

- Today: pages are rasterised at 2× at import. That means no text search, soft
  text at high zoom, and large `media/` folders.
- Options:
  - (a) Keep it.
  - (b) Store the PDF and render each page live with PDFKit (`PDFPage.thumbnail`
    or a tiled `CATiledLayer`), keeping ink in page space.
- Recommended: **(b)**, as a manifest v9 feature with v8 documents left as they
  are.
- Impact: blocks §16, 64 (PDF text), 66 and 67 at full strength.
- **Decided: (b)** as manifest v9 (CC-011).

**D-007: Folders and tags.**

- Today: flat shelves plus favourites.
- Recommended: nested shelves with a single parent, plus tags as a SwiftData
  relation. Drag a notebook onto a shelf.
- **Decided:** nested shelves (one parent) and tags, stored as a string list
  on the notebook rather than a relation (a tag has no properties of its own
  yet). Drag onto a shelf, a tag or All (CC-012).

**D-008: Lasso rotate and recolour.**

- Needs a selection-transform model (rotation per element, recolouring of
  `PKInk`).
- Recommended: recolour first. It is cheap and is the most requested.
- **Decided: both.** No format change was needed: `PageElement.rotation`
  already existed and every renderer applied it; nothing had ever set it.

## Risk register

| # | Risk | Prob. | Impact | Mitigation | Status |
|---|---|---|---|---|---|
| R-01 | Package without a library row is invisible (crash mid-create, store reset) | med | high | `info.json` + launch reconciliation | mitigated (tested) |
| R-02 | SwiftData store fails to open → in-memory library, new work vanishes | low | high | Move aside + rebuild from packages + notice | mitigated (tested) |
| R-03 | Undecodable manifest rebuilt and written over the original | low | high | Backup, quarantine, tolerant enums, preserve newer-version copy | mitigated (tested) |
| R-04 | Server-sent delete destroys local ink | low | high | Remote deletes go to the Trash | mitigated (tested) |
| R-05 | Accidental page delete is permanent | med | high | Soft delete + Undo + 30-day purge | mitigated (tested) |
| R-06 | Write failure blanks the editor / silent save failure | low | high | Keep the last good manifest; show a save-failure banner; staged ink retries | mitigated (tested) |
| R-07 | Large-notebook memory exhaustion (thumbnails, exit render, PDF import) | med | high | Thumbnail-size lazy renders, changed-only pushes, streamed import | mitigated (tested) |
| R-08 | Final write cut off by suspension | low | med | Background-task assertion around the flush | mitigated (tested) |
| R-09 | Main-thread work while the pencil is down (latency spikes) | med | med | All rewrites gated on pencil-up; encode off main; pencil-down no longer copies the drawing, stroke end copies it once (measured, measurements.md §2b). Device profiling still needed | partly mitigated |
| R-10 | PencilKit format change in a future iPadOS | low | high | Quarantine on decode failure; the original bytes are never overwritten | mitigated |
| R-11 | Retired AI model pinned in Info.plist | high | low | Override removed; `AIModelConfigurationTests` fails if the plist pins a model other than the default | fixed |
| R-12 | No telemetry: regressions in the field are invisible | high | med | D-004: MetricKit on the device, shared from Support | mitigated |
| R-13 | Rasterised PDFs: no text search, blurry at high zoom | high | med | D-006: live PDF from 1.6 imports; earlier imports re-import | fixed (tested) |
| R-14 | Purged page resurrected from the manifest backup after damage | low | med | Purge removes the page from the backup too (found by the torture test) | fixed (tested) |
| R-15 | Delete rolled back by recovery leaves the page blank, and saves go to the trash | low | high | Live pages are reconciled against the trash on every manifest load (found by the torture test) | fixed (tested) |
| R-16 | Deferred `info.json` write reads a purged SwiftData row and traps | med | high | Snapshot synchronously, defer only the write (found by the full suite) | fixed (tested) |
| R-17 | Orphan adoption re-sorted the whole notebook by creation date, undoing page moves | low | med | Adopted pages are appended; existing order kept | fixed (tested) |
| R-18 | Note content sent to a third-party AI without the user's permission (App Store Review Guideline 5.1.2(i)) | high | high | One consent gate in `NovaConversation` in front of every request; asked once per account; withdrawn in Settings (CC-009) | fixed (tested) |
| R-19 | NOVA's own style prompt sent as `pageContext`, which the server labels "the page the student is looking at" | high | low | The identity prompt is excluded from page context | fixed (tested) |
| R-20 | A question or page context over 6,000 characters is refused by the server (400), shown as "NOVA couldn't respond" | med | low | Both are cut to fit, measured in UTF-16 as the server's validator measures | fixed (tested) |
| R-21 | The published privacy policy names Anthropic for NOVA and does not mention ClassNotes; NOVA in ClassNotes runs on Groq | high | med | Policy text must be updated by the owner (outside this repository) | **closed: policy updated and App Store privacy label published 2026-10-09** |
| R-22 | Moving or resizing tape (lasso or finger) shifted its frame-relative path as if it were in page space: the strip landed twice as far as the finger went | high | low | One geometry for every element (`PageElement.moved/transformed`): page-space paths (fills) move, frame-relative ones (tape) don't | fixed (tested) |
| R-23 | NOVA answers that cited their page in the model's own forms (【p. 1】, "(see p. 3)", a "Page 1" heading) were left unlabelled: one in five | high | low | The citation reader takes every form the live evaluation found; the display shows ordinary brackets | fixed (tested, re-measured live) |
| R-24 | iCloud sync keeping a whole copy of every notebook it replaces could fill the device for a notebook written on elsewhere all day | med | med | Two copies per notebook, 30 days at most | fixed (tested) |
| R-25 | The app's entitlements file was never wired into the build and the App ID has no iCloud: sync cannot run until the owner creates the container | high | med | Sync is built, tested and gated off (`CMCloudSync`); turning it on is a portal step, then a build flag | **closed: container created, entitlements wired, sync on in 1.5 (81)** |
| R-26 | A pull racing an editor opening the same notebook could leave the editor holding the old version and later save it over the new one | low | high | The store refuses to replace a notebook registered as open, on the same actor that serves the editor's load (`beginEditing`) | fixed (tested) |
| R-27 | Signing with the iCloud entitlement turned on SwiftData's CloudKit default, which refuses the schema's unique ids: 1.5 (81)–(83) quit on launch on every real device while tests, the simulator and the device lab (all signed without the entitlement) passed | high | high | Every store configuration is `cloudKitDatabase: .none` (`ModelContainerFactory.configuration`), pinned by a test; a build whose entitlements change is launched first as a Release build on a simulator signed with the real entitlements | fixed in 1.5 (84) (tested; found on the owner's iPad) |
| R-28 | Reading a notebook with no package here wrote a blank one, so a notebook from another device got a blank stand-in that the next launch opened in the editor, and leaving could push that blank page over the server's real pages | high | high | Reads never create (`noSuchNotebook`); launch sets stand-ins aside by exact shape (CC-017); remote-only rows stay out of the launch push and iCloud; "Edit on this iPad" builds only from a complete fresh copy of the server's pages | fixed in 1.5 (85) (tested; found on the owner's iPad) |

## Permission matrix

| Permission | Required | Feature | Requested when | Fallback |
|---|---|---|---|---|
| Photos | no | Insert photo, image import | First tap on Photo (system picker needs no permission; `NSPhotoLibraryUsageDescription` covers saving) | Files import |
| Files | no | PDF and file import | System document picker; no prompt | — |
| Microphone | no | Voice notes | First tap on record | Feature disabled with an explanation |
| Camera | no | Document scan | First tap on Scan | Import from Files or Photos |
| Notifications | not used | — | — | — |

## Network classification

- **Fully offline:**
  - opening, writing, erasing, lasso, undo/redo;
  - pages, templates, shelves, trash;
  - export (PDF, images);
  - search over indexed handwriting and text (Vision runs on device);
  - beautify (on-device recognition; it never calls NOVA);
  - PDF, photo and scan import.
- **Online when available:** library mirror to ClassMate, settings sync,
  remote rename/delete pull, cover and page pushes. All are queued
  best-effort, and none blocks the UI.
- **Requires network:**
  - NOVA (chat, snip, explain);
  - sign-in, sign-up, password reset, account deletion;
  - viewing a remote-only notebook (one created on another device) unless it
    is cached;
  - bringing a remote-only notebook over with "Edit on this iPad": it is built
    only from a complete fresh copy of the server's pages, never the cache;
  - purchases.

## What NOVA sends (AI data flow)

Nothing in this table is sent until the account has allowed it
(`NovaConsent`, asked the first time, changeable in Settings). Everything
goes to `POST /classnotes/ai` on the ClassNotes server, which forwards it to
Groq. The editor, search, beautification and handwriting recognition never
call NOVA.

| Trigger | What is sent |
|---|---|
| A typed question | The question and the chat so far (the server keeps the last 8 turns, 2,000 characters each) |
| A snip | The snipped region as a JPEG, and its recognised text as a hint |
| "Read this notebook" | A contact-sheet picture of every page, plus an even share of every page's recognised text (at most 5,600 characters) |
| A question in a chat that is reading a notebook | The question, the best-matching pages' text and a share of the rest (at most 5,600 characters). The chat shows "Answering from this notebook" with a Stop button, and each question says which pages went with it |
| Follow-up suggestions | The chat so far, after a reply |

## External-service failure policy

| Service | Timeout | Retry | Offline fallback | User message | Data safety |
|---|---|---|---|---|---|
| ClassMate mirror push | URLSession default | Next launch's `pushAll`; per-edit pushes are best effort | Nothing is shown; local is the source of truth | none (silent by design) | Pushes never modify local data |
| Remote changes pull | URLSession default | Unacknowledged ids retry next launch | Skipped | none | Deletes go to the Trash (30 days), never to purge |
| NOVA | provider-defined | User re-asks | NOVA only | "NOVA can't reach the server. Your notes are safe; try again when you're online." | AI never writes to a document without a user action |
| Auth `/me` at launch | URLSession default | Next launch | A cached session stays signed in | none | Local notes are untouched by any auth outcome |

## Version compatibility

- **Current document schema:** manifest v9 (`backgroundPDF`, CC-011).
  `info.json` v1 and `trash.json` v1 are sibling files, so they never moved
  the manifest version.
- **Minimum readable schema:** v1. Every later field is optional or defaulted.
- **Migration policy:** additive only. A field is never removed or
  reinterpreted. `ensureCoverPage` keys off `coverPageVersion`, never
  `currentVersion`.
- **Rollback (an older build opens a newer document):**
  - Unknown element kinds decode to `.unknown`.
  - Unknown templates, sizes and orientations decode to safe fallbacks for
    display (from this round).
  - Before an older build first rewrites a manifest stamped newer than it
    understands, the original is copied to `manifest.v<N>.json` and never
    deleted.

## Change control

**CC-001: self-describing document packages (`info.json`).**

- What: each `<uuid>.cmnote/` gains `info.json` with the notebook's library
  metadata (title, kind, cover, page style, timestamps, trash date).
  `NotebookRepository` keeps it current.
- Why: R-01 and R-02. Without it, a package with no SwiftData row cannot be
  shown with its real name.
- Affected: `DocumentStore`, `NotebookRepository`, `AppServices` launch.
- Migration: backfilled at launch from the rows; there is no manifest change.
- Rollback: older builds ignore the file.
- Tests: `LibraryRecoveryTests`, `StoreRecoveryTests`.

**CC-002: manifest backup and quarantine.**

- What: every manifest write keeps the previous file as
  `manifest.backup.json`. A manifest that fails to decode is moved to
  `manifest.unreadable-<timestamp>.json`, and the backup is tried before
  rebuilding from page blobs.
- Why: R-03.
- Migration: none.
- Rollback: older builds ignore both files.
- Tests: `ManifestSafetyTests`.

**CC-003: soft page delete (`trash.json`).**

- What: deleting a page moves its record into the package's `trash.json` and
  renames its ink blob to `<id>.drawing.deleted`. Media stays until purge.
  Undo restores the page at its old position. Entries older than 30 days are
  purged when the notebook is opened.
- Why: R-05.
- Migration: none.
- Rollback: an older build ignores `trash.json`, and `.deleted` blobs are
  ignored by the orphan scan, so a deleted page stays deleted.
- Tests: `PageTrashTests`.

**CC-004: remote deletes go to the Trash.**

- What: `applyRemoteChanges` sets `deletedAt` instead of destroying the
  package.
- Why: R-04.
- Migration: none.
- Rollback: n/a.
- Tests: updated `applyRemoteChanges` tests.

**CC-005: SwiftData store recovery.**

- What: an unopenable store is moved to `Recovered Library/<timestamp>/`, a
  fresh store is opened, and the library is rebuilt from packages. An
  in-memory store is now the last resort, and is shown as such.
- Why: R-02.
- Rollback: the old store files are kept and can be moved back.
- Tests: `LibraryRecoveryTests`, `StoreRecoveryTests`.

**CC-006: recovery tidies the trash; purge tidies the backup.**

- What: loading a manifest removes trash entries for pages the manifest lists
  as live, moving their `.drawing.deleted` blob back when the live slot is
  empty. Purging a page also removes it from `manifest.backup.json`. No new
  files and no format change.
- Why: R-14 and R-15.
- Rollback: older builds never read either file's new state differently.
- Tests: `PageTrashTests` (`backupRollbackRevivesInk`, `purgedPageNotInBackup`)
  and `NeverLoseNotesTortureTests`.

**CC-007: NOVA fallback model comes from code, not Info.plist.**

- What: removed `SUPPORT_AI_MODEL` from `Config/Info.plist`, so
  `AIConfig.defaultModel` applies to the direct Groq fallback. The default
  path, `/classnotes/ai`, picks its model on the server and is unaffected.
- Why: R-11. The pinned model has been retired.
- Privacy, auth, pricing: unchanged. Nothing new is sent.
- Rollback: re-add the key.
- Tests: `AIModelConfigurationTests`.

**CC-008: search index v2 reads imported page backgrounds.**

- What: `SearchIndexer` also runs Vision over an imported page's background
  image (PDF page, scan, photo). `search.json` is version 2. A v1 index has
  its imported pages read once more; pages without a background are not
  re-read.
- Why: a PDF's words could not be found by search.
- Format: `search.json` is DERIVED data, never a source of truth. A missing or
  unreadable index is empty, never an error. The document format is unchanged.
- Privacy: Vision runs on device. Nothing leaves the iPad.
- Rollback: an older build reads a v2 index as an index (its fields are
  unchanged).
- Tests: `ImportedPageSearchTests`.

**CC-009: NOVA asks before sending anything; notebook-grounded answers.**

- What:
  - Every NOVA request waits at one gate (`NovaConversation`) until the
    account has allowed it (`NovaConsent`, per account, per disclosure
    version). The consent card says what is sent and to whom; Settings has
    the switch to withdraw it.
  - "Read this notebook" now grounds the chat: each later question carries
    the pages that match it (`NovaGrounding`), and answers are labelled from
    their own citations ("From your notes" with page links, or "General
    knowledge").
  - NOVA's identity prompt is no longer sent as page context; the question
    and page context are cut to the server's limits.
  - Removed the unused client calls for server-side "beautify" and "explain".
- Why: R-18 (privacy, App Store 5.1.2(i)), R-19, R-20, and the mandate's AI
  phase (grounding and "found in your notes vs. general knowledge").
- Privacy: no new kind of data is sent. Notebook text goes only after the user
  taps "Read this notebook", only in that chat, and the chat shows it.
- Auth, pricing, document format: unchanged.
- Rollback: the gate is client-side; a build without it sends as before.
- Owner action: the privacy policy (R-21) and the App Store privacy label
  should list "User Content" sent to an AI service for app functionality.
- Tests: `NovaConsentTests`, `NovaGroundingContextTests`,
  `NovaGroundedConversationTests`, `NovaReplySourceTests`,
  `NovaPayloadLimitTests`.

**CC-010: an account is optional (D-001).**

- What: the first screen offers "Continue without an account"
  (`AuthService.worksWithoutAccount`). A session the server rejects, or an
  account deleted in the app, signs the device out but keeps the library
  open, with a one-time notice. Signing in later runs the account sync at
  once (`AuthService.onSignIn`). NOVA without a session says to sign in.
- Why: mandate §53.15; a student must never be locked out of their own notes
  by a session expiring.
- Auth: unchanged on the server. Privacy: less is sent (nothing until the
  user signs in). Pricing: unchanged.
- Rollback: older builds lock the library behind sign-in as before; local
  notebooks are unaffected.
- Tests: `ClassMateNetworkingTests` (five working-without-an-account tests),
  `NovaConsentTests.noSessionNoAsk`.

**CC-011: live PDF pages (manifest v9, D-006).**

- What: importing a PDF keeps the PDF once in `media/`, and each page records
  which page of it it is (`PageRecord.backgroundPDF`). The editor and the
  zoom view draw that page live and tiled; search reads its text layer;
  export draws the original vector page. The PNG made at import stays.
- Format: manifest v9. The new field decodes tolerantly (a bad value costs
  the live drawing, never the page). A v8 build ignores the field and shows
  the PNG; the newer-manifest copy rule keeps the v9 manifest beside it.
- Storage: the PDF is shared media, removed only when no live or deleted page
  uses it; page transfer copies it. The storage torture test now imports PDFs
  and checks this after every step.
- Rollback: v8 builds keep working on v9 notebooks (PNG only).
- Tests: `LivePDFTests`, `NeverLoseNotesTortureTests`.

**CC-012: nested shelves, tags, and a metadata revision stamp (D-007, D-003).**

- What: SwiftData gains `Shelf.parentID`, `Notebook.tags` and
  `Notebook.metadataRevisedAt`, all defaulted, so lightweight migration adopts
  existing rows. `info.json` gains `tags` and `revisedAt` (optional; older
  descriptions read as before). Deleting a shelf moves what was in it up a
  level instead of off every shelf.
- Sync: shelves' nesting and tags are local to the device for the ClassMate
  mirror (its DTO has neither).
- Rollback: older builds ignore the new attributes and keys.
- Tests: `ShelfTreeTests`, `NotebookTagRulesTests`, `LibraryOrganisationTests`.

**CC-013: diagnostics kept on the device (D-004).**

- What: a MetricKit subscriber stores daily metrics and crash, hang, CPU and
  disk-write diagnostics in Application Support, 90 days and 120 payloads at
  most. Support shows a 30-day summary and "Share diagnostics".
- Privacy: payloads hold no note content and never leave the device unless
  the user shares them. Nothing new is collected by us; no privacy-label
  change.
- Tests: `DiagnosticsTests`.

**CC-014: iCloud notebook sync (D-003). On from 1.5 (81).**

- What: `NotebookSync` reconciles each notebook with a copy in the app's
  iCloud container by content fingerprint against the last agreed state:
  changed here goes up (file by file), changed there comes down (validated,
  and the replaced notebook kept), changed in both keeps both. Open notebooks
  are never replaced (`DocumentStore.beginEditing`). Removals only ever move
  things to a trash. Descriptions are reconciled newest-wins on
  `metadataRevisedAt`. This device's own files (search index, recovery
  copies) never travel.
- Storage: the local store is unchanged and stays the source of truth.
- Privacy: notebooks go to the user's own iCloud, which needs no privacy-label
  entry (data not collected by the developer).
- Switch: `CMCloudSync` in Info.plist, true from 1.5 (81). The container
  `iCloud.com.classmate.notes` exists on the App ID and
  `CODE_SIGN_ENTITLEMENTS = Config/ClassNotes.entitlements` is set for
  Release. Setting the flag to false turns it off again.
- Tests: `CloudSyncTests` (two devices, 13 scenarios), `CloudSyncTortureTests`.

**CC-015: NOVA reads citations as the model writes them.**

- What: `NovaReply.citedPages` also reads 【p. 1】, [p. 4], "(see p. 3)" and
  a heading or bold line naming the page; `NovaReply.display` shows the
  model's lenticular brackets as ordinary ones.
- Privacy and format: unchanged.
- Tests: `NovaReplySourceTests`, measured live (`NovaLiveEvalTests`).

**CC-016: drag and drop into pages and the library.**

- What: a drop on a page is routed by the types it offers
  (`DropRouting`): a PDF becomes pages after that page, a photo, words, a
  link or any other file becomes an element centred where it was dropped
  (`NotebookEditorModel.drop`). A drop on the library makes notebooks.
  Files larger than 200 MB are refused (`DropLoader.maximumBytes`).
- Storage: the same elements, media and imports as the toolbar makes; no
  format change.
- Privacy: nothing leaves the device.
- Tests: `DragAndDropTests` (routing, reading real `NSItemProvider`s,
  placement, PDF order, 200 repeated drops).

**CC-017: reading never creates a notebook; stand-ins are set aside.**

- What: `DocumentStore.manifest(for:)` throws `noSuchNotebook` when a
  notebook has no package, and derived files (`saveSearchIndex`, `writeInfo`)
  never make one. Launch reconciliation moves a stand-in an older build wrote
  (`isStandIn`: manifest v6, one blank page made a minute or more after the
  notebook, nothing else in the package) into `Set Aside/` and keeps the
  notebook remote-only. Remote-only rows are left out of the launch push
  (`fullSnapshot`) and iCloud (`rowIDs`). "Edit on this iPad"
  (`NotebookRepository.adoptRemote`) makes a real package from the server's
  page pictures, voice notes, files and links.
- Why: R-28.
- Storage: new folder `Notebooks/Set Aside/<uuid>-<stamp>.cmnote`, never
  deleted and invisible to the library and to iCloud. No manifest change.
- Rollback: an older build ignores `Set Aside/`. Up to 1.5 (84) it would
  write a new stand-in for the same notebook, which 1.5 (85) sets aside
  again.
- Privacy: nothing new leaves the device.
- Tests: `RemoteNotebookTests`, including the stand-in read off the owner's
  iPad.
