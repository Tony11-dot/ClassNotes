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
| Unit and regression tests | 592 tests in 104 suites (NotesKit) + 21 (ClassMateTheme), all passing |

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

## 3. Search

The library search runs off the main thread, 220 ms after typing stops.

| Benchmark (100 notebooks × 10 pages = 1,000 pages) | Before | After |
|---|---|---|
| Rare term (`krebs cycle`, 1 notebook matches) | 36–50 ms | **7.7–10.9 ms** |
| Common term (on most pages) | 87–110 ms | **7.4–15.4 ms** |
| First search after launch (every index read from disk) | not measured | **19–34 ms** |

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

## 5. Unmeasured: needs a physical iPad and Instruments

| Metric | Why it's unmeasured | How to measure it |
|---|---|---|
| Pencil-to-pixel latency | Belongs to PencilKit and the display; the simulator has no Pencil | Instruments on a device; or a high-speed camera |
| Frame rate while writing, scrolling and zooming | The simulator's GPU path is not the device's | Instruments → Animation Hitches |
| Launch to interactive | Depends on device storage and the dyld cache | Instruments → App Launch, or the `Notebook open` signpost |
| Device memory ceiling on large notebooks | iOS memory limits are per device | Xcode memory gauge, or Instruments → Allocations, with a 500-page notebook |
| Battery during a 1-hour session | Device only | Xcode Energy Log |
| Crash-free rate | No telemetry (D-004) | App Store Connect → Crashes, until D-004 is decided |

Signposts are in place for these. They log under subsystem `app.classnotes`,
category Points of Interest:

- Intervals: `Notebook open`, `Manifest load`, `Page load`, `Page decode`,
  `Page read`, `Page encode`, `Page save`, `Page thumbnail`, `Search`,
  `PDF import`, `Page sync`.
- Events: `Manifest recovered`, `Library recovered notebooks`.

Record with Instruments' Points of Interest track on a device.
