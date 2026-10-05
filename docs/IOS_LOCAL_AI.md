# M16.7 — On-device AI for iPhone and iPad

This is an uncommitted review candidate based on M16.6. It enables the existing native
WhisperKit transcription architecture on iOS and adds a shared `LLMProvider` adapter
for Apple's on-device Foundation Models runtime. No physical device installation,
production provisioning, commit, push, or M16.8 work is part of this candidate.

## Baseline

- Branch: `m14-swiftui-first`.
- HEAD: `d27ffaf6acd35d6769239205915dfc46cade12e0`, `feat(ios): add project sources and chat`.
- Working tree was clean when work started.
- Fresh baseline macOS run: 462 tests in 82 suites, 456 passed, 6 existing skips.
- Clean archived HEAD iPhone run: 50 tests in 10 suites passed.
- The committed M16.6 acceptance record reports 50 iPad tests passed. An additional
  archived-baseline iPad run failed to bootstrap its Simulator test runner; this is
  not counted as a new successful baseline run.
- Baseline iOS Release Simulator build passed. Bundle: 25,085,577 logical bytes;
  `du -sk`: 24,524 KiB. Same unsigned universal Simulator configuration is used for
  the size comparison below.

## Framework evaluation and scope adjustment

| Option | Findings | Decision |
| --- | --- | --- |
| Existing WhisperKit 1.1.0 | Swift/Core ML; package minimum iOS 16, below this app's iOS 18 target; segment timestamps, language selection/detection, decoding cancellation, existing verified local catalog and offline tokenizer override | Reuse the pinned dependency and runtime. No second Whisper implementation. |
| Apple Foundation Models | Native iOS 26 API, Apple Intelligence eligibility/readiness gate, request-scoped sessions, guided structured output, streaming, task cancellation, system-managed model | Selected initial local LLM runtime. No new package or model weights in the app bundle. |
| MLX Swift / MLX Swift LM | Native Swift/Metal and downloadable quantized models are viable on Apple Silicon devices; introduces runtime/model/tokenizer/package and licensing ownership. Official documentation explicitly rules out Simulator inference | Alternative for an app-managed LLM catalog, not implemented in this candidate. No claim that MLX is unsafe or unviable on devices. |
| Embedded llama.cpp | Official iPhone SwiftUI example supports an XCFramework built from native C/C++; Simulator/device builds are possible. Requires owning the C bridge, native binary, model format, tokenizer, sampling and cancellation integration | No embedded runtime introduced while a system-native provider is available. Existing macOS llama.cpp server integration is preserved. |
| Ollama | Existing macOS/local-network server integration is separate from on-device inference | Preserved on macOS. No Ollama process or server runtime ported to iOS, and no new LAN configuration workflow. |

