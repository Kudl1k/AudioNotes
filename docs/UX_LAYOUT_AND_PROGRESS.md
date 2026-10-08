# M14.3 — Layout density and progress

## Audit before changes (2026-10-02)

Baseline: M14.2 is the separate commit `908e157`; its 414 offline tests and
Release build passed. This pass does not amend earlier commits.

Native inspection uses the DEBUG in-memory Project Chat fixture, synthetic
content, mock providers and a separate temporary file root. Before images live
in `review/M14.3/`. The following includes source inspection; it does not imply
that all desktop/accessibility acceptance has been completed.

| Screen | Structural finding | Planned treatment |
| --- | --- | --- |
| Project workspace / empty | Outer VStack has no expanding content region, so the entire header/empty state can center. Segmented Picker exposes a multiline label with zero usable width; native AX measured that label at 224 points high in the populated Chat workspace. | Natural-height header, visually hidden picker label, explicitly expanding content region. |
| Project Overview / Recordings / Sources | List already expands and rows are appropriately dense; shared header consumes too much height. Search is unrelated to Chat and compresses the segments at narrow widths. | Retain native lists; compact shared header; fit navigation/search horizontally or stack the controls when necessary. |
| Project Chat | Message list and composer are already shared M14.2 components. Excessive parent header consumes their viewport. | Fix parent; retain chat architecture and domain controls. |
| Recording Detail | Large title, 24-point header padding plus extra playback top padding; TabView adds 16-point insets to children that add their own insets. | Compact identity/playback group and remove duplicate horizontal content padding. |
| Transcript | Search/rows have different leading insets; fixed 860-point row width constrains a timeline that benefits from width. | Align search and rows; preserve lazy renderer, timestamp navigation and off-actor search. |
| Summary / generator | Generator is a top-aligned ScrollView, not a centering bug. Its introductory icon and widely spaced prose consume height before settings. | Compact introductory group; retain bounded settings/prose and existing summary sections. |
| Recording Chat | Header/composer are already compact; narrow inspector makes provider information wrap. | Retain shared rows/composer and their insets; align elapsed presentation only. |
| Library / All Recordings | Native sidebar is dense; bottom status means library count/cost/import, not a global task engine. Empty library has same intrinsic-height-stack risk. | Keep sidebar; expand list/empty content and use workspace header spacing. |
| Generation details / usage / history | Bounded sheets, native lists and scroll views; Spacers separate actions horizontally. | Keep; align operation-duration formatting in secondary metrics. |
| Settings / providers / model screens | Native sidebar/grouped forms; fixed sidebar and top inset previously address titlebar behavior. | Preserve Settings structure; unify only model-download progress. Do not remove titlebar compensation without evidence. |

No GeometryReader is responsible for these workspace gaps. Horizontal Spacers
in toolbars/action rows are intentional. No new cards, palette or typography system
are required. Workspace actions already have suitable toolbar placement.

## Progress inventory before changes

| Existing operation | Available facts / ownership | Presentation gap |
| --- | --- | --- |
| Audio preparation/splitting/transcription/merge/save | Library-owned RecordingViewModel; phases, completed audio, real part counts; measured EMA throughput/ETA | Separate progress/time layout; synthetic 10–90% phase weighting and 95% saving do not describe completed audio. |
| Recording/project chat including project retrieval | Separate library-owned models; actual phase, streamed prose, Stop and retry | Both elapsed tasks count ticks (`+= 1`) and invalidate parent observation once a second. |
| Single/hierarchical summary | Library-owned SummaryViewModel; phase strings, cancellation and existing cost estimate/history | Duplicated spinners, no visible elapsed time. No defensible fraction/ETA exposed. |
| Source extraction / OCR / attachment transcription | Library-owned SourcesViewModel; source phase/unit counts/start dates; Cancel/Retry | Elapsed seconds suffix, separate spinner; attachment provider status is currently discarded. |
| Project import | Serial library-owned ProjectImportQueue; item states, unit counts, start dates, Cancel Remaining | Relative-date elapsed and distinct progress bars; summary already reports added items. |
| Whisper model download | Settings model / managed store; real byte counts, cancellation, error | Distinct progress layout, no elapsed; no measured ETA/speed. |
| Local model preparation | Part of existing transcription/provider phase | Remains indeterminate unless service exposes completed work. |
| Indexing/search | Disposable retrieval actor, invoked as part of project chat; local transcript/source search loading | Use actual chat preparation/search state; no standalone indexing workflow or percentage. |

Project generation and production embedding generation do not exist. No such UI
is introduced. Existing Decimal cost/usage snapshots and privacy gates stay below
presentation. Cancellation must keep calling the existing underlying operations.

