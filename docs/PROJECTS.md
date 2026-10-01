# M12.1 — Projects foundation and multi-source workspace

The project foundation is implemented. Native/manual release acceptance remains
open. M12.2, project AI, semantic search and embeddings have not been implemented.
The pre-existing M11 acceptance checklist also remains open.

## Data model and ownership

`Project` stores a unique UUID, name, optional plain-text description, createdAt and
updatedAt. Its recording relationship nullifies on deletion; shared sources cascade.
`Recording.project` is optional, single membership. The recording's existing audio,
transcript/history, source, summary/history, chat and generation relationships retain
their identity and ownership. Moving a recording is a relationship edit plus dates,
with no audio/file copying or provider request.

The existing `RecordingSource` now has an optional `project` relationship alongside
its optional `recording` relationship. Import and repository operations assign only
one owner. Project documents never require a dummy recording. This deliberately
keeps the existing persistent model name instead of introducing a parallel source
system or a polymorphic persisted enum. SwiftData does not enforce an exclusive-or
constraint across these relationships; future ownership operations must preserve it.
Project import turns every audio file into a new recording, rather than creating
shared audio attachments. Existing recording-specific attachments remain intact.

Project/source editing and deletion live in `SwiftDataProjectRepository`; batch
import/extraction and cancellation live in `ProjectImportQueue`, retained by the
library. Views invoke these services rather than manipulating ownership or files.
The domain/project repository use Foundation/SwiftData without AppKit. The existing
native extraction/viewer stack remains macOS-specific; no iOS UI is introduced.

Dates change for project edits, recording membership/title/removal and project source
addition, completed extraction, rename/removal. Playback, progress ticks and streamed
AI tokens do not write project.updatedAt.

## SwiftData migration

The app and test/storage containers add `Project` and the two optional project
relationships to the existing schema. SwiftData performs additive lightweight
migration at the existing store location. No migration moves files, creates projects
for old recordings, changes old AI data, or rewrites source/citation identity.
Existing recordings and recording-owned sources migrate with project = nil.

The existing idempotent primary-audio backfill is retained. Startup reconciliation
also marks interrupted project source extraction failed with a retry message. Queued
URLs are intentionally in-memory; interrupted imports are not resumed after quit.

`LegacyM11Schema` freezes all ten pre-project persistent entity definitions. The
on-disk test creates this schema, closes it, opens the new schema and runs backfill
twice. It verifies recording/source/unit/segment IDs, audio paths, transcript history,
summary versions, chat references, structured source-reference bytes, provider and
authentication metadata, request usage/pricing and Decimal cost bytes remain intact.
A separate reopen test covers interrupted project extraction. The existing pre-M9
migration test remains in the full regression suite. These are actual on-disk fixture
upgrades, not acceptance against a separately archived production user library.

## Managed-file layout and deletion

The existing owner-independent layout is reused:

```text
<managed root>/
  Recordings/<recording UUID>.<audio extension>
  Sources/<source UUID>/original.<extension>
                       thumbnail.jpg
```

The app keeps its existing Application Support store/root resolution. Sources are
keyed by unique source IDs rather than project names or project folders. This avoids
changing URL, thumbnail, viewer or export behavior and makes project rename/move
independent of file storage. Text units persist once in SwiftData; chunks remain
on-demand values. Original user files are never rewritten or deleted.

Deleting a project presents Keep Recordings and Delete Project, Delete Recordings
and Project, and Cancel. The message explicitly explains shared-source deletion.
Keeping recordings removes membership, preserving their managed audio, attachments,
transcripts, summaries, chats and generation/cost history. Explicit recording deletion
cascades that history and cleans both file scopes. Active recording work blocks the
recording-deletion option; keeping recordings allows their work to continue.

Before project deletion, the library closes its queue to new jobs for that project,
cancels queued/current work and awaits the current task. Files are staged under a
unique managed removal directory, metadata is committed, then staged files are
removed. Save failure rolls back metadata and restores staged files. Cleanup failure
after commit is reported as such. Project-source deletion uses the same staging rule;
a queued/processing source must finish or be cancelled first. Recording deletion
continues through the existing recording repository. There is no new crash-recovery
journal for interruption in the middle of a staged deletion.

## Classification, multi-file import and queue

The native multi-selection panel offers existing supported audio, PDF, JPEG/PNG,
HEIC/HEIF and text/Markdown formats when a project is active. Outside projects it
retains audio import. When viewing a project recording, library import targets that
recording's project. Recording Sources → Add Source retains recording-local meaning.

`SourceImportService.type(for:)` inspects URL native contentType/UTType and falls back
to extension-derived UTType only when native type data is unavailable. The importer
then validates a regular local file, existing size limits, managed-copy hash and
actual native audio/extraction validity. Regular-file/symlink errors retain their
existing typed behavior. Filename classification does not certify the bytes: corrupt
PDF/images/text/audio fail their existing validation/extraction.

