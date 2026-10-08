# iOS Project Sources and Chat (M16.6)

## Architecture audit

Project Chat reuses the existing shared `Project`, `RecordingSource`, `ChatSession`,
`ChatMessage`, and `GenerationRecord` models. The iOS workspace calls the same
library-owned `ProjectImportQueue`, `RetrievalService`, `ProjectChatViewModel`, and
`LLMProviderResolving` seam as macOS. Retrieval snapshots are scoped by project UUID,
include only member recordings and project-owned sources, then build the existing
in-memory lexical index off the SwiftData actor. Context assembly remains bounded by
the selected provider context window; the Project Chat budget reserves output, system
instructions, recent history, and evidence separately. No new embedding or cloud RAG
path was added.

`ProjectCitation` continues to store authoritative retrieval chunk, source, unit,
recording, locator, and content revision identity. Model-provided prose aliases are
resolved against the request package and a fresh project retrieval snapshot before
messages persist. Recording locators retain segment IDs and timestamp ranges; PDF
locators retain zero-based page indices. iOS displays one-based page labels and opens
the corresponding PDFKit page. Project Chat history, selected scope, generation usage,
retry, cancellation, and cloud excerpt consent use the existing shared persistence
and provider code. No SwiftData model or migration changed.

The iOS-only layer consists of `IOSProjectWorkspaceShell`, its source list and PDFKit
viewer, and the iOS Project Chat composition. It uses the M16.5 native segmented
workspace convention, shared M14 Markdown/message/composer/scroll components, and
`IOSFeatureProviders.llm`. The compact iPhone workspace uses three segmented
destinations; iPad keeps the existing library `NavigationSplitView` and uses its detail
column. Glass is limited to the Add controls and composer.

## Supported formats

| Format | iOS availability | Processing |
| --- | --- | --- |
| PDF | Yes | PDFKit native text extraction; Vision OCR fallback; zero-based page locators; native PDFKit viewer |
| PNG, JPEG, HEIC/HEIF | Yes | Vision OCR; local image viewer; source remains usable as local OCR evidence |
| TXT | Yes | UTF-8/UTF-16 text extraction and selectable text viewer |
| Markdown (`.md`, `.markdown`) | Yes | Text extraction and native app Markdown renderer |
| Audio | Yes, via Add to Project | Creates a project recording; transcription is user initiated; transcript segments enter shared retrieval |
| Word / PowerPoint | No | Not advertised; there is no document extraction implementation |

The file picker uses the shared `SourceImportService.supportedTypes` list. The native
UTType picker does not imply formats outside this table are processed.

## Import and storage

Multi-select Files imports enqueue into the library-owned serial `ProjectImportQueue`.
The shared queue copies each selected file into managed Application Support storage,
persists the source metadata, then invokes `NativeSourceProcessingService`. It reports
the current file and actual processor phase/unit counts. Audio follows the existing
audio import path and creates a recording without automatic transcription. Failures
are shown in plain language with retry where the source is retained. Rename changes
metadata; deletion stages and removes the managed copy with the existing rollback-aware
repository. URLs from Files are not retained as permanent dependencies.

PDF page boundaries and image OCR region locators are retained in `SourceTextUnit`.
Text/Markdown extraction retains source identity and section locators. No source text,
prompt payload, OAuth token, or API credential was added to logging. Cloud providers
receive the question, bounded conversation history, and retrieved excerpts after the
existing consent prompt. Existing local provider behavior remains local according to
its provider descriptor and privacy gates.

## iOS interactions

- Sources are native rows with type, page/size/OCR or processing state, open, rename,
  retry, and confirmed deletion actions.
- The PDF viewer uses `PDFView` through `UIViewRepresentable`. The coordinator changes
  document/page only when those values change, so unrelated SwiftUI updates do not
  reset the reading position.
- Markdown sources reuse `MarkdownMessageView`; plain text is selectable; images use
  the shared cost-limited local image loader.
- Project Chat uses shared streaming, Stop, retry, Markdown, copy, citations, history,
  usage tracking, and Markdown export via the iOS `ShareLink` flow.
- Audio citations select the correct recording, reveal the cited transcript segment,
  and seek to its original timestamp. PDF citations open the cited page. Text and image
  citations open the source without claiming line/region precision.
