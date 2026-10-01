# OpenAI transcription — Milestone 3

Implementation and offline validation are complete. A user-run live request reached OpenAI but returned HTTP 429; successful live transcription and the full manual app workflow remain pending; do not treat this milestone as fully verified until the checklist below is completed with a manually configured key.

## API contract checked 2026-09-30

Official sources were fetched before implementation:

- [File transcription guide](https://developers.openai.com/api/docs/guides/speech-to-text): the general-purpose recommendation is currently `gpt-transcribe`; timestamp-oriented transcription uses `whisper-1`. The guide states a 25 MB limit.
- [Create transcription reference](https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create): multipart `POST https://api.openai.com/v1/audio/transcriptions`, file and model fields, optional ISO 639-1 language, `verbose_json` and segment timestamp request/response examples. Its accepted formats include FLAC, MP3, MP4, MPEG, MPGA, M4A, OGG, WAV, and WebM.
- [Error guidance](https://developers.openai.com/api/docs/guides/error-codes): HTTP 429 can represent throttling, exhausted credits, project/organization spend limits, or approved usage limits. The app distinguishes known codes and the broader quota type.
- [Authentication reference](https://developers.openai.com/api/reference/overview): HTTP Bearer authentication.

The reference also lists GPT-4o transcription variants and diarization. This milestone exposes only **cloud `whisper-1`**, chosen specifically to preserve segment timestamps. Requests use `response_format=verbose_json` and `timestamp_granularities[]=segment`. Automatic language selection omits the language field. No diarization is requested; speakers remain nil.

The model picker and persisted model enum currently have one supported choice. Other models require a corresponding response mapper/capability decision before being enabled; text-only output must not be disguised as accurate segment timestamps. This is not local Whisper.

## Architecture

`AppServices` composes shared configuration, credential storage, and a URLSession client. `TranscriptionProviderResolver` selects Mock or OpenAI. `RecordingViewModel` resolves once at the beginning of each attempt; changing Settings affects the next attempt, including retry, without reopening the detail. An active attempt retains its provider/configuration snapshot. The view model contains no provider-specific networking logic.

`OpenAITranscriptionProvider` retrieves the credential through `CredentialStoring`. `OpenAIAudioUpload` validates and reads each managed audio part on a worker actor, with bounded reads and cancellation checks. It submits a generic filename rather than the user's original filename. The conservative per-upload limit is **25,000,000 bytes**. When the source exceeds that limit, `OpenAIAudioSplitter` uses AVFoundation to export contiguous, compressed M4A parts sized below the upload ceiling. Temporary part files live in a uniquely named system temporary directory and are removed after completion, error, or cancellation; they are never added to SwiftData or the library. Merged segment timestamps are offset by each part's original start time.

`OpenAITranscriptionClient` performs the multipart upload with async URLSession and decodes Sendable DTOs off the main actor. The provider maps them into the existing SwiftData graph on the main actor. Language names in verbose responses are normalized to language codes where possible. Invalid or empty results are not persisted. Transcript persistence and seek callbacks remain the Milestone 2 implementation.

Progress within each network request is **indeterminate**; no server processing percentage is invented. For split files, the UI reports completed audio duration and derives overall progress and ETA from completed parts. Task cancellation cancels URLSession/export work and maps to cancelled, not failed. Attempt IDs prevent late callbacks/results from saving after cancellation. A retry restarts the complete operation; completed temporary parts are not persisted for resume. No automatic retries risk duplicate charges. Cancelling locally cannot guarantee that already-accepted server work is unbilled.

## Credentials and errors

`KeychainService` uses device-local, nonsynchronizing generic-password entries under `cz.kudladev.AudioNotes.provider-credentials`. It supports presence checks, retrieval, update, and deletion, with typed OSStatus failures. Normal tests use `MockCredentialStore`; they never access the real account's Keychain.

Settings uses SecureField, clears entered text after saving and on dismissal, and checks only key presence. It never retrieves a stored key into the view. “API key configured” means stored locally, not verified with the server. Non-secret provider/model/language preferences use UserDefaults; no key appears in SwiftData or preferences.

The client uses an ephemeral URLSession, disables cookies/cache, and refuses redirects. Credentials exist only in Keychain and transient request memory. Nothing logs request headers, keys, transcript responses, or raw error bodies. Typed errors retain HTTP status or URL error code for debugging and expose concise messages. Known error codes distinguish exhausted credits, project/organization spend limits, approved usage limits, quota exhaustion, and ordinary rate limits. A provider-neutral diagnostic interface lets the detail view show safe HTTP status, allowlisted code, sanitized request ID, and bounded Retry-After delay in a disclosure. No raw response messages are displayed.

## Validation

- Debug macOS build, including a signed sandboxed build: passed.
- Full unit suite: 47 tests passed (including parameterized cases).
- URLProtocol isolates each network scenario; no real API is required by unit tests.
- Covered: credential abstraction and settings behavior, preferences/reload/fallback, resolver snapshots and retry, multipart fields and bytes, managed-file validation, language/timestamp mapping, missing key, malformed response, HTTP failures, offline/timeout failures, network cancellation with no partial persistence, and switching back to Mock. Existing playback and persistence round-trip tests pass.
- Compiler warnings: only App Intents metadata extraction skipped because the app has no AppIntents dependency. Unsigned test-host runs may emit macOS linkd/CoreMedia diagnostic noise; tests pass.
- Manual live validation: user configured a key in the signed app and reported HTTP 429. Successful transcription is not yet verified. The updated signed build distinguishes current billing/rate-limit codes and exposes safe diagnostics. No real credential was supplied to the agent or added to fixtures.

## Manual acceptance checklist

Use a signed run with the same bundle identifier/signing identity across relaunches. Open **AudioNotes → Settings…** (⌘,).

- [ ] Launch, select OpenAI, enter a real key in SecureField, and Save Key. Verify the input clears and “API key configured” appears.
- [ ] Choose automatic detection or a language, import a supported file under the limit, and play it.
- [ ] Transcribe a recording without a saved transcript; observe phase, elapsed time, and indeterminate activity within a request.
- [ ] Transcribe a source larger than 25 MB; verify it is split into temporary M4A parts, progress advances by completed audio duration, and timestamps seek to the original recording locations.
- [ ] Receive real text with segment timestamps; click a timestamp and verify playback seeks.
- [ ] Quit/reopen; verify transcript and selection persist, Settings reports the key configured without exposing it, and a new real transcription succeeds using the retained credential.
- [ ] Cause a failure (for example, temporarily remove the key), then restore it and retry successfully without reopening the recording.
- [ ] Cancel an in-flight request; verify no transcript is saved and retry remains available.
- [ ] Switch to Mock and verify a different recording gets labeled sample text without requiring credentials/network access.
- [ ] Update and remove the saved key; verify configuration status reflects each change.

No live API check is automatically performed by launching the app or saving a key. Start transcription explicitly; this submits the selected managed recording and incurs normal provider usage.

## Files in this milestone

Created:
- `App/AppServices.swift`
- `Services/Credentials/KeychainService.swift`
- `Services/Transcription/TranscriptionConfiguration.swift`, `TranscriptionProviderResolver.swift`, `TranscriptionDiagnosticError.swift`
- `Services/Transcription/OpenAI/`: provider, client, upload builder, DTO mapper, typed errors, and safe HTTP diagnostics
- `Features/Settings/`: native Settings view and view model
- `AudioNotesTests/`: `MockCredentialStore`, `ProviderConfigurationTests`, `ProviderSettingsTests`, `OpenAIResponseTests`, `OpenAIAudioUploadTests`, `OpenAINetworkStub`, `OpenAITranscriptionProviderTests`, `OpenAIHTTPErrorTests`
- This document

Modified:
- App scene, LibraryView, and RecordingDetailView for shared resolver injection
- RecordingViewModel for per-attempt provider resolution; TranscriptionControls for Settings access
- Xcode build settings for outgoing sandbox networking
- README, transcription architecture notes, and roadmap

Milestone 2's persistence schema, provider protocol, mock provider, repository, timestamp rendering, and playback implementation are retained.

## Later milestones

Transcription configuration is independent of any future LLM configuration. Milestone 4 should introduce a separate LLM abstraction rather than extend the transcription protocol. The credential abstraction can be reused without placing secrets in settings models. Gemini/local transcription should be added through the resolver/catalog and new service implementations. No summaries, chat, local inference, chunking, export, accounts, or sync were introduced.
