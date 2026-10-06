# M10 — Local AI implementation report

M10 adds native Local Whisper transcription and Ollama summaries/chat without changing the transcript, chat rendering, source, or export data models. Implementation and automated checks are complete for the functionality listed below. Full desktop/offline acceptance remains open; M10 is not declared fully accepted and M11 has not been started.

## Providers and privacy

`OllamaLLMProvider` and `LlamaCppLLMProvider` implement `LLMProvider`; `LocalWhisperTranscriptionProvider` implements `TranscriptionProvider`. Provider IDs (`ollama`, `llamaCpp`, `localWhisper`) are stable identifiers. llama.cpp connects to a separately started `llama-server` through its OpenAI-compatible chat completions endpoint. The server model name and endpoint are configurable; Soniquill does not launch the server. Its API is currently non-streaming and text-only. `ProviderExecutionLocation` distinguishes local, remote-server, and cloud execution independently of billing. Existing mock/cloud providers remain independently selectable for transcription, summary, and chat. Saved summary presets resolve their provider/model override through the same resolver and privacy boundary.

`LocalAIConfiguration` stores non-secret preferences: Local Only, Ollama and llama.cpp server addresses/model names, independent Ollama summary/chat model names, context budget, Whisper model, and language. No new credentials are needed or stored. `PrivacyLLMProvider` and `PrivacyTranscriptionProvider` evaluate Local Only below SwiftUI, when a generation starts and before each hierarchical summary request. Cloud and remote-server inference are rejected before entering the underlying provider; there is no cloud or model fallback. This policy does not forbid deliberate model downloads or account setup, which do not send source content. Enabling the switch cannot undo data sent by a request that was already in flight; stop active cloud jobs before changing privacy configuration.

Only exact `localhost`, `127.0.0.1`, and `::1` endpoints are classified as running on this Mac. LAN IPs, `.local` names, lookalike domains, and other hosts are remote. HTTP/HTTPS endpoints may specify a port but cannot embed credentials, query strings, fragments, or custom paths. Inference redirects are refused; the default Ollama session disables proxy configuration, cookies, and cache. Remote Ollama is an external service with unknown billing, never labeled fully local.

A localhost Ollama server can itself route to cloud models. The client rechecks `/api/show` **before every content request**, rejects `remote_host`, `remote_model`, `:cloud` models, and unverified architecture metadata. This is a conservative boundary for standard Ollama installations, not a defense against a compromised local server deliberately lying about its implementation. No API keys or unrelated app metadata are sent to Ollama.

## Ollama API and models

Official documentation checked September 30, 2026:

