# M8.3 — Usage & Cost implementation report

Implemented September 30, 2026. Cost tracking remains local and native. The
implementation passes offline validation; live provider and native UI acceptance
are still pending. No API requests were made with a user's credentials for this
verification.

## Files created

- `AudioNotes/Services/Usage/UsageCost.swift`: Decimal money, currency, normalized transcription usage, per-request usage/cost, billing/status enums, pure calculator and adaptive formatter.
- `AudioNotes/Services/Usage/ProviderPricingCatalog.swift`: versioned definitions and immutable persisted snapshots with source metadata.
- `AudioNotes/Services/Usage/UsageTracking.swift`: operation/request lifecycle, LLM wrapper, OpenAI token normalization, usage-preserving errors and aggregation.
- `AudioNotes/Services/Usage/UsageRepository.swift`: recording/library/provider/feature totals, local-calendar ranges and restart reconciliation.
- `AudioNotes/Services/Usage/CostEstimator.swift`: duration/part estimates and explicit-output-ceiling token budget ranges.
- `AudioNotes/Features/Usage/UsageCostView.swift`: native dashboard, operation history, generation details and transcription metadata.
- `AudioNotesTests/UsageCostTests.swift`: domain, network, lifecycle, persistence and workflow tests.
- `docs/USAGE_COST.md`: this report.

## Files modified

These paths describe changes made for M8.3, on top of the existing working tree:

- `App/AudioNotesApp.swift`: reconcile unfinished persisted operations once at launch.
- `Models/GenerationRecord.swift`, `Summary.swift`, `ChatMessage.swift`: persist usage/cost data and generation associations.
- `Services/LLM/LLMProvider.swift`, `Chat/LLMChatTypes.swift`, `Chat/ChatContentNormalizer.swift`: model metadata and normalized usage across response boundaries.
- `Services/LLM/OpenAI/OpenAILLMClient.swift`, `OpenAILLMProvider.swift`, `OpenAILLMRequestDTO.swift`, `OpenAILLMResponseDTO.swift`: retain summary usage, request streaming usage, preserve billed refusal/parse-failure usage and cancel stream producers.
- `Services/ChatGPT/ChatGPTResponsesClient.swift`, `ChatGPTPlanLLMProvider.swift`: retain account-path token usage and preserve authentication isolation.
- `Services/LLM/SummaryRepository.swift`, `Chat/ChatRepository.swift`, `Services/Transcription/TranscriptRepository.swift`: persist operations and retain the model container through asynchronous tasks.
- `Services/Transcription/TranscriptionProvider.swift`, `OpenAI/OpenAITranscriptionProvider.swift`, `OpenAITranscriptionClient.swift`: stable provider/model/billing metadata and part request callbacks before cancellation/result validation.
- `Features/RecordingDetail/RecordingViewModel.swift`, `SummaryViewModel.swift`, `Features/Chat/ChatViewModel.swift`: logical operation lifetimes, request tracking, retry aggregation and associations.
- `Features/Library/LibraryView.swift`, `Features/RecordingDetail/RecordingDetailView.swift`, `SummaryView.swift`, `TranscriptionControls.swift`, `Features/Chat/ChatInspectorView.swift`: optional library cost, totals/dashboard access, summary/history/transcription labels and chat Details.
- `Services/Export/ExportModels.swift`, `ExportContentBuilder.swift`, `MarkdownExporter.swift`, `PDFExporter.swift`, `Features/Export/ExportSheetView.swift`: shared opt-in generation/cost metadata.
- `AGENTS.md`, `docs/ROADMAP.md`: cost invariants, completed implementation and remaining acceptance checks.

Paths above are relative to `AudioNotes/` unless otherwise specified. The existing
Xcode synchronized source groups include new files automatically; this change does
not alter the project file, dependencies or deployment target.

## SwiftData/schema changes

No new `@Model` type. `GenerationRecord` adds optional Codable JSON Data fields for
request usage/cost, calculated cost, transcription estimate and summary budget
range; an optional billing-kind snapshot; optional assistant-message ID; and an
attempt counter with default 1. Its feature/status enums now include transcription,
in-progress and cancelled. `Summary` adds optional generation ID and reported-usage
Data. `ChatMessage` adds optional generation ID. Existing token fields remain for
compatibility; incomplete aggregate categories remain nil rather than fabricated
zero totals.

