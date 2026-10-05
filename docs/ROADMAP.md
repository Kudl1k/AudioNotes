# AudioNotes Roadmap

## v0.1 — MVP

Goal: import a recording and turn it into useful AI notes.

### M1 — Foundation
- [x] Create macOS project
- [x] SwiftData models
- [x] Library UI
- [x] Audio import
- [x] Audio playback

### M2 — Transcription
- [x] TranscriptionProvider protocol
- [x] Mock transcription provider
- [x] Processing state machine
- [x] Transcript persistence
- [x] Transcript UI
- [x] Click timestamp to seek audio

M2 introduced a clearly labeled mock provider. See [transcription architecture](TRANSCRIPTION.md). Local Whisper is also a planned transcription provider option; the interface supports local and remote implementations independently of LLM selection.

### M3 — OpenAI transcription
- [x] Keychain service (credential abstraction tested offline)
- [x] Provider settings
- [x] OpenAI transcription API implementation (`whisper-1`, segment timestamps)
- [x] Upload/transcription activity (indeterminate; no fabricated percentages)
- [x] Phase-aware processing UI, elapsed time, measured multi-part progress/ETA, cancellation, and library status
- [x] Split OpenAI audio sources above 25 MB into temporary compressed M4A requests and restore original segment timestamps
- [x] Error handling
- [x] Retry with current provider configuration
- [x] Offline HTTP/cancellation tests and macOS build
- [ ] Live OpenAI transcription with a manually configured API key
- [ ] Complete manual workflow, including Keychain and transcript persistence across relaunch

Implementation is ready; a live request returned HTTP 429. Successful live transcription and manual acceptance remain pending. See [M3 verification and limitations](OPENAI_TRANSCRIPTION.md).

Oversized OpenAI uploads are split locally into temporary M4A parts. Progress within each API request remains indeterminate; overall progress and ETA use completed part audio durations. Retry currently starts the full operation again, and active jobs are not restored after app termination.

### M3.5 — Sign in with ChatGPT (Token Sharing & ChatGPT Plan Inference)
- [x] OIDC authorization code flow with PKCE (RFC 7636 S256, cryptographically random state & nonce)
- [x] Stable host identifier (`urn:uuid:...`) persisted locally for installation identity
- [x] Ephemeral local loopback listener on IPv4 `127.0.0.1` with styled local HTML response page
- [x] Out-of-app authorization opened in default system browser (`NSWorkspace`)
- [x] Dynamic client registration support (`dynamic_agent_client` initial registration + persistent issued client ID)
- [x] ID token verification (issuer `https://auth.openai.com`, audience, expiration, nonce, JWKS RSA signature verification)
- [x] Secure Keychain storage for sensitive tokens (access token, refresh token, retained ID token)
- [x] Automatic token refresh before expiration with terminal error handling (`ChatGPTTokenRefresher`)
- [x] ChatGPT Responses API client (`POST /v1/responses`, SSE stream parser with `store: false`)
- [x] `ChatGPTPlanLLMProvider` integrated into LLM provider resolution
- [x] Distinct error mapping for plan usage limits (`subscription_sharing_usage_limit_exceeded`, `subscription_sharing_usage_unavailable`)
- [x] Settings UI for ChatGPT connection status, sign-in, disconnect, manage usage, and authentication method selection (ChatGPT Plan vs API Key)
- [x] Strict billing isolation: Audio transcription remains on API key authentication; ChatGPT OAuth is restricted to LLM inference
- [x] 16 unit tests covering PKCE, host ID, token verification, token refresh, LLM provider resolution, Responses SSE parsing, and Settings VM

### M4 — AI summaries
- [x] LLMProvider protocol & provider resolver (`MockLLMProvider`, `OpenAILLMProvider`, `ChatGPTPlanLLMProvider`)
- [x] OpenAI Structured Outputs with strict JSON schema (`gpt-4o-mini`, `gpt-4o`)
- [x] Summary domain model & SwiftData atomic persistence
- [x] Summary presets (`General`, `Meeting`, `Lecture`, `Interview`, `Podcast`, `Brainstorm`, `Custom`)
- [x] Prompt builder with context limit enforcement (>100k tokens) & timestamped grounding
- [x] Summary UI with structured sections & clickable timestamps seeking audio playback
- [x] Non-destructive regeneration preserving existing summaries on failure or cancellation
- [x] Provider settings for Summaries sharing the OpenAI Keychain credential or ChatGPT Plan
- [x] Comprehensive offline unit test suite (81 passing tests across 23 suites)

### M5 — Chat With Recording
- [x] ChatSession & ChatMessage SwiftData persistent models with `@Relationship` on `Recording`, cascade deletion, ordering, and status (`inProgress`, `completed`, `interrupted`, `failed`)
- [x] Structured transcript references (`TranscriptReference`) linking answer segments to authoritative timestamps and speakers with click-to-seek audio integration
- [x] Dedicated prompt builder (`ChatContextBuilder`) enforcing strict grounding, context token budgeting (>100k tokens), and explicit separation between authoritative transcript and supplementary derivative summary
- [x] Authoritative reference resolver (`TranscriptReferenceResolver`) validating model segment IDs against stored transcript segments, ignoring hallucinations, and deriving exact playback timestamps
- [x] LLM streaming abstraction on `LLMProvider` (`streamChat(messages:context:)`), implemented across `MockLLMProvider`, `OpenAILLMProvider`, and `ChatGPTPlanLLMProvider`
- [x] Incremental streaming JSON answer parser (`StreamingJSONAnswerParser`) handling chunked SSE responses and JSON deltas
- [x] SwiftData repository (`SwiftDataChatRepository` / `ChatStoring`) ensuring isolated conversational history per recording
- [x] Transient UI streaming drafts avoiding high-frequency SwiftData writes during generation
- [x] Non-blocking, interruptible generation (`stopGeneration`) preserving partial answers marked as `interrupted`
- [x] Collapsible inspector sidebar (`ChatInspectorView`) in `RecordingDetailView` with suggested prompts, transcript reference chips, retry, and clear chat confirmation
- [x] Provider settings supporting independent chat model selection for OpenAI API key and ChatGPT Plan
- [x] 16 dedicated unit tests across 4 test suites (`ChatStreamingParserTests`, `TranscriptReferenceResolverTests`, `ChatContextBuilderTests`, `ChatViewModelTests`), bringing the total test suite to 104 passing tests across 27 suites with 0 failures