## Layout implementation

`WorkspaceSpacing` names the existing compact scale: 4 points for related labels,
8 for controls, 12 for sections, 16 for workspace edges. It is deliberately not a
new application design system. Native typography, colors, controls and existing
summary/chat containers remain.

Project identity now uses a natural-height title/metadata group. Description is
bounded to two lines with the complete text available through selection/help.
The content region, rather than the header, consumes remaining height. The empty
state stays centered **inside that region**; project identity/navigation no longer
move to the center of the window. The segmented control hides its visual label
but retains its accessible name. `ViewThatFits` places title/filename filtering
beside navigation when possible and below it when narrow. Chat omits this filter
because it never searched chat messages. Overview/Recordings/Sources retain the
existing native lists, row actions, source authority and navigation.

At the normal 1100 × 834 window size, native accessibility inspection measured
the baseline empty-project title at screen y=386 versus y=164 after the change
(same window origin). The initial populated Project Chat message viewport was
about 304 points tall; the corrected parent allows roughly 514–525 points,
depending on the existing coverage warning. These are fixture/window observations,
not performance benchmarks or invariant pixel requirements.

Recording Detail uses a smaller native title and 16-point header padding, removes
the extra playback top inset and duplicate horizontal TabView padding. Transcript
search/rows share the 16-point edge; timeline rows can use available width while
the existing lazy renderer/search/timestamps are preserved. Summary introduction
is compact, with the decorative large icon removed; its form remains bounded and
scrollable, and generated summary sections remain unchanged. All Recordings also
has an explicitly expanding list/empty region.

The minimum-height active-operation check additionally exposed the native TabView's
minimum content height pushing the recording title under the toolbar. Compressing
the TabView triggered a native constraint crash and was discarded. Recording Detail
now uses a scrollable column with one GeometryReader for actual available height
and `onGeometryChange` for the actual header/progress height. The tab viewport uses
the remainder, with a 240-point usable minimum; in a short window the column scrolls
instead of forcing native constraints smaller. The view hierarchy does not switch
on resize, preserving view-owned search/tab state. Transcript/summary retain their
own scrolling viewport. Geometry is used here because of the measured native
constraint failure, not to manufacture blank space or a hero header.

Native inspection found two important constraints beyond spacing: forcing the
whole header's vertical `fixedSize` caused a hosting-constraint loop, and wrapping
the recording's native inspector in an outer breadcrumb stack blurred its title.
The final implementation uses header layout priority and puts the breadcrumb
**inside** Recording Detail's content stack. Library still supplies the same
navigation/move actions. No additional titlebar-height compensation is introduced.

Recording Chat retains its inspector width, rows, composer, context controls and
scroll behavior. Project Chat retains all M14.2 shared presentation and gains
space from its parent. Settings/provider forms, usage/history sheets, menus,
sidebar organization, Markdown renderer and thumbnail/retrieval architecture are
deliberately unchanged. The sidebar's transcription label now shows an actual
known part count or the actual phase, rather than defaulting unknown parts to 1/1.

## Shared progress presentation

`OperationProgressView` accepts a title, optional status, factual fraction or unit
counts, optional start time/ETA and optional existing cancellation action. Unknown
work uses a small native spinner. Known completed work uses a native linear bar,
percentage and factual details. No new global operation registry, lifecycle enum,
task engine, persistence model or provider abstraction is introduced.

`OperationProgressValue` normalizes display input: unknown/non-finite values remain
indeterminate; valid fractions are bounded to 0…1; unit totals must be positive.
`OperationDurationFormatter` uses `m:ss` below an hour and `h:mm:ss` thereafter,
including durations over 24 hours. Invalid/negative elapsed values safely display
0:00. Usage processing duration uses the same formatter without changing cost math.

Elapsed time is `now - startedAt`, not accumulated timer ticks. The small
`OperationElapsedTimeView` leaf owns a one-second SwiftUI TimelineView. Chat models
no longer publish a timer mutation once per second. No timer writes SwiftData or
invalidates an entire message list; disappearing views have no retained timer task.
Operation start remains in its existing library/settings owner, so returning after
navigation catches up from the original timestamp. The 80 ms stream coalescing,
supersession/cancellation guards and off-actor Markdown parsing stay unchanged.

