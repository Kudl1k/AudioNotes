# M9 — Multi-source recording workspaces

A Recording now owns general RecordingSource relationships alongside its compatible
primary audio fields. Audio, PDFs, text documents, and images contribute selected
context to summaries, chat, local search, validated citations, and shared exports.

## Architecture and persistence

`RecordingSource` stores identity, display/original names, import date, source type,
managed filename, content hash, typed processing state, and encoded source-specific
metadata. It belongs to a Recording with cascade deletion. Additional audio sources
have their own Transcript relationship. Primary audio continues using the existing
Recording transcript, duration, and filename; there is no destructive data rewrite.

`SourceTextUnit` stores one extracted PDF page, document section, or OCR observation
with an ordering position, text origin and encoded typed locator. Empty PDF pages
remain represented internally. Native text, OCR, and transcript text are distinct.
OCR regions include normalized bounding boxes and confidence. SourceMetadata is a
Codable enum for audio duration, PDF page count/unreadable page indices, document
character count, or image dimensions rather than a collection of nullable columns.

SwiftData adds optional source/reference/selection fields and default-valued
relationships through lightweight migration. SourceCompatibilityMigration then
creates exactly one primary audio source per old Recording, with the Recording ID
as its stable source ID, without moving files. Backfill is idempotent and marks
interrupted source jobs recoverably failed on launch. The frozen LegacyM8Schema test
creates a pre-M9 on-disk store and verifies the new container preserves audio paths,
segment IDs/text, summary versions, chat/transcript references, generation IDs and
Decimal costs. Reopen/cascade tests cover new source text and references.
The app continues opening its existing default store location; this change does not
switch users to a different database. An archived production library still needs
manual acceptance before release.

## Formats and managed originals

Supported imports:

| Type | Formats | Local preparation |
| --- | --- | --- |
| Audio | AVFoundation-compatible audio, as before | Validate tracks and duration; explicit transcription |
| PDF | PDF, unlocked | PDFKit text per page; local OCR fallback |
| Image | JPEG, PNG, HEIC/HEIF | ImageIO dimensions/orientation, Vision OCR, thumbnail |
| Document | TXT, MD/Markdown | UTF-8 (including BOM) or BOM-marked UTF-16; Markdown heading/range provenance |

Sources attach through a native multi-selection NSOpenPanel or URL drag/drop in the
Sources tab. New Workspace supports a document-first workspace. Originals are copied
to Application Support/AudioNotes/Sources/<source ID>/original.<extension>. Existing
primary audio remains under Recordings. UUID directories are implementation details,
never UI labels or export citations. Original files are never rewritten. Derived
thumbnails live next to managed originals; text lives in SwiftData and retrieval
chunks remain in memory. Removing an external original does not affect managed data.

Streaming SHA-256 of the managed copy detects renamed duplicates. Legacy hashes are
computed only for matching source types; adding a photo does not scan unrelated large
audio files. Failed/cancelled copies are removed, and a metadata-save failure discards
its unused copy. Only regular local files are accepted; symlinks are rejected. Local
limits are 512 MB per original and 64 MB for text documents. Unsupported/locked/damaged
sources return typed errors rather than executing content. TXT/Markdown are reliable
native text formats. DOCX and RTF are deliberately not exposed: macOS attributed-string
importers would require separate fidelity/resource/security validation, and this
milestone introduces no office dependency.

Removal confirms deletion, stages owned files for rollback if the database save fails,
removes derived models and invalid references, and preserves the workspace, saved prose
and factual cost history. Removing primary audio clears its legacy playback/transcript
fields and timestamp links. References are also revalidated on every display/export.
A source currently processing cannot be removed; cancel it first.

## Local extraction, OCR, thumbnails and progress

NativeSourceProcessingService owns PDFKit/Vision work outside SwiftUI. PDF pages with
meaningful native text avoid OCR. Other pages are rendered locally and recognized,
keeping their original zero-based page index. UI labels add one. Mixed/empty/unreadable
pages produce partial status with page diagnostics; entirely unusable documents fail.
Valid text-free images remain available for optional visual analysis with an explicit
OCR limitation. OCR failures are recoverable and never crash processing.

