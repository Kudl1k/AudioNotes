# AudioNotes

Native macOS audio library built with Swift 6, SwiftUI, SwiftData, and AVFoundation. Targets macOS 15 or later; no third-party dependencies.

Open `AudioNotes.xcodeproj`, select the **AudioNotes** scheme, and run on My Mac. Select a development signing team if needed for a signed build.

Import audio with **File → Import Audio…** (⌘O), the toolbar, or by dropping audio files into the window. Select a recording to play, pause, or seek. The detail has Summary and Transcript tabs and a Chat toolbar button that toggles the right inspector. Choose **Transcribe** to use the provider selected in **AudioNotes → Settings…** (⌘,). Mock works offline; OpenAI uses a key saved in macOS Keychain and cloud `whisper-1` for segment timestamps. Transcripts are saved with clickable timestamps; mock transcripts remain labeled as samples. OpenAI processing uses indeterminate progress and supports cancellation/retry. AI summaries and sending chat messages are not implemented yet.

## Structure

- `AudioNotes/App`: app lifecycle, SwiftData container, and menu commands.
- `AudioNotes/Models`: six persistence models with inverse relationships and cascade deletion.
- `AudioNotes/Services`: actor-isolated audio import, main-actor playback, storage configuration, recording repository, and provider-based transcription.
- `AudioNotes/Features`: library and recording MVVM, transcription controls, recording details, and chat inspector.
- `AudioNotes/Utilities`: shared timestamp formatting.
- `AudioNotesTests`: Swift Testing tests using generated WAV fixtures and isolated temporary storage.

Imported audio is copied to `Application Support/AudioNotes/Recordings` in the app's sandbox container. Metadata is stored beside it in `Library.store`. Recordings reference relative filenames with UUIDs, so moving or deleting the original file does not affect playback and duplicate names never overwrite files. Import failures are reported per file; a failed metadata save removes the copied audio. File I/O runs in an actor and UI/persistence operations run on the main actor.

## Validation

```sh
xcodebuild -project AudioNotes.xcodeproj -scheme AudioNotes \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project AudioNotes.xcodeproj -scheme AudioNotes \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test
```

Tests also cover mock transcription, processing states, cancellation/retry races, transcript save failures, chronological ordering, persisted mock provenance, and timestamp formatting. Tests cover copying and duplicate imports, invalid and corrupt audio, cancellation, storage failure, playback loading and seeking, recovery from missing files, batch import errors, metadata-save cleanup, persistent model relationships, and cascade deletion. Use a signed run for a manual Finder drag-and-drop and file-panel sandbox check.

## Transcription providers

See [the transcription architecture](docs/TRANSCRIPTION.md) for state handling, persistence, cancellation, and extension points. Mock and OpenAI are connected. The interface also supports a future local Whisper provider without coupling the recording UI to an inference runtime. See [OpenAI setup, limitations, and the pending live acceptance checklist](docs/OPENAI_TRANSCRIPTION.md).
