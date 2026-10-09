# Measurements

Measured, not assumed. Every number here comes from a test you can run again.
Anything that could not be measured is listed as **unmeasured**, with the
reason.

Last updated: 2026-10-09.

## How these were taken

- **Source.** `PerformanceBenchmarkTests` and `NeverLoseNotesTortureTests`
  (Packages/NotesKit). Each benchmark prints a `BENCH` line.
- **Run command.**
  `xcodebuild test -scheme NotesKit-Package -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' -only-testing:NotesKitTests/PerformanceBenchmarkTests`
- **Host.** Apple M4 Mac, 24 GB, macOS 27.2, Xcode 27.0 (27A266a), iPad Pro
  11-inch (M5) simulator.
- **Build.** Debug (unoptimised), as the test bundle builds. A Release build is
  faster for Swift-heavy paths such as search and decoding; that difference has
  not been measured.
- **Runs.** The suite was run on its own, six times. Ranges are across those
  runs; each run's value is itself a median of 3 to 7 repetitions. Running the
  benchmarks alongside the whole suite inflates them by up to 3×; those numbers
  are not used here.
- **What a simulator can and can't tell you.** It measures the app's own CPU
  and I/O cost. It does **not** measure the Pencil, the display, thermal
  limits, an older iPad's flash storage, or iOS's memory pressure. Treat these
  as relative numbers (before and after, or this path against that one), not
  device latencies.

## 1. Data safety

| Check | Result |
|---|---|
| Randomised crash and damage torture test | **3,000 steps** (4 seeds × 750). Every invariant is checked after every step. 0 violations after the fixes; ~4–7 s per run |
| Operations mixed in | write, out-of-order (stale) write, stage without writing, finish a staged write, insert, delete, late save to a deleted page, restore, move, duplicate, element edit, purge |
| Failures injected | process crash (fresh store, staged ink lost), write cut off between backup and new manifest, manifest damaged (garbage, truncated, missing), with and without a crash |
| Invariants | ink that reached disk is on its live page or in Recently Deleted, byte for byte; a live page shows its newest staged or written ink; no duplicate pages; no phantom pages; purged pages never return; Recently Deleted lists exactly the deleted pages; page order and elements are exact unless damage forced the one-step rollback the backup represents |
| Bugs it found | 2, both fixed with targeted regression tests (README, "Phase 1 outcome") |
| Unit and regression tests | 735 tests in 136 suites (NotesKit) + 21 (ClassMateTheme), all passing (round 5) |

## 2. Storage

| Benchmark | Result (range across runs) | Notes |
|---|---|---|
| Load the manifest of a 1,000-page notebook (cold store) | **26–38 ms** | 1,237 KB of JSON, 2 text elements per page |
| One element edit in that notebook | **51–74 ms** | Full manifest rewrite plus the backup rename. Off the main thread (on the document actor) |
| Encode a 10,000-stroke page | **22–39 ms** | 3,222 KB. Runs detached, off the main thread |
| Save that page (atomic write) | **1.2–1.5 ms** | |
| Read that page | **0.4–0.7 ms** | |
| Decode that page (`PKDrawing(data:)`) | **24–57 ms** | |
| Thumbnail that page (360 px wide) | **116–160 ms** (one outlier at 313 ms) | Off the main thread, cached by content fingerprint; an unchanged page costs nothing the second time |

## 2b. Main-thread work around each stroke

What the canvas does on the main thread when the pencil touches down and
when a stroke ends. This is not latency; it's how much of the frame the app
spends before PencilKit gets it back. `PerformanceBenchmarkTests.strokeBookkeeping`.

| Read | 1,000 strokes | 10,000 strokes |
|---|---|---|
| `canvas.drawing` (a full copy out of PencilKit) | 0.24 ms | 2.6 ms |
| `canvas.drawing.strokes.count` | 0.42–0.51 ms | 4.4–4.8 ms |

| Moment | Before | After |
|---|---|---|
| Pencil-down | one stroke count: ~0.45 ms / ~4.4 ms | **none**: the page as it stood is already held, and counted only if a shape settles |
| Stroke end | two full reads: ~0.7 ms / ~7 ms | one read plus a count: ~0.45 ms / ~4.4 ms |