VisionOCRService uses accurate recognition, automatic language detection, and only
recognition languages supported by the installed OS. Czech and English are preferred
when available. Extracted Unicode is not transliterated. OCR is probabilistic and may
misread individual diacritics; tests check English/Czech recognition and Unicode
preservation without claiming perfect recognition. ImageIO applies image orientation
when downsampling. Images used for local OCR are bounded to a 2000-pixel maximum
dimension; PDF OCR uses bounded page rendering. Originals retain full resolution.
PDF and image thumbnails are generated/cache-stored locally.

SourcesViewModel owns import/processing state and tasks; LibraryViewModel retains it
across recording navigation. Ready sources remain usable while others process. Phase,
completed units/pages and elapsed time are real; no invented within-request percentage
or ETA is displayed. Import identifies the current copy/duplicate-check stage. After
15 seconds, OCR explains possible first-use delay. Cancellation calls VNRequest.cancel
and retains originals for retry. Active jobs are not resumable after application exit.

A developer benchmark using the reported screenshot measured approximately 55 seconds
for the first local Vision invocation and under half a second for subsequent invocations;
this is consistent with cold initialization, not provider upload latency. It does not
establish performance of the user's original photo, which is in the protected app
container. Matching-type duplicate checks and bounded OCR eliminate avoidable work.

## Chunks, retrieval, selection and source authority

SourceChunk is a Sendable/Codable value with a stable SHA-256-derived chunk ID, source
ID/name/type, text, origin, and SourceLocator. Audio chunks reuse M8 segment snapshots
and retain segment IDs/start/end. PDF chunks retain pages, documents section/character
ranges, and images OCR regions. Large text is split into bounded in-memory pieces;
persisted source text is not duplicated. Reprocessing replaces derived units, so old
unit-specific references become invalid and stop appearing; original source IDs survive.

RecordingContextRetriever runs deterministic, diacritic-insensitive lexical retrieval
across sources, ranking relevance without a source-type bias and reserving representative
relevant chunks from different sources. Small selected sets fit entirely; larger sets
obey a hard approximate text-context budget. Search shows type, filename, location and
excerpt and uses the same native source navigation. No cloud indexing, embeddings or
vector database is introduced. Approximate sizing is never billed usage.

Chat and summary source popovers default to all ready/partial usable sources, with all,
transcript-only and per-source toggles. Empty selection fails before a provider request.
Preparing/failed/unusable sources are excluded. Requests snapshot selected source IDs
on GenerationRecord. SourceConversationHistory excludes earlier assistant answers whose
recorded selection includes excluded/deleted sources; those answers remain visible in
persistent history. Derivative whole-recording summaries are not silently included in
filtered chat context. Existing history lacking reliable selection metadata remains
visible but is conservatively omitted from the unified AI-history payload.

LLMs return IDs, not trusted pages or times. For transport compatibility chat's structured
`referenceSegmentIDs` accepts source chunk IDs on the unified path; multi-source summaries
use `referenceChunkIDs`. SourceReferenceResolver validates IDs against the actual selected
request chunks and the current Recording before persistence/display, deriving filename,
locator and excerpt locally. Unknown, cross-recording, duplicate and deleted IDs are
rejected. TranscriptReference and its original resolver remain supported for old chats.
No prose timestamp/page produces a clickable citation.

SourceReferencePresentation groups image regions into one displayed image chip, PDF
chunks by page, and document chunks by section without discarding underlying reference
records. Large citation groups collapse after five visible chips. Primary audio references
seek/reveal the transcript; additional audio uses its own playback preview. PDF references
navigate PDFKit to the exact stored page; images open native previews; document references
scroll to the authoritative section/range. Source names can be renamed without changing
original filenames or identities. Known machine IDs are cleaned at response boundaries;
ordinary brackets and unrelated UUIDs remain untouched.

## Multimodal behavior, budgets, privacy and provider security

OCR does not understand visual structure. The composer makes its image mode visible.
Actual image data requires explicit upload permission plus selected ready source, query
relevance and an implemented vision-capable model. Unknown model IDs and unavailable
provider paths default conservatively to text only. Model input capabilities live in a
provider-independent LLMInputCapabilities descriptor exposed through the provider/model
capability layer. Verified GPT-4o/4o-mini/4.1 family metadata enables the implemented
OpenAI API and ChatGPT-plan transports; other providers need their own implementation
and verified capability metadata. No alternate provider receives files implicitly.

