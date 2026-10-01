# M12.2 — Project Retrieval & Unified Context Engine

M12.2 adds a local retrieval service for explicit recording/project scopes. It adds
no project AI workflow or production search UI. M12.3 is not started. The remaining
M11/M12.1 desktop acceptance remains open.

## Architecture and ownership

`RetrievalService` is owned by `LibraryViewModel`, not `ProjectWorkspaceView`.
It captures retrieval-only SwiftData values on their owning main actor, then calls
an actor-isolated `ContextRetriever` through a cancellable detached task. The
snapshot fetches scope membership, current transcripts/segments, sources and text
units. It does not traverse chat, summaries, generation records, pricing, or audio
files. SwiftData snapshot copying still takes main-actor time; background indexing
is not a claim that large production-store materialization is free.

`RetrievalScope` uses stable UUIDs: `.recording(UUID)` / `.project(UUID)`.
Recording scope contains only that recording's current transcript and eligible
recording-owned attachments. Project scope contains current project recordings'
transcripts/attachments plus project-owned sources. Sources with ambiguous ownership
are excluded. Other projects, historical transcripts, generated answers and summaries
are excluded. Membership never broadens normal Recording Chat.

`RetrievalSnapshot`, `RetrievalDocument`, matches, options, coverage and context packages
are Sendable values, not SwiftData models. Documents retain project/recording/source
IDs, recording title, source name, content type, original unit/segment IDs, typed
locator, original text and a content revision. Content types are transcript, pdfText,
imageOCR, markdown and plainText; scanned PDF text retains PDF type and OCR origin.

Options support recordings/project sources/all ownership, selected recording IDs,
selected source IDs, content types, result limit, context budget, diversity and
optional transcript neighbors. Empty selection sets mean no eligible content.
Coverage describes the entire scope, independently of query/filter match counts:
searchable/untranscribed recordings and searchable/processing/failed attachments.
Untranscribed recordings retain title/ID metadata in results but contribute no text
matches and are never transcribed automatically. Valid text-free images contribute
no OCR search documents. Existing recording visual-input anchors remain compatible.

## Chunking and identity

Audio windows group whole ordered original segments, targeting at most 3,200 text
characters and 90 seconds, with a boundary at gaps greater than 15 seconds. Windows
containing more than two segments overlap by one segment. Oversized individual
segments are split into bounded text slices; every slice retains that segment's
original full time range, without inventing subsegment timestamps. Speaker labels
remain text. A pathological original segment longer than 90 seconds necessarily
retains that longer authoritative range.

PDF chunks never cross an extracted page; zero-based page indices display as one-based
page labels. Image OCR stays within the original OCR region and source image. PDF
OCR stays on its PDF page. Text/Markdown preserves the extraction service's heading
sections and original offsets. Within a long unit, splitting prefers paragraph,
newline, then word boundaries between 1,600 and 3,200 characters. Original text is
preserved exactly; no normalized text is persisted.

Retrieval IDs are deterministic hashes of a versioned namespace, source UUID and
underlying segment/unit UUIDs plus slice position. New unrelated sources do not
renumber existing chunks. SHA-256-derived content revisions cover snapshot text and
relevant provenance/labels, off the main actor. Changed text can keep the same chunk
ID while changing its revision. Future derived semantic data must key by both.
No raw audio/file bytes are hashed by retrieval.

Existing M9 `SourceChunk` IDs and recording citation validation remain unchanged.
The recording compatibility adapter uses the shared lexical backend on those IDs;
it preserves its prior full-context, fallback and source-diversity behavior. The
new scoped service uses coherent retrieval windows. M12.3 must resolve those new
windows with scoped authority rather than the legacy recording chunk index.

## Lexical ranking and context

`LexicalIndex` is an independent immutable inverted BM25 index (k1=1.2, b=0.75).
Body scoring visits only postings for query terms. Unicode NFC, case and accent
folding make composed/decomposed and accented/unaccented Czech searchable. Technical
identifiers retain internal underscores, slashes and hyphens (`copy_from_user`,
`TCP/IP`, `S7-1500`, `GPT-5`). Metadata also indexes slash/hyphen components, so
`kernel-slides.pdf` can provide a kernel title signal. Punctuation is token separation.
There is no heavy NLP dependency, stemming, translation or cross-language synonym
expansion. Czech and English terms must actually occur in content/metadata.

A small Czech/English conversational-filler set receives 0.15 query weight, without
removing words. Normalized exact token/phrase matches add 25% of body score, capped
at 1. Title/filename signals add 0.12 per weighted matching term, capped at 0.4.
They cannot grow without bound or replace substantial body evidence. Phrase forms
are cached at index build time rather than retokenized for each query. No recency
boost exists. Ties use stable document UUID ordering, and score accumulation uses
sorted terms for deterministic floating-point results.