`ProjectImportQueue` retains per-file waiting/copying/processing/added/failed/cancelled
state, source identity, actual unit progress and elapsed activity. One worker performs
one complete copy/extraction at a time across projects in that library/window. It is
a conservative memory bound for PDF/OCR work. It does not globally coordinate all
recording source jobs, local inference or multiple app windows; those existing
coordination limits remain open.

Audio uses `AudioImportService`, title derivation, managed recordings storage and
primary-audio backfill, with project assigned before save. No transcription starts
on import and no provider is resolved. Documents/images use `SourceImportService`
and `NativeSourceProcessingService`: PDFKit native text/OCR fallback, Vision image
OCR, UTF-8/UTF-16 text/Markdown extraction and local thumbnails. No generation record,
LLM request, embedding or cloud upload is created for ordinary import/extraction.
Local Only behavior is preserved by using the existing local preparation paths.

Unsupported and failed items do not discard successful imports. Extraction failure
retains the managed original and source for Retry. Cancel Remaining cancels pending
jobs and the current operation; native copy/hash routines check cancellation at their
existing boundaries, so a synchronous copy or framework operation can take time to
return. Source processing checks cancellation/ownership before publishing its result.

Repeated same-URL drop events coalesce while queued/active for the same project.
Documents/images use existing SHA-256 duplicate detection within the project.
Separate explicit audio imports are allowed to create separate recordings, as in
existing audio import. No content-based audio deduplication is introduced.

## Native navigation and UI

The NavigationSplitView sidebar provides All Recordings, alphabetically ordered
projects with folder symbols, New Project and eight recent recording rows.
All Recordings opens a native filtered list of the complete library.
All recordings remain accessible regardless of membership. Project context menus
provide rename/edit, import and confirmed deletion. File → New Project uses ⇧⌘N;
⌘O retains import, offering project files when a project is active.

`LibraryDestination` is a typed enum of All Recordings, recording UUID and project
UUID. Scene storage keeps compatible old recording UUID values and prefixes project
IDs. Deleted/unrecognized destinations fall back to All Recordings. Background progress
does not change selection; moving membership does not cancel recording work.

Project workspace has Overview, Recordings and Sources with title/filename filtering,
deterministic newest-first rows, counts, optional description and import activity.
Overview lists recent recordings/sources and current project/recording work. Recording
rows show title, duration, date and transcription state, without reading segments/chat.
They open existing detail and offer Move to Project, Remove, Export and Delete.
Recording detail exposes a compact project breadcrumb and existing feature UI.

Shared project source rows show status, measured page/unit progress, warnings and retry.
They reuse the shared thumbnail loader and existing PDF/image/text source preview.
Open, rename, retry, Show in Finder and confirmed delete are available. The import
summary makes partial failures visible and opens the per-file activity list, with
Cancel Remaining and Clear Finished. Global Activity returns to active projects.

Native URL drops continue to import files into project sidebar rows or the selected
project workspace. Recent Recording and All Recordings rows also drag existing
recording identities onto project sidebar rows or a project workspace. The app declares the private recording-reference UTI in its bundle metadata. The
transfer carries only the recording UUID; the receiving library resolves it against
its current recordings and calls `SwiftDataProjectRepository.move`. This changes
membership without copying audio, recreating the recording, or interrupting active
recording work. Both project drop targets show hover feedback. Drop dispatch/hover,
keyboard focus, source previews and appearance require native desktop acceptance. No
Chat/AI placeholder tab exists in M12.1 itself.

## Chunk identity and M12.2 assumptions

`RecordingContextSnapshot.chunks(for:)` is the common pure derivation routine for
immutable source input. It preserves the prior source/unit/offset hash IDs, typed
page/section/image locators and audio segment identity/timestamps. Project source
text uses the same persisted units and can feed that routine without a fake recording.
M12.1 imports do not persist duplicate SourceChunk text or build project retrieval.

Source UUIDs and their explicit owner relationships provide the future authority
chain: project → shared source → page/section/image, or project → recording → source /
transcript → original timestamp. Future project citation resolution must verify that
chain at request start and before persistence/display, and handle membership changes.
Current recording AI context/export remains strictly recording-scoped: attaching a
recording to a project never implicitly includes shared project documents.

No ProjectChatSession, ProjectGenerationRecord or generalized AI artifact ownership
has been introduced prematurely. Optional membership and shared-source relationships
allow later explicit project artifacts/retrieval without moving recording history.

## Validation and performance

Final Debug and Release macOS builds and full Debug regression run passed: **337 tests in 62 suites**,
including **15 new project tests**. `git diff --check` passed. No new Swift or
SwiftData compiler/runtime diagnostics appeared. The existing App Intents metadata
warning remains because the app has no AppIntents dependency.