A suspected cost was ruled out by measurement. The editor writes the focused
page on every stroke, but in this toolchain Observation does not notify
observers when an equal value is written, so it doesn't re-render the 18
views that read it.

## 3. Search

The library search runs off the main thread, 220 ms after typing stops.

| Benchmark (100 notebooks × 10 pages = 1,000 pages) | Before | After |
|---|---|---|
| Rare term (`krebs cycle`, 1 notebook matches) | 36–50 ms | **7.7–10.9 ms** |
| Common term (on most pages) | 87–110 ms | **7.4–15.4 ms** |
| First search after launch (every index read from disk) | not measured | **19–34 ms** |

At ten times that size (round 3; the target is 300 ms for 1,000 pages):

| Benchmark (1,000 notebooks × 10 pages = 10,000 pages) | Result (3 standalone runs) |
|---|---|
| Rare term | **67–111 ms** |
| Common term | **87–105 ms** |
| First search after launch | **187–481 ms** |

Where the time goes at 10,000 pages (Debug build, one probe run, 3 rounds):
calling into the document store once per notebook 15–19 ms, checking each
index file's size and date 14–24 ms, the matching itself 21–23 ms. Batching
the store calls would save the first of those; at a third of the target with
ten times the pages, it isn't worth the code yet.

Where the time went, profiled in an optimised standalone build with the same
search code over 1,000 pages:

| Step | Cost |
|---|---|
| Folding (case and diacritics) | 2 ms. Not the bottleneck, contrary to the first hypothesis |
| `String.contains`, per term | 36 ms. Character-by-character with grapheme breaking. **Replaced by `memmem` over UTF-8: 0.9 ms** |
| Counting occurrences | 12 ms → **0.6 ms** with the same change |
| Building a snippet for every hit | 25 ms for a common term. **Now built only when a row is shown** (a result shows 4 hits) |

Decoded, folded indexes are kept in memory between keystrokes, keyed by each
file's size and modification time. The tests check that a replaced or deleted
file is read fresh.

Imported pages are now read by Vision too (round 2). That cost is paid once per
page, in the background indexer; searching doesn't pay it. On-device time per
page is unmeasured.

## 4. Import

| Benchmark (100-page PDF) | Result |
|---|---|
| Total import time | **485–728 ms** (4.9–7.3 ms per page) |
| Memory growth during import, sampled between pages | **0.3–0.5 MB** above baseline. Each page is rendered and written inside its own autorelease pool, so peak memory inside a single page's render is not captured by this sampling |
| Ink saves made **while** the import runs | p50 **0.46–0.62 ms**, p95 **0.59–1.44 ms**, max **0.83–4.59 ms** (61–104 saves per run) |
| Cancelling part-way | No pages are added and every page image already written is removed (tested) |

Before this round, the import ran inside the document actor. By construction,
every ink save waited for the whole import to finish. That "before" figure was
not measured separately.

## 5. NOVA evaluation set (round 4)

Thirty questions over three notebooks written the way recognised
handwriting reads (`NovaEvalSet`): 25 that the notes answer (18 sharing
words with the page, 4 naming the page, 3 paraphrased) and 5 they don't.

**Retrieval** (`NovaRetrievalEvalTests`, every test run; the same with 40
unrelated pages added to each notebook):

| Style | Questions | Right page first | Every answering page found | Every answering page sent |
|---|---|---|---|---|
| Shares words with the page | 18 | 100% | 100% | 100% |
| Names the page | 4 | 100% | 100% | 100% |
| Paraphrased | 3 | 67% | 100% | 100% |
| **All** | **25** | **96%** | **100%** | **100%** |

**The live model** (`NovaLiveEvalTests`, `CLASSNOTES_LIVE_EVAL=1`, through
the production endpoint under a throwaway account, 2026-10-09):

| | Before the citation fix | After |
|---|---|---|
| Answerable, cites a right page | 19 / 25 | **23 / 25** |
| Answerable, answered without a citation | 5 / 25 | 1 / 25 |
| Answerable, called general knowledge | 1 / 25 | 1 / 25 |
| Not in the notes, says so | 5 / 5 | **5 / 5** |
| Citations to a page that doesn't exist | 0 | **0** |