`ContextAssembler` greedily selects ranked evidence, suppressing audio matches with
at least 60% overlap relative to the shorter time interval and exact duplicate
same-location text. Distinct slices with identical authoritative locators survive.
Optional diversity penalizes repeated sources by 10%, capped at 20%; it does not
force one result per source. Recording compatibility retains the existing M9
source-diversity behavior instead of changing it silently.

`RetrievalBudget` subtracts output, system, history and optional image reserves from
a provider-independent context window and applies a caller ceiling. Recording chat
uses the same budget calculation with its existing model capabilities/reserves.
These are conservative UTF-8 token estimates, not provider tokenizer counts, usage,
or billing. A result-count limit is additional to the hard budget.

The context package remains structured. Assembly budgets the actual JSON-escaped
entries, including provenance/labels and separator allowance. Oversized entries are
omitted rather than stripping their authority. Ranked entries receive budget first.
Optional transcript expansion can add one next/overlapping neighboring window per
selected match only after primary evidence; PDFs never expand automatically. Final
entries group by stable source ID and use original chronological/page/offset order,
while retaining relevance scores. Small window overlap is intentionally retained;
full duplicate/near-duplicate evidence is suppressed, not persisted repeatedly.

`ContextPackage.serializedSourceData()` JSON-escapes source boundaries, filenames and
text, with stable document UUIDs and readable labels. Consumers must pass it in a
user-role DATA message and use the separate `groundingInstructions`; source content
must never become system instructions. No provider currently consumes project context.
`RetrievalReferenceIndex` checks explicit scope and selections, rejects invalid,
cross-scope, deleted and duplicate IDs, and returns authoritative context entries.
Before accepting future historical/model references, reconstruct it from a fresh
scope snapshot; never infer citations from prose or model page/timestamp numbers.

## Index lifecycle, invalidation and concurrency

Indexes are derived and in-memory only. The cache holds at most three scopes and
48 MiB of authoritative text as an eviction hint. This is not a process-memory cap:
postings, normalized text, snapshots, windows and Swift allocation overhead also
consume memory. An individual large request can exceed the cache allowance and is
searched without retaining that scope afterward.

Each request captures fresh membership/content. On the retrieval actor, per-source
snapshot equality reuses unchanged documents. New/changed sources alone are
rechunked/revisioned; removed sources disappear. The affected scope's inverted index
rebuilds when its source set/content/labels change. Unchanged queries reuse the index.
Playback, costs, chat edits, duration and project description are not indexed and do
not cause rebuilds. No view-appearance or import-completion rebuild occurs; many
completed imports naturally coalesce into the next requested build. There is no
app-wide rebuild or persisted derived schema migration.

Concurrent requests are serialized by the actor; publication follows cancellation
checks. A service request supersedes/cancels the previous same-scope worker, and
request identities prevent superseded results from publishing. Builder, scoring,
diversification and assembly passes check cancellation. JSON encoding/hash of one
source and individual Foundation sorting operations are bounded synchronous passes
that do not stop midway. `isRetrieving` describes real active work without fabricated
percentages. Project deletion blocks new requests, cancels/awaits project and deleted
recording work, and discards indexes before metadata/file deletion. Failed deletion
can rebuild from authoritative data on the next query.

LRU eviction, explicit removal or service recreation rebuild safely from SwiftData.
There are no persisted cache files to corrupt or orphan. Static signposts cover index
build, lexical search, diversification and assembly; no source text or query appears
in production logs. Retrieval has no network/provider/Keychain dependency, no image
upload and no generation/cost records. Local Only does not alter this local baseline.
`RetrievalBackend` is the extension point for a future backend; embeddings, semantic
retrieval, vector databases and rerankers are absent.

## Validation and measurements

Deterministic tests cover English/Czech/mixed queries, accented/decomposed Unicode,
technical tokens, natural-language filler, phrases, bounded metadata boosts, stable
windows, overlap/deduplication/diversity, original PDF/image/Markdown/audio locators,
JSON safety, hard context budgets, optional neighbors, scope filters, empty/missing
projects, incomplete/failed sources, untranscribed metadata, scope-safe references,
cache reuse/eviction, cancellation, deletion during work, and same-scope supersession.
SwiftData integration tests move/remove recordings, delete sources, edit/replace
transcripts and refresh OCR, then re-query without restarting. Local Only is enabled
in an isolated configuration; project queries create zero generation records.
The service cannot call providers/network APIs by construction. This is not a physical
network-disconnection desktop acceptance test.

Recording-chat regressions verify only recording transcript/attachments are sent;
existing source selection/history exclusion, citation/export and M1–M12.1 tests remain
in the full suite. A heartbeat test verifies main-actor work progresses during worker
indexing; this does not certify desktop frame rate or large production-store faults.

