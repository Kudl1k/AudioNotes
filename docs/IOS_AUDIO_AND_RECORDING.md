# M16.3 — iOS audio import, playback and recording detail

## Status and baseline

Implemented as a native SwiftUI iPhone/iPad workflow. Changes remain uncommitted for review; no push was performed. M16.4 has not started. M16.2 was first verified and committed separately as `52d62a3284d5cfd777b02a7ad87a7805e551125a` (`feat(ios): add native app target and navigation shell`). Its clean-tree baseline was 437 macOS tests in 78 suites, macOS Release and iOS Simulator builds, and native launch on iPhone 17/iPad (A16).

No SwiftData model property, relationship, schema identifier, `LibrarySchemaV1`, `LibraryMigrationPlan`, or migration version changed. The existing real `Recording`/`TranscriptSegment`/`Summary` models are used. Existing project membership is retained. No new provider or paid request is executed.

## Import and file ownership

`IOSRootView` uses SwiftUI `.fileImporter` with multiple selection, from the Library/All Recordings toolbar and empty-state **Import Audio** action. iPad uses the same implementation. The filter derives from `SourceImportService.supportedTypes`, retaining only types conforming to audio: the shared definition currently contains `UTType.audio`. There is no independent iOS extension allowlist.

The broad native audio type includes familiar M4A, WAV, MP3, AAC and AIFF containers, but an extension is not proof of decodability. `AudioImportService` checks regular file/native content type (extension-derived UTType only as the existing fallback), then AVFoundation audio tracks and finite positive duration. Native QA covered PCM WAV and AAC-in-M4A; other codecs are not claimed to have been individually accepted. The Files picker filters native audio types; content validation still occurs after selection.

The existing shared import actor calls `startAccessingSecurityScopedResource()` for each external URL and balances successful access with `defer`/`stopAccessingSecurityScopedResource()`, including failures and cancellation. It copies with `FileManager.copyItem`, using a UUID filename plus original extension, so equal source filenames do not overwrite one another. Files-provider access ends after import; no external bookmark or original URL is needed for playback.

Managed files live in the existing `LibraryStorage` hierarchy:

```
<iOS app container>/Library/Application Support/AudioNotes/
  Library.store
  Recordings/<recording UUID>.<extension>
```

The macOS hierarchy is unchanged. No second storage tree was introduced. Import copies and validates before creating/persisting metadata; the repository saves the existing title, original filename, duration, imported date and managed audio filename, and backfills the primary audio source through the existing compatibility service. A metadata-save failure discards the copy. Validation/cancellation removes the current unsuccessful copy. There is no import temporary-file staging in `tmp`.

`IOSAudioImportModel` is root/library-owned and retains the batch task across navigation. It reuses `LibraryViewModel.importURLs` and the existing repository transaction. Imports are serial; failures preserve successful items. The shared method now returns a factual result and accepts optional progress/friendly-error callbacks; default macOS callers retain their previous behavior. UI reports the current **Importing X of N**, elapsed time and indeterminate progress, then the imported count and per-file errors. No byte percentage or fabricated ETA is shown.

Cancel keeps completed recordings, prevents subsequent files and rolls back the current unpublished copy. A filesystem copy itself cannot be interrupted mid-call; cancellation is checked immediately afterward and before persistence. The Cancel button changes to a disabled cancelling state while cleanup completes. Invalid AVFoundation audio uses M14.4's **This file does not contain playable audio.** Storage/Files-provider failures have actionable iOS copy, rather than raw provider errors. Picker cancellation creates no result/error.

## Native detail and management

The iPhone detail has a wrapping/truncating recording identity and metadata header, Transcript/Summary segmented selection and a pinned touch player. iPad uses the same view inside split navigation, with bounded detail/player widths and a 760-point readable summary width. Header title supports three lines, original filename two lines, with middle truncation; the header can scroll at large text sizes. Metadata includes the existing duration, import date and optional project label; no model fields were added.