Decimal amounts remain Decimal in Codable payloads, including pricing snapshots.
New optional/defaulted attributes are designed for lightweight migration. Old
records are not repriced or backfilled with invented usage. Disk reopen, full graph
persistence and recording cascade deletion are covered by tests. Migration against
an archived pre-M8.3 production store has not been manually validated.

The existing recording-to-generation cascade remains authoritative. Clearing chat
or deleting an individual summary leaves the recording's operation history; deleting
the recording removes its costs. There is no separate permanent spending archive.

## Pricing catalog and official verification

`ProviderPricingCatalog` selects the latest definition whose effective date is not
later than the actual request start. Provider/model/operation IDs are stable keys.
Every request saves rates, units, currency, effective/verification dates and source
URL. Totals consume stored costs; opening history never consults today's catalog.
A later app release can add versions. No pricing website is fetched during normal
app use, and no remote manifest or FX service is implemented.

All bundled rates were verified September 30, 2026, using official documentation:

| Provider/model | Input / million | Output / million | Cached input / million | Other |
| --- | ---: | ---: | ---: | --- |
| OpenAI GPT-4o mini, including `2024-07-18` snapshot | USD 0.15 | USD 0.60 | USD 0.075 | Standard text |
| OpenAI GPT-4o alias | USD 2.50 | USD 10 | USD 1.25 | Standard text |
| OpenAI Whisper-1 | — | — | — | USD 0.006 / audio minute |
| Claude Sonnet 4.5 alias | USD 3 | USD 15 | USD 0.30 | Five-minute cache writes USD 3.75 / million |
| Claude Haiku 4.5 alias | USD 1 | USD 5 | USD 0.10 | Five-minute cache writes USD 1.25 / million |
| Gemini 2.5 Flash | USD 0.30 | USD 2.50 | USD 0.03 | Paid-tier standard text |

