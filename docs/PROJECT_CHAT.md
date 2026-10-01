# M12.3 — Project Chat implementation report

M12.3 adds a persistent, project-owned conversation over M12.2 local retrieval. M11, M12.1 and M12.2 desktop acceptance remains open. M12.4 has not started.

## Ownership and persistence

`ChatSession` is reused with an optional `project` relationship alongside its existing optional `recording`. Repository entry points create sessions for exactly one owner. A Project cascades its sessions/messages and generation records. It does not adopt a recording's chat. One persistent session per project is created today; the relationship permits additional sessions later without implementing session-management UI.

`GenerationRecord.recordingID` is now optional. Project operations have a real `projectID`/`project` relationship and no recording owner. Existing recording IDs and relationships remain intact. The global UsageRepository includes both owners and aggregates project totals separately. Money, pricing snapshots, provider usage and local estimates retain their existing types and semantics. Compatible failed retries reuse the logical generation and aggregate request usage; changed provider/model/authentication/settings/selection starts a new generation. Regeneration uses current settings and current evidence, following Recording Chat's replacement behavior.

Session selection is JSON-encoded non-secret metadata: Entire Project or selected recording/shared-source UUID sets. Selecting a recording includes its primary transcript and attachments. Clear scope disables sending. Deleted IDs are pruned. Projects and sessions retain UUID identity through renames. No credentials or managed paths enter chat metadata.

The session stores the pending user-message ID before generation. At reattachment after restart, it becomes an interrupted question with Retry; startup's existing usage recovery marks unfinished operations cancelled. Active spinners are never restored. User questions persist even when retrieval/provider work fails. Active streaming stays in memory; no per-token SwiftData writes. Final messages or interrupted partial prose are persisted, with generation linkage and usage at request boundaries/completion. Partial messages do not acquire incomplete citations.

## Send pipeline and budgeting

1. Insert the user message and publish preparation state immediately.
2. Snapshot selected searchable source IDs and current provider/settings.
3. Locally construct a query from the latest question; short or referential follow-ups include at most two preceding user questions, capped at 400 characters each. No rewrite, reranking or history-summary AI calls occur.
4. Call the library-owned RetrievalService with `RetrievalScope.project(project.id)` and an explicit source-ID filter. M12.2 ContextRetriever/ContextAssembler performs local lexical ranking, diversity and serialized-data budgeting off the UI actor.
5. Bound recent history, reserving the current question and evidence space. Previous assistant messages are included only when their generation's source scope remains within current searchable selection; interrupted/unknown-scope answers are omitted.
6. Adapt the resulting ContextPackage into escaped, minimal user-role JSON with S1/S2 request aliases, readable names/locations and relevant excerpts. The full project, paths, scores, stable/internal IDs and unrelated content are not sent.
7. Verify the assembled prompt estimate plus output reserve against the selected model's context window. Make one provider generation request, stream/coalesce deltas, validate citations against a fresh project snapshot, then persist the final answer and usage.

Explicit maxOutputTokens is reserved in full, rather than silently reduced. Without an explicit ceiling, the default reserve is capped at one quarter of the window/8,000 tokens. System/framing overhead is reserved. Roughly one third of remaining space (at most current question plus 6,000 tokens) is available for recent history; retrieval has the rest, capped at 12,000 tokens. A question or explicit output ceiling that cannot fit fails usefully before provider execution. Token counts are UTF-8 estimates for budgeting, not billed usage. The final provider continues to enforce its own model limits.

Retrieval can return empty evidence. The provider receives `[]` and instructions to acknowledge missing evidence; no unrelated fallback chunks are added. No available content in the selected scope disables sending. Coverage uses existing eligibility/provenance rules, counts selected searchable recordings/sources and separately reports untranscribed, processing and failed items. Opening/typing does not derive chunks or build an index. Snapshotting source values stays on their owning actor; M12.2 indexing/search and citation document derivation use immutable values off that actor.

## Providers, privacy and grounding

Project Chat uses `resolveChat()` and `chatSettings()`: the same Chat provider/model/output-length/settings and supported presets configured for Recording Chat. The compact settings link opens existing provider/model controls. OpenAI API/ChatGPT-plan, implemented Claude Code authentication and Ollama paths are reused. Gemini remains unavailable in the existing resolver; M12.3 does not pretend to implement it or add providers.

Execution uses the existing PrivacyLLMProvider gate, including live Local Only evaluation at provider execution. Ollama retains verification of local/cloud model metadata, endpoint handling and its no-fallback policy. Retrieval has no provider/network dependency. There is no existing shared Whisper/Ollama workload coordinator to reuse; this pass introduces none.

External-provider preflight asks permission to send relevant excerpts, the question and bounded history. Permission is scoped to the selected provider/model and the library-window's project-chat model lifetime; navigating normally preserves it, restarting does not. Only retrieved selected text is passed. No PDF originals, image bytes, managed paths, project UUIDs, retrieval scores or unrelated project material are uploaded. Project images contribute local OCR text only in this milestone. Project Only evidence grounding is the default and sole mode.