Sources checked during this pass:
[Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models),
[SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel),
[MLX Simulator limitation](https://github.com/ml-explore/mlx-swift/blob/main/Source/MLX/Documentation.docc/troubleshooting.md),
[official llama.cpp iPhone example](https://github.com/ggml-org/llama.cpp/tree/master/examples/llama.swiftui),
and the resolved Argmax 1.1.0 package sources and Apple SDK Swift interfaces.

**Material difference from the original app-managed LLM proposal:** the language-model
catalog contains one system-managed Apple model. AudioNotes cannot offer Download,
Cancel Download, Delete, a pinned model version, a byte size, or a user-selected
quantization for that model. It reports availability and points users to Apple
Intelligence in system Settings. It neither starts Apple Intelligence setup nor
silently downloads assets when a provider is selected. App-managed download,
verification, deletion and byte accounting apply to Whisper models. A multi-tier,
app-managed language-model catalog remains unimplemented; this choice needs explicit
review when judging the original milestone's complete catalog criteria.

The Foundation Models path requires iOS 26 and an eligible, enabled, ready Apple
Intelligence installation. iOS 18 remains the app deployment target; the provider is
unavailable on older OS versions. Hardware, region, supported language, asset readiness,
and Apple's guardrails can reject a request. No Czech-language quality claim is made.

## Architecture audit and integration

Reusable components are the transcription and LLM protocols/resolvers, capability
and preset descriptors, Local Only wrappers, summary prompt/response models, structured
chat events, source context preparation, Project Chat retrieval/provenance, usage
tracking, native Markdown rendering, persistent histories and export content.

- `LocalWhisperTranscriptionProvider` still implements `TranscriptionProvider`.
  iOS now links WhisperKit and includes the existing worker runtime. Its stable
  persistence ID remains `localWhisper`; iOS presents **On Device**.
- `LocalLLMProvider` implements `LLMProvider`, stable provider ID `onDevice`, model
  ID `apple-system-language-model`. `LocalLLMRunning` is the injectable runtime seam.
- `SystemLocalLLMRuntime` imports Foundation Models only on iOS. macOS builds retain
  Ollama, llama.cpp and Whisper behavior; On Device LLM is excluded from macOS selection.
- Summary, Recording Chat and Project Chat use their existing view models, provider
  resolvers, persistence, stream batching and citation resolution. There is no separate
  local summary/chat service or local feature mode.
- Provider/model preferences and overrides remain independent. Deletion or unavailable
  assets do not rewrite defaults or historical outputs. Unknown model overrides fail;
  they do not silently switch to Apple's model.
- Presets retain saved parameters. Temperature and output ceiling are supported;
  top-p and reasoning controls are deliberately not advertised/passed by this adapter.
  OutputLength remains independent from the output-token safety ceiling. No seed control
  is introduced because the shared preset interface does not expose one.
- `modelDisplayName` is a provider-independent display seam. Stable IDs are retained
  for request identity, with readable names snapshotted for history and exports.
- The privacy wrapper now forwards transcription capabilities, including timestamps
  and unsupported diarization.

## Transcription catalog, licenses and attribution

The unchanged pinned `WhisperModels.json` manifest supplies exact artifact bytes and
SHA-256 values. iOS selects only these multilingual variants; macOS keeps all five
existing entries.

| Model | Stable ID | Exact download bytes | Initial guidance |
| --- | --- | ---: | --- |
| Whisper Tiny | `openai_whisper-tiny` | 79,398,546 | Default for a new iOS preference; smallest download; start here |
| Whisper Base | `openai_whisper-base` | 149,482,602 | Larger download; memory/performance acceptance pending |
| Whisper Small | `openai_whisper-small` | 489,250,614 | May use significant memory; device acceptance pending |

Origins: [Argmax Core ML artifacts](https://huggingface.co/argmaxinc/whisperkit-coreml)
at immutable revision `0f63a7800b00dd0226abd051b906c246e1907482`, with tokenizer
artifacts from the official OpenAI repositories/revisions already recorded per file
in the manifest. The pinned model card declares MIT. Whisper weights/software use
[OpenAI's MIT license](https://github.com/openai/whisper/blob/main/LICENSE).
Preserve its copyright/permission notice when redistributing substantial copies.
`WhisperModels-LICENSE.txt` now accompanies the existing Argmax MIT license and
third-party notices (including Apache-2.0 portions of swift-transformers). Downloaded
artifacts are model/tokenizer data, never arbitrary executable code.

Apple's system language model is not redistributed by AudioNotes. The app consumes
Apple's SDK/framework under the applicable Apple developer/platform terms. No public
repository, third-party model license, weight size or redistribution permission is
inferred for it.

## Transcription behavior

- The existing worker actor converts audio locally and uses sequential 120-second PCM
  windows, independent of upload limits and retrieval chunks.
- Model loading uses `download: false` and the existing local-only tokenizer override;
  missing/malformed tokenizer files fail closed.
- Segment start/end times are offset to the original audio. Language detection and
  explicit supported languages are retained. Transcript-to-audio seeking uses the
  existing segment model. Word timestamps are disabled; speaker diarization is unsupported.
- Progress reports only measured completed audio after a window finishes. No within-window
  percentage or loading ETA is invented. Existing throughput/ETA tracking remains shared.
- Cancellation stops decoding/future windows and unloads the engine. A Core ML load or
  prediction can finish before the next cancellation checkpoint. Failed/cancelled work
  does not save a completed partial transcript.
- Missing models never invoke the runtime or download automatically. Errors are presented
  without raw framework diagnostics or implicit cloud fallback.

## Model management, storage and lifecycle

Settings → Local AI shows native model rows, byte progress, Ready/Not Downloaded/
Downloading/Verifying/Download Failed states, Retry, Cancel and confirmed Delete.
The transcription sheet and Create Transcript surface reuse the model row, allowing
missing-model resolution without a mandatory trip to Settings.

Whisper originals live under managed Application Support:
`AudioNotes/Models/Whisper/<model ID>`. Downloads stage under `.download-<UUID>`.
Known artifact bytes plus a 256 MiB reserve are checked against available capacity
before any transfer. URLSession reports actual transferred bytes. Every file's length
and SHA-256 are checked before the ready marker and final directory publication.
Failures/cancellation clean staging; startup cleans abandoned staging after termination.
Retry starts a clean transfer, without claiming resumable downloads. iOS model storage
is excluded from backups. Models remain in Application Support for predictable offline
availability, rather than a purgeable cache or user-visible Documents folder.

Storage accounting enumerates actual managed files, including temporary staging while
present; inaccessible accounting is **Unavailable**, not a fabricated zero. It excludes
recordings, the database and Apple's system-model storage. The inference lease prevents
model removal/replacement during use. Delete preserves all recordings, transcripts,
summaries, messages, generation history and citations.

`AppServices` owns the shared `LocalInferenceCoordinator`, Whisper store and settings
view model. The gate prevents overlapping heavy Whisper/LLM operations from this app.
Providers also have a private admission gate when injected independently. Whisper
unloads on all operation boundaries. Foundation Models sessions are request-scoped;
stream workers are cancelled/awaited before releasing the gate. AudioNotes does not
retain sessions between requests. Apple may cache its system model; the app cannot
promise to unload Apple's OS-owned resident weights.

Downloads are foreground URLSession operations, not background-transfer sessions.
Backgrounding cancels downloads and active local transcription/summary/chats through
existing interruption/persistence paths. A memory warning interrupts local inference.
A ready directory is never published from a partial transfer. App termination is not
resumable. There is no invented temperature reading or automatic thermal-state cutoff;
iOS schedules/throttles native work. Sustained serious/critical thermal behavior needs
physical acceptance.

## Language-model context, streaming and citations

The provider advertises a conservative 4,096-token text-only context. Shared Project
Chat budgets system instructions, current question, recent history, output and evidence
before local retrieval. Small-context Recording Chat uses its existing source-chunk
path. Summary hierarchy uses the same provider and keeps one final summary version.
The final serialized, escaped user-role messages are estimated again, with a default
1,024-token output reserve and 512-token schema margin. Explicit oversized ceilings or
prompts fail rather than being silently shortened or switched to another model.
On iOS 26.4+, the native runtime additionally counts instructions, user data and guided
schema using Apple's tokenizer, reserves output plus 128 boundary tokens, and rejects
an oversized request before generation. Earlier iOS 26 uses the conservative estimate;
framework rejection remains possible. Budget counts are not billed usage measurements.

The adapter builds a native guided schema from the existing structured response schema.
Generated answer snapshots become ordinary shared text-delta events; final responses
use the existing DTOs. Summary timestamps supplied by the model cannot authorize
navigation. Chat reference IDs/aliases resolve only against supplied transcript/source
snapshots, with Project Chat performing its fresh project-authority checks before
persistence. Hallucinated, duplicate and cross-scope IDs are rejected. Retrieval,
selection, source diversity, original locators and provenance are unchanged.

## Privacy, history and costs

On-device inference receives only local value snapshots. The native adapters have no
URLSession or cloud-provider dependency. Whisper has no inference-time model/tokenizer
network fallback; Foundation Models uses `SystemLanguageModel.default`. Model downloads
are separate explicit actions. Imported data/history remain escaped user-role JSON,
separate from trusted grounding instructions. No prompts, transcript/project contents,
private responses, managed paths or credentials are newly logged.

Local Only continues to gate each provider execution and hierarchy pass. Both native
providers report local execution and local billing. History/UI show **On Device** /
**No API charge**; internal zero Decimal cost is not presented as an API invoice.
Apple's runtime does not supply factual billed token usage through this adapter;
missing counts stay unavailable. Outputs remain readable after Whisper deletion or
Apple-model unavailability. Existing historical pricing and cloud costs are untouched.

## Validation and review evidence

`IOSLocalAITests` exercises provider descriptors/privacy, preset sanitization, escaped
role separation, context overflow before runtime, missing/unknown models, streaming,
reference rejection, runtime failure, cancellation/unload and admission behavior,
shared summary/Recording Chat/Project Chat persistence, mixed PDF/audio citations,
local costs, Whisper mapping/language/progress, and storage/startup cleanup.
`WhisperModelDownloadTests` now runs on iOS as well: successful integrity checks,
corruption, insufficient storage before transfer, progress, cancellation, retry and
lease release use tiny fake files. Normal suites download no production models.
The existing M16.6 large mixed corpus also constructs local prompts under the 4,096-token
budget, preserving project authority. Integration tests use runtime doubles through
`LLMProvider`, not a substitute feature implementation.

Final build/test counts, capture inventory and integrity findings are recorded in
`docs/review/M16.7/README.md`. Captures use DEBUG-only isolated temporary storage,
in-memory SwiftData, synthetic state and offline runtime doubles. The capture script
uses `simctl`, not physical installation or production accounts. Section-filtered
captures are component layouts from the actual Local AI view; they do not establish
manual scrolling acceptance. Provider-label/chat fixtures establish layout, while
service integration tests establish the local-provider state and citation path.

## Performance and limits

Whisper catalog byte sizes are measured manifest values, not estimated RAM requirements.
No real Whisper/LLM model was downloaded for benchmarking. Core ML/Apple Intelligence
Simulator behavior does not establish on-device ANE/GPU speed or memory. Native model
load time, real-time factor, TTFT, tokens/sec and inference RAM remain unmeasured.
Physical inference, Airplane Mode, memory pressure, sustained thermals, battery use,
quality across languages/model variants and Apple's supported-language/guardrail
behavior remain intentionally deferred until production Apple identity/signing is decided.
No Airplane Mode acceptance is claimed from mock, network-independent tests.

The unsigned universal iOS Release Simulator bundle comparison is recorded with exact
logical bytes in the review README; weights are absent from the bundle. The system LLM
adds no packaged weights/dependency; enabling WhisperKit adds native runtime code.
Simulator bundle size is not a signed/thinned App Store device download-size claim.

Native iPhone/iPad Settings, the existing visual controls, semantic colors, textual
status, byte accessibility values and stable action identifiers are retained. Light,
Dark and accessibility Dynamic Type captures are listed in the review inventory.
Physical VoiceOver and gestures/keyboard/scrolling/delete/provider-selection tapping
remain deferred: the device tool returned **Agent device access is turned off for this
 environment**. No live cloud provider, physical installation, signing registration,
commit or push was performed.

## Completion assessment

The shared native transcription/provider/model-management architecture is implemented
and covered offline. The native LLM provider and all three shared consumers are
implemented, buildable and covered with runtime doubles. Production runtime quality,
performance and device acceptance have not been established.

The candidate implements the **system-managed Apple LLM variant**, not the originally
suggested multi-tier app-managed LLM download catalog. Apple Intelligence compatibility
is a concrete product limitation; MLX/embedded llama.cpp remain alternatives rather
than being declared technically blocked. Consequently, the original full catalog and
language-model management criteria must not be declared fully complete. This is ready
for architectural review with that explicit scope difference; final commit/acceptance
requires resolving it and the recorded remaining checks. M16.8 is not started.
