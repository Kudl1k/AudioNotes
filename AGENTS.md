# AudioNotes — Codex Instructions

## Project

AudioNotes is a fully native macOS application for importing audio
recordings, transcribing them, generating AI summaries, chatting about
their contents, and exporting the results to Markdown or PDF.

The application must remain a native macOS application.

## Technology

- Swift 6
- SwiftUI
- macOS 15+
- SwiftData
- AVFoundation
- URLSession
- async/await and structured concurrency
- macOS Keychain for secrets

Avoid third-party dependencies unless there is a strong technical reason
to introduce one.

Do not use:
- Electron
- React Native
- Tauri
- WebViews for the primary UI
- Node.js/Python backend services

## Architecture

Use feature-based MVVM.

Main directories:

- App/
- Models/
- Services/
- Features/
- Utilities/

Keep views small.

Business logic must not live directly in SwiftUI views.

Prefer dependency injection through protocols instead of accessing
global singletons.

Do not create large "manager" classes containing unrelated functionality.

## Core models

The domain contains:

- Recording
- Transcript
- TranscriptSegment
- Summary
- ChatSession
- ChatMessage

A transcript is structured data, not just a String.

TranscriptSegment should support:

- start timestamp
- end timestamp
- text
- optional speaker

This is required so the UI can navigate from transcript/AI responses
to locations in the audio.

## Provider architecture

Transcription and LLM functionality MUST remain separate.

Use abstractions similar to:

    protocol TranscriptionProvider

    protocol LLMProvider

Do not couple the application directly to OpenAI, Anthropic, Gemini,
or another provider.

Provider-specific implementations belong under Services/.

Example:

Services/
    Transcription/
        TranscriptionProvider.swift
        OpenAITranscriptionProvider.swift

    LLM/
        LLMProvider.swift
        OpenAILLMProvider.swift
        AnthropicLLMProvider.swift
        GeminiLLMProvider.swift

The selected transcription provider and selected LLM provider must be
independently configurable.

Future local providers, such as Whisper, must be possible without
changing the application architecture.

## Secrets

Never store API keys in:

- source code
- UserDefaults
- SwiftData
- plist files
- JSON configuration files

API keys must be stored in macOS Keychain.

Never log API keys.

## Networking

Use URLSession and async/await.

Provider networking should be isolated from UI code.

Network errors should be represented as typed errors and presented to
the user in a useful way.

Support cancellation where practical.

## Audio

Use AVFoundation.

Imported audio should be copied into the application's Application
Support directory.

The database should reference the managed copy rather than depending
on the original user-selected file.

Audio playback should support seeking to transcript timestamps.

## Persistence

Use SwiftData for metadata and application data.

Do not store large audio binaries inside SwiftData.

Audio files belong in Application Support.

Persist:

- recordings
- transcripts
- transcript segments
- summaries
- chats
- chat messages

## AI summaries

Summary generation should eventually support presets:

- General
- Meeting
- Lecture
- Interview
- Podcast
- Brainstorm
- Custom

Do not hard-code summary formatting into SwiftUI views.

Summary generation belongs in the LLM/service layer.

## Chat

Every recording can have a persistent chat.

Chat questions are answered using the recording transcript as context.

Design the architecture so that transcript retrieval/chunking can be
added later.

For the initial version, sending the complete transcript is acceptable
when it fits within the provider context limit.

Do not introduce a vector database during the initial implementation.

## Export

Support:

- Markdown
- PDF

Both exporters should consume the same intermediate ExportContent model.

Do not independently construct completely different content for
Markdown and PDF.

Users should eventually be able to choose whether to include:

- summary
- key points
- action items
- transcript
- chat

## UI

Use native macOS SwiftUI controls.

Main application layout:

    NavigationSplitView

    Sidebar
        Recording library

    Content
        Recording detail
        Summary / Transcript

    Inspector
        Chat

Prefer standard macOS interaction patterns.

Support keyboard navigation where appropriate.

Avoid creating an iOS-looking interface on macOS.

## Concurrency

Use Swift structured concurrency.

Prefer:

- async/await
- Task
- actors where isolation is required

Avoid unnecessary DispatchQueue usage.

UI state updates must occur on the appropriate actor.

## Code quality

Before completing a task:

1. Build the project.
2. Fix compiler errors.
3. Run relevant tests.
4. Check for new warnings.
5. Remove temporary/debug code.
6. Summarize the changes made.

Do not silently change unrelated parts of the application.

Do not perform large architectural rewrites unless the current task
requires them.

When uncertain about an architectural decision, prefer the simplest
solution that preserves the architecture described here.

## Testing

Add unit tests for business logic and services where practical.

Important areas to test:

- audio importing
- persistence
- transcript transformations
- exporters
- provider request/response parsing
- error handling

Avoid tests that simply test SwiftUI implementation details.

## Development roadmap

The intended order is:

### Milestone 1 — Application foundation
- Native macOS project
- SwiftData models
- recording library
- audio import
- audio playback
- basic recording detail UI

### Milestone 2 — Transcription architecture
- TranscriptionProvider
- processing pipeline
- transcription state
- mock provider
- transcript UI

### Milestone 3 — First real transcription provider
- provider API integration
- Keychain credentials
- settings
- transcription progress/error handling

### Milestone 4 — Summaries
- LLMProvider
- summary generation
- summary presets

### Milestone 5 — Chat
- recording chat
- persistent chat history
- transcript context
- timestamp references where possible

### Milestone 6 — Export
- ExportContent
- Markdown export
- PDF export

### Milestone 7 — Multiple providers
- OpenAI
- Anthropic
- Gemini
- independent provider selection

### Milestone 8 — Long recordings
- transcript chunking
- retrieval
- hierarchical summarization

### Milestone 9 — Local processing
- investigate local Whisper/Core ML transcription
- optional local transcription provider

## Current development principle

Implement one milestone at a time.

Do not implement future milestones prematurely merely because they are
described in this document.

Keep the project compiling after every significant change.