| Operation | Final presentation / factual limits |
| --- | --- |
| Audio preparation/split/local preparation | Actual phase, spinner, elapsed, existing Cancel. No invented fraction or part total. |
| Multipart transcription | Actual Part X of N and completed count; fraction is completed audio duration / total duration, not phase weights. Completed parts alone advance it; merge/save do not invent 95%. Processed audio remains visible. |
| Attachment transcription | SourcesViewModel now relays already-supported provider status/progress through the existing tracker. The source row exposes actual parts/audio/elapsed/ETA and clears transient state after completion. |
| Summary, including hierarchical passes | Existing phase string, indeterminate progress, elapsed and existing Cancel. No fraction/ETA where the service lacks reliable totals. Regeneration shows progress alongside the existing summary/history. |
| Recording/project chat | Existing preparation/retrieval/waiting/streaming phases and Stop; elapsed appears in thinking and streaming headers. No fake token fraction. |
| Extraction/OCR | Existing real processor units, status, elapsed and Cancel. Preparation has no invented 0-of-1 total. |
| Project import | Active items use real phase/unit counts and start dates. Queued items say Waiting, without additional spinners. Existing Cancel Remaining, completion totals and mixed-batch errors remain. |
| Local Whisper model download | Existing reported byte fraction, readable downloaded/total bytes, elapsed and underlying Cancel. No ETA/speed was available, so none is synthesized. |
| Retrieval/indexing | Existing project-chat preparation/search phase remains the local indication. Transcript/source search loading indicators remain. There is no new standalone indexing workflow or semantic provider. |

Transcription ETA keeps the **existing** measured throughput tracker: completed
audio seconds / measured wall seconds, exponential smoothing alpha 0.35, remaining
audio / smoothed rate. It is absent until a part/window completes, prefixed `~`,
and cleared outside transcription. ETA changes on measured service updates, not
on fabricated within-request progress. The first sample can include preparation
and be conservative; this pass does not retune the engine. Unknown-total providers
still omit part counts and ETA as appropriate.

Cancellation buttons invoke existing underlying actions (including decoding,
downloads, import queue and provider streams); their established enablement is
retained. Completion removes active presentation. Typed failures, interrupted
prose/history, preserved previous transcripts and Retry/Regenerate paths remain.
The primary transcription retry label is now consistently "Retry". No cancellation
is represented as a successful zero-cost generation. Existing estimates and usage
remain in their existing scope; Decimal cost calculations, request/pricing snapshots,
local/no-API-charge classification and partial/unavailable totals are unchanged.

Accessibility uses native controls, named progress/cancel actions, explicit
percentage values and readable elapsed text. Time is available on demand; no live
region announces each second. Metrics stack at narrow widths and use monospaced
digits. There is no custom progress animation; native controls follow platform
behavior. Physical VoiceOver and changing the system Reduce Motion setting still
require manual acceptance; source inspection alone does not certify those settings.

## Validation (2026-10-02)

Baseline: **414 tests passed**, separate M14.2 commit `908e157`. Final M14.3:
**424 tests in 76 suites passed**, 13.157 seconds in the Swift Testing report.
Debug and Release builds passed after the last native-header correction.
`git diff --check` passes. No new Swift compiler warnings. Xcode reports the existing
"Metadata extraction skipped, no AppIntents.framework dependency found" warning.

New business/service tests cover duration boundaries, >24h, invalid durations,
timestamp elapsed after skipped ticks, unknown/clamped/real-unit progress, phases
without synthetic audio progress, fixture cancellation/failure/ordered timestamps,
isolated/idempotent fixture preparation and attachment progress lifecycle/local
billing. Existing TranscriptionProgressModelTests now expect real completed-audio
fractions rather than artificial phase weighting. The full suite includes existing
chat streaming/cancellation, retrieval/privacy, importer/extraction, download-store,
cost, migration and rendering regressions; these are not substitutes for live UI checks.
No SwiftUI implementation-detail or screenshot-testing dependency was added.

Reproduce automated checks:

```sh
xcodebuild -project AudioNotes.xcodeproj -scheme AudioNotes \
  -destination 'platform=macOS' -derivedDataPath /tmp/AudioNotes-M14-2 test
xcodebuild -project AudioNotes.xcodeproj -scheme AudioNotes \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/AudioNotes-M14-2-Release build
```

Native checks use the actual SwiftUI scene, accessibility inspection, native
window resizing/full screen and window-specific captures on macOS 27 / Apple
Silicon. The extra DEBUG AppKit fixture window is minimized: it is not the shipping
scene. macOS Stage Manager thumbnail captures were discarded/replaced. Synthetic
fixture content contains no real recordings or keys. There were no live provider
calls, real model installs or production-library writes.