The actions menu exposes Rename and destructive confirmed Delete. Rename changes metadata only. Delete uses `SwiftDataRecordingRepository` through the library, preserving its staged-file deletion/rollback semantics and removing the recording graph/history/files. Project deletion is not invoked: other members and shared project data survive. Playback is stopped before deleting, and navigation dismisses only after the library reports completion. Missing/damaged managed audio presents a useful playback error.

## Playback, seeking and lifecycle

The engine remains the shared `AudioPlaybackService`/local-file `AVAudioPlayer`; iOS does not have a second playback engine. A small `AudioPlaybackEngine` protocol and injectable factory make state transitions testable without hardware. The original macOS interval and behavior remain unchanged.

`IOSRecordingPlaybackModel` surrounds that engine with foreground iOS session policy. `IOSPlaybackAudioSession` serializes session activation/deactivation and file/player preparation off the UI actor. AVAudioPlayer is transferred once to the main-actor service, with no concurrent retained use by the preparation actor. Revision/cancellation checks reject superseded preparation. This avoids the main-thread session activation warning found during early native QA.

The session uses `.playback` / `.default`: user-requested audio is audible with the silent switch enabled and follows the current system route. Activation occurs on Play, not globally at app launch. Pause/stop/background/interruption deactivate with `notifyOthersOnDeactivation`. Blocking session APIs are necessary for iOS 18 (the async variants require iOS 27). See Apple's [playback category documentation](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playback).

Play/Pause, current position, duration and scrubber use the shared duration formatter. Dragging maintains a local preview and commits seeking on release; seeking preserves the current playing/paused state. Accessibility adjustment seeks directly. Completion updates the state and replay starts from zero. Basic interruption began, output-device removal, inactive/background and detail disappearance pause/stop coherently. Foreground does not unexpectedly resume audio. Media-service reset reloads the managed audio. Session operations are ordered so a cancelled activation cannot race a later pause.

No background audio entitlement, Now Playing/lock-screen controls, route picker, microphone recording or automatic resume was added. Physical calls, Bluetooth route loss and silent-switch behavior still require device acceptance; deterministic notification handling is tested.

## Transcript and stored summaries

The existing SwiftUI `TranscriptView` and off-actor `TranscriptViewModel` search are reused. Lazy rows display real ordered segment text, optional speaker and original timestamp. Timestamp actions seek the same player. iOS adapts the search keyboard/submit dismissal, interactive scrolling and a 44-point timestamp hit target. Filtering scrolls to the first match to avoid retaining an out-of-range viewport; normal manual scrolling is preserved. There is no playback-driven auto-follow or active-segment highlight in this pass, keeping timer observation inside the player leaf.

No transcript displays a useful **No transcript yet** state and no unavailable generate action. New recordings are playable without an AI provider.

Existing summaries and history are read-only. `SummaryMarkdownContent` snapshots structured stored fields on their owning actor; Markdown parsing runs off that actor and cancelled results cannot publish. The existing native `MarkdownMessageView` was moved unchanged out of the macOS chat file into Shared; both platforms use the same headings, paragraphs, lists, code and links renderer. Current/history selection is available when stored versions exist. The empty state explains that generation comes later. No historical model content is rewritten.

## Tests and build evidence

M16.2 had an iOS app target/scheme, but no runnable iOS test target. M16.3 adds hosted `AudioNotesTests-iOS`, reusing selected portable files from the existing test folder and the shared iOS scheme. macOS target configuration is preserved.

| Validation | Result |
| --- | --- |
| macOS baseline | 437 tests / 78 suites |
| macOS current | 442 tests / 79 suites, zero failures |
| iOS shared/hosted target | 26 tests / 6 suites, zero failures |
| iOS Debug generic Simulator build | Passed |
| iOS Release generic Simulator build | Passed |
| macOS Release build | Passed |
| Swift compiler warnings | No new Swift warnings; existing AppIntents metadata-extraction notice remains |