The fixtures represent hours through original segment timestamps and synthetic text,
not physical audio. The ordinary fixture has 20 one-hour recordings, 7,200 segments,
40 PDFs/800 pages and 1,700 windows. Stress has 100 one-hour recordings, 36,000 segments,
200 PDFs/4,000 pages and 8,500 windows, split between project and recording ownership.
Final Debug full-suite component measurements (2026-10-01, arm64 test host):

| Fixture | Cold index preparation | Warm snapshot comparison | Cold / warm search + assembly | Process high-water RSS before / after |
| --- | ---: | ---: | ---: | ---: |
| 20 hours / 1,700 windows | 509 ms | 0.223 ms | 4.73 / 4.52 ms | 271,728,640 / 425,197,568 bytes |
| 100 hours / 8,500 windows | 2,022 ms | 0.998 ms | 21.72 / 20.85 ms | 425,197,568 / 438,124,544 bytes |

Cold preparation includes per-source chunking/revision encoding, index construction and
cache comparison. Query timing includes scoring, diversification, assembly and publication.
It excludes fixture creation and SwiftData capture. The ordinary/stress tests execute
serially, but other test suites run concurrently. Process high-water RSS is an entire
test-host observation (about 405.5 / 417.8 MiB after these operations), not isolated index
allocation, current retained heap or a production-app memory ceiling. Values are one run,
not statistical guarantees or desktop Instruments acceptance.

An earlier uncached-phrase implementation measured about 80 / 389 ms warm queries.
Caching normalized phrase text at build time reduced query work; both variants retained
identical tested relevance/provenance. The measured scale supports an in-memory derived
index for this milestone; persistent indexing is not justified by a demonstrated need.

Final validation: **350 tests in 65 suites passed**, including 13 new test functions
across the three retrieval suites (the performance function has two argument cases).
Debug macOS build/test and Release universal macOS build (arm64/x86_64) passed. No new compiler/concurrency or persistence warnings were found; Xcode's existing
App Intents metadata warning remains. Intentional corrupt-image tests emit ImageIO errors,
which are unrelated to retrieval. New SwiftData integration fixtures use in-memory stores
and a separate temporary managed-file root so deferred faults cannot outlive deleted test
store files.

## Remaining manual acceptance and limitations

- Production-store cold snapshot/fault costs, native navigation/scrolling during
  indexing, real extraction/transcription variability, and repeated-window memory
  plateau still require desktop/Instruments acceptance.
- The cache restarts empty; a new service rebuild is tested, actual quit/relaunch
  desktop interaction is pending. There is no persisted index corruption path.
- Morphology, synonyms and Czech-to-English semantic equivalence are outside lexical
  retrieval. Queries with no lexical evidence return no project matches.
- Source readiness is all-or-completed partial data; sources actively processing are
  excluded rather than exposing half-written units. Missing originals do not prevent
  search of authoritative persisted extracted text; existing source viewers handle
  missing-file errors.
- Main-actor snapshot copies, equality comparisons over unchanged source text, and
  rebuilding the affected scope's postings still scale with project size. The cache
  is per library/window; cross-window coordination remains an existing acceptance item.
- There is no DEBUG inspector or new user-facing project search. Tests are the
  validation surface. Project Chat, generation, persistence and navigation remain M12.3+.

## File inventory for this pass

Created:

- `AudioNotes/Services/Retrieval/RetrievalModels.swift`
- `AudioNotes/Services/Retrieval/RetrievalSnapshot.swift`
- `AudioNotes/Services/Retrieval/LexicalIndex.swift`
- `AudioNotes/Services/Retrieval/ContextAssembler.swift`
- `AudioNotes/Services/Retrieval/ContextRetriever.swift`
- `AudioNotes/Services/Retrieval/RetrievalReferenceIndex.swift`
- `AudioNotesTests/RetrievalEngineTests.swift`
- `AudioNotesTests/ProjectRetrievalTests.swift`
- `AudioNotesTests/RetrievalPerformanceTests.swift`
- `docs/PROJECT_RETRIEVAL.md`

Modified:

- `AudioNotes/Features/Library/LibraryViewModel.swift` (service ownership/deletion)
- `AudioNotes/Services/Sources/RecordingContextRetriever.swift` (lexical adapter)
- `AudioNotes/Services/Sources/SourceContextPreparation.swift` (shared budget)
- `AGENTS.md`, `docs/ROADMAP.md`

The workspace contained substantial existing staged/unstaged/untracked work before
M12.2; this inventory identifies only this pass. No domain/persistence schema or
historical recording/source/reference/generation/pricing data was migrated.