| Desktop check | Result and scope |
| --- | --- |
| Project empty, populated, Overview/Recordings/Sources/Chat | Header stays at top; native lists/navigation work; relevant filter appears outside Chat. |
| Minimum 760 × 552, normal 1100 × 834, large 1600-wide, full screen | Navigation/search stack at minimum; chat retains bounded prose/composer and expands viewport. Short recording windows scroll the header/progress/tab column, keeping controls reachable instead of pushing the title into the toolbar. |
| Dark and fixture-local Light Mode | Project identity, controls, native materials and text readable; no system appearance preference changed. |
| Recording Detail/Transcript/Summary/Chat | Title and breadcrumb visible after final inspector correction; timestamp links, aligned search/rows, compact generator and native inspector retained. |
| Multipart transcription | Preparation, Parts 1/2/3, measured 33%/66%, ETA after actual completion, completion transcript at 0/4/8 seconds; failure presents Retry. |
| Navigate and resize during transcription | Leave for another project and return: same operation/elapsed, Part 2 at 33%, not a restarted operation. Active progress fits minimum width. |
| Cancellation | Native regeneration Cancel preserves the prior transcript/version. Mock download Cancel clears active state; fixture/unit tests also cover underlying cancellation. |
| Summary | Native Generate shows spinner/elapsed/Cancel, then resulting summary and Regenerate. A very fast mock does not certify prolonged hierarchical UI behavior. |
| Project Chat | Slow mock shows Waiting for AI, elapsed and Stop; streamed Markdown completes. The existing 500-message fixture exercises lazy history/full-screen layout. |
| Model download | Actual synthetic file writes show 4 KB / 16 KB, 25%, 0:03 elapsed. Successful verification becomes Installed; failure shows useful error and Download retry; cancellation clears presentation. |
| Import/OCR/indexing | Services covered by full offline suite and presentation/source audit. Attempted native audio import was rejected in the fixture; successful native import/extraction progress is **not** claimed for this pass. Prolonged OCR/import desktop acceptance remains open. |

Performance findings are structural: two per-second whole-chat-model mutations
were removed, no persistence ticks or new global observation added, existing lazy
lists/search/Markdown batching preserved. Window observations show more usable
content space. No new Instruments trace was collected, so no frame-rate, memory
or hitch improvement is claimed. Existing M11 measurements/manual debt remain open.

SwiftData schema, migration/versioning, provider selection/privacy rules, managed
file ownership and usage persistence are unchanged. Bundle identifier, signing,
notarization, Sparkle/appcast, release workflows and deployment target are unchanged.
Xcode 27 automatically rewrote objectVersion 77 to 110 during builds; it was restored
to 77 after validation. The project file is byte-for-byte unchanged from M14.2.

## Native review artifacts

All images are under [review/M14.3](review/M14.3/). They are native synthetic
fixtures, not screenshots of the user's library. Before images use M14.2 production
views; temporary baseline checkout received only the isolated layout/audio fixture
and mock-provider wiring to exercise the same operation, never production M14.3 UI.
Window/content selections differ where the caption says so; do not infer pixel
performance from images.

| Surface | Before | After |
| --- | --- | --- |
| Empty project | [Before](review/M14.3/before-project-empty.png) | [Normal](review/M14.3/after-project-empty.png), [minimum](review/M14.3/after-project-empty-minimum.png), [large](review/M14.3/after-project-empty-large.png), [Light](review/M14.3/after-project-empty-light.png) |
| Populated overview | [Before](review/M14.3/before-project-populated.png) | [After](review/M14.3/after-project-populated.png) |
| Project Chat | [Before](review/M14.3/before-project-chat.png) | [Normal](review/M14.3/after-project-chat.png), [full screen](review/M14.3/after-project-chat-fullscreen.png), [Light](review/M14.3/after-project-chat-light.png), [thinking](review/M14.3/after-project-chat-thinking.png) |
| Recording/Transcript | [Before](review/M14.3/before-recording-detail.png) | [After](review/M14.3/after-recording-detail.png) |
| Recording Chat | [Before](review/M14.3/before-recording-chat.png) | [After](review/M14.3/after-recording-chat.png), [Light](review/M14.3/after-recording-chat-light.png) |
| Summary generator | [Before](review/M14.3/before-summary.png) | [After](review/M14.3/after-summary.png), [generating](review/M14.3/after-summary-generating.png), [Light](review/M14.3/after-summary-light.png) |
| Multipart progress | [Before](review/M14.3/before-transcription-progress.png) | [Preparing](review/M14.3/after-transcription-preparing.png), [part 1](review/M14.3/after-transcription-part-1.png), [part 2](review/M14.3/after-transcription-part-2.png), [part 3](review/M14.3/after-transcription-part-3.png), [complete](review/M14.3/after-transcription-complete.png), [narrow/navigation](review/M14.3/after-transcription-narrow-navigation.png), [cancelled regeneration](review/M14.3/after-transcription-cancelled.png), [failure](review/M14.3/after-transcription-failure.png) |
| Mock model download | No changed baseline capture | [Bytes/time](review/M14.3/after-model-download-progress.png), [installed](review/M14.3/after-model-download-complete.png), [failure](review/M14.3/after-model-download-failure.png) |