Sources: [OpenAI pricing](https://developers.openai.com/api/docs/pricing),
[GPT-4o mini](https://developers.openai.com/api/docs/models/gpt-4o-mini),
[GPT-4o](https://developers.openai.com/api/docs/models/gpt-4o),
[Whisper](https://developers.openai.com/api/docs/models/whisper-1),
[Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing),
[Gemini pricing](https://ai.google.dev/gemini-api/docs/pricing).

The catalog deliberately starts at the verification date; it does not assert that
current prices applied to legacy operations. It covers the implemented metered
OpenAI choices and a small future-provider baseline. Claude entries reject contexts
above 200k input tokens rather than invent a long-context rate. Cache writes require
a known matching TTL. New models and unsupported categories remain unavailable.
Regional rates, batch/flex/priority modes, tools, cache storage, enterprise discounts,
taxes and credits are outside these standard rates.

## Money and calculations

`Money` stores Decimal plus a currency code (initial catalog USD). Pricing is created
from decimal strings, never binary floating-point literals. Token costs multiply
full-precision counts/rates and divide by one million. Audio costs multiply Decimal
seconds by the minute rate before division by 60, avoiding repeating intermediate
division. Double is retained for AVFoundation times, converted through a decimal
string at the usage boundary; monetary arithmetic never uses Double.

Normalized input explicitly states whether it includes cached/cache-write tokens.
Inclusive inputs subtract them before regular billing; separated inputs do not.
Reasoning tokens are metadata within normalized output and are not billed twice.
Unknown usage, unsupported rates or categories return a nil amount with an explicit
status. Provider-reported monetary amounts can take precedence and retain their
source/status. Local operations are free API work; subscription-covered operations
have no attributed monetary amount.

`MoneyFormatter` uses adaptive precision, preserving fractions of a cent and showing
`<USD 0.001` in the locale's currency notation for smaller positive amounts. It never
uses display-rounded amounts for totals. Currency codes are extensible; conversion
is not implemented.

## Transcription and multipart aggregation

Whisper uses returned provider duration when available, otherwise the known processed
part duration. Each uploaded part has its own request and pricing snapshot. The
logical operation retains recording duration separately and sums processed duration
and cost across all requests. Cancellation or failed requests without returned usage
remain unavailable. Known completed parts remain in partial library totals.

The current splitter creates contiguous parts with no intentional overlap. If part
ranges overlap or a part is uploaded again, each processed duration is counted; tests
exercise overlap and repeated-part quantities. Local AVFoundation preparation has no
cloud charge. Estimates use recording duration and the existing split plan, label
part count approximate and retain an estimate separately from calculated usage.
The catalog documents minute rates; no undocumented invoice rounding rule is assumed.

## Summaries, hierarchy and retries

A tracking provider wraps the existing hierarchical generator. Every intermediate
summary and final synthesis contributes usage to one GenerationRecord. Intermediate
summaries remain internal; only the final version persists and references that
record. History versions retain their individual costs and original OutputLength.
Unknown internal usage makes the logical total unavailable while retaining known
request costs for partial totals.

Failed-operation retries with unchanged provider/model/authentication accumulate in
the same operation and increment its attempt count. A summary retry also preserves
preset/output-length identity; changed provider settings can begin another logical
operation. Each new request uses its own start-date price. Successful regeneration
creates a new version and operation. Chat retries reuse the failed operation, while
new questions and successful-response regeneration create new operations. Cancelled
attempts are retained, with unreported charges unavailable. Billing after a lost
response cannot be reconstructed; no usage is fabricated.

Short summaries with an explicitly configured output safety ceiling can show an
estimated budget range using the existing transcript token estimator and constructed
prompt. The range spans possible caching and output up to that ceiling. OutputLength
is not converted to an exact token count. Hierarchical-summary and routine chat
pre-flight estimates are omitted because output/context uncertainty is greater.

## Authentication and UI

API-key usage is metered. Only OpenAI's implemented ChatGPT-account path is treated
as plan usage, with `Included with plan` and separate request counts. Google OAuth,
Anthropic App Attest and workload identity resolve to API/cloud billing, not consumer
subscriptions. Billing/authentication metadata contains no credentials or tokens.
Claude and Gemini networking remains unavailable as before; pricing definitions do
not enable it or assume an account's free/paid tier.

UI additions are subtle summary/history/transcription labels, assistant Details,
Chat usage access, recording Usage & Cost, and library View → Show recording cost.
The library footer can show tracked API totals. The dashboard supports Today, This
Week, This Month and All Time using the user's calendar/time zone, operation/feature
and provider breakdowns, and separate plan counts. Empty history says No tracked
usage; incomplete totals identify unknown costs. Totals are computed by a repository
when operation records change, not by traversing chat/summary graphs in view bodies.
Operation history displays provider/model/authentication, tokens, request/attempt
counts, duration quantities and historical cost. AI export metadata is disabled by
default and uses one intermediate model for Markdown and PDF.

## Verification and limitations

Build command: `xcodebuild -project AudioNotes.xcodeproj -scheme AudioNotes -destination 'platform=macOS' -derivedDataPath /tmp/AudioNotes-M83 build`.
Test command: the same options with `test`.

The suite covers Decimal precision/large totals, tiny formatting, cached/separated
inputs, unknown usage/pricing, auth paths, provider monetary precedence, audio
minutes/overlap/retries, estimates, HTTP refusal/SSE usage, hierarchy, logical retry,
unknown-model generation, version effective dates, disk reopen, restart interruption,
cascade deletion, local time ranges and opt-in export. The integrated offline
workflow imports managed audio, transcribes, generates two summary versions, asks
five questions and reopens the persisted library to verify every subtotal.

Remaining acceptance: real provider credentials and invoices, native UI inspection,
application relaunch interaction, and archived-store migration. Rate calculations are
local calculations, not authoritative invoices. API cache/account-tier/discount/tax
or provider rounding differences can affect invoices. No live FX, remote pricing
updates, embedding costs, paid tools or new analytics server is introduced. User
working-tree changes were preserved.

Final automated result: **189 tests in 39 suites passed**, including **32 new test
functions** in the cost test file. The macOS build succeeded and `git diff --check`
passed. No warnings were introduced in M8.3 code. The previously existing unused
`try?` result warning in `PresetsManagementView.swift:128` and Xcode's AppIntents
metadata-extraction warning remain; neither prevents build or tests.
