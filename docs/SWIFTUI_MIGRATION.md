# M14 — SwiftUI-first UI architecture

Status: first pass (audit + platform boundary) implemented on 2026-10-01. Desktop,
accessibility and native interaction acceptance is still open, as listed at the end.
No iOS target, providers, persistence changes or release-infrastructure changes.

## Summary of the starting point

The audit found that AudioNotes was **already SwiftUI-first**. It was not the AppKit
application that the M14 brief assumed:

- `@main struct AudioNotesApp: App` with `WindowGroup`, a `Settings` scene and SwiftUI
  `Commands`. AppDelegate is used only through `@NSApplicationDelegateAdaptor` for the
  DEBUG-only performance fixture window.
- `NavigationSplitView` root with typed `LibraryDestination` UUID navigation.
- All 53 view types are SwiftUI. There was exactly **one** `NSViewRepresentable`
  (the PDFKit preview) and no `NSViewController`, `NSTableView` or `NSTextView`.
- The transcript renderer is a SwiftUI `LazyVStack` of stable segment rows. Markdown
  (chat, summaries) is a native SwiftUI semantic-block renderer (`MarkdownDocument`
  parsed off the main actor, plus `MarkdownMessageView`). There is no AppKit/`NSTextView`
  baseline to benchmark against.
- No SwiftUI imports exist in `Models/` or `Services/`.

AppKit was still scattered through features and services as small direct calls:
`NSOpenPanel`/`NSSavePanel` in four places, `NSPasteboard` in four, `NSWorkspace` in
eight, global `NSEvent.modifierFlags` polling in two composers, a manual
`NSWindow`/`NSWindowController` registry for Help windows, and `NSAlert`. Three
service files imported AppKit (two only to open a browser, one only for a clipboard
helper), and `SourceProcessingService` wrapped a `CGImage` in an `NSImage` only to
unwrap it again.

This pass therefore concentrated on the boundary, not on rewriting views.

## AppKit inventory and classification

Before = start of M14. After = this pass.

| Component | Before | After | Class | Decision and rationale |
| --- | --- | --- | --- | --- |
| App lifecycle / scenes | SwiftUI `App` | SwiftUI `App` | — | Already target architecture. Kept. |
| Help/Privacy/Licenses windows | `NSWindow` + `NSHostingView` + static `NSWindowController` registry | SwiftUI `WindowGroup(for: Page)` + `openWindow` | A | **Migrated.** Removes manual window retention. Reopening a page focuses its existing window; restoration disabled to match previous behavior. |
| Export Diagnostics save panel | `NSSavePanel.runModal()` inside the view model | `FilePanels` adapter, called from the command | A | **Migrated to boundary.** View model now takes a URL and has no AppKit import. |
| Diagnostics error alert | `NSAlert` inline in command | `Alerts.show` adapter | C | `Commands` have no view to attach `.alert` to. Kept AppKit, isolated. |
| Import audio / project files | `NSOpenPanel` inline in `LibraryView` | `FilePanels.chooseFiles` | C (platform API) | Kept NSOpenPanel per brief §29; behind one adapter. |
| Add Sources | `NSOpenPanel` inline in `SourcesView` | `FilePanels.chooseFiles` | C (platform API) | Same. |
| Recording export save | `NSSavePanel` inline in `ExportSheetView` | `FilePanels.chooseSaveDestination` | C (platform API) | Same; tag field retained. |
| Project Chat export save | `NSSavePanel` inline, `.plainText` type | `FilePanels`, Markdown (`md`) type | C (platform API) | Same. Fixed the panel's declared type to Markdown, matching the `.md` name and contents. |
| Copy (messages, code blocks, logs) | `NSPasteboard` in 3 views + `DebugLogService` | `Clipboard.copy` | C (platform API) | Isolated. `DebugLogService` (service) no longer imports AppKit. |
| Reveal in Finder / open folder | `NSWorkspace` in 6 views | `Workspace.revealInFinder` / `open` | C (platform API) | Isolated. |
| OAuth browser launch | `NSWorkspace` in ChatGPT and Gemini auth services | `SystemBrowserOpener` (platform) injected via existing `BrowserOpening` | C (platform API) | Services no longer import AppKit; tests still inject their own openers. |
| Composer Shift+Return | `NSEvent.modifierFlags` global poll; Shift+Return never inserted a newline (macOS vertical `TextField` ends editing on Return) | `onKeyPress(.return, phases:) { press in press.modifiers }`; Shift appends `\n` to the draft | A | **Migrated and fixed.** Uses the key event's own modifiers. Found by the smoke test: the newline is appended at the end of the draft, because `TextField` exposes no cursor position. |
| PDF source viewer | private `NSViewRepresentable` in feature file | `PDFPreviewRepresentable` in platform folder | C | Kept PDFKit (§78). Moved, and added a coordinator guard so unrelated SwiftUI updates no longer re-jump to the cited page (§63 bridge feedback). |
| PDF export renderer (`PDFExporter`) | CoreText + `NSAttributedString`/`NSColor`/`NSFont` | unchanged | C | Kept (§82). It is not coupled to any view hierarchy; it draws off-actor from shared `ExportContent`. An iOS port would swap `NSFont`/`NSColor` for `CTFont`/`CGColor` or UIKit equivalents inside this one file. |
| PDF page OCR raster / thumbnail | `PDFPage.thumbnail` → `NSImage` → `CGImage` | unchanged API, conversion at call site | C | PDFKit returns the platform image type; converted to `CGImage` immediately. Image thumbnails now write the `CGImage` directly. OCR rasterization untouched to avoid OCR regressions. |
| DEBUG performance fixture window | `NSApplicationDelegate` + `NSWindow` | unchanged | C | DEBUG-only by design (M11): avoids the user's saved scene identifiers. Not shipped. |
| Transcript renderer | SwiftUI `LazyVStack` | unchanged | — | Already SwiftUI. See decision below. |
| Markdown renderer | SwiftUI semantic blocks | unchanged | — | Already SwiftUI. See decision below. |