The automated suites cover model creation/rename, empty/content deletion, keep/delete
recordings, assign/move/remove, file preservation, shared-source ownership/rename/remove,
reopen/stable chunks, migration/history/pricing, mixed import and unsupported items,
retry, cancellation, deletion awaiting extraction, bounded work across projects,
navigation restoration, active transcription moves and strict recording AI scope.

Mixed native fixture import uses 3 WAV, 2 PDF, 2 PNG, 1 Markdown and 1 unsupported ZIP.
It creates 3 recordings and 5 shared sources; 8 entries succeed and the unsupported
entry is reported. PDF extraction and injected deterministic OCR use the existing
native processing pipeline. Real Vision recognition has separate existing tests;
this batch test does not establish OCR accuracy on real photos.

The component metadata test persists 100 projects, 500 recordings and a project with
100 recordings/200 sources, then uses a new context to fetch project names and the
first workspace's row metadata. Observed Debug timing was about **25–26 ms** in the
selected and full suite runs. This measures fetch/relationship metadata, not SwiftUI
rendering, scroll FPS, full production opening, or absence of all Core Data faulting.
Rows/counts do not explicitly read segments, chat or derive chunks. A native trace
is still required to rule out indirect eager-loading and repeated-render regressions.

For an isolated native development fixture:

```sh
open -n /tmp/AudioNotes-M12/Build/Products/Debug/AudioNotes.app \
  --args --performance-fixtures --performance-projects
```

Both flags are DEBUG-only. This extends the existing synthetic 504-recording fixture
with 100 projects and 200 generated shared PDFs; the first project has 100 recordings.
It uses in-memory SwiftData, separate temporary managed files and mock providers.
Never use production libraries or metered requests for these fixtures.

Assistive automation was unavailable (assistive access disabled). An isolated
clean-environment launch/profile did not establish a visible rendered workspace;
therefore its idle CPU/RSS observation is not project desktop acceptance and the
unusable raw trace was removed. No Light/Dark, VoiceOver, keyboard, scrolling FPS,
full-screen/narrow-window or stable-memory claim is made.

## Remaining acceptance and limitations

- Archived production-store migration and actual project relaunch/restoration.
- Native create/edit/delete/keep flows, picker and sidebar/workspace mixed drops.
- Navigation away/return during real long OCR/import and cancellation/deletion.
- Source previews and actual photo/scanned PDF OCR, failures and disk-pressure recovery.
- Light/Dark, narrow/fullscreen, keyboard/focus, VoiceOver and localization widths.
- Native project opening/scrolling profiles, eager-loading traces, idle CPU and repeated-navigation memory.
- Multiwindow coordination, quit with active work, crash recovery for staged deletion.
- Queue is in memory, serial within a library/window, and not resumable after termination.
- Project export and every project AI/retrieval feature remain deferred. Recording drag/drop is implemented; native interaction acceptance remains open.

## Files in this M12.1 change

The workspace already contained extensive modified/untracked M1–M11 implementation.
This inventory identifies the M12.1 edits only, not authorship of that existing work.

Created:

- `AudioNotes/Models/Project.swift`
- `AudioNotes/Services/Projects/ProjectRepository.swift`
- `AudioNotes/Services/Projects/ProjectImportQueue.swift`
- `AudioNotes/Features/Projects/ProjectWorkspaceView.swift`
- `AudioNotes/Features/Projects/ProjectLibraryDialogs.swift`
- `AudioNotes/Features/Projects/ProjectControls.swift`
- `AudioNotes/Features/Library/LibraryDestination.swift`
- `AudioNotes/Features/Library/AllRecordingsView.swift`
- `AudioNotesTests/LegacyM11Schema.swift`
- `AudioNotesTests/ProjectFoundationTests.swift`
- `AudioNotesTests/ProjectImportTests.swift`
- `AudioNotesTests/ProjectMigrationTests.swift`
- `AudioNotesTests/ProjectPerformanceTests.swift`
- `docs/PROJECTS.md`

Modified:

- `AGENTS.md`, `docs/ROADMAP.md`
- `AudioNotes/App/AudioNotesApp.swift`
- `AudioNotes/Models/Recording.swift`, `RecordingSource.swift`
- `AudioNotes/Services/LibraryStorage.swift`, `RecordingRepository.swift`
- `AudioNotes/Services/Sources/SourceImportService.swift`, `SourceProcessingService.swift`, `SourceCompatibilityMigration.swift`, `RecordingContextRetriever.swift`
- `AudioNotes/Features/Library/LibraryView.swift`, `LibraryViewModel.swift`
- `AudioNotes/Utilities/Development/PerformanceFixtureLibrary.swift`

`SourceProcessingProgressHandler` names the existing Sendable callback type so test
implementations preserve its module's Swift concurrency function type across target
build settings; no concurrency suppression or third-party dependency is added.
