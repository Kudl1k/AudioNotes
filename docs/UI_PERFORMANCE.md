# M11 — UI stability and native macOS polish

Status: measured hardening pass implemented; milestone acceptance remains open.
No new providers, source formats, dependencies, or subsequent milestone work were added.
The existing working-tree changes from M1–M10 were preserved.

## Validation

Validation on October 1, 2026 used Apple Silicon, 16 GB RAM, macOS 27.0 and Xcode 27.
The deployment target remains macOS 15+. The original full suite passed **300 tests
in 55 suites**. The expanded full suite passes **319 tests in 58 suites**.
Debug/native tests, Release, and the x86_64 Debug macOS build succeeded.
No new Swift or concurrency warnings were reported. Xcode's existing
“Metadata extraction skipped, no AppIntents.framework dependency found” warning
remains; it does not indicate an application compiler failure.

The tests exercise business logic, persistence and native services. They are not a
replacement for desktop UI tests or Instruments scrolling/interaction acceptance.
Opt-in live AI tests remain opt-in; these runs do not make metered provider calls,
download models, or certify Local Whisper/Ollama under load.

Reproduce:

```sh
xcodebuild -project AudioNotes.xcodeproj -scheme AudioNotes \
  -destination 'platform=macOS' -derivedDataPath /tmp/AudioNotes-M11-baseline test

xcodebuild -project AudioNotes.xcodeproj -scheme AudioNotes \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/AudioNotes-M11-release build

xcodebuild -project AudioNotes.xcodeproj -scheme AudioNotes \
  -destination 'platform=macOS,arch=x86_64' \
  -derivedDataPath /tmp/AudioNotes-M11-intel build
```

Use `-only-testing:AudioNotesTests/PerformanceBaselineTests` or
`-only-testing:AudioNotesTests/NativePerformanceFixtureTests` for component
measurements. Tests check data correctness without exact timing thresholds.

## Fixtures

| Fixture | Duration metadata | Transcript segments | Chat messages | PDF pages | Images | Historical summaries |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Small | 5 minutes | 50 | 3 | 0 | 0 | 0 |
| Medium | 60 minutes | 800 | 30 | 30 | 0 | 0 |
| Large | 3 hours | 2,400 | 120 | 100 | 4 | 8 |
| Stress | 6 hours | 6,000 | 260 | 100 | 104 | 8 |

IDs, timestamps, text, source locations and message ordering are deterministic.
Transcript arrays deliberately start in reverse order. The stress workspace has
105 additional sources and 6,308 derived context chunks. Each fixture also has a
current summary. The native development library adds 500 lightweight recordings
for a total of 504. Images are generated 4,096 × 3,072 PNGs with small thumbnails;
PDFs are generated locally with Core Graphics/Core Text.

These are synthetic transcripts and pre-extracted source context. The fixtures do
not include six hours of physical audio or measure actual OCR/Whisper accuracy.
PDF generation and pre-extracted units are independent fixture data; use real files
for extraction, OCR, citation-content and playback acceptance.

For the isolated DEBUG fixture window:

```sh
open -n /tmp/AudioNotes-M11-baseline/Build/Products/Debug/AudioNotes.app \
  --args --performance-fixtures --performance-recording stress --performance-tab chat
```

Recording options: `small`, `medium`, `large`, `stress`. Tab options: `transcript`,
`summary`, `sources`, `chat`. `--performance-empty-library` opens a fresh empty
fixture window. Both flags use an in-memory database and the temporary
`AudioNotes-M11-Fixtures` managed-file root. They never seed the production library.
A DEBUG-only native window delegate avoids depending on saved production scene
identifiers. Fixture preparation has its own progress state; its synthetic database
construction/file generation is not a production-launch benchmark. The fixture
window's providers are mocks. DEBUG flags and fixture code are absent from Release.

## Measured findings