No D (remove) items were found: no dead AppKit UI exists. The replaced Help-window
controller and the inline `DefaultBrowserOpener`/`copyToClipboard` were deleted, not
kept alongside the new code.

## SwiftUI component inventory

All views are SwiftUI. "Embedded logic" notes where a view performs persistence or
service work directly, which matters more for M14 than AppKit.

| Feature / component | State ownership | Embedded logic in view | Perf. sensitive | Recommendation |
| --- | --- | --- | --- | --- |
| `LibraryView` (sidebar, split view) | `LibraryViewModel` (`@Observable`), library-owned task models | Constructs repositories and performs project moves; four boolean-bound `.alert`s | Medium (500+ rows tested in M11) | Move `move(_:to:)` into `LibraryViewModel`; unify alerts into one identifiable presentation enum |
| `AllRecordingsView`, `ProjectSidebarRow`, `ProjectLibraryDialogs` | Library model / `@Query` | Minimal | Medium | Keep |
| `ProjectWorkspaceView` | Library + project import queue | Repository delete/rename/move inline; four `.alert`s | Medium | Same cleanup as LibraryView |
| `RecordingDetailView`, `TranscriptionControls`, `PlaybackControls` | `RecordingViewModel`, `TranscriptionProgressModel`, `AudioPlaybackService` | Starts transcription via a repository built in the view (operation itself is library-owned) | Medium | Keep; progress model is already testable |
| `TranscriptView` | `TranscriptViewModel` (worker sort/search, 150 ms debounce) | None | **High** | Keep SwiftUI |
| `SummaryView`, `SummaryHistorySheet` | `SummaryViewModel` | Repository make-current/delete inline | Medium | Move history mutations into `SummaryViewModel` |
| `TranscriptHistoryView` | view model | Passes repositories in | Low | Keep |
| `ChatInspectorView` (Recording Chat) | `ChatViewModel`, `ChatScrollState` | Builds chat repository | **High** (streaming) | See chat findings |
| `ProjectChatView` | `ProjectChatViewModel`, `ChatScrollState` | Export write in view | **High** | See chat findings |
| `AssistantMessageView`, `MarkdownMessageView`, `MarkdownCodeBlock`, `ChatSourcesView` | Content-keyed async parse; `Equatable` block view | None | **High** | Keep; already shared by both chats |
| `SourcesView`, `SourceSelectionView`, `SourceThumbnailView`, `SourcePreviewView` | `SourcesViewModel`, shared thumbnail cache | Minimal | Medium | Keep |
| `ExportSheetView` | `ExportViewModel` | None after this pass | Low | Keep |
| Settings (`ProviderSettingsView`, `ProviderConnectionsView`, `GenerationDefaultsView`, `LocalAISettingsView`, `ClaudeCLIConnectionView`, model pickers) | `ProviderSettingsViewModel` (`ObservableObject`), `LocalAISettingsViewModel` | Minimal | Low | Already SwiftUI `Settings` scene. Do not convert `ObservableObject` for syntax alone (§8) |
| Presets (`PresetsManagementView`, `PresetEditorView`) | repository-backed | Minimal | Low | Keep |
| `UsageCostView`, cost labels | `UsageRepository` totals computed in `.task` | Aggregation runs in `.task`, not body | Low–Medium | Keep |
| `WelcomeView` (onboarding), `LibraryRecoveryView`, `ReleaseInformationView` | Local | None | Low | Keep; pure SwiftUI |

