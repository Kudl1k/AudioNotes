# AudioNotes Roadmap

## v0.1 — MVP

Goal: import a recording and turn it into useful AI notes.

### M1 — Foundation
- [x] Create macOS project
- [x] SwiftData models
- [x] Library UI
- [x] Audio import
- [x] Audio playback

### M2 — Transcription
- [ ] TranscriptionProvider protocol
- [ ] Mock transcription provider
- [ ] Processing state machine
- [ ] Transcript persistence
- [ ] Transcript UI
- [ ] Click timestamp to seek audio

### M3 — OpenAI transcription
- [ ] Keychain service
- [ ] Provider settings
- [ ] OpenAI transcription API
- [ ] Upload progress
- [ ] Error handling
- [ ] Retry

### M4 — AI summaries
- [ ] LLMProvider
- [ ] OpenAI implementation
- [ ] Summary generation
- [ ] Summary persistence
- [ ] Summary presets
- [ ] Regenerate summary

### M5 — Chat
- [ ] ChatSession
- [ ] ChatMessage
- [ ] Chat UI
- [ ] Transcript context
- [ ] Streaming responses
- [ ] Persistent conversations

### M6 — Export
- [ ] ExportContent
- [ ] MarkdownExporter
- [ ] PDFExporter
- [ ] Export dialog

## v0.2

- [ ] Claude provider
- [ ] Gemini provider
- [ ] Speaker support
- [ ] Transcript search
- [ ] Custom summary prompts
- [ ] Better long-recording support

## v0.3

- [ ] Local transcription
- [ ] Whisper
- [ ] Local/private workflow