The provider-neutral ProjectChatPrompt separates system instructions from escaped source DATA. It treats transcripts, documents, OCR, labels and history as untrusted; commands to change settings, reveal instructions, upload files or execute actions have no authority. Providers retain their existing structured-response and disabled-tool behavior. Tests verify the serialization/system-role boundary; they cannot prove that every real model will resist every injection.

## Citations and navigation

ContextPackage entry order defines request aliases S1/S2. SourceReferenceResolver resolves structured aliases against the request's supplied chunks; inline aliases can also request those entries. Invalid aliases produce no trusted reference and their decoration is removed. Ordinary brackets/unrelated UUIDs retain the existing non-destructive normalization behavior. DEBUG diagnostics use static text, without aliases, excerpts or questions.

Before final persistence, a fresh project-scoped snapshot is taken. Only selected supplied sources are derived again off actor; RetrievalReferenceIndex checks project authority and document identity. The resolver rejects removed/moved/cross-project/unprovided IDs, changed content revisions and duplicates. Labels, locators, excerpts, recording IDs and original unit/segment IDs all come from trusted documents. The model supplies no authoritative timestamp/page/UUID. First-reference ordering is deterministic.

`ProjectCitation` persists trusted historical source metadata, project/recording IDs, original unit IDs and content revision separately from clean Markdown. SourceReference remains the common reference representation. Display groups image regions/PDF pages/document sections without discarding persisted references. Historical messages survive deletion or moves; chips retain readable metadata and become unavailable when current ownership/original units no longer match. Current recording/source titles are displayed when resolvable, without rewriting old answers. Exports retain historical labels.

Transcript citations open the correct current project recording, select Transcript, reveal the original segment and seek the trusted timestamp. Recording attachments and shared PDF/image/text references reuse existing native viewers and trusted locators. The recording breadcrumb returns to the project; the library remembers the Chat tab, draft, scroll-follow intent and visible row anchor. Deleted/moved citations cannot redirect outside the original project. Native click/seek/back behavior remains a desktop acceptance item.

## UI, streaming, cancellation and export

Project Workspace has a Chat tab, project-aware empty suggestions, searchable coverage, native Entire Project/Selected Sources sheet, Select All/Clear, readable-width lazy chat history, existing AssistantMessageView/MarkdownDocument, source grouping, copy, regenerate, generation details, Usage & Cost, retry and destructive clear confirmation. Return sends, Shift+Return inserts a newline, Esc cancels. Semantic colors and VoiceOver labels follow existing native controls.

Preparation feedback appears immediately; the specific Searching label appears only if retrieval lasts long enough for the elapsed timer, avoiding millisecond flashing. Thinking reflects provider wait; streaming starts on the first delta. Draft updates are batched at 80 ms, preserving all consumed text. ChatScrollState preserves user intent and Jump to Latest resumes following. Persistent rows do not observe streaming content. Markdown parsing remains detached and rejects cancelled results. A native horizontally scrolling table block was added to the shared renderer alongside existing lists/quotes/code.

The library owns one ProjectChatViewModel per project. Navigation does not cancel it; projects can generate independently. Cancel propagates to retrieval, provider stream and consumption; deletion cancels/awaits project chat before deleting project metadata. Failed and cancelled responses retain the question for retry. Retry/regenerate always retrieve fresh project material. Clearing messages preserves sources, recordings and cost history.

Project Chat Markdown export snapshots the existing ExportContent chat representation and uses NativeExportService/MarkdownExporter, including readable trusted source labels. Project PDF export UI and whole-project exports are not added.

## Validation and measurements

- Debug macOS build and full automated suite: **362 tests in 67 suites passed**; the expensive stress fixture and two pre-existing opt-in live tests are skipped in the normal run. The stress fixture passed separately. Final validation after the last stream-observation adjustment is recorded below.
- Existing Recording Chat streaming/rendering/context/view-model/UX, M1–M12.2 and frozen pre-M12 on-disk migration tests passed. The frozen schema's non-optional recordingID migrates to the optional current field while historical usage/pricing/citations remain intact.
- Eleven new ProjectChatTests plus a separate end-to-end stress test cover first feedback/one-request streaming, trusted aliases/pages/audio titles, boundaries and selected-source/history exclusion, empty evidence, follow-ups, retry refresh, cancellation/partial prose, current-scope deletion/move invalidation, unavailable historical citations, renames, eligibility/no automatic processing, selection/session ownership, on-disk reopen/interruption, cascade deletion, cloud consent, metered pricing/usage, Local Only preflight, independent library-owned project generations, 250-message budgeting, injection serialization, and native table parsing.
- Existing synthetic 100-hour/200-PDF/4,000-page fixture: 36,000 segments, 8,500 chunks; cold index about **2.014 s**, cold query **22.01 ms**, warm snapshot comparison **1.00 ms**, warm query **20.97 ms**. Full-test-host high-water RSS **397,787,136 bytes (~379 MiB)**, not isolated index memory.
- 250-message deterministic history budgeting: **3.17 microseconds**, retained four messages and reserved 3,555 tokens for evidence in an 8K model with a 2K output ceiling. This measures budgeting, not native scrolling or total send latency.
- Separate end-to-end 100-hour/200-source/250-message SwiftData fixture: model attachment **100 ms**, synchronous send feedback **122 ms**, cold retrieval **4.000 s**, mock first token **4.046 s**, completion **4.165 s**. Only **three history messages and three evidence chunks/sources** were passed; estimated input **3,527 tokens** plus 2,048 output reserve stayed within 8K. Final citation revalidation snapshots text only for supplied source IDs. Timings include the real service/snapshot/persistence path but exclude native view rendering and real provider latency.
- Running that large owning-actor SwiftData fixture concurrently with unrelated suites caused three existing Whisper polling tests to time out. Those tests pass in the normal full suite; the stress test is explicitly opt-in and run separately to avoid invalidating their polling deadlines. Run it with `TEST_RUNNER_AUDIONOTES_PROJECT_CHAT_STRESS=1 xcodebuild -project AudioNotes.xcodeproj -scheme AudioNotes -configuration Debug -destination 'platform=macOS' -only-testing:AudioNotesTests/ProjectChatPerformanceTests test`.
- New DEBUG-only `--performance-fixtures --performance-project-chat` launch seeds an in-memory Operating Systems project with four synthetic lecture topics, 23-page slides and Markdown notes under the existing separate temporary managed-file root. Uses mock providers, no metered calls or real-library seeding. Synthetic audio has transcript/timestamp metadata but no playable recording file.
- Isolated native fixture process launched. macOS denied assistive access and window capture, so no native click/visual/accessibility acceptance is claimed. The fixture process was stopped; the user's existing app process was left running.

