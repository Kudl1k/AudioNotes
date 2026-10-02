# M14.2 — Unified Chat Presentation

## Initial audit (before implementation)

M14.1 is commit `9bd151d` (workspace actions), following platform isolation
`47aad6c`. The worktree was clean. Neither commit is amended.

| Area | Recording Chat before | Project Chat before | Classification / decision |
| --- | --- | --- | --- |
| Surface / model | ChatInspectorView / library-owned ChatViewModel | ProjectChatView / library-owned ProjectChatViewModel | DOMAIN-SPECIFIC: retain separate models and thin surfaces |
| Messages / persistence | ChatSession, ChatMessage, recording owner | Same models, exclusive project owner, pending/interrupted question IDs | DOMAIN-SPECIFIC: no schema or repository changes |
| Composer / keys | Vertical TextField, Return sends, Shift+Return appends | Same duplicated keys; suggestions fill draft | SHARED PRESENTATION: one cursor-aware composer; preserve distinct suggestion actions |
| Rows / copy / retry | Role header, details, interrupted badge, Copy, regenerate | Same controls, different padding and user alignment | SHARED PRESENTATION: shared row shell/actions; content supplied by each surface |
| Markdown | AssistantMessageView, off-actor block parsing, code Copy | Same renderer | SHARED PRESENTATION: preserve renderer |
| Citations | Revalidated transcript references and source chips; seek/source callbacks | ProjectCitation authority/unavailable groups; project navigation | RECORDING-SPECIFIC / PROJECT-SPECIFIC: compose existing content inside row |
| Streaming | Separate draft, first delta immediate, 80 ms coalescing | Same batching, cleans S aliases | SHARED PRESENTATION only; retain domain publishers/finalization |
| Thinking / elapsed | Immediate waiting state, existing elapsedSeconds timer | Immediate preparing state, retrieval then waiting, existing timer | SHARED PRESENTATION: one indicator with actual phase supplied by model |
| Cancellation / partial | Stops provider task, persists consumed partial with validated refs | Cancels/awaits retrieval/provider; partial without final citations | DOMAIN-SPECIFIC: unchanged semantics |
| Retry | Rebuild recording context, no new user message | Reretrieve current project evidence, reuse question ID | DOMAIN-SPECIFIC: closure-driven shared Retry control |
| Scrolling | Local ChatScrollState; near-bottom geometry + user phase | Same state machine, model-owned state and UUID anchor | SHARED PRESENTATION: one list wiring, preserve navigation state |
| Empty / suggestions | Ready-source guidance, recording prompts send directly | Coverage guidance, project prompts fill draft | SHARED PRESENTATION shell; scope-specific text/actions |
| Provider / model | Global Chat settings via resolver; provider description | Same settings, SettingsLink; external excerpt consent | DOMAIN-SPECIFIC controls/consent retained; no new pickers |
| Token / parameters / presets | Resolver chatSettings, output length/token ceiling/temperature/etc.; no chat preset picker | Same resolver settings, project budget reserve; no chat preset picker | DOMAIN-SPECIFIC: no generation settings changes or new preset UI |
| Usage / price | GenerationDetailsButton and UsageCostView(recordingID) | Same controls, UsageCostView(projectID) | SHARED PRESENTATION: details in row; existing Decimal repository calculations |
| Context / retrieval | Transcript/summary or selected ready-source context; recording lexical retrieval | Explicit project RetrievalService scope/selection, bounded history/BM25 | RECORDING-SPECIFIC / PROJECT-SPECIFIC: no engine merge; semantic foundation is not user-enabled |
| Errors | Useful provider messages, Retry and SettingsLink | Same actions; cancellation also exposes retry | SHARED PRESENTATION: shared error panel, original model messages |
| Lifetime / drafts | Library retains model/task/input; view-local scroll state | Library retains model/task/input/selection/scroll | DOMAIN-SPECIFIC ownership retained; recording scroll state moved to its model |
| Accessibility | Send/Stop/copy/citations, Escape cancellation | Similar controls, some implicit labels | SHARED PRESENTATION: consistent labels/IDs, no live announcement per token |

The known ProjectChat test polls for a first draft for at most one second, including
retrieval and scheduler load. Investigate observed failures; do not relax assertions.

## Implementation and validation

Results will be recorded here after implementation. Native/manual checks are distinct
from component tests. M14.3 is outside this work.

## Final presentation architecture