- [Chat API](https://docs.ollama.com/api/chat), [model list](https://docs.ollama.com/api/tags), [model details](https://docs.ollama.com/api-reference/show-model-details)
- [Streaming](https://docs.ollama.com/api/streaming), [structured output](https://docs.ollama.com/capabilities/structured-outputs), [vision](https://docs.ollama.com/capabilities/vision)
- [Usage](https://docs.ollama.com/api/usage), [errors](https://docs.ollama.com/api/errors), [context length](https://docs.ollama.com/context-length)
- [Pull](https://docs.ollama.com/api/pull), [cloud behavior](https://docs.ollama.com/cloud), [official response types](https://github.com/ollama/ollama/blob/main/api/types.go)

The default server is `http://localhost:11434`. Settings > Local AI offers connection testing and refresh, and refreshes when opened without continuous polling. GET `/api/tags` supplies names/sizes; POST `/api/show` supplies capabilities and architecture context length. Cloud-backed, corrupt, embedding-only, or unverified entries are excluded from the usable chat list. An unavailable selected model stays selected with a setup message. Discovery never replaces it with the first installed model. Connection state is distinct from the number of usable models.

LAN servers require macOS local-network permission. The app declares `NSLocalNetworkUsageDescription`; if access is denied, enable Soniquill in System Settings > Privacy & Security > Local Network and retry. `Configuration/AudioNotes-Info.plist` permits HTTP local networking and contains a narrow HTTP exception for the configured lab server `mac.lab`. Custom qualified DNS names need HTTPS or their own explicit ATS domain exception; ATS remains enabled for other domains. A LAN server remains remote and requires Local Only to be disabled. DNS, timeout, ATS, and network failures have separate remediation messages. See Apple's [local network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) and [ATS local networking documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking).

To opt into sandboxed discovery against a chosen server without inference or source uploads, run `TEST_RUNNER_AUDIONOTES_LIVE_OLLAMA=1 TEST_RUNNER_AUDIONOTES_LIVE_OLLAMA_ADDRESS=http://mac.lab:11434 xcodebuild -project AudioNotes.xcodeproj -scheme AudioNotes -destination 'platform=macOS' -only-testing:AudioNotesTests/LocalAILiveTests test`. The Whisper smoke test stays disabled unless separately enabled.

LAN connection validation (2026-10-01): the app build and 30 Ollama/local-policy tests passed. `/usr/bin/curl` reached `mac.lab:11434`, listed three models, and retrieved valid vision model metadata. The opt-in sandboxed discovery test failed with URLSession `-1009` (network unavailable, underlying network error 50 despite a satisfied path), consistent with local-network access being denied. Granting Soniquill local-network permission and rerunning discovery remains manual acceptance; a successful sandboxed LAN connection is not claimed. The build emitted only the existing AppIntents metadata extraction notice.

llama.cpp LAN validation (2026-10-01): the configured server at `mac.lab:11435`
(resolving to `192.168.123.238`) responds to metadata-only command-line checks and
reports a 4,096-token slot for the selected model. An app-native metadata test first
failed with ATS `-1022`; the exact `mac.lab` HTTP exception now fixes that rejection.
The rebuilt app then fails with URLSession `-1009` / underlying network error 50,
with a satisfied Wi-Fi path. This is consistent with app-specific Local Network
access being denied; it is not proof that the server is down. The current Debug
configuration has App Sandbox disabled, so this is app-native networking validation,
not a sandbox acceptance claim. The build and ten relevant offline tests pass.
Successful live app access remains pending enabling Soniquill in macOS Local Network
settings and retrying. No source content or inference was sent by this live check.
Llama.cpp transport errors now retain provider, endpoint, operation and URLSession
code, with distinct ATS/DNS/timeout/TLS/network guidance; they no longer claim Ollama
is unreachable. The new opt-in `LocalAILiveTests.nativeAppCanReadLlamaCppContext`
requires `TEST_RUNNER_AUDIONOTES_LIVE_LLAMACPP=1`, plus
`TEST_RUNNER_AUDIONOTES_LIVE_LLAMACPP_ADDRESS` and
`TEST_RUNNER_AUDIONOTES_LIVE_LLAMACPP_MODEL`. It reads only `/props`.

POST `/api/chat` uses non-streaming generation for summaries and NDJSON streaming for chat. `format` carries the existing provider-independent JSON schema; it is also included in the prompt. Temperature/top-p map to `options.temperature`/`top_p`; the output safety ceiling maps to `num_predict`; context maps to `num_ctx`. Ollama output is capped at the smaller of the requested ceiling and one quarter of context, with a 2,048-token default. OutputLength remains a separate requested detail instruction. `truncate:false` and `shift:false` request failure instead of silently dropping grounded context. `keep_alive:0` requests model release after generation. Ollama controls scheduling; hierarchy passes are sequential.

Chat uses `StreamingJSONAnswerParser` to expose Markdown deltas, validates the complete JSON at completion, and resolves returned IDs against selected authoritative transcript/source snapshots. A truncated transport or invalid final structured answer fails rather than saving a completed answer. Numeric model timestamps never authorize local-summary links. Source citations retain authoritative audio timestamps, PDF pages, document ranges, and image anchors.

Vision is enabled only by reported `vision` capability, with at most two prepared JPEG inputs and the existing per-image size ceiling. REST messages carry base64 image data and corresponding source chunk IDs. Text-only or unknown models receive local OCR/text. Existing native Markdown rendering is shared unchanged.

The model context is the smaller of the configured budget and metadata, with a conservative 16,384-token fallback. Retrieval accounts for history, output reserve, instruction reserve, and image budget; payload construction checks the full text prompt/schema/output budget again. Approximate counts are budgeting only. Metadata can change between refresh and generation; a smaller newly reported window causes a useful error rather than truncation. Image token estimates cannot precisely predict every model's tokenizer. Very small context windows or unusually long individual source units can require a larger context/model.

Ollama is never bundled, installed, launched, stopped, or repaired by Soniquill. Pull behavior was reviewed; an in-app Ollama marketplace/pull UI is deliberately deferred. Use the official Ollama website/application to install models.

llama.cpp request compatibility (2026-10-01): `/v1/chat/completions` uses
`response_format: {"type":"json_object","schema":…}` with the full shared summary/chat
schema. This is the schema-constrained form documented in the [official server API](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md#post-v1chatcompletions-openai-compatible-chat-completions-api),
and avoids requiring support for the newer nested OpenAI `json_schema` wrapper.
HTTP errors display the bounded `error.message` diagnostic; missing/non-JSON details
use status-specific guidance without dumping the response body. No automatic retry,
format relaxation, model switch, or cloud fallback is added.

llama.cpp context budgeting (2026-10-01): unknown server metadata starts with a
conservative 4,096-token descriptor, rather than the generic 100,000-token fallback.
Summary preparation reads the selected model's per-slot `default_generation_settings.n_ctx`
from [GET /props](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md#get-props-get-server-global-properties).
Missing/invalid metadata fails before inference. Prompt sizing uses the same server's
`/apply-template` and `/tokenize`, below the privacy boundary with redirects blocked;
these requests produce no generation/cost records. A dropped connection (URLSession
`-1005`) triggers one immediate retry for these read-only metadata/sizing operations,
with cancellation and Local Only rechecked before the retry. Inference is not retried
automatically because the server may have completed work before its response was lost.
The error distinguishes a dropped connection from unavailable network access; `-1005`
alone does not establish a Local Network permission denial. The server's `/health`
and `/tokenize` endpoints responded to command-line checks with synthetic text on
2026-10-01. The opt-in native app-hosted `/props` test also passed against
`mac.lab:11435` with the selected model (one live test, Ollama/Whisper tests skipped).
The build and 24 selected offline tests passed, including transient recovery,
bounded persistent failure, cancellation, and no inference retry. Only the existing
AppIntents metadata-extraction notices appeared. Successful app-native generation
with a real transcript remains unverified.
Every inference reserves 256 tokens
of template slack plus an output ceiling capped at one quarter of the server context.
OutputLength remains the requested final detail. Oversized source chunks are split into
request-only text fragments retaining original IDs/locators; stored source text is
unchanged. Initial groups, derivative notes and final synthesis are checked before
inference. Derivative notes carry at most eight short authoritative anchors, further
bounded by the context budget, and repeated anchors are deduplicated. Cancellation and
Local Only checks apply to metadata, sizing, and every inference request. Live acceptance
against the user's server remains pending. Offline tests cover a long Czech source in a
simulated 4,096-token context, original text/locator preservation, final references and
OutputLength, measured over-budget rejection, invalid metadata, privacy, usage, and 400
diagnostics.

Repeated llama.cpp sizing validation (2026-10-01): an app console log contained
39 dropped HTTP requests (21 `/tokenize`, 18 `/apply-template`). A native app-hosted
test with 150 synthetic source prompts reproduced 16 drops, all recovered by the
bounded retry. Requesting `Connection: close` for HTTP metadata/sizing requests
then completed the same 150 checks with zero HTTP drops in 12.4 seconds (baseline
13.4 seconds). HTTPS keeps normal pooling; inference retains its existing transport
and is never automatically retried. This is evidence of a connection-reuse
compatibility issue, not proof of a specific server/router defect. The server
responses advertised both `Connection: close` and `Keep-Alive`. The opt-in
`nativeAppCanRepeatedlySizeLlamaCppPrompts` test sends synthetic text only and
performs no inference. The build and selected offline/live suites passed (17 tests,
including two skipped Ollama/Whisper live tests); only the existing AppIntents build
notice appeared. macOS `nw_path_necp_check_for_updates` diagnostics still appeared
during successful checks. Real-transcript generation remains manual acceptance.

## Whisper runtime and model management

Chosen runtime: [Argmax WhisperKit](https://github.com/argmaxinc/argmax-oss-swift), MIT, pinned to **1.1.0** (`1e2a163736dfa5a198e637ae44c114e1c6d5cc2d`). The Xcode target links only the WhisperKit product and its native ArgmaxCore dependency, not the CLI, server, TTS, or diarization products. The package resolves Apple's ArgumentParser as a tooling dependency; it is not linked into inference. This is the justified third-party dependency for native speech inference.

[whisper.cpp](https://github.com/ggml-org/whisper.cpp) was evaluated: maintained C/C++ inference, CPU/Metal support and broader Intel compatibility are useful, but it requires maintaining a C bridge, native binary integration, PCM preparation, and model/runtime ownership. WhisperKit provides a maintained Swift/Core ML pipeline and existing audio/language/timestamp APIs with a smaller app integration surface. It targets macOS versions below Soniquill’s macOS 15 deployment target and is suited to Apple Silicon. M10 enables Local Whisper only on arm64; Intel builds show an unavailable state while cloud/Ollama choices remain available. The x86_64 macOS build was also verified; Intel Core ML inference performance/compatibility is not claimed. Upstream MIT license and third-party notices are included as bundled text resources.

Bundled `WhisperModels.json` describes Tiny, Base, Small, Medium, and Large v3 Turbo multilingual Core ML variants from [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml). Each URL pins an immutable repository revision. The tokenizer files come from the pinned official OpenAI multilingual tokenizer repository, with the large-v3 tokenizer used for the large-v3 vocabulary. Every catalog file includes exact bytes and SHA-256; LFS hashes were taken from repository metadata and small files were hashed when preparing the bundled manifest. Model files are data and are never executed as arbitrary binaries.

Managed storage: Application Support/AudioNotes/Models/Whisper/<variant>. Files never enter SwiftData. A private staging directory receives downloads; size/hash checks precede publication of a ready marker and atomic directory move. Failed/cancelled staging data is deleted; retry starts again, with no unsafe partial resume. Available capacity is checked before download, including a 256 MiB margin. Confirmed download/removal actions show measured repository byte sizes. Progress comes from URLSession download byte callbacks across files, with no fabricated percentages. A lease prevents removal, another download, or another Whisper model inference while a model is in use. Recordings and their persisted content are untouched by model deletion.

Inference cannot automatically download models or tokenizers. `OfflineWhisperKit` overrides the upstream tokenizer loading entry point because upstream's `download:false` does **not** prevent its tokenizer fallback from accessing the Hub. The override parses local files directly and fails closed. The adapter is intentionally segment-only; word timestamp/highlighting support is deferred.

## Local transcription, progress and cancellation

`LocalWhisperRunning` is an injectable runtime boundary. `WhisperKitRuntime` runs in a worker actor, prepares bounded 120-second PCM inference windows using native audio conversion to 16 kHz mono, and processes them sequentially through Core ML. The original audio stays authoritative. There are no cloud upload chunks, no 25 MB ceiling, no temporary encoded upload files, and no Python/Homebrew/backend requirement.

Each returned segment time is offset by its window's original start. Empty text is removed; non-finite, negative, reversed, or empty transcript results are rejected. Auto Detect and runtime-supported language codes are available; primary output remains transcription in the spoken language. Translation and word-level display are deferred. Fixed inference boundaries can reduce quality around window edges; broader real-recording evaluation is still needed.

Processed-audio progress is reported only after a completed inference window. Existing progress tracking computes a smoothed measured throughput and ETA from those observations; loading/within-window inference has no invented percentage. Generation history stores the selected human-readable model title, execution location, logical job duration and cost classification; processing speed can be derived from original duration divided by elapsed time. Internal inference windows do not become separate generation records.

Task cancellation reaches URLSession downloads and WhisperKit's decoding callback/task checks; it stops future windows and unloads models on success/failure/cancellation. An individual Core ML prediction/model-load operation can finish before the next cancellation checkpoint. Cancellation never saves a completed partial transcript. Active library tasks retain the existing lifetime behavior and are not resumable across app termination.

## Transcript regeneration and history

The Transcript tab offers **Regenerate…**, including Local Whisper with the selected model/language settings. Successful regeneration archives the previous transcript; cancellation, provider failure or persistence failure keeps it current. **History** supports reading/searching/seeking earlier versions, restoring one as current, and confirmed deletion of historical versions. Versions preserve original segment IDs, timestamps, language, provider provenance and a generation-record link for model/usage details. Audio files are not duplicated. Existing stores gain optional/defaulted version relationships and generation links. Restore/delete are disabled during active transcription; deletion of a recording cascades all versions. Existing summaries/chats are not rewritten, and reference resolution remains against the current authoritative transcript. See [transcription architecture](TRANSCRIPTION.md).

## M9, cost, persistence and export

PDFKit, native Vision OCR, document extraction, and lexical retrieval remain local. Ollama uses the same RecordingSource/SourceChunk path for multi-source summaries and chat; legacy audio-only local jobs also use source context for smaller model budgets. Sequential hierarchical summaries aggregate every intermediate request into one logical generation and retain final requested OutputLength. Presets can save discovered Ollama model names and never replace missing models.

Local Whisper and localhost Ollama use BillingKind.local and display “Local · No API charge.” Remote Ollama uses unknown external billing; cloud providers retain their metered/subscription semantics. Decimal monetary calculations and historical pricing snapshots are unchanged. Actual Ollama final `prompt_eval_count`/`eval_count` supply token usage; missing counts remain unavailable. Nanosecond generation timings support optional tokens/sec in generation details. Local inference duration supports realtime-factor display. Local processing contributes no metered API amount; unavailable external costs remain unavailable. Optional execution-location/model-title fields on GenerationRecord preserve legacy records.

Both existing exporters consume the same ExportContent. Optional generation details include local/remote classification and human-readable Whisper model titles, never model storage paths. Markdown/PDF content, citation authority and chat rendering use the existing M8/M9 implementation.

The existing outgoing-network sandbox entitlement allows loopback Ollama and deliberate HTTPS model downloads. Existing incoming-network permission is for account loopback authentication, not Whisper. Application Support model files are inside the app's managed container. No sandbox disabling, global filesystem entitlement, WebView, or backend service was added.

## Validation and remaining acceptance

Automated offline suites cover endpoint classification, execution-time privacy gates, no cloud invocation, persisted preferences, model listing/metadata, vision rejection, request options, context preflight, usage normalization, NDJSON/completion/error/cancellation handling, multi-source Markdown/citation boundaries, hierarchy/usage aggregation, missing Whisper models, timestamps/languages, measured ETA, download integrity/cleanup, low disk space, leases and deletion. Existing source/migration, persistence, Markdown, export, OpenAI and ChatGPT tests continue to run.

The opt-in native test downloads Tiny (~80 MB) to a temporary directory, verifies installation, transcribes the upstream English JFK fixture, optionally transcribes a supplied Czech AIFF, transcribes repeated audio across two inference windows to verify original offsets, cancels active native inference, removes the model and deletes test files. The Czech smoke input was synthesized locally with the installed Zuzana voice. Tiny's Czech output retained content but showed spelling/diacritic errors; this is an integration check, not an accuracy benchmark. The final live run passed. The final normal suite passed **262 tests in 52 suites** (the two native tests remain opt-in). The macOS target build succeeded and `git diff --check` was clean.

Run normal tests with `xcodebuild -project AudioNotes.xcodeproj -scheme AudioNotes -destination 'platform=macOS' test`. Enable the native smoke test deliberately with `TEST_RUNNER_AUDIONOTES_LIVE_WHISPER=1`; optionally pass `TEST_RUNNER_AUDIONOTES_LIVE_CZECH_PATH=/absolute/path/to/speech.aiff`. Normal tests do not download/load models or require Ollama.

The native sandboxed localhost-discovery check passed with existing entitlements. This Mac's Ollama server responds to `/api/tags`, but inspected entries fail `/api/show` with missing weight blobs. Soniquill does not repair or silently change that installation. Successful live Ollama summary/chat/vision/hierarchy and offline full-workspace desktop acceptance therefore remain pending. Also pending: real Czech/English recording quality, >1 hour completed transcription, all model sizes, Intel manual unavailable controls, relaunch UI and archived production migration, model-management and transcript-regeneration/history desktop interaction, and network-disconnected export/source/citation acceptance. No unperformed manual checks are marked complete.

A final parallel regression run exposed an existing chat-stop test's 80 ms scheduling assumption. The assertion now checks a valid streamed prefix and lossless final stopped content, while separate draft-publication tests retain batching coverage.

Compiler warning review: no new warnings from the M10 implementation. Existing unused `try?` warning in PresetsManagementView and Xcode's AppIntents metadata extraction notice remain. Live network fixture downloads also report the machine's proxy-PAC DNS diagnostic; downloaded data/hash checks and native inference still succeeded.

## File inventory and future seams

Created: Services/LocalAI/{LocalAIConfiguration,PrivacyProviders}.swift; Services/LLM/Ollama/{OllamaClient,OllamaLLMProvider}.swift; Services/LLM/StructuredResponseSchema.swift; Services/Transcription/LocalWhisper/{LocalWhisperTranscriptionProvider,WhisperKitRuntime,WhisperModelStore}.swift and WhisperModels.json and bundled WhisperKit license/notices; Features/Settings/{LocalAISettingsView,LocalAISettingsViewModel}.swift; Features/RecordingDetail/TranscriptHistoryView.swift; Tests/{LocalAITests,OllamaTests,OllamaProviderIntegrationTests,WhisperModelDownloadTests,LocalAILiveTests}.swift; docs/LOCAL_AI.md; SwiftPM Package.resolved.

Modified integration points: AppServices/AudioNotesApp; LLMProvider, LLMProviderResolver, LLMConfiguration, LLMModelCapabilities; shared/OpenAI structured DTO/schema/parser boundaries; TranscriptionProvider, TranscriptionProviderResolver, TranscriptionConfiguration; SourceContextPreparation, MultimodalContextService, MultiSourceSummaryGeneration; SummaryViewModel/SummaryView, ChatViewModel/ChatInspectorView, RecordingViewModel/TranscriptionControls/TranscriptionProgressModel; ProviderSettingsView and PresetEditorView; GenerationRecord, UsageTracking, UsageCost, UsageRepository/UsageCostView; Recording/Transcript, TranscriptRepository and transcript-history/regeneration tests; existing resolver identity tests and chat stop regression (removed a wall-clock race assertion); AGENTS.md and ROADMAP.md. Pre-existing uncommitted M1–M9 work was retained.

Relevant future seams: runtime protocol isolates WhisperKit; provider descriptors isolate local discovery; privacy gates stay below views; model catalog/data integrity is versioned with the app; source retrieval and structured references stay provider-independent. Improvements can add word alignment, smarter speech boundaries, shared resource scheduling, resumed downloads, and additional native runtimes without replacing persisted transcripts or source IDs. No M11 functionality was started.
