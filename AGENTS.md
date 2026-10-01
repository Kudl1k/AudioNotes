# AudioNotes — Codex Instructions

## Project

AudioNotes is a fully native macOS application for importing audio
recordings, transcribing them, generating AI summaries, chatting about
their contents, and exporting the results to Markdown or PDF.

The application must remain a native macOS application.

## Technology

- Swift 6
- SwiftUI
- macOS 15+
- SwiftData
- AVFoundation
- URLSession
- async/await and structured concurrency
- macOS Keychain for secrets

Avoid third-party dependencies unless there is a strong technical reason
to introduce one.

Do not use:
- Electron
- React Native
- Tauri
- WebViews for the primary UI
- Node.js/Python backend services

## Architecture

Use feature-based MVVM.

Main directories:

- App/
- Models/
- Services/
- Features/
- Utilities/

Keep views small.

Business logic must not live directly in SwiftUI views.

Prefer dependency injection through protocols instead of accessing
global singletons.

Do not create large "manager" classes containing unrelated functionality.

## Core models

The domain contains:

- Recording
- Transcript
- TranscriptSegment
- Summary
- ChatSession
- ChatMessage

A transcript is structured data, not just a String.

TranscriptSegment should support:

- start timestamp
- end timestamp
- text
- optional speaker

This is required so the UI can navigate from transcript/AI responses
to locations in the audio.

## Provider architecture

Transcription and LLM functionality MUST remain separate.

Use abstractions similar to:

    protocol TranscriptionProvider

    protocol LLMProvider

Provider IDs are stable persistence identifiers. Keep provider/model capabilities in provider-independent descriptors. Desired response detail is represented by OutputLength; maxOutputTokens is a separate provider safety ceiling.

Do not couple the application directly to OpenAI, Anthropic, Gemini,
or another provider.

Provider-specific implementations belong under Services/.

Example:

Services/
    Transcription/
        TranscriptionProvider.swift
        OpenAITranscriptionProvider.swift

    LLM/
        LLMProvider.swift
        OpenAILLMProvider.swift
        AnthropicLLMProvider.swift
        GeminiLLMProvider.swift

The selected transcription provider and selected LLM provider must be
independently configurable.

Future local providers, such as Whisper, must be possible without
changing the application architecture.

## Secrets

Never store API keys in:

- source code
- UserDefaults
- SwiftData
- plist files
- JSON configuration files

API keys must be stored in macOS Keychain.

Never log API keys.

## Networking

Use URLSession and async/await.

Provider networking should be isolated from UI code.

Network errors should be represented as typed errors and presented to
the user in a useful way.

Support cancellation where practical.

## Audio

Use AVFoundation.

Imported audio should be copied into the application's Application
Support directory.

The database should reference the managed copy rather than depending
on the original user-selected file.

Audio playback should support seeking to transcript timestamps.

## Persistence

Use SwiftData for metadata and application data.

Do not store large audio binaries inside SwiftData.

Audio files belong in Application Support.

Persist:

- recordings
- transcripts
- transcript segments
- summaries
- chats
- chat messages
- summary versions and generation metadata

## AI summaries

Summary generation should eventually support presets:

- General
- Meeting
- Lecture
- Interview
- Podcast
- Brainstorm
- Custom

Do not hard-code summary formatting into SwiftUI views.

Summary generation belongs in the LLM/service layer.

## Chat

Every recording can have a persistent chat.

Chat questions are answered using the recording transcript as context.

Design the architecture so that transcript retrieval/chunking can be
added later.

For the initial version, sending the complete transcript is acceptable
when it fits within the provider context limit.

Do not introduce a vector database during the initial implementation.

Assistant message content is clean Markdown, separate from structured transcript
references. Resolve references against the recording before persistence and display;
never derive clickable sources from prose or model timestamps. Render semantic
Markdown blocks natively, including partial streaming content. Legacy citation
cleanup is non-destructive and must preserve ordinary brackets and unrelated UUIDs.

## Export

Support:

- Markdown
- PDF

Both exporters should consume the same intermediate ExportContent model.

