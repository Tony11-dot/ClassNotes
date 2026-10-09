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

## Open-decision register

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

**D-002: Reference hardware for the performance gates.**

- Recommended: low end is iPad (A16) with Apple Pencil (USB-C); high end is
  iPad Pro (M5) with Apple Pencil Pro.
- Impact if unresolved: no §52 number can be claimed as passed.

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

**D-004: Telemetry.**

- Options:
  - (a) MetricKit only: on device, no third party; daily hang, crash, launch
    and memory payloads.
  - (b) A third-party SDK such as Sentry.
- Recommended: **(a)** first. It needs no new dependency and no privacy-label
  change if payloads stay on device or go to our own API without note content.
- Impact if unresolved: the crash-free rate (A3) cannot be measured.

**D-005: Free-tier limits.**

- `freeNotebookLimit` is nil (uncapped). The mandate requires that no core note
  taking becomes inaccessible when a subscription lapses.
- Recommended: any cap limits *creating* notebooks, never *opening* them. That
  is already how it is wired.

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

**D-007: Folders and tags.**

- Today: flat shelves plus favourites.
- Recommended: nested shelves with a single parent, plus tags as a SwiftData
  relation. Drag a notebook onto a shelf.

**D-008: Lasso rotate and recolour.**

- Needs a selection-transform model (rotation per element, recolouring of
  `PKInk`).
- Recommended: recolour first. It is cheap and is the most requested.

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
| R-12 | No telemetry: regressions in the field are invisible | high | med | D-004 | open |
| R-13 | Rasterised PDFs: no text search, blurry at high zoom | high | med | D-006 | open |
| R-14 | Purged page resurrected from the manifest backup after damage | low | med | Purge removes the page from the backup too (found by the torture test) | fixed (tested) |
| R-15 | Delete rolled back by recovery leaves the page blank, and saves go to the trash | low | high | Live pages are reconciled against the trash on every manifest load (found by the torture test) | fixed (tested) |
| R-16 | Deferred `info.json` write reads a purged SwiftData row and traps | med | high | Snapshot synchronously, defer only the write (found by the full suite) | fixed (tested) |
| R-17 | Orphan adoption re-sorted the whole notebook by creation date, undoing page moves | low | med | Adopted pages are appended; existing order kept | fixed (tested) |
| R-18 | Note content sent to a third-party AI without the user's permission (App Store Review Guideline 5.1.2(i)) | high | high | One consent gate in `NovaConversation` in front of every request; asked once per account; withdrawn in Settings (CC-009) | fixed (tested) |
| R-19 | NOVA's own style prompt sent as `pageContext`, which the server labels "the page the student is looking at" | high | low | The identity prompt is excluded from page context | fixed (tested) |
| R-20 | A question or page context over 6,000 characters is refused by the server (400), shown as "NOVA couldn't respond" | med | low | Both are cut to fit, measured in UTF-16 as the server's validator measures | fixed (tested) |
| R-21 | The published privacy policy names Anthropic for NOVA and does not mention ClassNotes; NOVA in ClassNotes runs on Groq | high | med | Policy text must be updated by the owner (outside this repository) | **open (owner)** |

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

- **Current document schema:** manifest v8. `info.json` v1 and
  `trash.json` v1 are added this round as sibling files, so the manifest
  version does not change.
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