Features named in the brief that **do not exist** in this codebase and therefore were not
audited or verified: M12.4 project generation / generated-document list and viewer,
generated-notes TOC, "Copy as Markdown", waveform/timeline drawing, a production
embedding/semantic UI, and a UI-test target.

## Renderer decisions

**Transcript: keep the existing SwiftUI renderer.** There is no AppKit renderer to
compare, so the brief's "prototype SwiftUI and compare" step does not apply. The
renderer's measured behavior is in [UI_PERFORMANCE.md](UI_PERFORMANCE.md): lazy rows
with stable segment IDs, worker-side sorting/search with cancellation of superseded
results, scroll-to-segment citation targeting, and up to 6,000-segment (6-hour) synthetic
fixtures. Known trade-off: SwiftUI `Text` selection works within a segment, not across
segments. A continuous cross-segment selection would be the only concrete reason to
prototype an `NSTextView` renderer. Do that only with a before/after benchmark.

**Markdown: keep the existing SwiftUI semantic-block renderer.** It is shared by
Recording Chat, Project Chat and summaries, parses off-actor, and supports streaming
partial content. Representative block parsing was measured at about 6.5 ms per 100 parses
(M11). As with transcripts, selection is per block. No 10k/50k-word generated-document
surface exists yet (M12.4 not started), so the long-document benchmark is deferred to
that milestone.

## Architectural boundaries after this pass

```
Models/, Services/          no SwiftUI; AppKit only in PDFExporter (documented)
Features/                   SwiftUI views + @Observable presentation models; no AppKit imports
Platform/macOS/AppKit/      FilePanels, Clipboard, Workspace (+ SystemBrowserOpener),
                            Alerts, PDFPreviewRepresentable
Utilities/Development/      DEBUG-only fixture delegate (AppKit, not shipped)
App/                        scenes, commands, composition (AppServices)
```

`PDFKit` is imported only by `PDFPreviewRepresentable` and `SourceProcessingService`.
PDFKit exists on iOS too; only its image return type differs.

Rules for new code:

- New UI is SwiftUI. Add AppKit only in `Platform/macOS/AppKit` and only when SwiftUI
  has no adequate API (panels with tags, Finder reveal, PDFKit, alerts from `Commands`).
- Features call platform adapters by intent (`FilePanels.chooseFiles`, `Clipboard.copy`).
  They are simple `@MainActor` enums rather than protocols, because nothing needs to
  substitute them (§65). Protocol seams exist only where tests inject behavior
  (`BrowserOpening`).
- Representables keep business logic outside. They guard synchronization in a
  coordinator so SwiftUI updates do not re-apply state.

## Presentation state, navigation and operations

- Presentation and service state: `@Observable` is the norm (17 declarations). Three remain `ObservableObject`:
  `ProviderSettingsViewModel`, `ClaudeCLISettingsViewModel` and `UpdateService` (Sparkle's
  KVO-backed `canCheckForUpdates`). `ChatGPTAuthService` publishes auth state through
  Combine. These are stable, and M14 does not convert them for syntax alone.
- Navigation: `LibraryDestination` uses stable UUIDs for recordings and projects, and
  scene restoration is compatible with M11. Rename/reorder do not change identity. Citation
  navigation (Project Chat → recording → timestamp, and → PDF page/image/text) is unchanged.
- Long-running work is owned below views. The library owns transcription, source,
  summary, chat and project-import models across navigation (M11/M12). `.task` usage was
  audited (15 sites). Every one is a load/parse/search/aggregate scoped to its view, and
  none starts transcription, provider calls, indexing or generation.
- Streaming: the existing 80 ms coalescing in both chat view models is retained.
- Elapsed timers: two per-row `TimelineView(.periodic(by: 1))` instances (transcription
  controls, source processing), which tick only while the job is running.

## Findings that remain (recommended next steps, in order)