Do not independently construct completely different content for
Markdown and PDF.

Users should eventually be able to choose whether to include:

- summary
- key points
- action items
- transcript
- chat

## UI

Use native macOS SwiftUI controls.

Main application layout:

    NavigationSplitView

    Sidebar
        Recording library

    Content
        Recording detail
        Summary / Transcript

    Inspector
        Chat

Prefer standard macOS interaction patterns.

Support keyboard navigation where appropriate.

Avoid creating an iOS-looking interface on macOS.

## Concurrency

Use Swift structured concurrency.

Prefer:

- async/await
- Task
- actors where isolation is required

Avoid unnecessary DispatchQueue usage.

UI state updates must occur on the appropriate actor.

## Code quality

Before completing a task:

1. Build the project.
2. Fix compiler errors.
3. Run relevant tests.
4. Check for new warnings.
5. Remove temporary/debug code.
6. Summarize the changes made.

Do not silently change unrelated parts of the application.

Do not perform large architectural rewrites unless the current task
requires them.

When uncertain about an architectural decision, prefer the simplest
solution that preserves the architecture described here.

## Testing

Add unit tests for business logic and services where practical.

Important areas to test:

- audio importing
- persistence
- transcript transformations
- exporters
- provider request/response parsing
- error handling

Avoid tests that simply test SwiftUI implementation details.

## Development roadmap

The intended order is:

### Milestone 1 — Application foundation
- Native macOS project
- SwiftData models
- recording library
- audio import
- audio playback
- basic recording detail UI

### Milestone 2 — Transcription architecture
- TranscriptionProvider
- processing pipeline
- transcription state
- mock provider
- transcript UI

### Milestone 3 — First real transcription provider
- provider API integration
- Keychain credentials
- settings
- transcription progress/error handling

### Milestone 4 — Summaries
- LLMProvider
- summary generation
- summary presets

### Milestone 5 — Chat
- recording chat
- persistent chat history
- transcript context
- timestamp references where possible

### Milestone 6 — Export
- ExportContent
- Markdown export
- PDF export

### Milestone 7 — Multiple providers
- OpenAI
- Anthropic
- Gemini
- independent provider selection

### Milestone 8 — Long recordings
- transcript chunking
- retrieval
- hierarchical summarization
- OpenAI transcription splits sources above its 25 MB upload ceiling into temporary compressed M4A parts
- Transcription progress reports phase, completed audio duration, elapsed time, measured ETA, and cancellation

Milestone 8 work also covers officially documented account authentication where compatible with the macOS deployment target. Google Gemini OAuth uses a system-browser native-app flow and does not imply Gemini consumer-subscription billing. Secrets, including OAuth access and refresh tokens, belong in Keychain. Anthropic App Attest must not be implemented from reverse-engineering or copied CLI flows; verify current official support and OS requirements first.

Represent authentication methods and account connection state with typed provider-independent models. Snapshot the chosen method as non-secret generation metadata. Keep OAuth client IDs and cloud project IDs as developer configuration; never treat them as the user's API credentials.

Long-transcript chunks are derived from ordered `TranscriptSegment` snapshots, preserve original segment IDs/timestamps, and use modest overlap without duplicating transcript text in persistence. Retrieval belongs in services, not SwiftUI. Lexical retrieval is the privacy-friendly baseline. Approximate token counts are for context budgeting only. Hierarchical summary intermediates are internal work; persist one resulting summary version for the logical generation and retain the requested final `OutputLength`.

Transcription progress is provider-independent and must never fabricate within-request percentages. ETA is available only after measured part throughput. OpenAI split files are temporary and must be deleted after success, failure, or cancellation; merged segment timestamps are offset to the original recording. Active tasks are retained by the library while navigating, but are not resumable after app termination.

### Milestone 9 — Multi-source recordings
- RecordingSource relationships for audio, PDF, images, and text documents
- Managed originals, native PDFKit extraction, Vision OCR, local thumbnails
- Unified local retrieval, strict source selection, authoritative source citations
- Optional capability-gated image input, multi-source summaries, shared exports