- Coverage reports searchable recordings/sources and warnings for untranscribed,
  processing, or failed material. Unready text is never added to retrieval context.

## Validation and remaining acceptance

Shared import, managed storage, source processing, retrieval, citation authority,
context limits, Project Chat persistence, cancellation/retry, provider selection,
and cost tracking have deterministic macOS unit tests. Final macOS validation passed
456 tests with 6 existing skips (462 total). iPhone 17e and iPad Pro 11-inch
Simulator runs each passed 50 tests, with no skips or failures. The new large-project
measurement test accounts for one additional test in each suite. Build and warning
results are recorded after the final compatibility pass below.

The DEBUG-only iOS fixture builds 20 recordings with 160 transcript segments, 30
project sources, and a persistent 250-message chat history. Sources are split evenly
among PDF, text/Markdown, and OCR image material. Citation and failure fixtures use
stable synthetic metadata; no provider or network request is made. The iPad visual
route uses the same fixture generator and the same final question, Markdown answer,
recording citation, and PDF citation, with an eight-message window sized for that
layout. iPhone screenshots retain all 250 messages; the large-history capture is not
used to claim that iPad scrolling is smooth.

The source-import fixture queue is seeded again when the production Sources view
appears, so the same `IOSProjectSourcesView` rows used during actual imports display
the review batch. The seven-item batch includes completed, processing, waiting, and
failed entries. Its processing card identifies item 2 of 7 and offers Cancel; rows are
flat native list content. Failed source rows show the shared `SourceImportError`
user-facing mapping and a visible Retry action. Unknown processing errors are mapped
to a general recovery message instead of exposing Cocoa/PDFKit/database descriptions.

Fresh captures for iPhone 17e, iPhone 17 Pro Max, and iPad Pro 11-inch (M5) are in
`docs/review/M16.6/`. They cover recordings, empty/populated sources, progress,
processing/failure, PDF/image/Markdown viewers, empty chat, recording and PDF
citations, mixed citations/history, and accessibility text size. Captures are static
render evidence; they do not establish native interaction or scrolling performance.

### Performance measurements

Measurements use a deterministic in-memory SwiftData fixture with 20 recordings, 160
transcript segments, 30 sources (10 PDF, 10 Markdown/text, 10 OCR image), 250 chat
messages, and 250 derived retrieval documents. Tests use no provider inference. The
environment is the Xcode 27.0 test runner on macOS 27.0.1 arm64 plus iPhone 17e and
iPad Pro 11-inch (M5) iOS 26.5 Simulators. Simulator timings are component timings,
not physical-device predictions.

The test samples project chat attach/presentation preparation five times. First attach
was approximately 30–36 ms; representative median was 6–8 ms. Mapping all 250 persisted
messages into `ChatMessagePresentation` was included. Markdown parsing of 125 short
assistant documents took about 1.0–1.2 ms in the test runner. This measures parser
preparation, not SwiftUI body evaluation, frame time, or native row rendering.

Retrieval searches the 250-document lexical index. Values below show first query and
five-sample median; selected chunk and estimated-token counts are from the assembled
context. The cold recording query was a 0.45–0.49 s outlier; its median was 34–44 ms.
Warm PDF, mixed, and irrelevant queries were about 17–21 ms. Context JSON serialization,
history budgeting, and provider prompt assembly took about 17–19 ms for the
representative iOS Simulator runs.

| Query | First / median retrieval | Indexed documents | Selected chunks | Context estimate | Provider prompt estimate | Provenance |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Recording-focused `copy_from_user` | 0.45–0.49 s / 34–44 ms | 250 | 11 | 1,901 tokens | 2,880 tokens | Recording source and original segment IDs/timestamp retained |
| PDF-focused page 23 query | 17–18 ms / 17–18 ms | 250 | 14 | 2,323 tokens | 2,990 tokens | PDF source ID and zero-based page 22 retained |
| Mixed recording/document query | 17–18 ms / 17–18 ms | 250 | 11 | 1,901 tokens | 2,880 tokens | Recording and PDF references both present |
| Irrelevant query | 18–21 ms / 18–21 ms | 250 | 0 | 0 tokens | 2,424 tokens (instructions/history only) | Empty evidence; no fabricated source |