The tables contain observed Debug wall-clock results, not statistical guarantees.
Selected-suite runs reduce unrelated test work; OS scheduling, cold caches and
other processes still affect measurements. Full-suite image timings were much
higher under concurrent work, so native component timings below use the selected
native suite. No scrolling FPS, launch-to-interactive improvement, or leak-free
claim follows from these numbers.

### Context eligibility

**Problem:** chat `canSend`, ready-source checks and summary eligibility constructed
`RecordingContextSnapshot` synchronously. Typing and view updates could therefore
sort all transcript segments, construct intermediate transcript chunks, split text,
decode locators and hash stable IDs repeatedly.

**Root cause:** a UI eligibility question used the full retrieval preparation path.

**Change:** `RecordingContextAvailability` short-circuits on actual usable content,
respects source selection and preserves text-free ready image anchors. Ready-source
metadata can also be computed without deriving chunks. Full preparation copies
SwiftData values on their owning actor and derives chunks from Sendable input on a
worker. Discarded zero-overlap intermediate `TranscriptChunk` objects are no longer
constructed. Ordering, stable chunk IDs, source locators and original timestamps
remain equivalent.

| Fixture | Original: ten context-based eligibility checks | After: ten availability checks |
| --- | ---: | ---: |
| Small | 20.60 ms | 0.076 ms |
| Medium | 80.62 ms | 0.047 ms |
| Large | 238.09 ms | 0.066 ms |
| Stress | 623.64 ms | 0.462 ms |

Full context is still built for a generation. In the final selected-suite stress
run, copying immutable input took **15.47 ms** on the main actor, and pure derivation
took **20.19 ms**. The benchmark measures the pure routine synchronously; the
production async preparation runs that routine on a detached worker. Ten full
optimized context constructions took **331.74 ms**, compared with the original
623.64 ms. Moving derivation does not make copying SwiftData values free.

### Historical chat cleanup

**Problem/evidence:** cleaning 100 ordinary historical messages in a 6,000-segment
recording took **286.64 ms** in the selected-suite before run.

**Root cause:** each row copied all transcript IDs and constructed a Set even when
there were no UUIDs in its prose.

**Change:** authoritative ID input is a synchronous lazy argument. The normalizer
finds UUID candidates before evaluating it. Empty reference arrays also bypass
reference validation; row ID extraction no longer sorts transcript snapshots.

**Result:** the same 100 cleanups took **6.81 ms** in the selected-suite after run.
Existing marker cleanup remains non-destructive: ordinary brackets and unrelated
UUIDs are preserved. New tests verify lazy evaluation and authority filtering.

### Native component checks

| Operation | Observed result | Interpretation |
| --- | ---: | --- |
| Open generated 100-page PDF and read last-page text | 8.79 ms | Native PDFKit component remains usable; not a visual scrolling benchmark |
| Downsample 12 MP PNG to ≤220 px, cold | 69.78 ms | Work belongs off the UI actor |
| Same thumbnail cache hit | 0.122 ms | Returns the same decoded CGImage |
| Fetch metadata for 501 persisted recordings | 7.00 ms | Fixture metadata fetch was not a bottleneck |
| Save 501 recordings including the entire stress graph | 360.30 ms | Large graph commit is an unresolved main-actor concern |
| 100 block parses of the representative chat Markdown | about 6.5 ms | Small block parsing itself was already inexpensive |

Original source processing already wrote small thumbnails. This change moves
thumbnail file reads/decoding out of row rendering and caches them; the 12 MP test
checks downsampling robustness rather than claiming the old row decoded originals.
The library shares one cache across its source models. `NSCache` is configured with
128 entries and a 32 MB decoded-byte cost limit; these are eviction hints, not a
hard process-memory cap. Keys include URL, requested size, file size and precise
modification time. Image preview decoding is also asynchronous and capped at
2,400 px; its resources follow the sheet lifetime.

### Instruments and memory