### Milestone 10 — Local AI
- Ollama LLM provider, installed model discovery and capability-gated images
- Native WhisperKit local transcription and managed verified model downloads
- Local Only policy below SwiftUI, independent local/cloud provider selection
- Local execution metadata and no metered API charge classification

Local Only must gate provider execution, including preset overrides and each
hierarchical pass. Remote Ollama is an external server. Even localhost Ollama can
route cloud-backed models: verify model metadata before sending source content,
reject remote/cloud models and fail closed for unverified metadata. Never silently
switch models or fall back to cloud. Keep inference redirects and proxies out of
the localhost path.

WhisperKit is pinned and wrapped by LocalWhisperRunning. Inference must not download
models or tokenizers; preserve the offline tokenizer override. Download only pinned
trusted model data after an explicit user action, verify bytes/SHA-256, publish
ready state atomically, clean staging after failure/cancellation, and protect model
removal with an inference lease. Models live in managed Application Support, not
SwiftData. Whisper PCM inference windows are independent of cloud upload limits
and retrieval chunks. Offset segment timestamps to original audio, report only
measured completed audio, cancel decoding/future windows and release model memory.
The M10 implementation enables Local Whisper on Apple Silicon; Intel availability
must not be inferred from the SDK's deployment target.

Local billing and execution location are separate facts. Localhost Ollama and
Local Whisper display Local / No API charge; remote Ollama billing is unknown.
Keep factual usage, optional performance metrics, historical pricing and Decimal
money separate. Exports use readable model titles, never managed model paths.
See docs/LOCAL_AI.md for architecture, runtime rationale, validation and pending
manual acceptance. Do not start M11 as part of M10.

## Current development principle

Implement one milestone at a time.

Do not implement future milestones prematurely merely because they are
described in this document.

Keep the project compiling after every significant change.

## Usage and cost tracking (M8.3)

Keep factual usage, bundled versioned pricing and calculated cost separate. Money
uses Decimal and a currency code; never convert monetary calculations to Double.
Every logical generation persists request usage and the pricing snapshot used at
request start. Preserve historical snapshots when the catalog changes. Aggregate
all multipart/hierarchical requests and known retry usage; unknown failed or
cancelled usage is unavailable, never zero. Account authentication alone does not
imply subscription coverage: only the implemented ChatGPT-plan path is separated
from metered API usage. Local preparation/retrieval has no cloud charge.

Cost totals come from UsageRepository, outside view bodies. Sum full precision
before MoneyFormatter formats it. Unknown/legacy costs remain unavailable and
partial totals must identify unavailable entries. Pricing sources and verification
dates are developer metadata; updates ship with the app, without runtime scraping.
Do not backdate current rates to old records or store credentials in usage records.
Deleting a recording cascades its generation/cost history. See docs/USAGE_COST.md
for the bundled catalog, validation and remaining live/manual acceptance.


## Multi-source workspaces (M9)

Recording retains its legacy primary audio fields and transcript. Additional sources
are related RecordingSource models; never move legacy audio or rewrite historical
summaries, chats, generation usage, or pricing snapshots during migration. Additive
SwiftData schema changes plus SourceCompatibilityMigration provide an idempotent
primary-audio backfill. Original files live in managed Application Support storage.
PDF/image/text sources must not execute scripts, macros, embedded files, or actions.

Supported source imports are audio, PDF, JPEG/PNG/HEIC/HEIF, and UTF-8/UTF-16 TXT or
Markdown. SourceTextUnit persists extracted pages, document sections, and OCR regions
once, with nativeText/ocr/transcript provenance. PDF locators store zero-based indices;
labels show one-based page numbers. Native PDF text precedes Vision OCR fallback.
Vision language selection is limited to languages supported on the installed OS;
Czech and English are preferred when available. OCR is fallible. A valid text-free
image can be ready for explicitly authorized visual context; an unusable document
must not be marked ready. Processing runs outside views with real phase/unit progress,
elapsed time, cancellation, and recoverable failure; no fabricated ETA.