The five uncited answers had cited, in forms the app didn't read
(【p. 1】, 【Page 3】, "(see p. 3)", a "### Page 1" heading). The one left
cites with a bold "**Page 1 – …**" line, now read too. The one answer called
general knowledge was the balloon question: "rubbing" is on the static page,
but the model judged the page didn't cover balloons.

Run at 8 seconds between questions: at 3.5 seconds the endpoint's 20-a-minute
limit and the provider's own limit refused two thirds of them.

## 6. iCloud sync (round 4, two simulated devices)

`CloudSyncTortureTests`, three seeds, 220 random steps each (writes, new
notebooks, editors opening and closing, syncs in any order):

| Seed | Notebooks at the end | Kept-both copies | Writes that had to survive | Survived on both |
|---|---|---|---|---|
| 11 | 32 | 14 | 32 | 32 |
| 12 | 31 | 6 | 31 | 31 |
| 13 | 44 | 11 | 44 | 44 |

The two libraries converged in every run. iCloud itself carrying the files
is not measured here; that needs two real iPads (the container exists from 1.5 (81)).

## 7. Storage torture with PDF imports (round 4)

The 750-step crash and damage torture test now imports PDFs (33 imports
across the four seeds) and checks after every step that a page's PDF exists
while any live or deleted page uses it. All four seeds pass.

## 8. Round 5: drag and drop, long session, multitasking

Same host and build as above.

**Drag and drop (§78)** — `DragAndDropTests`: 200 drops in a row (photos
and text alternating) onto one page, 200 of 200 landed. Routing is checked
for PDF, four image formats, links, text, Office files and zips; reading is
checked through real `NSItemProvider`s.

**Long session (§44)** — `LongSessionTests`: six lectures over three
notebooks in one process. Each lecture writes three pages (15 saves each,
growing), drops a photo and a typed note on each, annotates a 4-page handout
every other lecture, switches tools, visits every page, moves one, deletes and
restores one, and searches. Then a fresh store reads everything back.

| Measure | Value |
|---|---|
| Pages written and checked after the relaunch | 21 of 21, byte-identical, all decode |
| Typed notes and photos still on their pages | all |
| Files quarantined as unreadable | 0 |
| Search finds that lecture's note | 6 of 6 |
| Mean of lectures 1–2 / 5–6 | 2.78 s / 2.01 s (no slowdown) |
| Footprint growth, after lecture 2 → after lecture 6 | +15.0 MB (from 101 MB) |

**Multitasking (§79)** — `MultitaskingCycleTests`: 1,000 cycles of writing,
the debounced save and the background flush landing in either order, the
process killed in the background about one cycle in ten (107 kills), the
window resized to a random width from 320 to 2,560 points at a random zoom.

| Measure | Value |
|---|---|
| Data-loss events | 0 of 1,000 |
| Page sizes that weren't a real page, or changed shape | 0 |
| The page's own space after the run | unchanged |

What a resize looks like on screen (no layout corruption, 300 ms to settle,
§80) needs a device; it is listed below.

## 9. Unmeasured: needs a hand on the device

| Metric | Why it's unmeasured | How to measure it |
|---|---|---|
| Pencil-to-pixel latency | Belongs to PencilKit and the display; the simulator has no Pencil | Instruments on a device; or a high-speed camera |
| Frame rate while writing, scrolling and zooming | Needs someone writing | Instruments → Animation Hitches |
| Launch to interactive | Ready to run: a devlab copy and a 1,260-page library are on the iPad Air (M4); waits for the iPad to be unlocked | Instruments → App Launch |
| Device memory ceiling on large notebooks | Same | Instruments → Activity Monitor, with the 300-page notebook |
| Battery during a 1-hour session | Device only | Xcode Energy Log |
| Layout after rotation and window resize (§80) | Needs a device and a hand moving the window | Instruments → Animation Hitches during rotation; screen recording |
| Crash-free rate | Needs time in the field | Support → Diagnostics on each device (D-004), App Store Connect → Crashes |

Signposts are in place for these. They log under subsystem `app.classnotes`,
category Points of Interest:

- Intervals: `Notebook open`, `Manifest load`, `Page load`, `Page decode`,
  `Page read`, `Page encode`, `Page save`, `Page thumbnail`, `Search`,
  `PDF import`, `Page sync`.
- Events: `Manifest recovered`, `Library recovered notebooks`.

Record with Instruments' Points of Interest track on a device.
