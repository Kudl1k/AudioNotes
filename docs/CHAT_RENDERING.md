# M8.2 implementation report

## Root causes

The provider-independent response already had separate content and references. OpenAI chat completions and ChatGPT Responses decoded `answer` plus `referenceSegmentIDs`, resolved IDs, then passed `dto.answer` through unchanged. Nothing enforced clean answer content before saving. The old renderer explicitly replaced recognized `【UUID】` tokens with Markdown timestamp links; unknown or malformed tokens survived. Consecutive inline links also placed timestamps directly beside each other.

The chat inspector parsed the whole answer into one Foundation `AttributedString` and rendered one SwiftUI `Text`. It did not translate Markdown block presentation intents into native headings, list rows, paragraph spacing or code containers. That caused flattened block structure despite useful Markdown from providers.

## Implementation

`LLMChatResponse` remains Markdown plus structured references. Its initializer normalizes known machine artifacts. The final generation path re-resolves segment IDs against the recording snapshot; the SwiftData repository independently enforces the same boundary for assistant inserts and updates. Provider-supplied timestamps, labels and excerpts are discarded and rebuilt from authoritative segments. Save errors now reach the existing failure UI instead of being silently treated as completion.

Both implemented remote paths construct this shared response type, and Mock uses it too. Existing provider DTOs do not reach the renderer. The prompt and both schema descriptions require Markdown in the answer and IDs exclusively in `referenceSegmentIDs`. Sanitization never creates references: only structured IDs can become clickable Sources.

`MarkdownDocument` parses a small semantic block model: paragraphs, ATX headings, ordered/unordered lists with indented continuation/nesting, fenced code, quotes and separators. Foundation parses inline emphasis, bold, code and links. SwiftUI renders each block with spacing; inline code receives restrained monospaced styling. Code has selectable unwrapped text, horizontal scrolling, padding and Copy actions. No dependencies, HTML renderer or WebView were added.

`AssistantMessageView` accepts clean Markdown and domain references and is shared by completed messages and transient streaming drafts. It caps readable width at 680 points. Sources are separate native buttons using canonical timestamps, sorted and deduplicated by segment ID. Segments within one second of the previous segment's end are grouped for display without changing persisted references. Five groups appear initially; an expansion button reveals the rest. A group seeks its first original segment through the existing `onSeek` callback to `AudioPlaybackService`.

Legacy messages are cleaned only for display/copy/history context. No database migration rewrites saved history. Cleanup targets UUID/numeric machine citation brackets, explicitly identified segment markers, known transcript IDs and the reported concatenated timestamp shape. Ordinary brackets, literary quotation brackets and unrelated UUIDs are preserved. Whole-message Copy uses the same cleanup; code Copy copies only the code.

Streaming keeps accumulating deltas without frequent persistence writes. Every update receives a best-effort block parse; unfinished fences render as code immediately. Foundation inline failure falls back to literal attributed text. An unfinished machine marker is hidden until more text arrives. Thinking/waiting behavior and stop/regenerate remain in place. Final and interrupted messages cross the clean-content persistence boundary.

`TimestampFormatter` produces `00:00`, `04:56`, `51:46`, and `1:04:32`. `AudioTime.format` delegates to it, while the pre-existing compact playback-clock `AudioTime.string` is retained.

## Files created

- `AudioNotes/Utilities/MarkdownDocument.swift`
- `AudioNotes/Utilities/TimestampFormatter.swift`
- `AudioNotes/Services/LLM/Chat/ChatContentNormalizer.swift`
- `AudioNotes/Features/Chat/AssistantMessageView.swift`
- `AudioNotesTests/ChatRenderingTests.swift`
- `docs/CHAT_RENDERING.md`

## Files modified

- `AudioNotes/Features/Chat/ChatInspectorView.swift`
- `AudioNotes/Features/Chat/ChatViewModel.swift`
- `AudioNotes/Services/LLM/Chat/LLMChatTypes.swift`
- `AudioNotes/Services/LLM/Chat/ChatRepository.swift`
- `AudioNotes/Services/LLM/Chat/ChatContextBuilder.swift`
- `AudioNotes/Services/LLM/Chat/StreamingJSONAnswerParser.swift`
- `AudioNotes/Services/LLM/OpenAI/OpenAILLMRequestDTO.swift`
- `AudioNotes/Utilities/AudioTime.swift`
- `AudioNotesTests/ChatUXTests.swift`
- `AudioNotesTests/TranscriptReferenceResolverTests.swift`
- `AudioNotesTests/SummaryPromptBuilderTests.swift`
- `AGENTS.md`
- `docs/ROADMAP.md`

## Tests and validation

The exact Czech regression fixture includes procedural lists, C identifiers, nested bullets, fenced C, Czech diacritics, raw UUID markers, `【53?】`, and `4:5651:46`. Tests verify clean domain content, semantic blocks and structured Sources. Additional coverage checks English/plain content, multiple paragraphs, headings, bold/italic/code inline intents, quotes, separators, malformed/partial Markdown, unfinished fences, known/unknown/duplicate IDs, chronological ordering, adjacent grouping, forged timestamp rejection, conservative legacy cleanup, canonical timestamps and SwiftData reload through a fresh model context.

A chat lifecycle integration test streams the requested Markdown chunks, verifies immediate waiting state, supplies raw markers and forged references from a custom provider, and checks clean persisted content plus authoritative timestamps. Existing Mock generation, stop/cancellation and Thinking lifecycle tests remain passing.

Validation commands use `xcodebuild -project AudioNotes.xcodeproj -scheme AudioNotes -destination 'platform=macOS' -derivedDataPath /tmp/AudioNotes-M82 build` and the same command with `test`. Full suite: 157 tests across 37 suites. No new compiler warnings were found. The existing unused `try?` warning in PresetsManagementView and Xcode's AppIntents metadata warning are unrelated to this change. `git diff --check` passes.

## Limitations and pending acceptance

- This is a focused Markdown subset, not full CommonMark: tables, images, HTML interpretation, syntax highlighting, reference-style links, setext headings and deeply irregular indentation are not implemented. Plain prose lacking semantic separators is not heuristically reconstructed into invented sections.
- Sources are message-level because current responses do not provide section-to-reference mappings. Grouping changes display only and seeks the first segment in each group.
- Legitimate prose timestamps and unrelated UUIDs are preserved; they never become clickable sources. Compatibility cleanup is deliberately limited to recognizable internal artifacts, rather than blanket UUID/bracket removal.
- Native text selection works per rendered text/code block. Selection spanning separate SwiftUI blocks follows native SwiftUI behavior; whole-response Copy remains available.
- Offline tests verify compiled rendering structure and playback callback wiring, not visual desktop appearance or interaction. Manual resizing, selection, source seeking and a real process relaunch remain acceptance checks. Reload tests use a fresh SwiftData context with an in-memory store.
- No live OpenAI or ChatGPT-plan request was performed. Claude/Gemini chat providers are not implemented in this checkout, so their live verification remains pending. The renderer and repository boundary are provider independent.