SourceChunk values are derived locally from source/segment snapshots, using stable
chunk IDs and typed audio/page/section/image locators. RecordingContextRetriever ranks
lexical relevance with deterministic source diversity and a hard context budget.
Source selection defaults to all ready sources and must also exclude previous answers
that used deselected sources. Do not add cloud embeddings or automatically upload PDFs.

LLMs return stable chunk IDs in structured fields. SourceReferenceResolver derives
all labels/locations/excerpts from recording-scoped source metadata and rejects invalid,
cross-recording, deleted, and duplicate IDs before persistence/display/export. Existing
TranscriptReference remains supported. Never derive a clickable location from prose or
model page/timestamp numbers. Group image OCR regions into one displayed image chip;
retain all region references in persistence. PDF page/document section groups follow the
same principle. Source navigation uses native PDFKit/image/text/audio views.

Imported source content is untrusted data, JSON-escaped in user-role context messages;
grounding/privacy instructions remain separate. Image understanding is distinct from
local OCR. Actual image input requires explicit upload permission, selected ready sources,
relevance, and an implemented provider/model capability descriptor. HEIC originals stay
local; optional request images are resized JPEG derivatives. Application limits are two
images per request and 5 MB per encoded image. Unknown models default to text input only.
Metered image input uses actual provider-reported input tokens within the existing request
cost tracker, never a generic per-image fee. Local extraction/OCR/search/thumbnails create
no cloud charge. Multi-source hierarchy persists one final summary and aggregates all
internal request usage with the requested final OutputLength.

See docs/MULTI_SOURCE.md for implementation details, migration coverage, supported
formats, official capability sources, and remaining live/native acceptance.

## UI stability and native polish (M11 — retained quality rules)

M11 is a quality milestone. Add no providers, source types, or major workflows.
Use deterministic offline performance fixtures and measure before changing architecture.
Keep `docs/UI_PERFORMANCE.md` honest about component benchmarks versus desktop acceptance.
M11 is not complete until its remaining native/manual acceptance checklist is verified.

Eligibility checks must use RecordingContextAvailability, not build retrieval context
from View.body or composer validation. Copy SwiftData values on their owning actor;
derive source chunks from Sendable input off that actor. Preserve stable chunk IDs,
original segment IDs/timestamps, strict source selection, and authoritative references.
Export can share one recording-scoped SourceReferenceIndex across its messages.

The library owns transcription, source, summary, and chat models while navigating.
Keep chat drafts and selections with the recording. View-owned search/Markdown tasks
must reject cancelled or superseded results. Chat scrolling follows user intent;
response growth alone must not disable following, and upward scrolling must not be
forced back down. Jump to Latest resumes following. Keep the existing stream batching.

Completed Markdown blocks are parsed on content changes outside the UI actor.
Citation cleanup lazily reads authoritative IDs only when UUIDs exist in prose;
ordinary brackets and unrelated UUIDs remain intact. Thumbnails load asynchronously
through the library's shared, cost-limited cache, keyed by file revision and size.
Exports snapshot shared ExportContent, render off actor, check cancellation before
atomic writing, and check PDF cancellation between pagination/rendered pages.

Development fixture launch flags and the fixture window are DEBUG-only. They use an
in-memory store, a separate temporary managed-file root, and mock providers. Never
seed a real library or run metered AI to benchmark. Instruments may include process
environment metadata: run profiling with a cleared environment and keep private
content and credentials out of diagnostics. Signposts contain static operation names.


## Projects foundation (M12.1 — implementation; manual acceptance pending)

M12.1 is explicitly authorized while the remaining M11 desktop acceptance stays open.
Project has a stable UUID, name, optional plain description, dates, recordings and shared
sources. Recording.project is optional single-project membership; standalone recordings
remain valid. Moves/renames change metadata only. Never create fake recordings for project
documents or move existing recording-owned sources into project ownership.

RecordingSource is reused with separate optional recording/project relationships. Import
and editing services assign one owner. Project sources use the existing local PDFKit,
Vision, text extraction, thumbnails, SourceTextUnit and SourceChunk derivation. Managed
sources stay under Sources/<source UUID>, independent of project names; primary recording
audio stays under Recordings. No new cloud processing or generation/cost records on import.

