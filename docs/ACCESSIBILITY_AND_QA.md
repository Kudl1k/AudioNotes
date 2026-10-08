# M14.4 — Accessibility, previews, performance and final UX QA

Status: implemented and validated on 2026-10-02 (Apple Silicon, Xcode 27, macOS 27, deployment target
macOS 15). This is the final M14 pass. It is a stabilization milestone: no architecture rewrite, schema,
storage, provider, signing, Sparkle or release changes. Committed separately, after M14.3 (see "Commit status").

What was physically tested and what was only inspected is stated per item. Nothing here claims physical
VoiceOver, IME, Reduce Motion or Increase Contrast validation.

## Audit (before changes)

| Area | Finding | Resolution |
| --- | --- | --- |
| Icon-only controls | Most already had labels from `Button("Title", systemImage:)`. The Transcription "gear" `SettingsLink`, the chat "+N more" buttons and the sidebar progress spinner had no intent label. | Labelled. |
| Message rows | Row announced "User message"; the visible "You / AudioNotes" header was read a second time. Streaming partial text sat in the accessibility tree and changed every ≤80 ms. | "Your message" / "Assistant message"; header hidden from VoiceOver; streaming content collapsed to one "Assistant is responding" element; one "Answer ready" announcement on completion. |
| Citations | Recording chat chips read "Seek to 12:34"; project chips "Source: …"; Sources chips had only the visual label. | "Open citation, <authoritative label>" / "Citation unavailable, …". Labels come from `SourceReference.label` / `ProjectCitationNavigation.label`; no metadata is invented. |
| Transcript | Each segment was a separate timestamp button plus separate text. | One element per segment: "Speaker, 5:59:56, text" with a "Play from <time>" action. Timestamp link stays in the keyboard loop. |
| Progress | Elapsed text could be treated as changing content; transcription step rows used only an icon for done/active/waiting. | `updatesFrequently` on the elapsed leaf, step rows expose Completed / In progress / Waiting values. Time is not part of any container label. |
| Errors | Several red `Text` errors relied on color and had no icon. | `InlineErrorLabel` (icon + text + "Error:" prefix) in Settings, Export, Presets and playback. Transcript/summary failure labels now start "Transcription failed" / "Summary failed". |
| Grouping | Project title + counts + description were three elements; sidebar recent rows read cost/title/date separately; list rows exposed child text. | Project header is one header element; sidebar and list rows are combined. |
| Source rows | Several "Open" and "Retry" buttons were indistinguishable. | "Open <name>", "Retry <name>", "Transcribe <name>". |
| Decorative images | Summary check/question/box icons and the chevrons in menus were read as images. | Hidden. Section titles in summaries now carry the heading trait. |
| Identifiers | Only the chat controls had ids. | Added for sidebar, project tabs/search, import, progress cancel, transcript search/segments, sources, playback, toolbar and chat usage/export/clear/scope/settings. |
| Empty / search states | AllRecordings, Project tabs, Sources search and Transcript search showed a blank list when a filter matched nothing, indistinguishable from "empty". A project with only sources showed an empty "Recent Recordings" section. | `ContentUnavailableView.search` everywhere a filter excludes content (shown only after the query's results are published); explicit "No recordings in this project" / "No shared sources" states; empty sections are omitted. |
| Long strings | Project and recording titles were unbounded; row titles could push controls. | Titles clamp to two lines or truncate in the middle, with `.help` for the full text. Exercised in the app with worst-case strings. |
| Previews | None. | See "Previews". |

Not changed on purpose: Markdown renderer, transcript renderer, repository construction in views, the
`onAppear` restoration, chat architecture, progress architecture.

## Fixes found by runtime QA

1. **Recording Chat crashed when opened in a narrow window** (`NSGenericException`: "The window has been marked
   as needing another Update Constraints in Window pass…", stack ending in
   `SplitViewChildController.hostingView(_:didUpdateMinSize:maxSize:)`). Reproducible and deterministic: open
   the chat inspector with ⌘⌥C or the toolbar when the detail pane is narrower than about 630 pt (a window
   under ~890 pt with the default sidebar). The M14.2 baseline, the M14.3 candidate and M14.4-before all crash;
   shrinking the window *after* opening the inspector is fine. Mechanism: the inspector's animation passes
   through widths at which the detail pane's minimum size cannot be satisfied. Fix: the Chat toggle (and its
   shortcut) is disabled while the detail pane is narrower than `RecordingDetailView.minimumDetailWidthForChat`
   (640 pt), with a tooltip explaining why. Verified: 760 and 880 wide stay up with the toggle disabled; 1100
   wide opens and works. Two earlier attempts (constant tab height, deferring the header-height state) did not
   change the outcome, which is how the cause was isolated to the inspector; both were reverted. This is a
   pre-existing defect, not an M14 regression, but it is a crash at a supported window size.