The final short-window correction is also captured [during resize](review/M14.3/after-transcription-minimum-resize.png)
and [scrolled to the transcript while active](review/M14.3/after-transcription-minimum-scrolled.png).
At the bottom, transcript/search and Cancel are reachable; the scrolled-away playback
header naturally passes behind the native toolbar material. The unscrolled narrow
capture shows the title below the toolbar.

To reproduce the offline fixture, run Debug with `--performance-fixtures
--performance-project-chat --performance-layout`; add `--performance-chat-stress`
for a slow stream/500 messages, `--performance-tab chat` for Recording Chat, or
`--performance-light` for local Light Mode. The separate `--performance-fixtures
--performance-operation-settings` uses the real LocalAISettingsView with injected
byte-writing I/O, dedicated preferences and a temporary model store. Models are
clearly named "not a model". These flags/types are DEBUG-only and cannot seed a
real library or ship mock downloads. Other /tmp automation helpers are not in the repo.

## File inventory

Created:

- Features/Shared/{WorkspaceSpacing,OperationProgressView}.swift
- Utilities/{OperationDurationFormatter,OperationProgressValue}.swift
- Utilities/Development/{OperationPresentationFixtures,OperationSettingsFixtures}.swift
- AudioNotesTests/OperationProgressTests.swift
- docs/UX_LAYOUT_AND_PROGRESS.md and docs/review/M14.3/*.png

Modified (Swift paths relative to AudioNotes):

- Features/Library/{AllRecordingsView,LibraryView}.swift
- Features/Projects/{ProjectWorkspaceView,ProjectControls}.swift
- Features/RecordingDetail/{RecordingDetailView,TranscriptView,SummaryView,SummaryViewModel,RecordingViewModel,TranscriptionControls,TranscriptionProgressModel}.swift
- Features/Chat/{ChatInspectorView,ChatViewModel,Shared/ChatStatusView}.swift
- Features/ProjectChat/{ProjectChatView,ProjectChatViewModel}.swift
- Features/Sources/{SourcesView,SourcesViewModel}.swift
- Features/Settings/{LocalAISettingsView,LocalAISettingsViewModel}.swift
- Services/Usage/UsageRepository.swift
- Utilities/Development/PerformanceFixtureLibrary.swift
- AudioNotesTests/TranscriptionProgressModelTests.swift
- docs/SWIFTUI_MIGRATION.md

## Remaining acceptance / commit status

Implementation and automated checks are committed as a **separate M14.3 commit**
(424 tests in 76 suites, Release build). M14.2 was already committed; no previous
commits were amended. M14.4 followed as its own commit.

Physical VoiceOver narration/focus order, IME and text selection, toggled system
Reduce Motion, live remote/local providers and billing, prolonged production
OCR/import/hierarchical generation and older M11–M13 desktop acceptance remain
open. The normal component/fixture checks cannot close them. The Markdown
renderer still selects text per semantic block. No credible totals/ETA can be
shown for operations whose services expose only phases. Very short windows can
require scrolling/balancing inspectors; no responsive claim is made below the
supported minimum. The native import rejection above is retained as an acceptance
limitation, not silently treated as a successful check. This report does not label
the entire desktop acceptance milestone complete.

## M14.4 — UX QA follow-up

Layout and progress architecture are unchanged. Runtime QA added: search-vs-empty states everywhere a filter can
exclude content (no more blank lists), explicit empty Recordings/Sources tabs, middle truncation with tooltips for
long project/recording/source names (checked with worst-case strings at 760×552), correct pluralization, a sidebar
footer background, and a fix for the narrow-window Recording Chat crash (the Chat toggle is disabled below a 640 pt
detail pane, with a tooltip). Cancelling a transcription moves straight to "Transcription cancelled" with Retry.
Progress accessibility: determinate progress has a label and percentage value, elapsed time is
`updatesFrequently` and not part of any label, step rows expose Completed / In progress / Waiting. Details,
screenshots and limits: [ACCESSIBILITY_AND_QA.md](ACCESSIBILITY_AND_QA.md). Prolonged import/OCR, real model
downloads and live providers are still manual acceptance.