### M6 — Export, Presets & Chat Polish
- [x] **AI Generation Configuration & Capabilities**:
  - Provider-independent model capabilities descriptor (`LLMModelCapabilities`) supporting temperature, top_p, penalties, reasoning effort, token limits, and JSON schemas
  - Strongly-typed generation settings (`LLMGenerationSettings`) with capability-based validation and clamping
  - Capability-aware parameter sanitization in OpenAI clients (e.g. omitting temperature/top_p on reasoning models such as `o1` and `o3-mini`)
  - Advanced generation settings controls in Provider Settings
- [x] **Saved AI Presets**:
  - Dedicated SwiftData persistent model (`AIPreset`) for custom summary and chat configurations without storing secrets
  - Repository (`AIPresetRepository` / `AIPresetStoring`) for CRUD and duplicate operations
  - Preset management UI (`PresetsManagementView` & `PresetEditorView`)
  - Preset picker integrated directly into `SummaryView` with user presets and "Save as Preset…" quick-save action
- [x] **Chat UX & Generation State Polish**:
  - Explicit generation lifecycle (`ChatGenerationState` with `preparing`, `waitingForFirstToken`, `streaming`, `completed`, `cancelled`, `failed`)
  - Clear thinking feedback bubble with live elapsed counter (`0:01`, `0:02`, etc.) while waiting for first token
  - Immediate stop capability before first token arrives without leaving orphaned empty messages
  - Multiline composer with Shift+Return support and message actions (Copy text, Regenerate assistant response)
  - Formatted transcript reference pills linking directly to audio playback timestamps
  - Non-destructive error state retaining chat history and offering one-click retry
- [x] **Export Architecture (Markdown & Native PDF)**:
  - Canonical intermediate export representation (`ExportContentBuilder` & `ExportOptions`)
  - Markdown exporter (`MarkdownExporter`) with optional YAML front-matter, metadata, key points, checklist action items, speaker timestamps, and chat transcripts
  - Local macOS PDF exporter (`PDFExporter`) using native `CoreText` and `CGContext` pagination without web engines or remote dependencies
  - Modal export sheet (`ExportSheetView`) with options toggles, format selection, and native `NSSavePanel` integration (`⌘E` shortcut)
- [x] 17 new unit tests across 4 suites (`LLMModelCapabilitiesTests`, `AIPresetTests`, `ChatUXTests`, `ExportTests`), bringing the total test suite to **121 passing unit tests across 31 suites with 0 failures**

## v0.2

- [ ] Claude provider (M7 work started; API implementation and credential UX pending)
- [ ] Gemini provider (M7 work started; API implementation and credential UX pending)
- [ ] Output length separate from max output tokens
- [ ] Generation records and usage metadata
- [ ] Summary version history and restore/delete UI
- [ ] Global generation history
- [ ] Provider/model capability-driven settings
- [ ] Speaker support
- [ ] Transcript search
- [ ] Custom summary prompts
- [ ] Better long-recording support

## v0.3

- [ ] Local transcription
- [ ] Whisper
- [ ] Local/private workflow

## M8 — Long recordings and provider authentication (in progress)

- [x] Segment-boundary transcript chunks with modest source-segment overlap and stable segment provenance
- [x] Approximate provider-independent token estimator for context sizing only
- [x] Deterministic lexical retrieval strategy and conversational follow-up query builder
- [x] Long-chat context selection before prompt construction; short recordings retain the full-transcript path
- [x] Native in-recording transcript search with timestamp/speaker excerpts
- [x] Hierarchical summary service with concise intermediate passes, final synthesis at the requested OutputLength, cancellation checks, and visible section progress
- [x] GenerationRecord records whether a summary used single-pass or hierarchical processing and its logical chunk count
- [x] Google desktop OAuth authorization-code flow using system browser, loopback callback, state, PKCE, refresh token, and Keychain storage
- [ ] Gemini provider consumes Google OAuth and API-key credentials; Google OAuth integration tests and end-to-end generation
- [ ] Provider-independent authentication selection/account state across feature settings
- [ ] Anthropic native authentication (only if Anthropic documents a supported route compatible with macOS 15)
- [ ] Generation usage aggregation for hierarchical intermediate requests
- [ ] Large transcript and long-summary manual verification
- [ ] M8 full test, migration, export, and security verification

### Authentication and privacy notes