Five new shared tests cover mixed batch partial success/progress, rollback on cancellation after copy, player play/pause/seek/completion/replay and transcript timestamp, Czech structured summary rendering input, and project-member deletion/file cleanup. Four iOS tests cover library-owned batch persistence/reopen, immediate cancellation cleanup, missing-audio error, real prepared player/timestamp seek and pause/interruption state. Existing audio-import tests cover success, invalid audio, duplicate filenames, managed destination and failure cleanup. Test command: `xcodebuild test -project AudioNotes.xcodeproj -scheme AudioNotesiOS -destination 'platform=iOS Simulator,id=<device>' -collect-test-diagnostics never`; macOS uses scheme `AudioNotes`, destination `platform=macOS`. Disabling automatic diagnostic collection avoids an observed post-test `simctl diagnose` stall; assertions and processes then exit successfully.

## Performance and native acceptance

QA uses actual native XCTest interaction with Simulator controls; no web UI. A temporary UI-test runner outside the repository drove the native Files picker. The five-file batch was placed in the Simulator's local Files-provider storage, then selected through **On My iPhone/iPad**, not injected into the import API. It contained two short valid files, one long-name WAV, a 30-minute 57.6 MB WAV and a deliberately invalid `.m4a`. Both iPhone 17 and iPad (A16) imported four recordings with one friendly error, showed managed rows, played/paused/seeked while playing, displayed empty transcript/summary, persisted after termination/relaunch and deleted one recording. Managed file count fell from four to three after deletion. iCloud Drive was not available; no iCloud acceptance is claimed.

A DEBUG-only `--performance-fixtures --ios-audio-review` fixture uses the existing isolated in-memory store/temporary storage policy, generates bounded audio buffers off actor and creates 6,000 real synthetic transcript segments plus Czech Markdown/history. It never seeds a real library or calls providers. Native iPhone swiping, search for segment 5,900 and timestamp seek reached **29:29 of 30:00**. Stored headings, paragraphs, numbered lists, code, link and Czech Unicode were displayed natively. Active playback paused after Home/foreground.

Copying uses filesystem APIs without whole-file `Data`; playback uses file-backed AVAudioPlayer rather than a complete decoded PCM array. The 57.6 MB/30-minute import and playback path succeeded. The transcript remains lazy. Player position polling is 250 ms (4 Hz) on iOS, confined to the control leaf; macOS retains 100 ms. Simulator process samples under XCTest are not isolated memory/FPS benchmarks; there is no claim of an Instruments memory budget or smoothness certification. Real-device long-session memory/performance acceptance remains open.

Light/Dark, large-text and long-name review results are recorded below after the final native checks. VoiceOver labels cover Play/Pause, seek position, current/duration, segment speaker/text/“Play from”, and Import Audio/progress/errors. Controls have touch targets where appropriate. Physical VoiceOver narration/focus is pending.

Review images: [iPhone library](review/M16.3/iphone-library-after-import.png), [iPhone detail](review/M16.3/iphone-recording-detail.png), [iPhone transcript](review/M16.3/iphone-transcript.png), [iPad detail](review/M16.3/ipad-recording-detail.png).

## Compatibility and next milestone

`project.pbxproj` remains `objectVersion = 77`. Xcode 27 locally rewrites that value during builds; it is restored after validation, without adopting a project-format upgrade. No macOS bundle ID, signing, Sparkle, appcast, notarization or release workflow changed. A native macOS regression used the isolated fixture window to import and play the same WAV; macOS detail geometry was retained.

Explicitly deferred: cloud/OpenAI transcription, summary generation, Recording/Project Chat, project source import, PDF/image OCR workflow, export/ShareLink, Whisper, Ollama connectivity, microphone, background/lock-screen controls. M16.4 must wire an explicit iOS provider/Keychain credential flow, the existing transcription pipeline with foreground progress/cancellation/error/restart semantics, and live provider acceptance before real OpenAI transcription can be enabled. M16.3 does not bypass privacy/runtime gates or run a hidden provider request.
