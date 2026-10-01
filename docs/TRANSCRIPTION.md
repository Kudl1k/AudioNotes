# Transcription architecture (Milestones 2–3)

## Current flow

1. Audio import copies the source into `Application Support/AudioNotes/Recordings` and saves a `Recording` with a relative filename.
2. `RecordingViewModel` resolves that managed file and resolves the selected `TranscriptionProvider` for each attempt.
3. The provider returns a new, unpersisted `Transcript` containing timestamped `TranscriptSegment` models.
4. `SwiftDataTranscriptRepository` validates the graph and saves it as the current transcript. Regeneration archives the previous version only after the new result is ready. Failed saves restore the previous current version and remove only the new graph, preserving unrelated context edits.
5. `TranscriptView` reads segments in ascending start-time order, with position and UUID as stable tie breakers. A `(TimeInterval) -> Void` callback connects timestamp buttons to playback; the view does not know about AVFoundation.

`MockTranscriptionProvider` remains available alongside the OpenAI implementation. It asynchronously reads the audio's duration, simulates about two seconds of work, and creates deterministic sample dialogue. Timestamps are scaled to fit the file. This is not speech recognition. Persisted `sourceName` and `isMock` fields keep sample transcripts identifiable after relaunch. The new fields are optional or have defaults for existing stores.

## State, progress, and cancellation

`TranscriptionState` is a typed enum: idle, preparing, transcribing, saving, completed, failed (with a message), and cancelled. `TranscriptionProgressSnapshot` carries phase, part counts, processed/total audio duration, overall progress, and ETA. `TranscriptionProgressTracker` calculates ETA from completed part durations and smoothed measured throughput. Elapsed UI time uses a monotonic clock; it is not persisted every second. Progress lives in the main-actor view model, not the persistence model. Reopening AudioNotes does not resume an in-flight job.

The provider receives an async operation's cooperative Task cancellation and a main-actor, Sendable progress callback. Progress is a fraction from 0 to 1, or nil for indeterminate work. Worker actors can await the callback. Providers should check cancellation before/after expensive stages, and cancel underlying network or inference work where supported.

The view model owns the task, rejects duplicate starts, and identifies each attempt with a UUID. The library retains per-recording view models so navigating to another recording does not cancel active transcription, and the sidebar shows a compact active status. Cancellation immediately enables retry and discards subsequent progress/results from the old attempt, even if a provider does not cooperate promptly. The short synchronous SwiftData save is not cancellable; cancellation is checked immediately before saving.

For OpenAI, an input larger than the 25 MB upload ceiling is exported into compressed temporary M4A parts and transcribed sequentially. Part timestamps are offset back to the source recording before persistence. A retry currently starts from the beginning; no temporary audio or partial transcript is persisted for resume. Network requests remain indeterminate until a full part completes.

Failures display an error with Try Again. No partial transcript is saved. Existing transcripts cannot be overwritten by this initial flow; regeneration is later work; provider selection is available in Settings.

## Milestone 3 and local Whisper

The interface accepts a local file URL and has no dependency on HTTP, API keys, or a particular vendor. A future local Whisper provider and the current OpenAI provider can both conform to `TranscriptionProvider` and be injected into `RecordingViewModel`. Transcription selection remains independent of future LLM/summary providers.

The protocol entry point is main-actor isolated because its required return type is the existing SwiftData `Transcript`. This is an orchestration boundary, not a place to run inference: a Whisper implementation must run model loading, audio decoding, and inference in a worker actor, return Sendable value data, and construct the unpersisted model graph on the main actor. Remote implementations should await URLSession requests and likewise map results to the model graph at this boundary. Do not mark SwiftData models `@unchecked Sendable` or transfer them through detached tasks.

Local Whisper support is a planned provider option, not implemented in Milestone 2. Model/runtime selection, downloads and disk usage, cancellation support, and configuration still need implementation. M3 adds OpenAI network access and Keychain credentials, but no local runtime or model download. See [the OpenAI implementation and verification notes](OPENAI_TRANSCRIPTION.md).

## Manual check

Import an audio file, select it, and choose Transcribe. Verify preparing/transcribing progress, Cancel, and Try Again. On completion, verify the sample warning, speaker labels, and timestamp seeking. Reopen the app and verify the persisted transcript and sample warning. Switch recordings during processing to verify cancellation. Automated tests cover the provider, state transitions, cancellation races, save failures, disk persistence, chronological ordering, and timestamp formatting.

## Regeneration and transcript history

In the Transcript tab, choose **Regenerate…** to review the selected transcription provider/model and cost estimate, then **Regenerate**. This supports Local Whisper as well as other selected transcription providers; change model/language in Transcription Settings before starting. The original audio is reused. The current transcript remains available during processing and after cancellation or failure. Successful regeneration publishes one new current version and archives the previous transcript, including its original segment IDs, timestamps, language, provider provenance and generation-usage link.

**History** lists current and older versions with creation dates and generation details. Select a version to read/search it and seek the original audio. **Make Current** restores an older version and archives the former current version. **Delete Version** requires confirmation, is available only for historical versions, and retains factual generation/cost history. Restore/deletion are disabled during active transcription. Deleting a recording cascades all its transcript versions and segments. Historical versions are persisted in SwiftData; audio is not duplicated. Old chat/summary references are not rewritten: source-reference validation continues to use the current transcript's authoritative segment IDs. Restoring a version makes its original segment IDs authoritative again. Existing summaries remain unchanged until explicitly regenerated.

Automated regression tests cover on-disk version reopening, restore/delete, recording cascade, generation linkage, retained current transcripts during processing, late cancelled results, provider failure, and replacement/restore/delete save failure without discarding unrelated edits.