## Remaining acceptance and limitations

- Native empty/first-send/search/thinking/streaming visual feedback, citation clicks/page/seek, back/scroll restoration, source-picker interaction, destructive confirmations and Markdown tables need desktop verification.
- Light/Dark, narrow/fullscreen, keyboard/focus, VoiceOver, long-chat scrolling, UI CPU/memory, time-to-first-feedback/token and production SwiftData fault/snapshot performance require native acceptance. Component benchmarks do not establish responsiveness of a real 100-hour project.
- Live configured OpenAI/Claude/Ollama, physically offline Ollama, cloud offline errors, real usage invoices and runtime injection behavior require manual/live acceptance. No metered live-provider requests were made.
- Gemini is unavailable in the current implementation. Project image understanding is OCR-only; no new provider or image-upload workflow.
- Query continuation uses bounded prior user questions, not paid rewriting or semantic understanding. Generic project-wide summaries may have limited lexical evidence; no hierarchy, embedding, reranking, hidden history summary or project-summary workflow is introduced.
- Metadata eligibility and send-time M12.2 snapshotting still fault source graphs on their owning actor. No persistent index or claim of an isolated total-memory cap.
- One project session, window-local drafts/scroll state and active tasks; cross-window job coordination and active-task resumption after termination are not implemented. Messages/scope/session and selected-project restoration persist; exact scroll position across process restart does not.
- Structured source chips are used; inline machine aliases are removed from readable Markdown/copy rather than implementing a separate numbered inline-link renderer.

## File inventory

Created:
- `AudioNotes/Services/ProjectChat/ProjectChatContext.swift`
- `AudioNotes/Features/ProjectChat/ProjectChatViewModel.swift`
- `AudioNotes/Features/ProjectChat/ProjectChatView.swift`
- `AudioNotes/Features/ProjectChat/ProjectChatSelectionView.swift`
- `AudioNotes/Utilities/Development/ProjectChatFixtures.swift`
- `AudioNotesTests/ProjectChatTests.swift`
- `AudioNotesTests/ProjectChatPerformanceTests.swift`
- `docs/PROJECT_CHAT.md`

Modified for this pass (several already had pre-existing workspace edits):
- `AudioNotes/Models/Project.swift`, `ChatSession.swift`, `ChatMessage.swift`, `GenerationRecord.swift`
- `AudioNotes/Services/LLM/Chat/ChatRepository.swift`, `LLMChatTypes.swift`, `ChatContextBuilder.swift`
- `AudioNotes/Services/LLM/MockLLMProvider.swift`
- `AudioNotes/Services/Sources/RecordingContextRetriever.swift`
- `AudioNotes/Services/Retrieval/RetrievalSnapshot.swift`
- `AudioNotes/Services/Usage/UsageRepository.swift`
- `AudioNotes/Features/Usage/UsageCostView.swift`
- `AudioNotes/Features/Library/LibraryView.swift`, `LibraryViewModel.swift`
- `AudioNotes/Features/Projects/ProjectWorkspaceView.swift`
- `AudioNotes/Features/RecordingDetail/RecordingDetailView.swift`
- `AudioNotes/Features/Chat/AssistantMessageView.swift`
- `AudioNotes/Utilities/MarkdownDocument.swift`
- `AudioNotes/Utilities/Development/PerformanceFixtureLibrary.swift`
- `AGENTS.md`, `docs/ROADMAP.md`

M12.4 can build on explicit project chat/generation ownership and trusted retrieval provenance. It must not implicitly widen Recording Chat scope or introduce another source-authority/persistence model. No M12.4 functionality is included here.