Both surfaces compose `ChatComposer`, `ChatMessageList`, `ChatMessageRow`,
`ChatActiveResponse` (shared thinking/streaming indicators), `ChatErrorView` and
`ChatEmptyState`. There is no generic chat engine, shared mega-view-model or new
presentation protocol. Each generic component has only one composed View parameter.
`ChatMessagePresentation` snapshots stable ID, role, generation ID and interrupted
state. Markdown and citation content remain composed by the surface, so the shared
row cannot resolve retrieval IDs or navigate sources. Rows share role headers,
backgrounds, Copy/context menu, Regenerate, interrupted badge and the existing
GenerationDetailsButton. Existing UsageCostView sheets retain their respective owners.

The recording adapter preserves transcript/source reference validation, legacy
citation cleanup and timestamp/source callbacks. The project adapter preserves
project provenance, current authority/unavailable chips, grouping and navigation.
Source selection, coverage, consent, headers, exports and suggestion behavior are
intentionally separate. No fake recording citation support or new provider UI was added.

The two library-owned models remain independent. Their changes are limited to
presentation identity, sent-turn notification, retained scroll position/intent,
actual-work labels and a cancelled-publisher guard. A generation allocates one
assistant UUID, reused by its final/interrupted message. The active lazy-list child
uses a namespaced identity (`active-<UUID>`) so it cannot collide with a persistent
row during finalization. One `ChatActiveResponse` changes from waiting into streaming;
it does not recreate identity on deltas. Direct ForEach children expose historical
row identity to the lazy container; persistent row content remains in small adapters.

## Composer decision and boundary