1. **Presentation boundary cleanup** — done in M14.1 (see below).
2. **One chat UI.** Recording Chat (`ChatInspectorView`, 527 lines) and Project Chat
   (`ProjectChatView`) already share the message renderer, `ChatScrollState` and
   streaming cadence. They still duplicate the composer, history list and message row.
   Extract a shared `ChatTranscriptList`/`ChatComposer` driven by a small protocol over
   both view models (§45).
3. **Shared progress component.** Unify the two elapsed-time labels and their formats
   (`0:12` vs `12s`) into one component over `TranscriptionProgressModel`-style
   state (§48–50).
4. **Previews and accessibility identifiers.** The project has no `#Preview` and no
   accessibility identifiers. Add mock-state previews for row/message/progress views
   once (1) and (2) define stable presentation inputs.
5. **Module evaluation (§68).** An `AudioNotesCore` package is **not recommended yet.**
   SwiftData models are registered by the v1 schema (`LibrarySchemaV1`), and moving them
   across a module boundary risks the M13 migration guarantees (§71). Services also use
   app-target conveniences. With AppKit now confined, a later split could take
   `Services/` minus `PDFExporter` plus the value-type models, with SwiftData models
   staying in the app.

## M14.1 — Presentation boundaries

Scope: `LibraryView`, `ProjectWorkspaceView` and `SummaryView`. This was an architecture
cleanup, not a redesign. No schema, storage-location, migration, module or release
changes.

### Audit (before)

| View | Direct persistence / workflow in the view | Alerts and confirmations |
| --- | --- | --- |
| `LibraryView` (+ `ProjectLibraryDialogs`) | Built `SwiftDataProjectRepository` and ran `move` for menu moves and dropped-ID loops (ID resolution, skip rules, navigation). Routed imports between `ProjectImportQueue.enqueue` and `importURLs` itself. Ran project create/rename in the editor callback. Owned the project-deletion in-progress flag and `Task`. Chose the reveal error message. Rename and delete already went through `LibraryViewModel`. | Five independent alerts: rename, delete-workspace, delete-project, workspace error and import error. Driven by four optional targets, a title string and two error strings. |
| `ProjectWorkspaceView` | `deleteSource`, `renameSource` and `move` called directly on a repository, with raw `localizedDescription` errors. No presentation model. | Four alerts (delete recording, delete source, rename source, error) over three optional targets, a name string and an error string. |
| `SummaryView` | `makeCurrent` in the view, and `delete` in the history sheet, both with `try?` so failures were **silently ignored**. Generation already went through `SummaryViewModel`. | Delete-version `confirmationDialog`; no error presentation. |

Fetching was already appropriate and is unchanged. `@Query` drives the library lists;
project lists derive from relationships, and metadata filtering stays in the views. Cost
snapshots are computed in `.task`, not in the view body. Long-running work (imports,
transcription, chat, project deletion's cancel-and-await) was already library-owned.

### Changes

- Dependency flow is now View → presentation model → existing repository → SwiftData.
  Views still construct the lightweight `SwiftData…Repository` adapters from their
  environment `modelContext`. That is the existing injection convention (`using:` parameters,
  also used by summary generation and existing tests); there is one computed property per
  view. No new repository architecture or DI framework was added.
- `LibraryViewModel` gains `prompt: LibraryPrompt?` (rename recording, delete recording,
  delete project), `renameText`, `error: LibraryError?` (import / workspace kinds with
  titles), `isDeletingProject`, `importFiles(_:to:context:)`, `move`, `moveRecordings`,
  `saveProject`, `urlsToReveal`, and `confirm…` methods. `importError`/`workspaceError`
  strings were replaced by the single typed `error`.
- New `ProjectWorkspaceViewModel` (per-workspace view state only): `prompt` (delete
  recording/source, rename source), `sourceName`, `errorMessage`, plus source rename/delete
  and recording move. Recording deletion still goes through `LibraryViewModel.delete`, so
  library-owned models are released. It does not own imports, chat or processing.
- `SummaryViewModel.makeCurrent` / `deleteVersion` report failures in `historyError`.
  The history sheet and the main view each present it; the main view's alert is suppressed
  while the sheet is open.
- `UserFacingError` keeps AudioNotes' own editing messages (`ProjectEditingError`,
  `WorkspaceDeletionError`) and replaces SwiftData/file-system descriptions with a
  context-specific sentence (for example "The recording could not be moved. Try again.").
  Import failure text is unchanged.

### Alert architecture

