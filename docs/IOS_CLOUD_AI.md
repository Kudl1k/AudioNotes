# M16.4 — iOS Cloud AI: Transcription, Summary & Recording Chat

## 1. Executive Summary

M16.4 implementation and automated acceptance are complete under the acceptance amendment. It reuses the existing transcription pipeline, summary generator, chat engine, context retriever, prompt builder, and usage/cost tracking rather than creating a separate mobile AI stack. Gemini transcription is integrated in the shared provider architecture. Live-provider acceptance was not performed because no authorized real account session was available. Physical-device/signing acceptance is intentionally deferred until the company Developer Team and production bundle identity are selected; neither is an M16.4 completion gate.

Key achievements:
- **Zero Architecture Duplication**: `RecordingViewModel`, `SummaryViewModel`, `ChatViewModel`, `OpenAITranscriptionProvider`, `OpenAILLMProvider`, and `ContextRetriever` execute identically on iOS and macOS.
- **Platform Capability Alignment**: iOS supports OpenAI API-key transcription, ChatGPT-plan Responses inference for eligible summary/chat requests, and Gemini OAuth for Developer API summary/chat/transcription. Gemini Advanced subscription access is not an API entitlement.
- **Native iOS Presentation & Interactions**:
  - Transcription progress, ETA, and cancellation integrated into [`IOSRecordingDetailShell`](file:///Users/stepankudlacek/XcodeProjects/AudioTranscript/AudioNotes/Platform/iOS/IOSRecordingDetailShell.swift).
  - Transcript segment-to-audio seek synchronization with active playback.
  - Markdown summary streaming with preset selection and generation history retention.
  - Native iOS multi-line chat composer with automatic keyboard avoidance, message bubbles, streaming SSE, and citation seeking.
  - Granular Usage & Cost breakdown sheet.
  - Secure ChatGPT account and OpenAI API credential management in native iOS Settings. Google account connection uses the configured native OAuth client and registered callback scheme.
- **Schema & Project Integrity**: Zero SwiftData schema changes. The required `objectVersion = 77` is preserved in the final candidate.
- **Current verification**: full macOS, iPhone Simulator, and iPad Simulator suites pass; macOS Release and iOS Simulator Debug/Release builds pass. Live-provider acceptance was not performed; physical-device acceptance is deferred to release signing.

---

## 2. Architecture & Reuse

```
                  ┌──────────────────────────────────────────────┐
                  │              Shared Domain Layer             │
                  │   Models: Recording, Transcript, Summary,    │
                  │   ChatMessage, GenerationRecord, Preset      │
                  └──────────────────────┬───────────────────────┘
                                         │
                  ┌──────────────────────┴───────────────────────┐
                  │             Shared ViewModels                │
                  │  RecordingViewModel, SummaryViewModel,       │
                  │  ChatViewModel, ProviderSettingsViewModel    │
                  └──────────────┬───────────────┬───────────────┘
                                 │               │
                 macOS Frontend  │               │  iOS Frontend
            ┌────────────────────┘               └───────────────────┐
            │                                                        │
   macOS Detail / Inspector                                 IOSRecordingDetailShell
   - Two-column / split-view                                - Compact & Regular adaptive
   - AppKit Chat Composer                                   - Shared/Native ChatComposer
   - Mac Settings Scene                                     - Pushed / Sheet Navigation
            │                                                        │
            └────────────────────┬───────────────────────────────────┘
                                 │
                  ┌──────────────┴───────────────────────────────┐
                  │            Shared Services Layer             │
                  │  OpenAITranscriptionProvider, OpenAILLM,     │
                  │  MultipartSplitter, ContextRetriever,        │
                  │  KeychainService, UsageCostService           │
                  └──────────────────────────────────────────────┘
```

### Components Reused As-Is:
1. **Transcription Pipeline**: `RecordingViewModel`, `OpenAITranscriptionProvider`, `AudioSplitPlan`, `AudioSplitter`, and `MultipartTranscriptionCoordinator`.
2. **Summary Pipeline**: `SummaryViewModel`, `SummaryPromptBuilder`, `OpenAISummaryDTO`, and `HierarchicalSummaryGenerator`.
3. **Chat Engine**: `ChatViewModel`, `ChatContextBuilder`, `ContextRetriever`, `PromptContext`, and streaming SSE parser.
4. **Usage & Cost Tracking**: `UsageCostService`, `GenerationRecord`, and `UsageCostView`.
5. **Persistence**: SwiftData container and models (`Recording`, `Transcript`, `Summary`, `ChatMessage`, `GenerationRecord`).

### Adapted / Native Platform Components:
1. **[`ChatComposer`](file:///Users/stepankudlacek/XcodeProjects/AudioTranscript/AudioNotes/Features/Chat/Shared/ChatComposer.swift)**: Cross-platform interface. On macOS, uses the existing custom AppKit `NSTextView` wrapper; on iOS, uses a native SwiftUI `TextField(axis: .vertical)` with Dynamic Type sizing, clear buttons, send action, and keyboard avoidance.
2. **[`ChatMessageBubble`](file:///Users/stepankudlacek/XcodeProjects/AudioTranscript/AudioNotes/Features/Chat/Shared/ChatMessageBubble.swift)**: Platform-adaptive bubble with custom background styling, message status indicators, copy actions, and citation chips.
3. **[`IOSRecordingDetailShell`](file:///Users/stepankudlacek/XcodeProjects/AudioTranscript/AudioNotes/Platform/iOS/IOSRecordingDetailShell.swift)**: Hosts segmented views (Transcript, Summary, Sources) with audio playback seeking, operation progress overlays, and dedicated sheets for Chat, Usage & Cost, and Regeneration alerts.
4. **[`IOSSettingsView`](file:///Users/stepankudlacek/XcodeProjects/AudioTranscript/AudioNotes/Platform/iOS/IOSSettingsView.swift)**: Configures OpenAI API keys and connects ChatGPT/Google accounts; OAuth credentials are stored in Keychain.

---

## 3. Provider Availability & Boundary Policy

Per the platform boundary matrix:
- **OpenAI**: ChatGPT plan Responses API supports eligible summaries/chat after explicit plan-use consent. Its account token is never sent to `/audio/transcriptions`. ChatGPT-plan requests omit `temperature`, `top_p`, and `max_output_tokens`; saved values remain available when switching to API-key auth.
- **Anthropic**: Disabled on iOS. The current implementation relies on the macOS `claude` CLI binary (`Process`).
- **Google Gemini**: iOS uses its platform-specific OAuth client through `ASWebAuthenticationSession`; macOS continues using the Desktop loopback client. Gemini transcription uses the official Files API and Interactions API, requests word timestamps and speaker labels, enforces the documented 30-minute limit, and deletes uploaded files after use. Billing belongs to the configured Cloud project.
- **Ollama / llama.cpp**: Disabled on iOS for M16.4. Deferred to M16.7 (LAN Ollama integration with `NSLocalNetworkUsageDescription`).
- **Local Whisper**: Disabled on iOS for M16.4. Deferred to future evaluation due to memory footprint and background execution constraints.

The platform boundary is enforced via [`PlatformCapabilities.isSupported(llmProvider:)`](file:///Users/stepankudlacek/XcodeProjects/AudioTranscript/AudioNotes/Platform/PlatformCapabilities.swift) and [`LLMProviderResolver`](file:///Users/stepankudlacek/XcodeProjects/AudioTranscript/AudioNotes/Services/LLM/LLMProviderResolver.swift).

See [iOS account authentication](IOS_ACCOUNT_AUTH.md) for official sources, capability matrix, token lifecycle, and interactive acceptance still required. Simulator-tested and physical-device-tested are separate states. No live provider request or real credential was used for automated validation.

### Capability and evidence matrix

| Authentication | Transcription | Summary | Recording Chat | Models and billing |
|---|---|---|---|---|
| OpenAI API key | Supported (`/audio/transcriptions`) | Supported | Supported | API model catalog; metered API usage |
| ChatGPT plan | Unsupported in AudioNotes | Supported through eligible Responses API | Supported through eligible Responses API | Authenticated account model catalog; eligible usage may be covered by the authorized plan |
| Gemini OAuth | Supported via Gemini 3.5 Transcribe | Supported via Gemini Developer API | Supported via Gemini Developer API | Google Cloud project quota/billing; transcription cost unavailable when exact usage is not reported |

Implementation, Simulator testing, live-provider testing, and physical-device testing are distinct states. Implementation and automated Simulator acceptance are complete; no live ChatGPT/Google sign-in or inference was performed because no authorized real account session was available. Physical-device acceptance is deferred to release signing and does not block M16.4.

---

## 4. Workflows

### 4.1. Cloud Audio Transcription
1. User chooses a transcription provider and taps Transcribe.
2. `RecordingViewModel` prepares managed audio and invokes the selected shared `TranscriptionProvider`.
3. OpenAI API-key transcription retains its existing 25 MB chunking path. Gemini uses the Files API and timestamped/diarized transcription, with a documented 30-minute limit; it does not reuse OpenAI's chunk threshold.
4. Progress shows factual phases, elapsed time, and measured ETA when available. Gemini reports upload/processing without invented percentages.
5. On success, the provider-independent `Transcript` and `GenerationRecord` are persisted. Gemini duration usage is recorded; cost stays unknown when exact price cannot be calculated from returned usage.
6. Cancellation or failure does not replace a valid transcript with a partial result; Retry uses the existing shared workflow.

### 4.2. Playback Synchronization & Seeking
- The transcript presents timestamps, speaker labels, and text chunks.
- Tapping on a timestamp or citation invokes `IOSRecordingPlaybackModel.seek(to: seconds)`, smoothly repositioning the `AudioPlaybackService` timeline.
- Active transcript segments reflect playback position during playback.

### 4.3. Summary Generation
- Enabled immediately once a transcript exists.
- Preset selection (e.g., Executive Summary, Action Items, Detailed Notes) and custom instructions are fed to `SummaryPromptBuilder`.
- Uses the independently selected LLM provider. ChatGPT-plan mode sends eligible streaming Responses API requests with `store: false` and omits unsupported generation parameters; Gemini uses the Gemini Developer API.
- Cancellation halts the active stream cleanly.
- Regeneration preserves previous summary records in generation history.

### 4.4. Recording Chat
- Accessible via the Chat button in the recording detail toolbar; chat provider selection is independent of summary and transcription.
- Opens full-featured chat interface (`ChatInspectorView` / sheet).
- Streams responses with live markdown rendering via `ChatMessageBubble` and `AssistantMessageView`. ChatGPT-plan chat uses eligible Responses API requests; Gemini uses the Gemini Developer API.
- Grounded citations link directly back to timestamped transcript excerpts.
- Terminal states and partial interruptions are tracked with Retry capabilities.

### 4.5. Usage & Cost Auditing
- Tapping "Usage & Cost" opens `UsageCostView`.
- Aggregates transcription minutes, input/output tokens, and dollar expenditures.
- Retains unknown costs honestly without discarding operation audit records.

---

## 5. Verification & Test Suite

### iOS Unit Tests (`AudioNotesTests/IOSCloudAITests.swift`)
Executed on **iPhone 17 Simulator (iOS 27.0)** as part of the full `AudioNotesiOS` test scheme:
```
38 passed, 0 skipped, 0 failed.
```

Executed on **iPad Pro 11-inch (M5) Simulator (iOS 27.0)**:
```
38 passed, 0 skipped, 0 failed.
```

### macOS Regression Tests (`AudioNotesTests`)
Executed on **macOS 27.0.1 (arm64)**:
```
443 passed, 6 skipped, 0 failed (449 total).
```

Builds also passed for AudioNotes macOS Release, AudioNotesiOS Debug Simulator, and AudioNotesiOS Release Simulator. No new Swift compiler warnings were emitted. The macOS test report contains an existing QoS runtime warning in `SourceProcessingTests.swift`; iOS reports existing AVAudioSession runtime warnings in `AudioPlaybackServiceTests.swift`.

### Invariant Checks
- `objectVersion = 77` restored and verified in `AudioNotes.xcodeproj/project.pbxproj`.
- SwiftData schema and `LibraryMigrationPlan` are unchanged.
- macOS Release configuration is unchanged.
- M16.4 is marked complete per the acceptance amendment. Live-provider acceptance is documented as not performed; physical-device/signing acceptance is deferred to the release milestone. No Apple App ID, certificate, provisioning profile, or App Store Connect record was created by this work.
- Signing configuration was not changed. Simulator builds use `CODE_SIGN_IDENTITY = -`; existing project configuration includes a `DEVELOPMENT_TEAM` value whose ownership must be confirmed during release handoff before any device signing.
- The candidate remains uncommitted until the final regression and review are complete; it has not been pushed.