The outer composer is SwiftUI. The text input is `ChatTextEditorRepresentable` under
`Platform/macOS/AppKit`, containing only NSTextView/NSScrollView editing, selection,
key commands, focus requests and height measurement. It has no provider, retrieval,
usage or persistence dependencies. macOS 15 SwiftUI selection APIs were considered,
but an exposed selection alone does not provide the marked-text check needed for
IME-safe Send interception. Apple's text-input command/marked-text contract is the
basis for the small bridge:
[Intercepting Key Events](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/TextEditing/Tasks/InterceptKeys.html),
[NSTextView](https://developer.apple.com/documentation/appkit/nstextview).

Unmodified Return sends only meaningful text, only when allowed, outside marked
composition; held key repeats do not send repeatedly. Shift/Option/Command/Control
Return remain native commands. Shift+Return replaces the current selection with a
newline and leaves the caret immediately after it. Normal clipboard commands,
selection, arrow movement and undo belong to NSTextView. Tab/Shift+Tab traverse
controls. Escape delegates Stop while generating and lets the input context discard
marked composition. Send is also blocked while marked text is active. Validation
trims for eligibility; existing domain send normalization preserves internal formatting.

Sending keeps/restores editor focus through a request counter. Ordinary response or
usage updates do not request focus, replace equal editor text, or reset selection.
Project suggestions still fill/focus the draft; recording suggestions still send.
The editor remains writable during generation, while Send is replaced by Stop and
source selection stays disabled. It grows from 34 to 140 points, then scrolls internally.
A separate cached text layout measures SwiftUI proposals without resizing the displayed
container. The scroll adapter sizes its non-automatically-resizing document during
layout and reveals the caret after edits. This fixed a real large-paste → clear → resize
crash caused by NSTextView resizing during drawing and invalidating hosting constraints.

## Lists, Markdown, scrolling and streaming

One SwiftUI ScrollView/LazyVStack implementation serves both widths (readable maximum
760 points). The existing AssistantMessageView/MarkdownDocument/code/table renderer
is unchanged. Completed content still parses off actor on content changes with
cancellation protection. Continuous selection across separate Markdown blocks remains
a known limitation. Message Copy and code Copy are retained; no Copy-as-Markdown feature.

Each model retains a macOS 15 ScrollPosition and ChatScrollState across navigation.
One position mechanism replaces the competing UUID anchor / string bottom-marker
wiring. Following targets the stable active or latest message ID at its bottom,
not the estimated content edge of a large lazy history. The latter could land in a
blank estimated region after Latest. User send resumes following the new turn;
first-token/stream/final updates follow only when allowed. Tracking/interacting/
decelerating suppress jumps. Geometry also distinguishes upward user movement and
wheel/keyboard movement from content growth/resizing. Away from bottom, new content
sets unseen state and exposes Jump to Latest. Returning near bottom resumes following;
Latest explicitly resumes and navigates to the actual message target.

Both domain publishers keep their existing first-delta-immediate / 80 ms batching.
No new throttle, provider frequency assumption or per-token SwiftData write was added.
Thinking appears synchronously after accepted Send, using actual recording preparation,
project search, waiting or generation state, with existing elapsedSeconds timers.
No reasoning content is shown and no M14.3 timer architecture was started. Stop/Escape
cancel the existing underlying tasks. Partial content, final citations, retries and
usage finalization stay in the corresponding models/services. Project retry still
reretrieves current material and does not duplicate the user question.

## Flaky-test investigation

The known ProjectChat test reproduced under full parallel-suite load. Its one-second
poll was brittle, but deterministic observation alone exposed a production race:
a publisher cancelled during its 80 ms suspension could already be queued for the
UI actor. Without a post-suspension cancellation check it could publish the next
request's empty buffer. `streamingDraft != nil` then falsely signalled consumed text,
so cancellation correctly had no partial answer to persist. A synthetic diagnostic
showed the new user question as the last message, with no partial assistant row.

Both publishers now check cancellation after suspension before mutating presentation.
The Project test waits through Observation signals, requires the actual expected
consumed text, and uses a retained AsyncStream completion gate until cancellation.
All existing reretrieval, question-count, cancellation, partial-status, alias-cleanup
and generation-finalization assertions remain; assistant identity/text assertions
were added. An independently observed Recording test had a 500 ms mock-completion
race; it now uses the same signal/gate approach. One-minute test limits are failure
safeguards, not synchronization sleeps. Temporary diagnostics were removed.

## Provider, usage, persistence and accessibility

Provider/model/output length, safety token ceiling, temperature/top-P/reasoning
settings still come from the existing resolver and Settings. Neither initial chat
surface had a chat preset picker; none was invented. Provider capability/privacy/
Local Only/Ollama metadata gates and separate context engines are untouched.
OpenAI/Anthropic/Gemini/Ollama behavior remains whatever the existing resolver supports;
this pass does not make unavailable integrations available. Project semantic retrieval
remains an incomplete foundation, not a newly enabled feature.

Generation details and scope usage sheets retain factual provider tokens, Decimal
pricing snapshots and local/unknown billing classifications. This pass neither computes
prices in views nor invents usage for mocks/local inference. Existing history owners,
SwiftData models, migration plan, storage and release configuration are unchanged.

Stable shared identifiers include `chat.composer`, `chat.send`, `chat.stop`,
`chat.copy`, `chat.regenerate`, `chat.retry`, `chat.settings`, `chat.latest` and
`chat.thinking`. Labels describe actions/roles; existing source labels remain
accessible. No live announcement per token or new custom animation was added.
Native progress indicators retain platform behavior. Actual VoiceOver narration,
physical IME interaction and Reduce Motion desktop acceptance remain open.

## Fixtures, measurements and runtime acceptance

`--performance-fixtures --performance-project-chat --performance-chat-stress`
launches 500-message recording/project histories and a delayed, long, code/table-rich
mock answer. `--performance-light` forces only the fixture scene into Light Mode.
All additions are DEBUG-only, idempotent, use the established in-memory store and
separate temporary managed root, and create no generation/cost records on seeding.
No real library, cloud model, preference changes or credential-backed Settings refresh
were used for the smoke tests. Temporary native AX/keyboard/screenshot helpers lived
outside the repository and targeted only the explicitly launched fixture process.

| Check | Result / scope |
| --- | --- |
| Both composers: Return, cursor-aware Shift+Return, clear and continued typing | Passed native fixture checks |
| Marked composition blocks Return/Send; Escape routing | Automated native text-editor tests; physical IME still open |
| 10,800-character paste, bounded scrolling, clear/shrink/resize/retype | Passed after text-layout correction; visible text verified |
| Immediate waiting and streamed Markdown | Passed fixture checks with two-second initial mock delay |
| 500-message historical Markdown/code and lazy scrolling | Fixture exercised; component measurements below |
| Upward scrolling during output / Latest | Viewport stayed on earlier paragraphs across screenshots; Latest resumed at the active message; shared implementation |
| Stop, partial answer and Retry | Both Stop paths exercised; Project partial + successful Retry; domain regression tests retain exact semantics |
| Project citations / Copy / code Copy | Kernel Modules opened at 51:46; message text and code copied successfully |
| Light / Dark / narrow/normal windows | Fixture checks passed; complete full-screen/VoiceOver/live-provider matrix remains open |
| History, navigation ownership, citation authority, reretrieval, usage/pricing | Existing offline/domain/reopen tests; no claim of live billing acceptance |

Early component measurements: 100/500 presentation snapshots about 0.2/0.8–0.9 ms;
100/500-message Markdown preparation about 6–8/30–31 ms; 10K input layout about 4 ms.
Final measurement output is in the validation logs. Native fixture RSS observations
were roughly 109–180 MiB; process snapshots are not an Instruments memory plateau or
isolated renderer memory measurement. Idle snapshots reached 0% CPU; streaming snapshots
are influenced by fixture rendering and concurrent test/build load. There is no measured
before/after desktop launch, scrolling-hitch or sustained CPU comparison. Existing
Markdown and 80 ms batching were retained; no unmeasured renderer rewrite was justified.

## File inventory and validation

Created: four files under Features/Chat/Shared (`ChatComposer`, `ChatMessageList`,
`ChatMessageRow`, `ChatStatusView`), the platform `ChatTextEditorRepresentable`,
DEBUG `ChatPresentationFixtures`, `ChatPresentationTests`, and this report.
Modified: both chat surfaces/models, ChatScrollState, PerformanceFixtureLibrary,
ChatUXTests, ChatViewModelTests, ProjectChatTests, SWIFTUI_MIGRATION.md and ROADMAP.md.
The project file's accidental Xcode 27 object-version update is reverted to 77.

Ten new focused tests cover send validation/modifiers/repeat, cursor/selection
newlines, marked-text state, Escape, bounded pure height measurement, stable message
presentation, active scroll gestures, wheel/growth/resize intent, idempotent 500-row
fixtures with no generations, and 100/500-message preparation. Existing Recording
and Project tests additionally check stable assistant IDs; two cancellation tests
use deterministic synchronization with stronger assertions.

Final verification (2026-10-02): **414 tests in 75 suites passed twice**, in 13.270 s
and 13.366 s of test execution. Both were complete offline suites, including the known
Project cancellation/reretrieval test and Recording cancellation coverage. Ten new
presentation tests passed. Release macOS build succeeded. No new Swift warnings;
Xcode's existing AppIntents metadata-extraction warning remains (the app does not link
AppIntents). Git diff whitespace check passed. Models/schema/migration/storage and
bundle/signing/Sparkle/release workflows were not changed. `project.pbxproj` is restored
byte-for-byte to HEAD, with Xcode 16 `objectVersion = 77`.