Full-suite macOS timing was noisy under concurrent test load (the cold retrieval
queries rose to seconds), while isolated and iOS Simulator samples were substantially
lower. No architecture change was made from that noisy run. The lexical index considers
the full indexed document set; the implementation does not currently expose a separate
scored-candidate counter. No scroll-smoothness classification is made from static
images. The 250-message screenshot is iPhone-only; iPad uses the same final answer
window in its capture. A dedicated 250-message iPad scrolling pass remains unverified.

### Automated coverage and persistence

- `ProjectImportTests` exercise a multi-URL mixed batch, UTType/extension filtering,
  managed copies, serial queue insertion, unsupported-file reporting, cancellation,
  retry of the same managed source, and delete/cancel cleanup. `SourceWorkspaceImportTests`
  cover process/reopen state and managed-file behavior. No native picker tap is claimed.
- Project Chat tests verify strict recording/project scope, ready/processing/failed and
  untranscribed coverage, retrieval result correctness, context budgets, Local Only,
  and citation authority. The disk-reopen test now restores the assistant Markdown,
  recording/PDF citations, project selection, and interrupted question state.
- Citation-action intent tests separately assert recording UUID + timestamp, PDF source
  UUID + page index, and text/image source UUID. The intent feeds both macOS and iOS
  navigation paths. It does not claim that a Simulator citation was tapped.
- Unsupported source content is excluded from retrieval. Coverage distinguishes
  searchable content from processing, failed, and untranscribed items; those entries do
  not contribute to a Project Chat answer.

The iOS supported-source matrix is PDF, JPEG/PNG/HEIC/HEIF, UTF-8/UTF-16 TXT and
Markdown, and audio recordings. PDFKit extracts native text before Vision OCR fallback;
images use local Vision OCR; text documents use local section extraction. Managed
originals and extracted units persist using the shared import pipeline. Word and
PowerPoint are not supported.

### M16.6 acceptance and remaining limits

Review corrected both deterministic capture defects. The chat fixture now persists
explicit `ChatSession`/`ChatMessage` relationships and routes through
`ProjectChatViewModel.attach` and the production shared message/citation views. The
iPad route displays the same final question and mixed-citation answer as iPhone. The
progress route re-seeds queue state at Sources-view appearance and uses real import-row
presentation, including a mapped failure and visible retry state. There were no
network calls.

The supported formats, source viewers, processing/failure presentation, citations,
Light/Dark, iPhone/iPad, and Accessibility Extra Large screenshots were reviewed.
No additional screenshot-visible regression was found. Project list rows and ordinary
source rows remain native/flat; material is limited to existing controls and progress
container presentation.

Automated source and Project Chat behavior is covered. The native Files picker, touch
gestures/context menus, actual citation taps, PDF page jump, audio timestamp seek,
keyboard, and native scrolling smoothness remain **deferred manual acceptance** because
this environment does not provide device interaction. Static screenshot captures and
programmatic citation-intent tests are not substitutes for those interactions.
Physical iPhone/iPad, physical VoiceOver, live ChatGPT/Gemini, and production signing
remain deferred. These environment/release checks do not block M16.6 implementation
completion. No schema changes were made.

### Final regression and repository integrity

- macOS full suite: 462 tests in 82 suites, 456 passed and 6 expected skips; no failures.
- iPhone Simulator: 50 tests in 10 suites passed, no skips or failures.
- iPad Simulator: 50 tests in 10 suites passed, no skips or failures.
- AudioNotes macOS Release, AudioNotesiOS Debug Simulator, and AudioNotesiOS Release
  Simulator builds passed. No new Swift compiler warnings were found. Xcode's existing
  AppIntents metadata extraction diagnostic remains because the target has no AppIntents
  dependency.
- `git diff --check` passed. `objectVersion` remains 77. SwiftData schema and migration,
  signing, bundle identifiers, OAuth, Sparkle/appcast, and macOS Release configuration
  have no M16.6 changes. The Xcode project file is unchanged from HEAD.
- `a73f72f` contains M16.5 and M16.5.1. ROADMAP and milestone documentation now agree;
  no history was rewritten. M16.6 remains an uncommitted review candidate.

The final screenshot captures are under `docs/review/M16.6/`; test logs are in
`/tmp/m166-final-macos-rerun.log`, `/tmp/m166-final-iphone-tests.log`, and
`/tmp/m166-final-ipad-tests.log`.