ProjectImportQueue is library-owned and serial across projects in that library/window.
Classification prefers native UTType, with extension-derived UTType only if unavailable.
Mixed-batch errors preserve successful items. Audio creates one Recording per file without
automatic transcription; document/image imports create project-owned sources. Extraction
failure/cancellation retains managed originals for retry. The queue survives navigation,
not app termination. Cancel and await project work, block new enqueueing during deletion,
then stage managed files before committing metadata deletion. Keep Recordings nullifies
membership and preserves the entire recording graph/files; explicit Delete Recordings
cascades their history and files after active recording work finishes.

LibraryDestination supplies typed UUID navigation and compatible M11 scene restoration.
Project workspace has Overview/Recordings/Sources and title/filename filtering only.
Project shared sources never enter recording AI context or recording exports implicitly.
Chunks remain derived Sendable values with source/unit IDs and typed original locations;
future project retrieval must resolve project membership and recording/source authority.
Do not implement Project Chat, summaries, embeddings, semantic retrieval or M12.2 here.
See docs/PROJECTS.md for migration tests, file inventory, decisions and open acceptance.

## Project retrieval (M12.2 — implementation; desktop acceptance pending)

M12.2 is explicitly authorized without closing M11/M12.1 manual acceptance. RetrievalScope
uses stable recording/project UUIDs. Library-owned RetrievalService snapshots only current
scope membership, transcripts and eligible extracted sources on the owning actor; the
ContextRetriever actor builds/searches disposable local indexes off the UI actor. Recording
scope and normal Recording Chat never include project shared sources or other recordings.
Project scope includes its current recordings' transcript/attachments and project sources.
No Project Chat, generation, summaries, embeddings or M12.3 workflow belongs in this pass.

RetrievalDocument preserves source/recording/project IDs, original segment/unit IDs, typed
locators, original text, readable labels and content revision. Coherent audio windows target
3,200 characters/90 seconds with one-segment overlap; oversized segments retain original
full timestamps. PDF/OCR page/image boundaries and document heading sections remain
trusted. Stable versioned retrieval IDs are distinct from legacy recording citation IDs;
never migrate historical citations to the new windows implicitly.

LexicalIndex is independent local BM25 with Unicode/Czech accent folding and intact
technical identifiers, bounded phrase/title signals, deterministic ordering and modest
source diversity. ContextAssembler applies a hard serialized-data token estimate budget,
suppresses heavy audio overlap and optionally includes bounded transcript neighbors.
ContextPackage stays structured; serialize escaped JSON as untrusted user-role DATA with
separate grounding instructions. RetrievalReferenceIndex checks explicit scope/selection
against freshly authoritative documents; never derive citations from model prose.

Fresh snapshots detect membership, deletion, transcript replacement and extraction edits.
Reuse unchanged per-source documents; rebuild only the affected scope's index on meaningful
change, lazily at query time. Cache at most three scopes with a 48 MiB authoritative-text
hint, not a total memory cap. Superseded/cancelled requests cannot publish. Project deletion
blocks new queries, cancels/awaits work and discards derived state. Indexes are in memory,
rebuildable after eviction/recreation; no persisted cache/schema or generation/cost records.
Indexing/search has no provider/network dependency and works under Local Only. Keep logs
and static signposts free of source/query content. See docs/PROJECT_RETRIEVAL.md for exact
strategy, file inventory, measurements, regression coverage and open desktop acceptance.

## Project Chat (M12.3 — implementation; desktop/live acceptance pending)

Project Chat reuses ChatSession/ChatMessage with exclusive optional project ownership;
Recording Chat remains recording-owned and recording-scoped. Project cascades its chat
and generation records while keep-recordings deletion preserves recording histories.
GenerationRecord has optional recordingID and separate projectID/project ownership; never
attribute project usage to an arbitrary recording. Reuse Decimal pricing/request tracking.