A forced native DEBUG fixture window loaded the generated library/stress workspace.
A ten-second Time Profiler attachment observed 53 running main-thread samples at
1 ms sampling weight, approximately 53 ms of sampled main-thread CPU. Including
sampled worker/event-thread activity gave approximately 64 ms total. AppKit layout
and event handling appeared in those samples. A later `ps` sample reported 0.0%
CPU and approximately 213 MiB RSS. Instrumentation affects resident memory, and
RSS is not the same as retained heap or physical footprint.

This is one warm-idle observation, not a before/after idle improvement or a repeated
navigation leak test. It does not establish scroll hitches, transient peak memory,
Whisper memory release, or a stable long-term heap plateau. The initial App Launch
attempt resolved another registered build, and a direct clean-environment launch
capture did not establish a rendered/interactive fixture window. Those attempts are
not treated as production launch measurements.

Accessibility automation and screen capture checks returned unavailable in this
session. No visual Light/Dark, VoiceOver, focus, resizing or scrolling acceptance is
claimed. Original raw captures/TOC exports containing inherited environment metadata
were removed. A restarted capture used a cleared environment; its exported
metadata contained no secret-like environment keys. Keep future captures similarly
isolated, and do not export private process environments or recording contents.

Static-name signposts cover audio playback loading, source-context derivation,
Markdown block parsing and export render/write. They contain no source text,
filenames, IDs, API keys or account tokens.

## Main-thread, rendering, persistence and concurrency audit

| Area | Finding and action | Remaining limit |
| --- | --- | --- |
| Eligibility | Full context generation removed from chat/summary validation | Malformed/empty legacy data can require a longer availability scan |
| Context preparation | Immutable value copy on owning actor; sorting/hashing/derivation off actor | Snapshot copy still scales with source size |
| Transcript | View no longer sorts/filters inside body; immutable stable rows, worker sorting/search, 150 ms debounce | Transcripts are treated as immutable versions; future same-ID editing needs an explicit revision |
| Source search | 180 ms debounce precedes snapshot creation; cancelled/superseded results cannot publish | A synchronous worker routine can finish its current bounded pass after cancellation |
| Markdown | Content-keyed async block parse; completed block view compares its document | Inline attributed-text rendering remains on the UI actor; parsing is not fully incremental |
| Streaming | Existing 80 ms batching and final response persistence retained | Giant accumulated responses and provider backpressure still need real UI profiling |
| Chat scrolling | Geometry changes from response growth do not revoke follow; user scroll pauses it; Jump to Latest resumes | Desktop scroll/trackpad acceptance remains open |
| Operation lifetime | Library retains chat/summary models as well as transcription/source models; navigation no longer cancels summary | Ownership is per library/window, not an app-wide registry |
| Duplicate work | Chat send/retry/suggested prompts and export destination/render starts are guarded below views | Cross-window/provider-wide guards remain to audit |
| Stale results | Search, transcript load, Markdown parse and export reject cancelled/superseded results | Real rapid navigation/focus sequences still need desktop acceptance |
| Export | Immediate typed state, shared content snapshot, off-actor render/write, atomic write, cancellation before commit and between PDF pages | Attributed-string construction/Markdown rendering and an already-started atomic write cannot be stopped midway |
| Export references | One authoritative recording-scoped index is shared across exported answers | Initial export snapshot still traverses the selected model graph on its actor |
| Images | Async loading, downsampling and shared revision-keyed cache | Total memory across windows and retained recording models is not proven bounded |
| SwiftData writes | Streaming/progress already remain primarily in memory; meaningful generation/request transitions persist | Stress graph commit took 360 ms; startup backfill and real database writes need profiling |
| Playback | Playback observations already live in PlaybackControls; polling only while playing | AVAudioPlayer initialization is still synchronous; real large files need profiling |
| Library | Stable UUID selection retained; last selection restored; render-time Reveal-in-Finder filesystem enumeration removed | Broad generation query/task-key construction and optional cost aggregation remain to profile |
| Recovery | Closed streams without completion now fail instead of staying busy; failed question persistence restores input | Live interruption/missing-file/low-disk recovery across all features remains open |