Before: 10 independent `.alert`/`.confirmationDialog` modifiers (Library 4, project dialogs 1, workspace 4, summary history 1) across the three screens,
each bound to its own optional or string. After: one prompt alert plus one error alert in
`LibraryView` and in `ProjectWorkspaceView`, each driven by an `Identifiable` enum or error
value through `alert(_:isPresented:presenting:)`. Summary keeps its delete-version
`confirmationDialog` and adds an error alert.

Prompts and errors are deliberately separate states. Confirming an action clears the
prompt before the action can set an error, so dismissing the prompt never clears a newly
raised error. Destructive confirmations keep their titles, buttons and messages. Project
deletion still disables "Delete Recordings and Project" while recordings are busy.

### Behavior changes (intentional, failure paths only)

- Summary make-current/delete failures are now reported instead of being ignored.
- Technical persistence descriptions are replaced by understandable messages.
- A drop onto a project row no longer enqueues imports into a project that has just been
  deleted (the panel path already checked this).

### Tests

`PresentationBoundaryTests` (15 tests) covers:

- prompt state and dismissal;
- forwarding to the repository on confirm;
- failure → user-facing error without technical text;
- error replacement and dismissal;
- dropped-ID resolution and navigation;
- project create selection and domain messages;
- reveal reporting;
- project deletion that keeps recordings;
- ignored imports into a deleted project;
- workspace source rename/delete/move;
- summary history success and failure, with real SwiftData persistence.

`LibraryViewModelTests` was updated to the typed error.

### Validation (2026-10-02)

The full Debug suite passed: 404 tests in 74 suites, including the 15 new tests. The
Release build succeeded with no new warnings. `project.pbxproj` stays in the Xcode 16
format; Xcode 27 rewrote it again and that was reverted. A runtime check in the isolated
DEBUG fixtures (in-memory store, temporary files, mock providers) covered:

- library rename prompt: prefilled, saved;
- workspace delete prompt: message, Escape cancels;
- project delete prompt: both destructive choices, Cancel;
- project source rename;
- project source delete: Return does not trigger Delete, an explicit Delete removes it;
- summary history View → Make Current.

No new stderr output appeared. Persistence failure alerts were verified by unit tests,
not at runtime.

### Remaining presentation-boundary issues

- `ProjectWorkspaceView` still calls `queue.retry(source, in:context:)` directly. It is a
  library-owned service call, not persistence logic.
- `LibraryView` restores scene selection and selects DEBUG fixtures in `onAppear`.
- The cost `.task(id:)` key is rebuilt from all generation records on each body evaluation.
- Other views outside M14.1 scope still construct repositories inline: `ChatInspectorView`,
  `TranscriptHistoryView` and `RecordingDetailView`, which forward to their models.
- File › Export… is unavailable while focus is in the chat inspector (pre-existing).

## Future iOS readiness

Ready: SwiftUI views throughout, typed navigation, no SwiftUI/AppKit in services
except `PDFExporter`, and platform calls behind five small adapters that an iOS layer
would re-implement (`.fileImporter`/`UIDocumentPicker`, `UIPasteboard`, share sheet instead
of Finder reveal, `PDFView` from PDFKit on iOS, SwiftUI alerts).

Not ready: `PDFExporter` fonts/colors, `PDFPage.thumbnail` image type, `AVAudioPlayer`
session configuration, Local Whisper/Ollama assumptions, the Sparkle updater, and
macOS window scenes (`Settings`, information windows). None of this is in M14 scope.

## Validation

2026-10-01, Apple Silicon, Xcode 27, macOS 27, deployment target macOS 15.