Final component samples: 10K editor layout 4.30–4.39 ms; 100/500 presentation values
0.20–0.21/0.85–0.87 ms; 100-message Markdown preparation 12.5–13.1 ms. The 500-message
Markdown preparation took 240.5 ms in one loaded run and 48.2 ms in the next; earlier
isolated samples were about 30–31 ms. These are total component preparation timings,
not opening/scrolling/hitch measurements and not proof of a desktop speedup.

The implementation is ready to commit as a separate M14.2 change. Complete milestone
acceptance remains open for physical IME, VoiceOver narration, full-screen/Reduce Motion,
live providers/costs and production-history/performance checks. Existing renderer
cross-block selection and unmeasured desktop performance remain technical debt. No
M14.1 commit was altered; no M14.3 work was started.

## M14.4 — Chat accessibility and keyboard follow-up

Rows are announced "Your message" and "Assistant message" (the visible "You / AudioNotes" header is hidden
from VoiceOver to avoid repeating it). While an answer streams, the partial text is not exposed: one element,
"Assistant is working: <phase>" and then "Assistant is responding", and a single "Answer ready" announcement
at completion, so VoiceOver never rereads a growing response. Elapsed time is excluded from labels. Citation
chips read "Open citation, <authoritative label>" or "Citation unavailable, <label>"; the composer is
"Message" with the scope-specific placeholder as its placeholder value. Errors read "Error: …".

Escape stops generation only while the composer has focus (its `cancelOperation`, which discards marked text
first). The window-wide `.cancelAction` shortcut on Stop was removed because it stopped answers from unrelated
focus. File → Export… now stays enabled while the composer holds first responder (`focusedSceneValue`).
Verified in the isolated fixture; physical IME and VoiceOver remain open. See
[ACCESSIBILITY_AND_QA.md](ACCESSIBILITY_AND_QA.md).