Google OAuth is an API authorization flow for Gemini API access in the configured Google Cloud project; it does not grant use of a consumer Gemini plan for API billing. iOS uses the supplied platform-specific native OAuth client and registered reversed-client-ID callback scheme; macOS retains its Desktop client, system browser and loopback IP redirect. The iOS client ID/scheme are public OAuth configuration in the iOS Info.plist; no client secret is embedded. The app requests OpenID email plus the documented Gemini API scope, validates `state`, uses PKCE where supported, and stores tokens in Keychain. Google may require test-user enrollment or verification depending on deployment. See [Gemini OAuth](https://ai.google.dev/gemini-api/docs/oauth), [Google OAuth native apps](https://developers.google.com/identity/protocols/oauth2/native-app), and [iOS Sign-In setup](https://developers.google.com/identity/sign-in/ios/start-integrating).

Anthropic officially documents App Attest for direct Claude API use by registered iOS/macOS apps; usage bills to the app developer's workspace and App Attest does not identify an end user. The documented Swift package that implements this flow currently requires macOS 27 beta and Xcode 27, while AudioNotes targets macOS 15. This milestone therefore does not implement App Attest until it can be done without violating the deployment target or inventing an undocumented token exchange. It does not emulate Claude Code/CLI sign-in, use undocumented OAuth clients, access browser data, or claim Claude Pro/Max billing. The Anthropic API-key field remains available independently. See [Anthropic authentication](https://platform.claude.com/docs/en/manage-claude/authentication), [Anthropic App Attest](https://platform.claude.com/docs/en/manage-claude/app-attest), and the [official Swift package requirements](https://github.com/anthropics/ClaudeForFoundationModels).

Transcript chunks are derived in memory from authoritative `TranscriptSegment` snapshots and are not persisted as duplicate transcript text. Lexical retrieval is local and deterministic; approximate token counts are used only for chunk and context budgeting. Provider usage, when later returned by a provider, remains the only source of reported token usage. No embedding provider or vector store is required; `EmbeddingProvider` is an optional future seam.


### M8.2 — Chat rendering and citation UX

- [x] Native semantic Markdown blocks with Foundation inline formatting; selectable text, aligned/nested lists, fenced code and code copying
- [x] Shared completed/streaming renderer with best-effort unfinished Markdown and code fences
- [x] Clean Markdown response boundary plus recording-scoped reference validation before persistence
- [x] Non-destructive legacy display/copy cleanup for known machine citation artifacts
- [x] Canonical zero-padded source timestamps, separate source chips, chronological deduplication, adjacent grouping and expansion
- [x] Czech regression fixture, Markdown/citation/timestamp tests, streaming integration and SwiftData reload coverage
- [ ] Live OpenAI/ChatGPT-plan chat and native desktop interaction/relaunch acceptance
- [ ] Claude/Gemini chat acceptance after their provider implementations exist

See [M8.2 implementation report](CHAT_RENDERING.md) for scope, validation and limitations.

### M8.3 — Usage & Cost Tracking

- [x] Decimal money/currency, adaptive formatting, provider-independent billing and calculation states
- [x] Central versioned bundled pricing catalog verified against current official OpenAI, Anthropic and Gemini documentation on September 30, 2026
- [x] Request-level pricing snapshots, factual token/audio usage and calculated historical costs persisted on GenerationRecord
- [x] Whisper pre-flight duration/part estimate, actual per-part processed/provider duration and one logical transcription cost
- [x] Summary token usage, all hierarchical intermediate calls, summary history cost and explicit-output-ceiling budget estimates for supported short summaries
- [x] Assistant generation association, response Details, recording chat totals, recording and library totals
- [x] Native Usage & Cost screen, local-calendar Today/Week/Month/All Time filters, provider breakdown and separate ChatGPT-plan request counts
- [x] Optional library costs, known/partial totals, opt-in shared Markdown/PDF generation metadata
- [x] Known retry charges retained in a logical operation when provider/model/authentication match; cancelled/unfinished requests remain unavailable when usage is missing
- [x] Offline full-recording workflow, SwiftData reopen/cascade, historical-price stability, Decimal, HTTP/SSE usage and hierarchy/retry tests
- [ ] Live credential-backed transcription, summaries, five chat questions and native UI/relaunch acceptance
- [ ] Migration acceptance against a separately archived pre-M8.3 production database

Claude/Gemini network providers remain outside this change; their verified baseline
catalog entries do not enable an unavailable provider. Unsupported models, billing
tiers or usage categories must show unavailable pricing rather than guessed prices.
No remote pricing fetch, FX conversion or new analytics service is introduced.
See [M8.3 implementation report](USAGE_COST.md) for exact coverage and limitations.

M8.3 automated validation: macOS build succeeded; **189 tests in 39 suites passed**,
including 32 new cost test functions. See the report for existing warnings and
pending live/manual acceptance.


## M9 — Multi-source recording workspaces

- [x] Additive RecordingSource / SourceTextUnit SwiftData architecture and idempotent primary-audio backfill
- [x] Existing audio/transcript/summary history/chat/transcript references/cost survive a frozen pre-M9 database migration fixture
- [x] Audio/PDF/JPEG/PNG/HEIC/HEIF/TXT/Markdown managed imports; multiple files, native picker and Sources drag/drop
- [x] Independent local processing state, actual phase/unit progress, elapsed time, cancellation, recoverable failure, retained library-owned tasks
- [x] Original files remain unchanged; streaming SHA-256 duplicate detection by content, limited to matching legacy source types
- [x] PDFKit page text with zero-based provenance, one-based labels, Vision fallback only when native text is unavailable, partial-page failures
- [x] Local Vision OCR with supported-language discovery, Czech/English preference, OCR regions/confidence, image dimensions, local thumbnails
- [x] UTF-8/UTF-16 text and Markdown section/range extraction; selectable native text preview
- [x] SourceChunk snapshots, deterministic unified lexical retrieval/search and strict context budgets
- [x] Compact chat/summary source selectors; excluded-source answers also excluded from subsequent AI history
- [x] Structured recording-scoped SourceReference validation and native audio/PDF/image/document navigation
- [x] Group image-region citations into one source chip; group page/section references and keep all underlying evidence
- [x] Explicit optional image upload; conservative model metadata; resized JPEG image parts for implemented OpenAI API and ChatGPT-plan paths
- [x] Multi-source single-pass/recursive hierarchical summaries using the existing generator/tracker; one final persisted version
- [x] JSON user-role source data plus separate grounding/injection rules; native PDF viewer blocks external/embedded actions
- [x] Existing Decimal pricing snapshots and aggregate costs include actual multimodal input usage; image counts visible in generation Details
- [x] Shared Markdown/native PDF Sources sections and readable validated citation labels
- [x] Offline migration/reopen/cascade, processing, retrieval, privacy, reference, multimodal-payload, hierarchy and export regression tests
- [ ] Live provider image/chat/summary acceptance with user-configured credentials
- [ ] Full native picker/drag/drop/navigation/removal/relaunch acceptance, including cold Vision startup on representative photos
- [ ] Migration acceptance against a separately archived production library

See [M9 implementation report](MULTI_SOURCE.md). Native OCR can have substantial first-use
initialization latency; it runs locally with elapsed/status feedback and cancellation.
Image upload is opt-in and OCR alone cannot understand diagram structure. DOCX/RTF/office
imports are not exposed in this milestone. Local-processing provider work belongs to M10.


M9 automated validation (September 30, 2026): isolated native build and **223 tests in
47 suites passed**. The final shared-workspace macOS build also succeeded and **248 tests
in 50 suites passed**, including concurrent feature work. Existing warnings were reviewed;
no new M9 Swift warnings. Live provider and full native/production-library acceptance
remain unchecked above.


## M10 — Local AI (implementation complete; manual acceptance pending)

- [x] Provider-independent local/remote/cloud execution metadata and independent provider choices
- [x] Ollama LLMProvider integration for native streaming chat, summaries and sequential hierarchy
- [x] Configurable server, exact loopback classification, connection test and dynamic installed-model discovery
- [x] Model metadata/context/vision checks; missing/cloud-backed/unverified models fail without fallback
- [x] Existing structured Markdown/source reference validation and M9 text/PDF/OCR/image context
- [x] Temperature/top-p/output ceiling/context mapping with full-prompt budget preflight
- [x] Native WhisperKit 1.1.0 runtime behind an injectable transcription protocol; Apple Silicon availability
- [x] Tiny/Base/Small/Medium/Large v3 Turbo catalog with immutable trusted URLs, exact bytes and SHA-256
- [x] Confirmed model download/removal, measured byte progress, disk-space check, staging cleanup and model leases
- [x] Local-only tokenizer loading; no automatic inference download, Python, Homebrew or backend
- [x] Bounded native PCM windows, original timestamp offsets, runtime languages, measured progress/smoothed ETA
- [x] Native cancellation, model unloading and no completed partial transcript persistence
- [x] Local Only enforced below views/resolvers, including preset overrides and hierarchy requests
- [x] Local/no-API-charge usage, optional performance details and persisted execution/model-title history
- [x] Native Tiny smoke: English, synthesized Czech, multiple inference windows, timestamp offsets, cancellation and removal
- [x] Native sandbox-to-localhost Ollama discovery check with the existing network entitlements
- [x] macOS build, full offline regression suite and warning review
- [ ] Successful live Ollama summary/chat/vision/hierarchy (inspected installed models have missing weight files)
- [ ] Completed >1 hour real transcription and representative Czech/English accuracy acceptance across model sizes
- [ ] Fully local network-disconnected recording/PDF/image workflow and desktop/relaunch/export acceptance
- [x] x86_64 macOS build with Local Whisper unavailable on Intel
- [ ] Intel unavailable-state interaction and archived production migration acceptance

See [M10 implementation report](LOCAL_AI.md) for created/modified files, official API
sources, model/runtime rationale, privacy and cost semantics, tests and limitations.
Tiny's Czech smoke output had spelling/diacritic errors; no universal accuracy claim
is made. Ollama is external and its model pull/marketplace UI is deferred. No M11
work was started. Only the completed functionality above is checked.

M10 automated validation: macOS target build succeeded; **262 tests in 52 suites**
passed, with opt-in native tests disabled in normal runs. Separate native Whisper
and sandboxed localhost Ollama discovery runs passed. See the report for warnings
and pending full manual acceptance.

## M11 — UI/UX stability, performance, and native macOS polish (active)

The measured hardening pass is implemented; **M11 acceptance is still open**.
The M11 pass introduced no M12 functionality. Explicitly requested M12.1 work follows below; outstanding M11 acceptance remains open.

- [x] Audit eligibility/context derivation, chat cleanup, rendering, operation ownership, source images and export
- [x] Deterministic small/medium/large/stress fixtures; 504-recording native development library, 260-message chat, 105-source stress workspace
- [x] DEBUG-only in-memory/temporary-storage fixture scene with mock providers, generated native PDFs and 12 MP images
- [x] Replace repeated context construction in chat/summary eligibility with content availability checks
- [x] Derive source context from Sendable snapshots off the main actor; preserve chunk/citation authority
- [x] Debounced source/transcript search with cancellation/stale-result protection and stable transcript rows
- [x] Lazy authoritative-ID cleanup, unchanged citation compatibility rules, content-keyed off-actor Markdown block parsing
- [x] Respect manual chat scrolling; Jump to Latest resumes following; retain existing 80 ms stream batching
- [x] Library-owned summary/chat work and drafts survive recording navigation; completion does not steal the selected tab
- [x] Recording-scoped activity menu, last recording selection restoration, stable scene identifier, native sidebar menu and ⌘O import
- [x] Guard duplicate chat/export starts; restore unsaved questions on persistence failure; fail streams missing a final response
- [x] Asynchronous downsampled image loading and shared thumbnail cache; revision invalidation and missing/corrupt thumbnail coverage
- [x] Export busy state, off-actor rendering/writing, cancellation and shared citation index; valid native PDF text/footer regression
- [x] Explicit accessible chat action labels, Escape cancellation, decorative thumbnail exclusion and readable transcript width
- [x] Static-name performance signposts, measured component baseline/report, full offline tests and Swift warning review
- [ ] Production-library launch/open/scroll/playback/streaming, repeated-navigation memory, SwiftUI hitches and large export profiling
- [ ] Full desktop interaction, focus, keyboard/menus, last-tab restoration, window sizing, Light/Dark/contrast/Reduce Motion and VoiceOver acceptance
- [ ] Relaunch/interrupted work and missing managed-file recovery across primary and additional sources
- [ ] Live slow/disconnected network, Ollama/Local Whisper resource contention, cancellation and disk-pressure acceptance
- [ ] App-wide multiwindow operation ownership/duplicate prevention and quit-with-active-work acceptance

See [M11 audit and measurements](UI_PERFORMANCE.md) for before/after numbers, file
inventory, automated coverage, unresolved main-thread/persistence/memory concerns,
and the native acceptance checklist. Synthetic fixtures do not certify real audio,
model accuracy, all UI interactions, or a production migration.


## M12.1 — Projects Foundation & Multi-Source Workspace (implementation; acceptance pending)

- [x] Persistent Project with stable UUID, optional description and meaningful-change dates
- [x] Zero/one project per Recording; standalone/global access and metadata-only move/remove
- [x] Shared project documents without fake recordings; reuse RecordingSource and M9 extraction/OCR/storage/viewers
- [x] Additive SwiftData schema; frozen pre-M12 on-disk migration/reopen coverage preserving history, references and pricing
- [x] Native New/Edit/Delete Project; explicit keep-recordings or delete-recordings semantics, staged managed-file cleanup
- [x] Projects sidebar, All Recordings access, typed UUID navigation, breadcrumb and compatible scene restoration
- [x] Overview/Recordings/Sources workspace, metadata filtering and deterministic ordering
- [x] Drag existing recent/all-library recordings onto project sidebar/workspace targets; move membership without reimporting files
- [x] Multi-selection import, project-sidebar/workspace file drop targets, native UTType classification
- [x] One audio file per Recording, project-owned PDF/image/text sources, no automatic transcription or AI charges
- [x] Library-owned serial import/extraction queue, measured unit progress, elapsed activity, failures, cancel remaining and retry
- [x] Imports continue while navigating; project deletion awaits cancellation and blocks new project jobs
- [x] Recording moves preserve active transcription, recording attachments, summaries, chat and costs
- [x] Shared source chunk derivation and strict recording AI/export scope retained for future project retrieval
- [x] Offline metadata fixture: 100 projects, 500 recordings, 100-recording/200-source workspace
- [x] DEBUG-only opt-in project desktop fixtures with in-memory storage, temporary managed files and mock providers
- [ ] Archived production-store upgrade/relaunch acceptance
- [ ] Native project creation/edit/deletion, picker/drop feedback, mixed-batch activity and source-viewer interaction acceptance
- [ ] Light/Dark, narrow/fullscreen, keyboard/focus and VoiceOver acceptance
- [ ] Project opening/list scrolling Instruments traces, eager-loading audit, repeated-navigation memory and idle CPU acceptance
- [ ] Cross-window coordination and quit/relaunch during import acceptance

See [M12.1 implementation report](PROJECTS.md). Explicitly requested M12.2 retrieval
work follows below. Project AI work is recorded in M12.3 below. Component/offline tests do not complete
native/manual acceptance.

M12.1 automated validation: Debug and Release macOS builds and **337 tests in 62 suites** passed,
including 15 project tests. Metadata fixture fetch/first-workspace preparation took
about 25–26 ms; this is a component measurement, not desktop scrolling acceptance.


## M12.2 — Project Retrieval & Unified Context Engine (implementation; desktop acceptance pending)

- [x] Explicit UUID recording/project RetrievalScope and library-owned local RetrievalService
- [x] Unified Sendable retrieval documents with stable IDs, content revisions and original provenance
- [x] Current project recordings' transcripts/attachments plus project-owned extracted sources
- [x] Strict recording scope retained for Recording Chat; historical citation IDs preserved
- [x] Coherent bounded transcript windows/overlap, original timestamps, PDF page/OCR/image/section boundaries
- [x] Independent BM25 inverted index, Czech/English Unicode normalization and technical identifiers
- [x] Bounded phrase/title/source signals, deterministic ordering, overlap suppression and modest diversity
- [x] Ownership/selected-recording/selected-source/content-type filters
- [x] Structured ContextPackage, serialized-data budget, shared model reserve calculation and optional audio neighbors
- [x] Scoped authoritative reference index and escaped user-role source DATA with separate grounding
- [x] Coverage and untranscribed recording metadata; processing/failed sources excluded safely
- [x] Lazy affected-scope rebuild, unchanged source reuse, bounded LRU eviction and disposable in-memory indexes
- [x] Membership/removal/transcript/OCR invalidation, cancellation/supersession and deletion cleanup tests
- [x] Local Only fixture, no indexing/provider/network dependency or generation/cost records
- [x] Deterministic 20-hour and 100-hour/200-source/4,000-page stress fixtures and component measurements
- [x] Main-actor heartbeat during background indexing and existing recording-chat regression coverage
- [ ] Production-store cold snapshot/fault and native UI responsiveness acceptance
- [ ] Repeated navigation/window memory plateau and real quit/relaunch acceptance
- [ ] Physically disconnected network desktop acceptance

See [M12.2 implementation report](PROJECT_RETRIEVAL.md) for algorithms, file inventory,
measurements and limitations. M12.3 Project Chat is recorded below. M11/M12.1 manual
acceptance remains open; component tests do not close those checklists.

M12.2 automated validation: Debug macOS build/test and Release universal macOS build
passed; **350 tests in 65 suites**, including 13 new retrieval tests. Synthetic 20-hour
and 100-hour fixtures indexed in about 509 ms / 2,022 ms and searched warm in about
4.52 ms / 20.85 ms. Full-test-host high-water RSS was about 405.5 / 417.8 MiB; this
is not isolated index memory or native desktop acceptance.


## M12.3 — Project Chat & Cross-Source AI (implementation; desktop/live acceptance pending)

- [x] Project-owned persistent ChatSession/messages, additive owner relationships, separate project generation/cost ownership
- [x] Native Chat workspace tab, project-aware suggestions, searchable coverage and unavailable-content guidance
- [x] Every send/retry/regenerate uses M12.2 project-scoped local retrieval, strict source selection and current membership
- [x] Deterministic follow-up queries, bounded recent history, current-question protection and output/evidence reserve
- [x] Minimal escaped user-role project DATA, provider-neutral grounding and external-provider excerpt consent
- [x] Existing Chat provider/model/settings and runtime Local Only/Ollama verification integration
- [x] Entire Project/Selected Sources, recording transcript/attachment scope, shared source selection, Select All/Clear and persistence
- [x] Request-local S1/S2 aliases, fresh trusted citation validation, deduplication and historical unavailable chips
- [x] Native recording timestamp/PDF/image/text navigation plumbing, remembered Chat tab and window-owned scroll state
- [x] Library-owned independent generation state, batched streaming, cancel/await, retry/regenerate and interrupted-work recovery
- [x] Shared native Markdown rendering with horizontally scrolling tables, lazy history, Copy and generation Details
- [x] Existing usage/pricing tracker, project totals, estimated evidence/history counts separate from billed tokens
- [x] Project Chat Markdown export through shared ExportContent and native export service
- [x] Deterministic Operating Systems tests and isolated DEBUG desktop fixture
- [x] Recording Chat/M1–M12.2 regression and on-disk migration/reopen tests
- [ ] Native end-to-end first-send/streaming/citation/seek/back/source-picker acceptance
- [ ] Light/Dark, narrow/fullscreen, keyboard/focus and VoiceOver acceptance
- [ ] 250-message native scrolling/stream CPU and 100-hour production-store/UI memory/latency profiling
- [ ] Configured live OpenAI/Claude/Ollama, disconnected-network and provider usage/cost acceptance
- [ ] Production upgrade/restart, cross-window behavior and runtime prompt-injection acceptance

See [M12.3 implementation report](PROJECT_CHAT.md) for file inventory, ownership,
request/citation architecture, validation, component measurements and limitations.
Gemini remains unavailable in the existing provider resolver; project images use local
OCR text. M11/M12.1/M12.2 manual acceptance stays open. M12.4 has not started.

M12.3 automated validation: full Debug macOS suite **362 tests in 67 suites passed**
(the stress test and two existing opt-in live tests skip in normal runs); the isolated
100-hour/200-source/250-message send-pipeline stress test passed separately. Cold
end-to-end mock completion was about 4.2 seconds with three evidence chunks and three
history messages. See the report for component limits and final build validation.


## M12.3.5 — Local Embeddings & Hybrid Retrieval (foundation only; incomplete)

- [x] Provider-independent embedding metadata and batched embedding protocol seam
- [x] Local-only guard for semantic index construction
- [x] Disposable in-memory normalized cosine index over M12.2 retrieval chunks
- [x] Deterministic reciprocal rank fusion (RRF, constant 60) without score-scale mixing
- [x] Semantic indexing/query errors preserve lexical BM25 fallback
- [x] Retrieval unit coverage for cosine ranking, dimensions, locality and rank fusion
- [ ] Select and validate native local runtime and multilingual English/Czech model/license
- [ ] Model download, integrity verification, managed storage, deletion and status UX
- [ ] Incremental durable vector storage keyed by model identity and chunk fingerprint
- [ ] Wire semantic availability/settings and lifecycle into Project Chat
- [ ] Index progress, cancellation, LocalAIJobCoordinator priority and memory-pressure handling
- [ ] Offline semantic quality fixtures, baseline metrics, performance and lifecycle acceptance

See [Local Semantic Retrieval](SEMANTIC_RETRIEVAL.md). The feature is not user-enabled;
BM25 remains the production behavior. Do not start M12.4 as part of M12.3.5.


## M13 — Ship V1 / Release Engineering (in progress; not ready to distribute)

- [x] Record baseline release audit, stable macOS 15/Apple Silicon release identity, build-derived version, Developer Team selection, hardened-runtime/no-sandbox decision
- [x] Integrate official Sparkle 2 updater, signed-feed configuration seam and standard native menu/settings controls
- [x] Prepare GitHub Actions Pages feed deployment; validate signed DMG enclosure against actual release URL/bytes before deploy
- [x] Add privacy/help/licenses, first-launch setup/skip, safe diagnostics and retry/reveal database recovery UX
- [x] Establish v1 SwiftData schema, synthetic checked-in on-disk migration fixture, pre-migration WAL-aware metadata snapshot
- [x] Journal recording/project/source file deletion for crash recovery; avoid production provider response-body logging
- [x] Prepare Release checklist, guide, privacy/license notices and local Developer ID/notarization/DMG workflow
- [x] Debug app build and optimized Release app build; complete **373 tests in 70 suites** serially; release-tool tests **6/6**; Apple Silicon Release excludes developer OAuth configuration
- [ ] Enable Pages via repository Settings → Pages → GitHub Actions; add public EdDSA key as repository variable
- [ ] Install Developer ID certificate and configure notarytool Keychain profile; no production certificate/profile/Sparkle key exists on the audit Mac
- [ ] Validate notarized/stapled DMG, Gatekeeper and signed Sparkle update against the real public appcast and release assets
- [ ] Clean-user/quarantine install, complete on-device provider/Local Only/privacy/accessibility/performance/stability bug bash, clear all P0/P1
- [ ] Publish and accept actual AudioNotes 1.0.0; archive production release artifacts and final per-build acceptance record

See [M13 implementation status](M13_IMPLEMENTATION.md), [release audit](RELEASE_AUDIT.md),
[release checklist](RELEASE_CHECKLIST.md) and [release guide](RELEASING.md). Public
repository is `Kudl1k/AudioNotes`; Pages currently reports disabled and the stable
feed / v1 asset return 404. No production update URL is embedded. The application is
not ready to distribute until the remaining manual/credential/live gates pass.

## M14 — SwiftUI-first UI architecture (first pass; desktop acceptance pending)

- [x] UI architecture audit: app was already SwiftUI-first (SwiftUI `App`, `NavigationSplitView`, 53 SwiftUI views, one PDFKit representable); SwiftUI transcript and Markdown renderers retained
- [x] AppKit classified and confined to `Platform/macOS/AppKit` (file panels, clipboard, Finder/browser, alerts, PDF preview); services no longer import AppKit except the retained CoreText `PDFExporter`
- [x] Help/Privacy/Licenses windows migrated from manual `NSWindow` controllers to a SwiftUI window scene; composer Shift+Return uses key-event modifiers instead of global `NSEvent` state
- [x] Debug tests (389/73) and Release build pass; no new warnings; no schema, signing, Sparkle or bundle changes
- [ ] Desktop acceptance of migrated menus, panels, copy, Finder reveal, composer keys and PDF citation jumps
- [ ] Presentation-boundary cleanup, single shared chat UI, shared progress component, previews/accessibility identifiers

See [M14 migration report](SWIFTUI_MIGRATION.md).

## M14.2 — Unified Chat UI (implementation; broader desktop acceptance pending)

- [x] Audit and duplication map; separate Recording/Project domain engines retained
- [x] Shared composed composer, rows, lazy list, thinking/streaming, errors and empty states
- [x] Native cursor-aware Shift+Return, marked-text gating, keyboard focus and bounded editor
- [x] Stable assistant identity, retained scroll intent, message-targeted Latest and manual-scroll protection
- [x] Markdown, authoritative citations/navigation, Copy, provider settings and existing usage semantics retained
- [x] Cancelled-publisher race fixed; deterministic cancellation tests preserve/strengthen assertions
- [x] Isolated DEBUG 500-message/long-stream fixtures and native paste/resize/scroll/Stop/Copy checks
- [ ] Physical IME, VoiceOver, complete full-screen/Reduce Motion and live-provider desktop acceptance

See [M14.2 audit and implementation report](UNIFIED_CHAT_UI.md). M14.1 remains committed
separately; older manual acceptance is not closed.

## M14.3 — Workspace density and operation progress (committed)

- [x] Compact project/recording workspace layout, shared progress and elapsed-time presentation, factual multipart transcription progress and ETA
- [x] Native fixture review (sizes, Light/Dark, multipart, cancel/failure, model download)
- [x] Committed separately from M14.4 (`refactor(ui): improve workspace layout and progress UX`); 424 tests in 76 suites, Release build

See [UX layout and progress report](UX_LAYOUT_AND_PROGRESS.md).

## M14.4 — Accessibility, previews, performance and final UX QA (committed)

- [x] Accessibility audit and fixes: labels, grouping, selection, citations, progress, errors, identifiers; 0 unlabeled controls on the surfaces swept
- [x] SwiftUI previews on deterministic in-memory fixtures (DEBUG only)
- [x] Fixed: Export… disabled with composer focus, window-wide Escape stop, raw AVFoundation import error, usage-cost key rebuilt per render
- [x] Narrow-window Recording Chat crash **mitigated** (release-safety guard: Chat unavailable in a detail pane narrower than ~640 pt, with an explanation); the underlying constraint loop is not fixed
- [x] Search/empty states, long-name truncation, pluralization; no performance regression against M14.2
- [x] 431 tests in 77 suites (twice), Release build, no new warnings, Xcode 16 project format kept
- [x] Committed separately from M14.3 (`refactor(ui): improve accessibility and final QA`)

## M14 — closed

M14 (initial architecture pass, M14.1 presentation boundaries, M14.2 unified chat, M14.3 layout and progress,
M14.4 accessibility and QA) is **complete as an engineering milestone**. It is not a statement that physical
acceptance was performed. Explicitly deferred and still open (none of these was completed):

- [ ] Physical VoiceOver validation (narration and focus order)
- [ ] Physical IME composition validation
- [ ] Reduce Motion validation
- [ ] Increase Contrast validation
- [ ] Real/live provider acceptance
- [ ] Prolonged OCR/import acceptance
- [ ] Real model-download acceptance
- [ ] Ollama fixture discrepancy
- [ ] **Technical debt:** investigate the underlying AppKit constraint loop in narrow Recording Chat (the < ~640 pt guard is a mitigation only)
- [ ] Markdown streaming CPU profiling
- [ ] UI-test target
- [ ] Menu equivalents for context-menu-only Rename/Delete
- [ ] Older M11–M13 acceptance debt (see those milestones)

See [M14.4 report](ACCESSIBILITY_AND_QA.md) and the [M14 migration report](SWIFTUI_MIGRATION.md).

## M16 — iOS / iPadOS Port

Goal: deliver native iPhone and iPad companion targets sharing core models, persistence, business logic, and providers with macOS, without duplicating architecture or code. M15 is reserved for the macOS Release Candidate / signing / notarization / distribution work and is not part of M16.

- [x] M16.0 — Architecture and portability audit ([audit report](IOS_PORT_AUDIT.md))
- [x] M16.1 — Shared/platform boundary preparation (zero behavior change on macOS; [boundary report](IOS_PLATFORM_BOUNDARIES.md))
- [x] M16.2 — iOS target + library and navigation shell ([implementation report](IOS_TARGET_AND_NAVIGATION.md))
- [x] M16.3 — Native audio import + recording detail, foreground playback, stored transcript/summary/history and management ([report](IOS_AUDIO_AND_RECORDING.md)); implementation and Simulator QA complete, physical device/VoiceOver acceptance pending
- [x] M16.4 — Cloud AI + chats and account authentication; implementation, iPhone/iPad Simulator suites, macOS regression, and required builds pass. Live-provider testing was not performed (no authorized account session available). Physical Device / Signing Acceptance is intentionally deferred to release work; it does not block this milestone ([account authentication and deferred acceptance](IOS_ACCOUNT_AUTH.md), [cloud AI implementation/status](IOS_CLOUD_AI.md))
- [x] M16.5 — Native iOS UX and project organization, including M16.5.1 visual refinement — committed in `a73f72f` (`feat(ios): polish recording workflows and project UX`). Automated regression/build validation and visual review are recorded; Simulator gestures/keyboard, physical devices, VoiceOver, production signing and live providers remain deferred. See [final acceptance record](IOS_UX_AND_PROJECTS.md#final-m165-acceptance-record). Sources/OCR/Project Chat are not introduced in this UX pass.
- [x] M16.6 — Project sources and shared Project Chat — implementation and deterministic visual review complete. Source imports/viewers and Project Chat reuse the shared queue, retrieval, persistence, provider, and citation architecture. Populated iPhone/iPad chat and mixed import/failure fixtures are captured; retrieval/context and 250-message preparation measurements are recorded; persistence, citation intents, and import recovery are covered. macOS 456 passed / 6 expected skips; iPhone and iPad each 50 passed. Release/debug builds and integrity checks are recorded in the [implementation report](IOS_PROJECT_SOURCES_AND_CHAT.md). Native Files/citation/gesture/keyboard/scroll interactions, physical devices/VoiceOver, live providers, and production signing remain deferred. Markdown chat sharing uses native `ShareLink`; PDF export remains a separate platform capability.
- [ ] M16.7 — Local capabilities (LAN Ollama/llama.cpp, Whisper feasibility spike)
- [ ] M16.8 — iPad polish (adaptive split, inspector, keyboard shortcuts, drag & drop)
- [ ] M16.9 — iOS QA, accessibility, memory, performance, and validation

### Deferred to release/signing: Physical Device / Signing Acceptance

- [ ] Confirm owning company Developer Team and permanent production bundle identifier.
- [ ] Register production App ID/capabilities and configure signing/provisioning; prepare TestFlight/App Store records only in the release milestone.
- [ ] Install on physical iPhone; validate ChatGPT loopback while backgrounded and Google OAuth callback.
- [ ] Verify Keychain persistence, provider inference, token refresh, disconnect, and background/foreground behavior.
- [ ] Validate VoiceOver and device-specific audio playback.

The current iOS bundle identifier is development/project configuration. No production App ID, provisioning, or App Store Connect record was created for M16.4. Existing project `DEVELOPMENT_TEAM` configuration was left unchanged; Simulator builds use `CODE_SIGN_IDENTITY = -`. Confirm team ownership before any device signing.

See [iOS Port Architecture and Portability Audit](IOS_PORT_AUDIT.md), [iOS Platform Boundaries](IOS_PLATFORM_BOUNDARIES.md), and [iOS Target & Navigation Shell](IOS_TARGET_AND_NAVIGATION.md).