MultimodalContextService prepares only relevant selected image candidates and encodes
orientation-correct bounded JPEG derivatives, preserving HEIC/original files. Application
limits are at most two images per request, each at most 5 MB, and maximum derivative
dimension 1536 pixels. These are conservative application ceilings, not claimed universal
provider limits. Chat uses the retrieved image sources rather than attaching every image.
Explicit source selection also permits selected visual sources; the popover explains
request limits. Summaries attach at most two permitted images in source-level passes;
synthesis does not resend images. Text and history/output reservations plus conservative
image-context reservations guard model context limits. Dense fine print or more images
may require a narrower selection/additional requests.

Source context is serialized as escaped JSON in user-role messages, separate from system
grounding/privacy rules. Prompts label source content and intermediate summaries as
untrusted data, distinguish source statements and OCR/visual interpretations, prohibit
following embedded instructions, and ask for relevant discrepancies. This is prompt-level
mitigation, not a claim that a model can never be influenced by hostile text. Providers
receive no document executable actions, secrets, app controls or tool-execution authority.
Native PDF previews allow internal page navigation and block external/embedded actions.
No original PDF is automatically uploaded. Credentials remain in existing Keychain stores;
source/generation records contain no API keys or OAuth tokens.

Capability and payload verification uses the current official [OpenAI image-input guide](https://developers.openai.com/api/docs/guides/images-vision),
[GPT-4o-mini model description](https://developers.openai.com/api/docs/models/gpt-4o-mini),
and Apple's [Vision language detection](https://developer.apple.com/documentation/vision/vnrecognizetextrequest/automaticallydetectslanguage)
and [supported-language discovery](https://developer.apple.com/documentation/vision/vnrecognizetextrequest/supportedrecognitionlanguages()).
Metadata was verified September 30, 2026 and ships with the application; no runtime scraping.

## Summaries, usage and exports

HierarchicalSummaryGenerator has a multi-source overload and continues using the existing
LLMProvider and UsageTrackingLLMProvider. Manageable contexts use one structured pass;
large sets use bounded source/chunk passes and recursive reduction before final synthesis.
Intermediate notes remain in memory and carry validated original citation IDs. Final
citations are resolved back to original chunks, timestamps from model output are discarded on the source-aware path (including new audio-only summaries from implemented source-summary providers),
and only the final requested OutputLength summary version is persisted. Cancellation and
failed final synthesis preserve earlier saved summaries.

Every internal paid request belongs to the same logical GenerationRecord, captures its
pricing snapshot at request start, and aggregates provider usage including image tokens.
ImageInputCount records submitted image parts and is shown in generation Details. There
is no generic image/page fee and no charge for local extraction/OCR/retrieval/thumbnails.
Existing Decimal/currency calculations and historical pricing snapshots remain unchanged.
Unknown failed/cancelled usage remains unavailable. ChatGPT-plan operations remain in their
existing subscription category; other account authentication is not subscription coverage.
Text-only manageable summary budget estimates use the existing CostEstimator; hierarchical
and image estimates remain unavailable instead of guessed. Image input billing follows
provider-reported input-token totals as documented in the official image-input guide.

ExportContent remains canonical for both Markdown and native CoreText PDF. The optional
Sources section lists display names, and validated summary/chat references use readable
filename/page/time/section labels. Presentation grouping prevents repeated image labels.
Neither exporter emits source/chunk IDs. AI generation metadata continues to be opt-in.

## Files created

- Models/RecordingSource.swift
- Services/Sources/SourceCompatibilityMigration.swift
- Services/Sources/SourceImportService.swift
- Services/Sources/OCRService.swift
- Services/Sources/SourceProcessingService.swift
- Services/Sources/RecordingContextRetriever.swift
- Services/Sources/SourceContextPreparation.swift
- Services/Sources/SourceReferencePresentation.swift
- Services/Sources/MultimodalContextService.swift
- Services/Sources/SourceSummaryContext.swift
- Services/Sources/MultiSourceSummaryGeneration.swift
- Features/Sources/SourcesViewModel.swift
- Features/Sources/SourcesView.swift
- Features/Sources/SourceSelectionView.swift
- Features/Sources/SourcePreviewView.swift
- Tests: LegacyM8Schema, MultiSourceTestSupport, SourceProcessingTests, SourceContextTests,
  SourceImportTests, SourcePersistenceTests, SourceMultimodalTests, SourceWorkflowTests
- docs/MULTI_SOURCE.md

Paths above are relative to AudioNotes/ for application files and AudioNotesTests/ for tests.

## Existing files extended

- App/AudioNotesApp.swift; Models/Recording.swift, Transcript.swift, ChatMessage.swift,
  Summary.swift, GenerationRecord.swift
- Services/LibraryStorage.swift, RecordingRepository.swift, Transcription/TranscriptRepository.swift
- Services/LLM/LLMProvider.swift, MockLLMProvider.swift, HierarchicalSummaryGenerator.swift,
  Configuration/LLMModelCapabilities.swift, Chat/LLMChatTypes.swift, Chat/ChatContextBuilder.swift,
  Chat/ChatRepository.swift, Prompt/SummaryPromptBuilder.swift
- Services/LLM/OpenAI/OpenAILLMProvider.swift, OpenAILLMClient.swift, OpenAILLMRequestDTO.swift,
  OpenAILLMResponseDTO.swift
- Services/ChatGPT/ChatGPTPlanLLMProvider.swift, ChatGPTResponsesClient.swift
- Services/Usage/UsageTracking.swift, UsageRepository.swift
- Services/Export/ExportModels.swift, ExportContentBuilder.swift, MarkdownExporter.swift, PDFExporter.swift
- Features/Library/LibraryView.swift, LibraryViewModel.swift
- Features/RecordingDetail/RecordingDetailView.swift, RecordingViewModel.swift, SummaryView.swift,
  SummaryViewModel.swift, TranscriptView.swift
- Features/Chat/ChatViewModel.swift, ChatInspectorView.swift; Features/Export/ExportSheetView.swift
- AudioNotesTests/OpenAINetworkStub.swift (HTTP-body-stream capture for transport assertions)
- Services/LocalAI/PrivacyProviders.swift (forward M9 source-summary capability through the concurrently added wrapper); AudioNotesTests/ChatGPTAuthTests.swift (provider/authentication/capability assertions)
- AGENTS.md; docs/ROADMAP.md

Unrelated pre-existing edits and concurrent local-provider work are not M9 implementation files.

## Validation and remaining acceptance

Validation on September 30, 2026: the isolated M9 build passed **223 tests in 47 suites**.
After shared-workspace integration, the native macOS build succeeded and **248 tests in
50 suites passed**, including concurrently developed features. `git diff --check` passed.

The isolated M9 native macOS build/test suite passes automated processing, frozen-schema
migration, restart/reopen/cascade, managed copy/duplicates, OCR language/error/cancellation,
source diversity/budgets/filter privacy, prompt delimiters, invalid/cross-recording/deleted
references, multimodal payload/capability/relevance, source hierarchy/usage and shared exports.
No live API request was made for this milestone. Native GUI picker/drop/page navigation,
representative photo performance, production-store migration and live credential-backed
image summaries/chat still require manual release acceptance. Tests do not claim perfect
OCR recognition or prove model resistance to prompt injection.

Warnings reviewed: the existing unused try? result in PresetsManagementView and Xcode's
AppIntents metadata-extraction warning; no new M9 Swift warnings in isolated validation.
The shared workspace has concurrent local-provider files. The full shared suite passed
after forwarding the M9 source-summary capability through its privacy wrapper and
verifying resolver provider/authentication identity rather than concrete wrapper classes.
No new local-provider implementation was authored as part of M9.

## M10 seams and limitations

Source types/locators/retrieval remain independent of inference providers. Local providers
can consume the same selected context and typed image inputs by implementing capabilities
and source summary/chat contracts and opting into supportsSourceSummaries; audio providers remain independently configurable.
Lexical retrieval can later be replaced behind RecordingContextRetrieving, with embeddings
covering the same SourceChunk IDs/locators. No local inference engine, cloud sync, global
chat, vector store, office editor, annotation system or automatic web search is introduced
by M9. Multimodal PDF page rendering is local OCR only; actual provider PDF input is not
implemented. Processing tasks do not resume after termination. Reprocessing invalidates
old derived chunk citations instead of inventing migrated locations. Long-source budget
estimates are not yet available, and UI performance with extreme numbers of text units
requires profiling before raising import/context limits.