| Check | Baseline (`a1bad0c`) | After |
| --- | --- | --- |
| Debug test suite | 389 tests / 73 suites passed | 389 tests / 73 suites passed |
| Release build | — | succeeded |
| New compiler/concurrency warnings | — | none (only Xcode's existing AppIntents metadata notice) |

One full-suite run failed `ProjectChatTests.retryReretrievesWithoutDuplicatingQuestionAndCancellationPersistsPartial`
on an interrupted-status expectation. That test does not touch any changed file. It
passed three isolated runs and the next full run. The test waits at most 1 s for a
streaming draft under parallel load, which makes it timing-sensitive. This is
pre-existing flakiness, recorded here rather than masked. Across the Phase A validation
it failed 2 of 6 full branch runs (both the cancel-time `.interrupted` status
expectation, with the test taking 9–13 s under load). The 3 latest consecutive full
runs passed, and 4 baseline full runs passed. The test exercises only
`ProjectChatViewModel`, which this change does not touch. It is not disabled. Address it
separately if it becomes reproducible.

No bundle identifier, signing, entitlement, Sparkle, appcast, schema or persistence
changes were made.

## Runtime smoke test (2026-10-01)

Launched the Debug build with `--performance-fixtures` (and `--performance-project-chat`).
In DEBUG these flags make `LibraryStartup` use an in-memory SwiftData store, and they make
`AppStorageLocations` use the temporary `AudioNotes-M11-Fixtures` root, with mock
providers. The production library is never opened. (An earlier draft of this document
wrongly said the opposite.) Preferences and Keychain are still the real ones, so Settings
was only viewed.

| Check | Result |
| --- | --- |
| Main window, Settings, menus, ⇧⌘N / ⌘O / ⌘E / ⌘W, Check for Updates… present | Pass |
| Help / Privacy / Licenses windows open; choosing again re-focuses without duplicates; Done, Return and ⌘W close; reopen after close | Pass |
| Export Diagnostics: panel, disclosure message, JSON written; save into a read-only folder shows the user-facing failure alert | Pass |
| ⌘O library import (audio-only filter, Import button) → managed copy in the temporary root | Pass |
| Project import (⌘O, "Import Files to …", Markdown accepted) and recording Add Sources | Pass |
| Export… save panel (Tags field, `.md` name) and written Markdown | Pass |
| Project Chat export: Markdown type, `.md` written (`net.daringfireball.markdown`) | Pass |
| Copy: message, code block, Settings › Copy Debug Logs; Czech text intact | Pass |
| Reveal in Finder (recording) and Reveal Data Folder (opens folder) | Pass |
| ChatGPT sign-in opens the default browser on the OpenAI authorization page (not completed) | Pass |
| Recording Chat and Project Chat: Shift+Return inserts a newline, Return sends | Pass after fix |
| PDF citation opens on the cited page (p. 23); after scrolling to p. 1, window resizes and focus changes do not jump back; re-opening the citation jumps again | Pass |
| Runtime console | Only an NSTableView reentrancy warning and a sandbox-extension message, both identical on the baseline build |

Regressions found and fixed during the smoke test:

- Shift+Return (see table above). The baseline was also broken: global modifier polling
  sent the message instead.
- `FilePanels` disabled the save-panel Tags field and renamed the Add Sources button,
  which AppKit's defaults (Tags shown, "Open") did not do. The adapter now leaves
  AppKit defaults alone unless a caller overrides them.

Not verifiable here:

- Gemini browser sign-in: this build has no `GoogleOAuth.json` and the account was
  already connected. It is covered only by the injected-opener unit tests.
- Citation to a *different* PDF page in the same viewer: the fixture has a single cited
  page, and each citation presents a new sheet.
- Whether SwiftUI actually called `updateNSView` during the resizes. The test shows no
  jump, not that the guard fired.

Observed but unrelated to M14: File › Export… is disabled while focus is in the chat
inspector. `.focusedValue` is scoped to the detail view, unchanged from the baseline.
Opening Settings refreshes the OpenAI model list with the configured key.

## Open acceptance

VoiceOver, full keyboard Tab order, Light Mode, window size extremes, Sparkle update
installation, and all open M11–M13 acceptance items remain open.

## M14.2 — Shared chat presentation

Recording Chat and Project Chat now share composed SwiftUI rows, list/scroll wiring,
composer, thinking/streaming, error and empty-state presentation. Their library-owned
models, context/retrieval, consent, citations/navigation and generation/usage engines
remain separate. See [the audit, duplication map and implementation report](UNIFIED_CHAT_UI.md).

The intentional new AppKit exception is
`Platform/macOS/AppKit/ChatTextEditorRepresentable.swift`: an NSTextView/NSScrollView
adapter limited to text, selection, keyboard/IME, focus and sizing. macOS 15 SwiftUI
selection APIs alone do not expose the marked-text state required to intercept Send
safely. Shift+Return now inserts at the cursor/selection; unmodified Return sends
outside composition. The outer UI and Markdown renderer remain SwiftUI. Proposal
measurement uses a separate text layout, and document sizing is controlled outside
drawing to avoid the large-paste/shrink hosting-constraint crash found during smoke tests.

Both scopes use retained ScrollPosition/ChatScrollState; following and Latest target
actual stable message IDs in the lazy history. The renderer's separate-block text
selection limitation remains. Schema, migration and release settings are unchanged.
Physical IME, VoiceOver narration, full-screen and live-provider acceptance remain
open; fixture/component checks do not close the older M11/M14 acceptance lists.