Every project send/retry/regeneration uses the library-owned RetrievalService with
RetrievalScope.project and explicit selected source IDs. Selecting a recording includes
its transcript/attachments; shared sources require project authority. Persist session
selection; exclude previous assistant answers whose context falls outside current scope.
Never concatenate project contents. Reserve system/current question/output/evidence space,
truncate recent history deterministically, and validate the assembled prompt estimate.
Follow-ups use bounded previous user questions locally; no hidden paid rewriting calls.

ProjectChatPrompt uses separate grounding instructions and escaped user-role JSON DATA.
Only retrieved excerpts/readable labels/request S1 aliases reach providers; no managed
paths, stable project IDs, scores, originals or unrelated content. Project grounding is
explicit; empty evidence does not add arbitrary fallback chunks. External-provider consent
covers relevant excerpts/history; existing runtime PrivacyLLMProvider/Ollama metadata gates
remain authoritative under Local Only. Project image context is local OCR text only.

Resolve aliases against supplied ContextPackage entries and a fresh project-scoped
RetrievalReferenceIndex before saving. Persist trusted ProjectCitation provenance separately
from clean Markdown, using original segment/unit IDs and revision. Never trust prose-derived
locations. Historical answers survive deletion/moves; unavailable citations cannot navigate
outside current original-project authority. Current readable labels may update without
rewriting history. Reuse native recording/PDF/image/text navigation and shared source groups.

The library owns project chat models/tasks/drafts/scroll intent across navigation. Reuse
80 ms stream coalescing, lazy rows, off-actor Markdown and ChatScrollState. Persist user
questions before work, final/interrupted prose at boundaries, never per token. Cancel
retrieval/provider/stream; project deletion cancels and awaits chat. Pending questions recover
as interrupted on restart with Retry, never a restored spinner. Markdown chat export uses
shared ExportContent/NativeExportService. DEBUG project-chat fixtures are isolated and mock-only.
See docs/PROJECT_CHAT.md for inventory, measurements, limitations and open acceptance.
Do not start M12.4 as part of this pass.

## Local semantic retrieval (M12.3.5 — foundation only; incomplete)

BM25 remains the default and reliable fallback. `EmbeddingProvider` is a
provider-independent injection seam, and semantic retrieval accepts providers
that explicitly declare local execution only. The disposable in-memory
`SemanticIndex` uses normalized cosine similarity over the exact M12.2
`RetrievalDocument` chunks; `RetrievalRankFusion` uses deterministic RRF
(constant 60) without adding BM25 and cosine scores. Semantic errors fall back
to lexical results. No production embedding provider/model, model management,
persistent vector store, setting, or Project Chat semantic enablement is
implemented yet. Do not describe semantic search as available to users until
those pieces and their privacy/quality acceptance are complete. See
`docs/SEMANTIC_RETRIEVAL.md`.


## Existing recording drag to projects

Recent Recording and All Recordings rows carry a private Transferable containing
only a stable recording UUID. Declare its exported UTI in the app Info.plist so
NSPasteboard can instantiate it. Project sidebar rows and the current project workspace
accept that type alongside existing file URL imports. Resolve dropped UUIDs against
the library's current recording list, then move each through SwiftDataProjectRepository;
never reimport/copy audio or recreate history. Preserve active recording tasks. Show
drop hover feedback. Menu-based Move to Project remains available. Native drag/drop
acceptance is still required.

## SwiftUI-first UI (M14 — first pass; desktop acceptance pending)

SwiftUI is the default UI technology. AppKit belongs in `Platform/macOS/AppKit` behind
small intent-named adapters (`FilePanels`, `Clipboard`, `Workspace`, `Alerts`,
`PDFPreviewRepresentable`); features and services must not import AppKit. `PDFExporter`
is the documented exception. Representables keep logic outside and guard state sync in
a coordinator. Keep the SwiftUI transcript and Markdown renderers unless a measured
benchmark justifies change. Do not move SwiftData models across modules while v1
migration guarantees depend on them. See docs/SWIFTUI_MIGRATION.md. Do not start iOS.