2. **File → Export… disabled while the chat composer had focus.** `.focusedValue` only reaches the command when
   the focused view is inside the providing view's focus chain; the AppKit text view in the inspector is not.
   Switched to `.focusedSceneValue`. Verified with the composer holding first responder (text typed into it):
   Export… stays enabled, ⌘E opens the sheet, Escape dismisses it, the draft is intact. Export is still
   unavailable when no recording is shown (project, All Recordings).
3. **Escape stopped generation from anywhere in the window.** The Stop button carried
   `.keyboardShortcut(.cancelAction)`, so Escape in the transcript search field stopped an answer streaming in
   the inspector. The composer's own `cancelOperation` already stops generation (and discards marked text
   first), so the window-wide shortcut was removed. Verified: Escape in the composer stops the answer;
   Escape with focus in the transcript search leaves it streaming to completion.
4. **Undecodable audio showed "fake.m4a: Cannot Open"** (raw AVFoundation text). `AudioImportService` maps
   `AVFoundationErrorDomain` failures to `AudioImportError.invalidAudio` ("This file does not contain playable
   audio."). Test added.
5. **Library cost totals were keyed on every `LibraryView` evaluation.** See Performance.
6. Persistence failures in Sources and Transcript History used `error.localizedDescription` (SwiftData text);
   they now say what failed and to try again. File-write errors keep the system text, which names the file and
   the cause and is useful. Pluralization: "1 recordings", "1 sources", "1 pages", "3 part" now read correctly.
   The sidebar footer count had no background and overlapped list rows at small heights; it uses the bar material.

## Accessibility acceptance

| Check | Result |
| --- | --- |
| Code-level audit (all feature views) | Done; table above. |
| Accessibility tree inspection through the system accessibility API (what VoiceOver consumes) | Done with a small AXUIElement walker against isolated DEBUG fixture processes: roles, labels, values, selection (`AXSelected` on the sidebar row, radio group value 1 on the Chat tab), identifiers present. A sweep for interactive controls without a name found **0 unlabeled controls** on Settings (General, Presets, Export, OpenAI, Anthropic, Gemini), project Overview/Sources/Chat, the recording transcript, Recording Chat and the export sheet (the only unnamed items were system scroll-bar parts and window traffic lights). |
| Keyboard (real key events) | ⇧⌘N create project (type name, Return), ⌘O panel with multi-select, ⌘E from inside the composer, ⌘, Settings, ⌘⌥C chat, ⌘W and Return in Help windows, Escape in sheets and composer. Not re-run this pass: Shift+Return, ⌘A/⌘C/⌘X/⌘V and arrow/Option/Command movement in the composer (unchanged NSTextView behavior, covered by `ChatPresentationTests`); a full Tab/Shift+Tab traversal map. |
| Return and destructive actions | Not re-run; the M14.1 dialogs were not changed. |
| Physical VoiceOver | **Not performed.** VoiceOver was not enabled; doing so changes system state. Findings above come from the accessibility tree, not from listening. |
| Physical IME / marked-text composition | **Not performed.** No input method was switched. The marked-text gating is covered by the existing automated tests (Return and Send are blocked while marked text exists, Escape discards it). Still open. |
| Reduce Motion | **Not toggled.** `Features/` contains no `withAnimation`, `.animation`, `.transition`, matched geometry or symbol effects; motion is native control behavior, which follows the system setting. |
| Increase Contrast | **Not toggled.** Native controls only; the custom tinted chips and bubbles keep text on near-neutral fills. Needs a manual look. |
| Light / Dark | Both reviewed in fixtures (screenshots below). The fixture window forces Light via `--performance-light`; no system preference was changed. |
| Streaming and VoiceOver | Streaming text is not exposed; one "Answer ready" announcement at completion (`AccessibilityNotification.Announcement`). Verified in the tree that the active response is a single element ("Assistant is working: …" then "Assistant is responding"). |

## Previews

`Utilities/Development/PreviewCatalog.swift` (DEBUG only, `#Preview`): chat message rows (user, assistant with
long Markdown/table/code/Czech text and citation chips, interrupted), chat status/error/empty state, composer
(empty, with text, generating), operation progress (indeterminate, multipart determinate with ETA, unit counts,
download, cancel, error), project workspace (populated, empty, minimum width) and the transcript.

Fixture strategy: `PreviewFixtures` builds an in-memory `ModelContainer` through the existing
`LibraryStorage.makeContainer(inMemory:)`, a storage root under the temporary directory that nothing writes
to, the existing `PerformanceFixtures` data, and mock providers. No second mock system was added. The project
workspace previews use the real `ProjectWorkspaceView`, `ProjectImportQueue` and `LibraryViewModel`.

Proof of no side effects, as far as it can be shown without rendering: the previews reference no credential
store, settings view model, provider client, `NSOpenPanel`, `NSWorkspace` or `URLSession`; `FinalQATests`
checks that the container is in-memory, that the storage root is under the temporary directory and that
building the fixtures creates no files. **The previews compile (Debug and Release builds) but were not rendered
here: Xcode's canvas cannot be driven from the command line.**

## Performance

All measurements are Debug builds on the fixtures; they are observations, not thresholds. No CI threshold was added.

| Scenario | Result |
| --- | --- |
| Idle CPU / memory (recording + chat open, 504-recording fixture) | 0.0% CPU; about 246 MiB RSS. After a stream the M14.2 and M14.4 builds both sit near 285 MiB. |
| Timers when idle | None. `OperationElapsedTimeView` is the only display timer and exists only inside active operations; the playback poll runs only while playing; the other `Task.sleep` calls are debounces. |
| Streaming a long Markdown/code answer into a 500-message chat | About 60–90% of one core while rendering, 0.0% immediately after. **Identical profile on the M14.2 baseline**, so not a regression; the renderer cost is pre-existing and unchanged. |
| 6,000-segment (6 hour) transcript | Opens (search field visible) in 0.6 s including probe overhead; 198 MiB RSS; 0.0% CPU settled; search over 6,000 segments filters to the expected single match; "No Results" state shown for a miss. |
| 100 / 500 chat messages | Presentation snapshots 0.2 / 0.9 ms; Markdown preparation 5.7 / 27.9 ms. 500-message history is lazy and scrolls; Latest behavior unchanged (M14.2). |
| Project scale | 100 projects / 500 recordings / 200 sources: fetch + first workspace metadata 0.029 s. |
| Active progress | Not separately sampled for CPU. Elapsed time re-renders one leaf per second, and progress updates no longer rebuild the usage key. |
| Window resizing | Project workspace (empty, populated, worst-case names) at 760×552 and 1100×834, and the recording column with an active transcription at 760×500, were inspected; no re-introduced gaps (screenshots). Chat at the minimum size and full screen were not re-inspected. |
| Usage-cost refresh key | See below. |

### Usage-cost refresh key (M14.1 item)

Confirmed: `LibraryView` held `@Query var generations` and rebuilt a string key from every record
(`id-hash-status` joined) in the `.task(id:)` argument on every body evaluation, which includes every
transcription-progress update through the sidebar. Fix with the smallest change: `UsageSnapshotRefresher`, a
small `Equatable` leaf view, owns the query and the key; `UsageRefreshKey` hashes the same three fields
(`id`, `statusRaw`, `requestUsageData`) without allocating strings. Cost accounting, `UsageRepository` and
snapshots are untouched.

Measured honestly: per evaluation, building the key for 5,000 records took 11.6 ms (old) vs 9.2 ms (new); the
data hashing dominates, so the per-call saving is modest. The benefit is frequency. With temporary
instrumentation, an 11-second multipart transcription with continuous progress updates built the key only at the
start and end (when generation records are inserted/finalized), not for any progress re-render. The
instrumentation was removed. `FinalQATests` covers key stability and change detection.

### `LibraryView.onAppear`

Reviewed, not moved. It runs once per appearance, guarded by `destination == .allRecordings`; the DEBUG fixture
selection is compiled out of Release. No repeated work was found.

## Operations

| Item | Result |
| --- | --- |
| Native import fixture failure (M14.3) | Not reproduced on the unmodified M14.3 build: M4A and WAV import and open correctly; the open panel filters to audio and says "Import". A file with an audio extension that is not decodable is rejected. Classification: **fixture/harness (A/B)**, plus a **pre-existing presentation leak (C)** — the rejection showed AVFoundation's raw "Cannot Open". Fixed (item 4 above). Not an M14 regression. |
| Library audio import | M4A and WAV pass; corrupt file shows the user-facing message. |
| Project import (multi-file) | One batch of five (PDF, PNG, Markdown, TXT, M4A) through the real panel with ⌘A: audio became a Recording; PDF extracted (1 page); PNG ran Vision OCR ("OCR complete"); both text files ready; "5 of 5 items added"; CPU 0.0% within seconds. Isolated in-memory store and temporary files; the real library was not opened. |
| Long import / OCR over time | Not exercised: the fixtures complete in about a second, so elapsed/cancel over a prolonged import and a slow OCR were **not** observed. Remains manual acceptance. |
| Multipart transcription | Part N of M, determinate fraction, elapsed, measured ETA after completed parts, completion (Dark and Light), cancel (immediately "Transcription cancelled" with Retry — no lingering "Cancelling…"). Over the 760×500 minimum the recording column scrolls and the title stays below the toolbar. |
| Model download | Not re-run natively; M14.3's synthetic byte-writing fixture and the unit tests are unchanged. No real model was downloaded. |
| Live providers | **Not performed.** No credentials were used and no metered request was made. Remains manual release acceptance. |
| Local provider | An Ollama server is running locally (0.34.2, six models). Its API was queried read-only. In the fixture host the in-app "Test Connection / Refresh Models" reported "Remote server / 0 installed chat models" using the fixture process's own preferences. That was not investigated further and is **inconclusive**; M14 changed no Ollama logic (M14.3 only added a download start time to the same view model). No generation was run. |
| Settings side effects | Opening Settings makes **no** model-list request: `fetchVoiceModels` and `fetchChatGPTModels` run only from their buttons or after ChatGPT sign-in. It does check Keychain presence for three providers and, when Anthropic is selected, lists Claude CLI models once per executable path (a local process). `FinalQATests` asserts zero list requests and zero secret reads on `refresh()`. The earlier observation was not reproducible from the code. |

## Regression checks

| Area | Result |
| --- | --- |
| Help / Privacy / Licenses | Open, re-choosing focuses the same window, ⌘W closes, Return (Done) closes. |
| Clipboard | Message Copy and code Copy verified (user clipboard saved and restored around the test). |
| File panels | Import panel: audio filter, document types, multi-select, "Import" button; Export diagnostics/Markdown/PDF/Project Chat export were not re-run (adapter unchanged since the M14 smoke test). |
| Reveal in Finder / Data Folder | **Not re-run**; the adapter is unchanged. |
| Browser / OAuth | Not repeated; covered by injected-opener tests. |
| PDF and transcript citation jumps | Not re-run natively; no navigation code was changed. Existing unit tests pass. |
| Persistence / SwiftData | No model, schema, migration or storage-location change (`git diff -- AudioNotes/Models` is empty). |
| Menus | Reviewed (see below). |

Menu review: no duplicated items. File has New Project… (⇧⌘N), Import… (⌘O), Close, Close All and Export… (⌘E,
enabled only while a recording is shown). Help has Help, Privacy, Third-Party Licenses, Export Diagnostics… and
Reveal Data Folder. Check for Updates… is disabled in the development host by design. The automatic window tabbing
items under View/Window are standard SwiftUI `WindowGroup` behavior and pre-date M14; the app offers no way to
create a tab, so they are inert. The Chat toggle has a shortcut but no menu item. Context-menu actions for
recordings and sources (Rename, Move, Reveal, Delete) are reachable through VoiceOver's actions menu. Move also
has the recording's Organize menu; Rename and Delete are context-menu only, which is remaining debt (see below).

## Validation

| Check | Result |
| --- | --- |
| Baseline before changes | 424 tests in 76 suites passed. |
| Final | **431 tests in 77 suites passed**, twice (12.9 s and 13.1 s). |
| New tests | `FinalQATests` (6): usage key stability, Settings makes no list request and reads no secrets, transcript spoken label, transcript search pending-vs-no-match, project header label, preview fixtures are in-memory/temporary/file-free. `AudioImportServiceTests` (+1): undecodable audio gives the user-facing error. |
| Async regression tests | The M14.2 cancellation/publisher tests are untouched; no sleeps were added. |
| Release build | Succeeded. |
| Warnings | None new. Xcode's existing "Metadata extraction skipped, no AppIntents.framework dependency found" remains. (One new Sendable-closure warning was introduced and fixed during the work.) |
| Xcode project format | Xcode 27 rewrote `objectVersion` to 110 during builds; restored to 77. `project.pbxproj` has no diff. |
| Release infrastructure | Bundle id, signing, Sparkle, appcast, workflows: unchanged. |
| `git diff --check` | Clean. |

## Screenshots

Only what documents M14.4: [recording chat, Dark](review/M14.4/recording-chat-dark.png),
[project with worst-case names at the minimum width](review/M14.4/project-long-names-minimum.png),
[empty project](review/M14.4/project-empty-dark.png),
[multi-file import result](review/M14.4/project-import-acceptance.png),
[transcription progress, Light](review/M14.4/transcription-progress-light.png) and
[after cancel, Light](review/M14.4/transcription-cancelled-light.png). Synthetic content only.

## Known limitations (retained)

- Markdown text selection does not span separate rendered blocks.
- Transcript selection does not span segments.
- AppKit remains for: file panels, clipboard, Finder/browser, alerts, the PDFKit view, the chat text editor
  (marked-text gating), `PDFExporter`, and the DEBUG fixture host.
- Streaming a long Markdown answer costs most of a core while it renders (unchanged since M14.2).
- Recording Chat is unavailable (toggle disabled) in a detail pane narrower than 640 pt; widen the window or
  hide the sidebar.
- Not physically validated: VoiceOver narration and focus order, IME composition, Reduce Motion, Increase
  Contrast, live providers, prolonged import/OCR, real model downloads, Reveal, Export PDF/diagnostics re-runs.
- Preview canvases were not rendered.
- Rename and Delete for recordings and sources have no menu-bar or toolbar equivalent to their context menus.

## Reproducing

```sh
xcodebuild -project AudioNotes.xcodeproj -scheme AudioNotes -destination 'platform=macOS' \
  -derivedDataPath /tmp/AudioNotes-M14-4 test
xcodebuild -project AudioNotes.xcodeproj -scheme AudioNotes -configuration Release \
  -destination 'platform=macOS' -derivedDataPath /tmp/AudioNotes-M14-4-Release build
git checkout -- AudioNotes.xcodeproj/project.pbxproj   # Xcode 27 rewrites objectVersion to 110
```

Fixture launch flags are DEBUG-only: `--performance-fixtures` with `--performance-project-chat`,
`--performance-layout`, `--performance-chat-stress`, `--performance-light`, and the new
`--performance-long-names` (adds a project with worst-case project, recording and source names);
`--performance-empty-library` for isolated import checks. Temporary AX/automation helpers lived under `/tmp`
and are not part of the repository.

## File inventory

Created: `Features/Library/UsageSnapshotRefresher.swift`, `Features/Shared/InlineErrorLabel.swift`,
`Utilities/Development/{PreviewFixtures,PreviewCatalog}.swift`, `AudioNotesTests/FinalQATests.swift`,
this document and `docs/review/M14.4/*.png`.

Modified: accessibility, state and empty-state work in `Features/{Chat,ProjectChat,Library,Projects,RecordingDetail,Sources,Settings,Export,Presets,Shared}` views,
`Features/RecordingDetail/TranscriptViewModel.swift`, `Features/Sources/SourcesViewModel.swift`,
`Platform/macOS/AppKit/ChatTextEditorRepresentable.swift` (accessibility label/placeholder only),
`Services/AudioImportService.swift`, DEBUG fixtures (`ProjectChatFixtures`, `PerformanceFixtureLibrary`),
`AudioNotesTests/AudioImportServiceTests.swift`, and the four milestone documents.

## Commit status

M14.3 and M14.4 are separate commits, in that order, on top of M14.1 and M14.2. M14.3 was reconstructed
byte-for-byte from the pre-M14.4 snapshot (tracked diff and all 67 files identical) before it was committed; the
M14.4 delta was then reapplied from a checksummed backup of the combined tree (100 files verified). Backups live
outside the repository and are not part of either commit.

## Post-M14 technical debt

- Investigate the underlying AppKit constraint loop in narrow Recording Chat. The ~640 pt guard above is a
  release-safety mitigation, not a fix, and must not be used as a model for other platforms.