No blanket service actor annotations, concurrency suppressions, model schema
rewrites, transcript dropping, pricing rewrites or source-citation heuristics were
introduced. Existing M1–M10 persistence/reference/pricing/provider regressions pass.
Large graph writes and potential retention of visited recording models are recorded
as open issues rather than claiming all main-thread work or memory growth is fixed.

## UX audit

### Fixed

- Repeated send/retry cannot replace an active chat request or consume a new draft.
- A stream ending without a final response leaves the busy state and offers retry.
- A failed question save preserves the unsent text.
- Chat scrolling follows reader intent instead of forcing every streamed update down.
- Summary completion no longer switches the selected tab, and navigating away no
  longer cancels library-owned summary work.
- Export actions guard duplicate starts, show a real busy state, preserve existing
  files on early cancellation, and report recoverable failures.

### Improved

- Native Jump to Latest button, last recording selection restoration, stable scene
  identity, standard Sidebar commands and File → Import Audio… using ⌘O.
- Activity popover lists existing recording operations with stable IDs and lets the
  user return to their recording; cancellation remains in the feature controls.
- Composer drafts/source selection and summary configuration survive recording
  navigation through library-owned models.
- Readable transcript width, lazy stable transcript rows, debounced search and
  asynchronous image placeholders.
- Explicit accessible names for Send, Stop and Clear Chat; Escape stops visible chat
  generation. Decorative thumbnails do not create redundant accessibility elements.
- Existing code blocks retain horizontal scrolling, selectable monospaced text and
  Copy; PDF rendering now supplies its own graphics context for headers/footers.

### Already good

- Native NavigationSplitView/List/Inspector/PDFKit rather than web UI.
- UUID list identity, lazy transcript/chat history, and separated playback controls.
- Existing immediate chat waiting state, 80 ms token batching, cancellation tests,
  final-message persistence and preservation of existing summary/transcript versions.
- Native managed imports, actor-owned file hashing/extraction, local-only provider
  gating, structured reference authority and Decimal historical usage/pricing.
- Existing Settings sidebar organizes existing controls; no empty future tabs added.
- Small Markdown block parsing and the fixture metadata fetch did not justify a
  subsystem rewrite.

### Deferred

- Production launch/open and scrolling acceptance, repeated-navigation memory,
  SwiftData large commits/startup reconciliation, and live local-model contention.
- Multiwindow coordination, quit-with-active-work confirmation, last-tab restoration,
  undo where meaningful, and a complete standard menu/focus audit.
- Full Light/Dark, increased contrast, Reduce Motion, VoiceOver, localization-width,
  narrow/wide/fullscreen and keyboard interaction acceptance.
- Physical disk pressure, real slow/offline provider streams and all managed-file
  recovery interactions. Existing service regression coverage does not certify them.

## Added tests

Nineteen new test functions across three new suites and the existing ChatUXTests:

- Deterministic fixture shapes, performance observations and historical cleanup.
- Native 100-page PDF, 12 MP downsampling, cache identity and corrupt/missing images.
- 501-recording SwiftData save/re-fetch preserving 6,000 segments, 260 messages,
  105 sources and eight historical summaries.
- Scroll-follow policy, source availability/selection equivalence, sync/async context
  equivalence, authoritative-reference deduplication and forged-source rejection.
- Retained recording-owned models/drafts/configuration, transcript ordering/search,
  cancelled snapshots and superseded source searches.
- Background Markdown/PDF export, valid PDF footer/text, duplicate export prevention,
  cancellation preserving an existing file, and recoverable out-of-space failure.
- Very long Markdown/code preservation, lazy cleanup preserving unrelated UUIDs,
  persistence failure preserving an unsent question, duplicate chat actions and an
  abruptly closed stream.

## Files changed in this pass

Some existing files were already untracked/modified before M11. The list below
identifies this pass's changes, not authorship of all existing working-tree changes.

Created:

- `AudioNotes/Features/Chat/ChatScrollState.swift`
- `AudioNotes/Features/Export/ExportViewModel.swift`
- `AudioNotes/Features/RecordingDetail/TranscriptViewModel.swift`
- `AudioNotes/Features/Sources/SourceThumbnailView.swift`
- `AudioNotes/Services/Export/ExportService.swift`
- `AudioNotes/Services/Logging/PerformanceSignposts.swift`
- `AudioNotes/Services/Sources/RecordingContextAvailability.swift`
- `AudioNotes/Services/Sources/SourceImageLoader.swift`
- `AudioNotes/Utilities/Development/PerformanceFixtures.swift`
- `AudioNotes/Utilities/Development/PerformanceFixtureLibrary.swift`
- `AudioNotes/Utilities/Development/PerformanceFixtureApplicationDelegate.swift`
- `AudioNotesTests/M11StabilityTests.swift`
- `AudioNotesTests/PerformanceBaselineTests.swift`
- `docs/UI_PERFORMANCE.md`

Modified:

- `AGENTS.md`, `README.md`, `docs/ROADMAP.md`
- `AudioNotes/App/AudioNotesApp.swift`
- `AudioNotes/Features/Chat/AssistantMessageView.swift`, `ChatInspectorView.swift`, `ChatViewModel.swift`
- `AudioNotes/Features/Export/ExportSheetView.swift`
- `AudioNotes/Features/Library/LibraryView.swift`, `LibraryViewModel.swift`
- `AudioNotes/Features/RecordingDetail/RecordingDetailView.swift`, `SummaryViewModel.swift`, `TranscriptView.swift`
- `AudioNotes/Features/Sources/SourcePreviewView.swift`, `SourcesView.swift`, `SourcesViewModel.swift`
- `AudioNotes/Services/AudioPlaybackService.swift`
- `AudioNotes/Services/Export/ExportContentBuilder.swift`, `PDFExporter.swift`
- `AudioNotes/Services/LLM/Chat/ChatContentNormalizer.swift`
- `AudioNotes/Services/Sources/RecordingContextRetriever.swift`, `SourceContextPreparation.swift`
- `AudioNotes/Utilities/AppStorageLocations.swift`, `MarkdownDocument.swift`
- `AudioNotesTests/ChatUXTests.swift`

## Remaining acceptance checklist

M11 remains active until these are checked with representative production data:

- [ ] Production app launch and startup reconciliation; interrupted work is actionable.
- [ ] Opening real large recordings and 500+ recording library interaction.
- [ ] Transcript scrolling, citation navigation, searching and playback together.
- [ ] Long chat history and huge partial/final Markdown/code block scrolling.
- [ ] Manual upward scrolling, Jump to Latest, composer focus/drafts and source selection.
- [ ] Immediate feedback, duplicate prevention and cancellation for every primary workflow.
- [ ] Rapid A/B recording navigation and background-job return/completion behavior.
- [ ] Large summary/history, 100+ page PDF and 100+ source workspace interactions.
- [ ] Repeated navigation with Allocations/Leaks and a stable retained-memory plateau.
- [ ] Production SwiftData fetch/write traces and large-graph commit mitigation if warranted.
- [ ] Real audio initialization/conversion and Local Whisper/Ollama concurrency under load.
- [ ] Network-disconnected local workflows and slow/disconnected cloud/Ollama streams.
- [ ] Missing/corrupt managed sources, thumbnails and provider responses in desktop flows.
- [ ] Low disk for import, conversion, model download and export with safe rollback.
- [ ] Light/Dark, contrast, Reduce Motion/transparency, VoiceOver and larger text.
- [ ] Narrow, normal, wide/fullscreen and longer Czech labels.
- [ ] Keyboard/focus/menu commands, native import/export panels and relaunch restoration.
- [ ] Multiwindow ownership/duplicate execution and native quit-with-active-work behavior.
- [ ] Existing M1–M10 live/native and archived-production migration acceptance.

No future milestone has been started.
