# M16 — iOS / iPadOS port: architecture and portability audit

Status: M16.0 audit, M16.1 boundaries, M16.2 target/navigation, M16.3 audio import/detail, and M16.4 cloud AI completed (2026-10-02).
Shared/platform boundaries prepared with zero macOS behavior change (see `docs/IOS_PLATFORM_BOUNDARIES.md`).
iOS target and adaptive navigation shell operational on iPhone/iPad simulators (see `docs/IOS_TARGET_AND_NAVIGATION.md`).
SwiftData schema remains 100% frozen; project.pbxproj remains on objectVersion = 77.
M15 (macOS release candidate, signing, notarization) is reserved and not part of M16.

## 1. Executive summary

- The architecture is suitable for one shared codebase with two platform front ends. Models, repositories,
  provider clients, retrieval, summaries, usage/cost and the Markdown model are plain Foundation/SwiftData
  and contain no AppKit. Only **7 of 208** source files import AppKit: five already live in
  `Platform/macOS/AppKit`; the other two are `PDFExporter` (the documented exception) and the DEBUG-only fixture delegate.
- There is **no `#if os(...)` or `canImport` anywhere** in the app. The only platform conditionals are
  `arch(arm64)` in the Whisper runtime and diagnostics. The codebase is macOS-only by construction, not by
  accident of conditionals, so the port is mostly additive.
- Rough reuse, by line count of the app target (23,175 lines in 208 files; heuristic classification from
  imports and API audit, not a per-line measurement): **~78 % shares as-is or with small edits, ~14 % needs an
  iOS-specific implementation or redesign, ~7 % is macOS-only.** Models/Services/Utilities (14.7 k lines) are
  roughly 85–90 % shared; Features/App/Platform (8.5 k lines) roughly 60–65 %.
- **Biggest surprise: provider coverage.** The only Anthropic path is the **Claude CLI (`Process`, macOS-only)**.
  There is **no Gemini LLM provider** (the resolver returns `UnavailableLLMProvider`) and nothing consumes the
  Google OAuth tokens. ChatGPT-plan and Google sign-in both depend on a loopback listener and the system
  browser. An iOS build therefore starts with **OpenAI (API key), Ollama/llama.cpp over LAN, and (later) local
  Whisper**. Adding providers is not M16 scope.
- **Biggest technical risk: background execution.** Every long operation is an in-memory `Task` over a
  foreground ephemeral `URLSession`; the OpenAI upload builds the multipart body in memory. iOS will suspend all
  of it within seconds of backgrounding. There is no resumable job state.
- SwiftData models and the migration plan contain nothing macOS-specific and should compile unchanged for iOS.
  This is the highest-consequence assumption and must be the first thing verified (compile-only spike).
- Recommended minimum: **iOS / iPadOS 18.0**, matching the macOS 15 floor and the APIs already in use.
- Recommended structure: **one new iOS app target sharing the existing source folder through
  file-system-synchronized-group membership exceptions**, no Swift package yet, same SwiftData schema, separate
  local database, no CloudKit.
- Free development constraint holds: everything through M16.6 is doable on the iOS Simulator with automatic
  signing (no paid membership). Local-network behaviour, Keychain-while-locked and background behaviour need a
  real device eventually (a free personal team can install on a device, with limits).

## 2. Current architecture

Targets (from `project.pbxproj`, `objectVersion = 77`, Xcode 16 format kept for CI):

| Item | Today |
| --- | --- |
| Targets | `AudioNotes` (macOS app), `AudioNotesTests` (hosted unit tests). No UI-test target. |
| Source membership | Two `PBXFileSystemSynchronizedRootGroup`s: `AudioNotes/` (one exception: `Resources/GoogleOAuth.json`) and `AudioNotesTests/` (none). Files are picked up by folder. |
| SDK / deployment | `SDKROOT = macosx`, `MACOSX_DEPLOYMENT_TARGET = 15.0`, `ARCHS = arm64`, Swift 6.0, `SWIFT_APPROACHABLE_CONCURRENCY = YES`, `MEMBER_IMPORT_VISIBILITY = YES`. |
| Packages | `argmax-oss-swift` 1.1.0 (product `WhisperKit`) and `Sparkle` 2.10.0, both exact pins and both linked into the macOS app only. `swift-argument-parser` is transitive. |
| Entitlements | Debug: `disable-library-validation` (for Sparkle). Release: empty. `ENABLE_APP_SANDBOX = NO`, hardened runtime on. |
| Info.plist | `Configuration/AudioNotes-Info.plist` merged with generated keys: ATS (`NSAllowsLocalNetworking` plus a developer-specific `mac.lab` exception), `NSLocalNetworkUsageDescription`, Sparkle `SU*` keys, exported UTI `com.audionotes.recording-reference`. |
| Assets | Root `Assets.xcassets` (macOS `AppIcon`, `AccentColor`, three provider icons) and `AudioNotes.icon`. |
| xcconfig | `App.xcconfig` (bundle id `cz.stepankudlacek.audionotes`, team, display name, category), `Version.xcconfig`. |
| SwiftData | 11 `@Model` types, one `ModelContainer` creation site (`LibraryStorage.makeContainer`), `LibrarySchemaV1` with `stages = []`. |
| Tests | 80 files, 431 `@Test`, Swift Testing, `TEST_HOST` = macOS bundle path. |
| CI | `.github/workflows/validate.yml` builds the macOS scheme on an Xcode 16 runner. |

Layering (matches `AGENTS.md`): `App/` (composition root `AppServices`, scene definitions), `Models/` (769 lines),
`Services/` (12,981 lines, 112 files), `Features/` (7,979 lines, 63 files), `Utilities/` (962 lines),
`Platform/macOS/AppKit/` (303 lines, 6 files). Composition is already in a Foundation-only
`AppServices`; view models are UI-framework-free; long operations are owned by library-level models.

## 3. Portability inventory

Legend: **SHARED** as-is · **SMALL** shared with small changes · **ABSTRACT** platform abstraction required ·
**MAC** macOS-only · **IOS** iOS implementation required · **INVESTIGATE** unknown.

| Subsystem | Class | Evidence / note |
| --- | --- | --- |
| SwiftData models (11) | SHARED (verify compile) | Foundation + SwiftData only; relative filenames, no absolute paths, no `.externalStorage`/Transformable; enums as raw strings. |
| Migration plan / schema | SHARED | `LibrarySchemaV1`, `LibraryMigrationPlan(stages: [])`; `SourceCompatibilityMigration` is platform-neutral. |
| `LibraryStorage` / container | SMALL | One site; defaults to `cloudKitDatabase: .automatic` (inert today, no iCloud entitlement). iOS root is `URL.applicationSupportDirectory`. |
| `AppStorageLocations` | MAC | Legacy sandbox-container lookup and `restorePreferences` read `~/Library/...` via `homeDirectoryForCurrentUser`. Gate with `#if os(macOS)` or move to a macOS file. |
| `MetadataBackup` (SQLite3) | SHARED | Online SQLite backup to `Backups/pre-v1.store`; SQLite3 exists on iOS. |
| Repositories (`RecordingRepository`, `UsageRepository`, project repo) | SHARED | SwiftData only. |
| Library services / `LibraryViewModel` | SHARED | No UI imports; owns the long-running task models. |
| Projects, `ProjectImportQueue` | SHARED | Copy-first import with security-scoped access inside the importers. |
| Source processing | SMALL | PDFKit text, ImageIO, Vision, CryptoKit portable; PDF page thumbnails use `NSImage` bridging (`SourceProcessingService.swift:62,70`) and must be re-done with CoreGraphics. |
| Audio import | SHARED | `AVURLAsset` header validation, `copyItem` into managed storage. |
| Audio playback | ABSTRACT | `AVAudioPlayer` is fine; iOS needs `AVAudioSession`, interruption and route handling that do not exist today. |
| Audio splitting (OpenAI) | SMALL | `AVAssetExportSession` async `export(to:as:)` is iOS 18+; preset exists. |
| Cloud transcription (OpenAI) | SMALL | URLSession/Foundation; foreground ephemeral session and in-memory multipart body are the iOS problem (see §19). |
| Local Whisper (WhisperKit) | INVESTIGATE (viable later) | See §13. |
| Summary generation | SHARED | LLM/service layer, prompt/preset code is Foundation-only. |
| Recording Chat / Project Chat engines | SHARED | View models have no UI imports. |
| Retrieval, chunking, lexical index | SHARED | Pure Swift (7 files); `getrusage` appears only in a test. |
| Embeddings / semantic foundation | SHARED | Provider-independent seam, no production provider. |
| Citations / reference resolution | SHARED | `SourceReferenceResolver`, `RetrievalReferenceIndex`, `SourceLocator` are Foundation. |
| Markdown (`MarkdownDocument` + renderer) | SHARED | Foundation `AttributedString`; renderer is SwiftUI. Only `Clipboard.copy` is platform. |
| PDF handling (view) | ABSTRACT | `PDFPreviewRepresentable` → `UIViewRepresentable`; locator semantics shared. |
| OCR (`OCRService`) | SHARED | `VNRecognizeTextRequest` on `CGImage`; available on iOS. |
| Image sources / thumbnails | SHARED | CGImage/ImageIO; displayed via `Image(decorative: CGImage)`; no `NSImage` in Features. |
| Document sources | SHARED | `Data(contentsOf:)` for text (≤ 64 MB) is a memory note, not a portability break. |
| Generation history / usage / pricing | SHARED | Foundation/SwiftData, `Decimal`. |
| Presets | SHARED | Foundation-only. |
| Provider settings models (`LLMConfiguration`, `LocalAIConfiguration`, `TranscriptionConfiguration`) | SMALL | `@Observable` + UserDefaults; carry macOS members (`claudeExecutablePath`) and "Runs on this Mac" copy. |
| OpenAI (LLM + transcription + models) | SHARED | Foundation URLSession. |
| Anthropic | MAC | Only implementation is `ClaudeCLI*` (`Process`). No API client. |
| Gemini | INVESTIGATE | LLM provider unavailable; OAuth service exists but is unconsumed. |
| Ollama / llama.cpp | SMALL | URLSession; address default `localhost`, macOS error copy, `.local`-means-"this Mac" semantics. |
| OAuth / account providers (ChatGPT plan, Google) | ABSTRACT + IOS | System browser + loopback listener; see §12. |
| Keychain | SMALL | Generic-password SecItem code compiles on iOS; accessibility decision needed (§12). |
| Export Markdown | SHARED | `ExportContent` → Markdown, off-actor. |
| Export PDF | ABSTRACT | `PDFExporter` uses `NSFont/NSColor/NSFontManager` over CoreText layout. |
| Diagnostics | SMALL | `DiagnosticExporter` portable; field named `macOS`; save-panel delivery is macOS. |
| Updater / Sparkle | MAC | `UpdateService`, `SU*` plist keys, `ReleaseCommands`. Must not link on iOS. |
| Filesystem | SMALL | Only `applicationSupportDirectory` and `temporaryDirectory` roots; no backup/protection attributes set. |
| Logging | SHARED | OSLog `Logger`, `OSSignposter`, in-memory `DebugLogService`. |
| Settings UI | IOS | `Settings {}` scene and a hand-built sidebar; settings *models* are shared. |
| Help / Privacy / Licenses | SMALL | Bundle `.txt` files shown by `ReleaseInformationView`; macOS `WindowGroup`; Help text is macOS-worded. |
| Commands / menu bar / shortcuts | MAC | `CommandGroup`, `@FocusedValue` actions (the *actions* are reusable). |
| Library / detail / project navigation shells | IOS | Redesign, same `LibraryDestination` model (§16). |
| Chat presentation (shared rows/list/status) | SMALL | See §15. |
| Chat composer | ABSTRACT + IOS | AppKit `NSTextView` representable; iOS composer is separate. |
| Tests | see §22 | |

## 4. AppKit and platform import map (file level)

Framework → files (app target). `Foundation`, `SwiftUI`, `SwiftData` (151/51/51 files) are universal.

| Framework | Files | iOS |
| --- | --- | --- |
| **AppKit** | `Platform/macOS/AppKit/{Alerts,ChatTextEditorRepresentable,Clipboard,FilePanels,Workspace}.swift`, `Services/Export/PDFExporter.swift`, `Utilities/Development/PerformanceFixtureApplicationDelegate.swift` (DEBUG) | UIKit counterparts, or exclude |
| **Sparkle** | `Services/Release/UpdateService.swift` (used by `AudioNotesApp`, `ProviderSettingsView`, `ReleaseCommands`) | Exclude; stub seam |
| **PDFKit** | `Platform/macOS/AppKit/PDFPreviewRepresentable.swift`, `Services/Sources/SourceProcessingService.swift` | Available; thumbnail path needs change |
| **AVFoundation** | `AudioImportService`, `AudioPlaybackService`, `Sources/SourceImportService`, `Transcription/MockTranscriptionProvider`, `OpenAI/OpenAIAudioSplitter`, `OpenAI/OpenAIAudioUpload`, `LocalWhisper/WhisperKitRuntime`, `OperationPresentationFixtures` (DEBUG) | Available; session handling missing |
| **WhisperKit / ArgmaxCore** | `LocalWhisper/WhisperKitRuntime.swift` | Declares iOS 16+; unverified in this app |
| **Vision** | `Sources/OCRService.swift` | Available |
| **ImageIO / CoreGraphics** | `MultimodalContextService`, `SourceProcessingService`, `SourceImageLoader`, `OCRService`, `PDFExporter`, fixtures | Available |
| **CoreText** | `PDFExporter`, `PerformanceFixtureLibrary` (DEBUG) | Available (see §14 on NSFont) |
| **Security** | `KeychainService`, `ChatGPTCredentialStore`, `ChatGPTJWKSVerifier`, `PKCEHelper`, `GoogleGeminiOAuthService` | Available |
| **CryptoKit** | `PKCEHelper`, `RecordingContextRetriever`, `SourceImportService`, `WhisperModelStore`, fixtures | Available |
| **Network** | `ChatGPTLoopbackListener` (`NWListener` on 127.0.0.1) | Compiles; wrong mechanism on iOS |
| **UniformTypeIdentifiers** | 11 files (import services, drag item, export/library views) | Available |
| **Darwin** | `ClaudeCLIRunner` (+ `Process`) | macOS-only |
| **SQLite3** | `MetadataBackup` | Available |
| **OSLog** | logging files | Available |
| UIKit, WebKit, StoreKit, AuthenticationServices, VisionKit, Photos | none | n/a |

Other macOS-only APIs outside the adapters: `Process` (Claude CLI), `homeDirectoryForCurrentUser`
(`AppStorageLocations`, `ClaudeCLIRunner`), `@NSApplicationDelegateAdaptor` (DEBUG), and SwiftUI macOS-only
API (§16, §20). `SettingsLink` appears at four sites; `Color(nsColor:)` at three; `HSplitView` once;
`.pickerStyle(.radioGroup)` once; `.buttonStyle(.link)` seven times.

## 5. Compilation conditions

Today: `arch(arm64)` in `WhisperKitRuntime.swift:10,97` and `DiagnosticExporter.swift:15`; `#if !DEBUG` in
`DebugLogService.swift:48`; 27 `#if DEBUG` blocks in 23 files (fixtures, previews). No `os()`, `canImport` or
`targetEnvironment` anywhere.

Policy for M16:

1. **Prefer target membership over conditionals.** macOS-only *files* (`Platform/macOS`, Claude CLI, Sparkle)
   are excluded from the iOS target by exception set. A new iOS-only folder holds the iOS adapters.
2. **Use a protocol seam only where shared feature code calls the platform.** Clipboard, file import/export
   presentation, external URL, "open provider settings", update availability, audio session. Do not create a
   protocol for something only one platform implements and shared code never calls.
3. **Allow `#if os(macOS)` only at leaf modifiers** (a handful of styling differences) and inside the legacy
   macOS-only helpers. No `#if` in view-model or service logic.
4. `isSupported` for Whisper must stop meaning `arch(arm64)` on iOS (the arm64 simulator slice would claim
   support; Intel macOS availability must remain separately decided, per `AGENTS.md`).

## 6. Current Xcode target structure and proposed iOS target (design only)

| Decision | Recommendation |
| --- | --- |
| Target name | `AudioNotesiOS` (scheme `AudioNotes iOS`) |
| Product name | `AudioNotes` (display name `AudioNotes`) |
| Bundle identifier | Provisional `cz.stepankudlacek.audionotes.ios` (so it can coexist with the Mac id in a future universal-purchase decision, and not collide on a personal team). Not final. |
| Platforms / families | iPhone + iPad (`TARGETED_DEVICE_FAMILY = 1,2`), no Mac Catalyst, no "Designed for iPad" Mac, no visionOS |
| Deployment target | iOS 18.0 (§17) |
| Signing | Automatic, personal team; team id supplied through an untracked local xcconfig, **not** the macOS `DEVELOPMENT_TEAM` baked into `App.xcconfig`. Simulator needs no signing. |
| Shared source | Add the existing `AudioNotes/` synchronized group to the iOS target with an exception set excluding `Platform/macOS/**`, `Services/Release/UpdateService.swift`, `Services/LLM/ClaudeCLI/**`, ClaudeCLI settings views, `Features/Release/ReleaseCommands.swift`, the DEBUG AppKit delegate, `Resources/GoogleOAuth.json` and (until §14) `PDFExporter.swift`. |
| iOS-only source | New root folder `AudioNotesiOS/` (app entry `@main`, root navigation, iOS adapters, iOS composer, iOS PDF preview, Info.plist, previews glue), added to the iOS target only. A separate folder avoids needing exclusions in the *macOS* target. |
| Packages | iOS target links nothing at first. `WhisperKit` only when M16.7 starts. **Sparkle is never linked.** |
| Assets | Add an iOS app icon set (`AppIconiOS`) to the existing catalog and set `ASSETCATALOG_COMPILER_APPICON_NAME` per target; provider icons and accent color are shared. Do not rename or move macOS assets. |
| Info.plist | New `Configuration/AudioNotesiOS-Info.plist`: exported UTI, `NSLocalNetworkUsageDescription`, ATS local-networking, scene manifest. **Not** copied: Sparkle keys, the `mac.lab` exception. No camera/mic/photos/background-mode keys until a feature needs them. |
| Entitlements | None (iOS is always sandboxed; no iCloud, no app group, no keychain group). |
| Tests | New `AudioNotesTests-iOS` target sharing the existing test folder (§22). |
| Schemes | Separate `AudioNotes iOS` scheme; the existing macOS scheme and CI invocation must not change. |

Constraints to verify in M16.1 (not assumed): (a) one synchronized group attached to two targets with a
per-target exception set behaves as expected in Xcode 16 *and* 27; (b) creating the target with Xcode 27
rewrites `objectVersion` to 110, which broke Xcode 16 CI before — plan to edit/restore to 77 and re-validate in
the Xcode 16 CI path; (c) `GENERATE_INFOPLIST_FILE` plus a custom plist behaves the same on iOS.

## 7. SwiftData findings (critical)

- 11 `@Model` types (`Project`, `Recording`, `RecordingSource`, `SourceTextUnit`, `Transcript`,
  `TranscriptSegment`, `Summary`, `ChatSession`, `ChatMessage`, `AIPreset`, `GenerationRecord`), each
  `@Attribute(.unique) var id: UUID`. They import Foundation and SwiftData only.
- Structured payloads are JSON `Data?` fields (references, citations, selections, usage/cost blobs); enums are raw
  strings; file references are relative (`Recording.audioFileName`, `RecordingSource.localFileReference`). No
  absolute path or URL is persisted anywhere; only `originalFileName` for display.
- `LibrarySchemaV1: VersionedSchema` lists the 11 live classes (its own comment warns to freeze them before a
  V2); `LibraryMigrationPlan` has `schemas = [V1]`, `stages = []`.
- Single container site `LibraryStorage.makeContainer(rootURL:databaseURL:inMemory)` using
  `ModelConfiguration(schema:url:)`; it first runs `MetadataBackup.prepareBaseline` (SQLite online backup),
  then `LibraryStartup` runs managed-deletion recovery, interrupted-usage marking and the source backfill.
- `.automatic` CloudKit default is inert today. If an iCloud entitlement is ever added to any target the
  `.unique` attributes become a problem; make `cloudKitDatabase: .none` explicit before that (one-line,
  behaviour-neutral on macOS, but decide it consciously in M16.1 since the rule is "do not modify macOS storage").

**Verdict:** the models and plan should compile for iOS unchanged. Verify with a compile-only spike before
anything else. **Do not** change the schema, identifiers, versions, or move models across modules.

macOS and iOS use the same schema and code, **separate local databases**; no CloudKit, no sync (M16 non-goal).
iOS store location: `URL.applicationSupportDirectory` (create the directory first — already done at
`LibraryStorage.swift:25`); the macOS legacy-container probing is irrelevant and must be gated out.

## 8. Filesystem assumptions and iOS mapping

| Category | Today | iOS mapping |
| --- | --- | --- |
| Library database | `<AppSupport>/default.store` | Application Support (backed up). Add file protection `completeUntilFirstUserAuthentication` explicitly. |
| Managed audio | `<AppSupport>/AudioNotes/Recordings/<UUID>.<ext>` | Application Support, backed up deliberately (it is user data). Consider a user-visible storage-use readout. |
| Managed sources | `<AppSupport>/AudioNotes/Sources/<UUID>/original.*` + `thumbnail.jpg` | Application Support. Thumbnails are derived data; moving them to Caches needs a regeneration path (not verified to exist). |
| Pre-v1 backup, deletion journals | `AudioNotes/Backups`, `AudioNotes/Deletion-<UUID>` | Application Support, exclude backup for Backups. |
| Whisper models | `<AppSupport>/AudioNotes/Models/Whisper/<id>` | Application Support with `isExcludedFromBackup = true` (re-downloadable, up to 1.6 GB). |
| Audio split parts | `tmp/AudioNotes-Transcription-<UUID>/part-NNNN.m4a` | `tmp`; **no launch sweep exists** — add one (OS cleaning is not guaranteed on kill). |
| Model download staging | `<models>/.download-<UUID>` | Same; add a launch sweep (no sweep found). |
| Caches | In-memory `NSCache` only | `Caches/` for any new derived cache. |
| Exports | User-chosen URL via `NSSavePanel`, atomic write | Generate in `tmp`, hand to `ShareLink`/`.fileExporter`; delete after share. |
| Diagnostics export | Save panel | Share sheet. |
| Bundle resources | `Bundle.main` (`WhisperModels.json`, `Help/Privacy/ThirdPartyLicenses.txt`, `GoogleOAuth.json`) | Add to iOS target (except `GoogleOAuth.json`). |
| Backup/protection attributes | none (`isExcludedFromBackup`, file protection never set) | Decide per row above. |

Hard-coded macOS paths exist only in `AppStorageLocations` and `ClaudeCLIRunner`.

## 9. File import (special attention)

- **All imports copy into managed storage; nothing is referenced externally.** `AudioImportService` copies to
  `Recordings/<UUID>.<ext>` then validates with `AVURLAsset`; `SourceImportService` copies to
  `Sources/<UUID>/original.<ext>` (512 MB, 64 MB for text, symlinks rejected) and hashes the copy.
  `ProjectImportQueue` classifies then delegates. No bookmark, no stored original path.
- Both importers call `startAccessingSecurityScopedResource()` with a `defer` stop and copy **inside** the access
  window. That is exactly what `.fileImporter`/Files-provider URLs need. The design does not assume permanent
  filesystem access.
- Gap to check on iOS: `ProjectImportQueue` holds URLs in a pending list and imports serially later; access is
  only opened inside each importer, so ownership is correct, but a security-scope that expires between pick and
  import (large batches, slow iCloud Drive downloads) is untested. File-provider items may need
  coordinated reading (`NSFileCoordinator`) or a download wait — **needs verification**.
- The current macOS shape is `async FilePanels.chooseFiles(...) -> [URL]`; SwiftUI `.fileImporter` is
  state-bound. Proposed adapter: a shared `FileImportRequest` value (types, multiple selection) plus a small
  view modifier that presents the platform picker and calls a shared `importPickedFiles([URL])` handler on the
  view model. macOS keeps `NSOpenPanel` behind the same modifier.
- `.dropDestination(for: URL.self)` already used by the library/project views works for iPad drags from Files;
  the same copy-inside-scope path applies.

## 10. Audio

- Import/validation (`AVURLAsset` tracks/duration), duration, playback (`AVAudioPlayer(contentsOf:)`, 100 ms
  polling task), the mock provider and the splitter's preset are all available on iOS. Nothing loads whole
  audio into memory; Whisper reads 120 s PCM windows.
- Missing for iOS: **`AVAudioSession`** (none today). Default category is soloAmbient: follows the silent
  switch and stops in the background. Needs `.playback` (and `UIBackgroundModes: audio` only if background
  playback is wanted), interruption/route-change observers (so `isPlaying` does not go stale), and optionally
  Now Playing / remote commands. Recording audio is not a feature, so no microphone permission.
- `OpenAIAudioSplitter` uses the async `AVAssetExportSession.export(to:as:)` (iOS 18). With an iOS 18 floor no
  change is needed; an iOS 17 floor would need `exportAsynchronously` or reader/writer.
- Temp files: split parts live in `tmp` and are removed on success/failure/cancel; orphaned on a kill (no sweep).

## 11. Providers

| Provider | Reality in code | iOS |
| --- | --- | --- |
| OpenAI LLM (API key) | `OpenAILLMClient`, ephemeral session, Foundation only | Share. |
| OpenAI transcription | `OpenAITranscriptionClient`; 25 MB limit, ≤ 600 s parts; multipart body built in memory as `Data`; `session.upload(for:from: Data)`; refuses redirects | Share; background caveats in §19. |
| ChatGPT plan | `ChatGPTResponsesClient` (SSE), tokens in Keychain; sign-in via loopback | Client shares; sign-in does not (§12). |
| **Anthropic** | `.anthropic` → `ClaudeCLILLMProvider` → `Process`. No API client; API key can be stored but nothing reads it | **Unavailable** on iOS. |
| **Gemini** | `.gemini` → `UnavailableLLMProvider`. `GoogleGeminiOAuthService` exists, unconsumed | **Unavailable**. |
| Ollama | `OllamaClient`, `/api/show` cloud-model guard, empty proxy dictionary, no redirects | Share (§12 LAN). |
| llama.cpp server | `LlamaCppLLMProvider`, same hardening | Share. |
| Mock | DEBUG/dev | Share — useful for simulator development without spend. |

There is no provider registry object: IDs are the enums `LLMProviderID` (`mock, openAI, anthropic, gemini,
ollama, llamaCpp`) and `TranscriptionProviderID` (`mock, openAI, localWhisper`), resolved by
`LLMProviderResolver`/`TranscriptionProviderResolver`. The platform switch is a `platformAvailable`-style filter
beside the existing `selectable` filters plus resolver fallback to `UnavailableLLMProvider` (which already
exists). `PrivacyLLMProvider`/`PrivacyTranscriptionProvider` (Local Only) are platform-neutral.

Claude CLI wiring that an iOS build must be able to exclude: `LLMProviderResolver` (both branches),
`LLMConfiguration` (`claudeExecutablePath`, `cachedClaudeModels`), `ProviderSettingsViewModel`,
`ProviderConnectionsView`, `ClaudeModelPicker`, `GenerationDefaultsView`, `UsageTracking.swift:182`.

**Scope note:** with Claude CLI unavailable and Gemini unimplemented, iOS cloud AI is OpenAI-only until the
(not-yet-started) native Anthropic/Gemini providers exist. That is a product decision, not an M16 task.

## 12. Ollama / llama.cpp over LAN, accounts, Keychain

**LAN.** Server addresses are user-configured (`ai.ollama.address`, `ai.llamaCpp.address`; default
`localhost`). `OllamaEndpoint` accepts http/https, host, optional port, rejects credentials/query/path.
Execution location is `.local` only for exact `localhost/127.0.0.1/::1`; LAN names and IPs are `.remote`
(external server, blocked under Local Only) — consistent with `AGENTS.md`. On iOS:

- `localhost` means the phone on a device; on the Simulator it reaches the host Mac. The default and the
  "Runs on this Mac" copy are wrong on iOS: ship an empty default and treat every iOS Ollama server as external.
  Consequence to decide: **under Local Only, iOS would allow only on-device components (Whisper later), no LLM.**
- Info.plist: `NSLocalNetworkUsageDescription` (existing text is fine). ATS: `NSAllowsLocalNetworking` should
  cover `.local` names, unqualified hosts and IP literals; arbitrary DNS names over HTTP (the developer's
  `mac.lab`) would need a per-domain exception — do **not** copy the developer exception into a shipping plist
  (document HTTPS or `.local`/IP). `NSBonjourServices` only if Bonjour discovery is added (it is not).
  **Needs verification** on device: Local Network permission is enforced on devices, not on the Simulator.
- Proxy bypass relies on `connectionProxyDictionary = [:]` plus refusing redirects; re-verify the empty-dictionary
  idiom behaves the same on iOS.
- Error copy references System Settings and macOS; make it platform-worded.

**OAuth / accounts (no redesign here).** Both flows open the **system default browser** via `BrowserOpening`
(`SystemBrowserOpener` → `NSWorkspace`) and receive the callback on a **loopback `NWListener`**
(`http://127.0.0.1:<port>/auth/callback`, PKCE S256, state validated). `ASWebAuthenticationSession` is not used.
Neither flow works on iOS as written: the app is suspended while the browser is in front, and loopback
listeners do not survive that.

Proposal (needs verification against each provider's current rules before any work):

- Introduce a platform-neutral `AuthorizationBrowser` seam (`authorize(url, redirectScheme) -> callback URL`),
  implemented on iOS with `ASWebAuthenticationSession`, replacing `BrowserOpening` + `ChatGPTLoopbackListening`
  at the call sites. macOS keeps loopback.
- Google: iOS needs an iOS-type OAuth client with a reversed-client-ID redirect and a different config parser
  (`GoogleOAuthConfiguration` accepts only the `installed` desktop shape; `GoogleOAuth.json` also carries a
  desktop client secret that is synced into the Keychain).
- ChatGPT plan: the allowed redirect forms for this client are not documented in the repo; it may not be
  available on iOS at all.
- **Recommendation: no account sign-in on iOS in M16.** Gemini has no consumer; ChatGPT is unverified. Use API
  keys.

**Keychain.** `KeychainService`, `ChatGPTCredentialStore` and the Google token store use `kSecClassGenericPassword`
with service/account, `kSecAttrSynchronizable = false`, accessibility `WhenUnlockedThisDeviceOnly` (set on add,
not on update). No access groups, no `kSecUseDataProtectionKeychain`, no `SecAccess`/LAContext. This compiles and
works on iOS. Two iOS facts: (1) `WhenUnlockedThisDeviceOnly` blocks reading the key while the device is locked,
so any future background transcription must use `AfterFirstUnlockThisDeviceOnly` (changing it needs a
read-old/write-new migration because the attribute is only applied on add); (2) adding the data-protection flag
in *shared* code would orphan existing macOS items — keep macOS behaviour as is. No credential logging was
found; keep it that way.

## 13. Local Whisper (investigation only)

- Runtime: WhisperKit via `argmax-oss-swift` 1.1.0, wrapped by `LocalWhisperRunning`; `OfflineWhisperKit`
  overrides `loadTokenizerIfNeeded` to load `tokenizer.json` from the model folder (upstream falls back to the Hub
  even with `download: false`). Hub/tokenizer code is vendored in ArgmaxCore (no separate swift-transformers pin).
- Package declares `iOS(.v16)`, `macOS(.v13)`, watchOS, visionOS. Core ML + `MLTensor` + Accelerate; no direct
  Metal import. `AudioProcessor` has macOS-only CoreAudio device code behind conditionals. The package ships a
  background-URLSession downloader that this app does not use.
- Pinned catalog (`WhisperModels.json`, SHA-256 per file, HuggingFace commit pin): tiny 79 MB, base 150 MB,
  small 489 MB, medium 1.53 GB, large-v3 turbo 1.64 GB (its encoder weights alone are 1.27 GB).
  `docs/LOCAL_AI.md` documents no memory estimates; none exist in the repo.
- App-side blockers: `isSupported` is `arch(arm64)` (true on the arm64 Simulator, meaningless for iPhone RAM);
  downloads use `URLSessionConfiguration.ephemeral` (cannot be a background session); one model loaded at a time,
  `prewarm: false` (first Core ML compile on first run); the tokenizer override was verified on macOS only;
  Simulator has no ANE (performance and, possibly, compatibility differ).
- **Classification: viable later; not for initial iOS.** Candidate first iOS scope would be tiny/base/small
  only, behind a measured RAM gate, foreground download with explicit user action and `isExcludedFromBackup`.
  Medium/large need on-device memory measurement first. Do not integrate in M16.1–M16.6.

## 14. PDF, OCR, images, export

- **PDF view.** `PDFPreviewRepresentable` (`NSViewRepresentable` over a read-only `PDFView` subclass; coordinator
  applies a zero-based `SourceLocator.pdf(pageIndex)` only when the locator changes) → port to
  `UIViewRepresentable` over the same `PDFView`. Citation/locator semantics stay shared. The `PDFView` subclass
  that blocks actions other than GoTo needs checking on iOS.
- **PDF extraction.** `PDFDocument(url:)`, `pageCount`, `isLocked`, `page.string` are available. Two lines use
  `PDFPage.thumbnail` → `NSImage` → `cgImage(forProposedRect:)`; replace with a CGContext page render shared by
  both platforms.
- **OCR.** `VNRecognizeTextRequest` (accurate, language correction, auto-detect, `cs-CZ`/`en-US` filtered by
  `supportedRecognitionLanguages()`) on a `CGImage`. Portable. Real OCR results on the Simulator are unverified.
  VisionKit is not used.
- **Images.** CGImage/ImageIO throughout; HEIC decode/encode on the Simulator unverified; 2,000/220/1,536 px
  downsamples avoid full decode.
- **Export.** `ExportContent` is shared; Markdown generation is pure. `NativeExportService` renders off-actor and
  writes atomically. iOS: write to a temp file, present `ShareLink`/`.fileExporter`. `PDFExporter` is the only
  AppKit service (NSFont/NSColor/NSFontManager over CoreText framesetter). Options: (a) make it
  platform-neutral using `CTFont`/`CGColor` (fixed print colors instead of dynamic `labelColor`) so both
  platforms share one implementation — preferred, but macOS output must be regression-checked (4 tests touch it);
  (b) a UIKit variant. Decide in M16.6 with a spike; do not edit `PDFExporter` earlier.

## 15. Chat

M14.2 produced shared SwiftUI presentation. Classification:

| Component | Class | Note |
| --- | --- | --- |
| `ChatMessageList` | SMALL | iOS 18 `ScrollPosition`, `onScrollGeometryChange`, `onScrollPhaseChange`, `defaultScrollAnchor(for:)`; fine at an iOS 18 floor. Behaviour (follow intent, Jump to Latest) needs touch validation. |
| `ChatMessageRow` | SMALL | `Color(nsColor:)` at one site; context menu duplicates visible Copy/Regenerate buttons. |
| `ChatStatusView` / `ChatErrorView` / `ChatEmptyState` | SMALL | `nsColor` ×2; `SettingsLink` ×1 → injected "open provider settings" action. |
| `ChatComposer` | ABSTRACT | Wraps `ChatTextEditorRepresentable`. |
| `AssistantMessageView`, `MarkdownDocument` | SHARED | `Clipboard` call only. |
| `ChatViewModel`, `ProjectChatViewModel`, `ChatScrollState` | SHARED | No UI imports. |
| `ChatInspectorView`, `ProjectChatView`, selection sheet | SMALL | `SettingsLink`, `FilePanels`, `Clipboard`, `.radioGroup`, `.link`, fixed sizes. |

Composer seam (what shared code sees): `text`, `isComposing` (marked-text gate), `canSend`, `focusRequest`,
`placeholder`, `onSend`, `onCancel`. Behaviour inside the AppKit class: Return sends, modified Return inserts a
newline, marked text blocks sending, auto-height 34–140 pt, accessibility label "Message" and id `chat.composer`.

iOS composer design (not implemented): a SwiftUI `TextField(axis: .vertical)` with `lineLimit(1...6)` (or
`TextEditor` if needed), a visible Send button, Return = newline on the software keyboard, and
`.onKeyPress`/`keyboardShortcut` for ⌘Return and Return on a hardware keyboard (iPad). No UIKit unless IME or
focus behaviour proves insufficient. The composer chooses its platform implementation internally so callers
are unchanged. The macOS narrow-detail crash workaround (Chat unavailable below ~640 pt, recorded as post-M14
debt) must not shape this — iOS has its own size-class presentation.

## 16. Navigation, project workspace, recording detail

Current macOS: `NavigationSplitView` two-column (sidebar `List(selection:)` of `LibraryDestination`: All
Recordings / projects / 8 recent recordings; detail switches between `AllRecordingsView`,
`ProjectWorkspaceView`, `RecordingDetailView`). Chat is an `.inspector` on `RecordingDetailView`, a tab in the
project workspace. Selection is `LibraryViewModel.selection`/`projectSelection` → `LibraryDestination`;
restoration is `@SceneStorage("library.selection")`. Hard-coded: root minimum 760×500, sidebar 220/270/380,
inspector 280/350/480, chat gate 640 pt. Settings is a separate scene with a hand-built 200 pt sidebar.

**iPad** (regular width): `NavigationSplitView` sidebar + detail (+ inspector for chat where width allows),
reusing `LibraryDestination` and `LibraryViewModel` unchanged; Settings as a sheet; hardware-keyboard shortcuts
reusing the same actions; drag/drop retained.

**iPhone** (compact): `NavigationStack` rooted at the library; `LibraryDestination` as the typed path. Root list
with sections (Recordings / Projects). Tapping pushes Recording Detail or Project Workspace. Toolbar: Import
(+), a "More" menu (usage/cost, new project, settings). Chat is a pushed screen/sheet from the recording, not a
side column.

**Recording detail (iPhone hierarchy):** header (title, duration, project, status) → compact player pinned at
the bottom → segmented control **Summary | Transcript | Sources** (existing three tabs) → toolbar menu:
Export, Generation history, Usage & Cost, Rename/Move/Delete → Chat button opening a full-height sheet. Do not
port the narrow macOS pane literally.

**Project workspace:** preserve information architecture (Overview / Recordings / Sources / Chat) as a
segmented control (iPhone) or tabs/sidebar sections (iPad); drag-to-project becomes **Move to Project** in a
row menu/swipe action everywhere.

Reusable regardless: all view models, `LibraryDestination`, drag item type, the selection semantics.

## 17. Minimum iOS version

Recommendation: **iOS / iPadOS 18.0.**

- The source already implies it: `Tab(_:value:)` (`RecordingDetailView`), `ScrollPosition`,
  `.onScrollGeometryChange`, `.onScrollPhaseChange`, `.defaultScrollAnchor(_:for:)` (`ChatMessageList`,
  `ChatViewModel`), async `AVAssetExportSession.export(to:as:)` in the splitter, and `Synchronization.Mutex` in
  five test files.
- Supporting iOS 17 would mean replacing five UI APIs with fallbacks (chat scroll following is the hard one) and the
  export call, for little reach gain on a new app.
- Everything else is iOS 17 or earlier: `@Observable`, SwiftData, `.inspector`, `NavigationSplitView`,
  `Transferable`, `#Preview`. WhisperKit declares iOS 16+, Vision/PDFKit/ImageIO are old.
- No APIs newer than iOS 18 were found (no `Observations`, `glassEffect`, `FoundationModels`, `@Entry`,
  SwiftData `#Index`/`#Unique`).
- iOS 18 matches the macOS 15 deployment target, so shared code is written against a single API generation.

## 18. Settings, UserDefaults, privacy

- **Shared preference semantics** (keep names/meanings; each platform has its own container — simulator builds
  never read the Mac's domain): `llm.*` provider/model/auth/output-length/generation settings,
  `transcription.provider/model/language`, `ai.localOnly`, `ai.whisper.*`, `ai.ollama.*`, `ai.llamaCpp.*`,
  `chatgpt.account.session` (no tokens). Secrets: none in defaults (verified).
- **macOS-only/presentational:** `llm.claude.*` (CLI path/models), `storage.desktopPreferencesRestored`,
  `libraryShowsCost` and the `library.selection` scene storage (fine to share conceptually),
  `onboarding.completed.v1`, `chatgpt.ext_agent_host_id`.
- `restorePreferences` (copies `llm./transcription./ai.` keys from legacy macOS plists) must not run on iOS.
- Settings UI: settings *models* are shared; the `Settings` scene and its sidebar are macOS presentation. iOS
  gets a `NavigationStack` list (Providers, Generation defaults, Presets, Export, Local AI, About/Privacy/
  Licenses, Diagnostics).
- Help/Privacy/Licenses: shared text resources, iOS presentation as pushed screens/sheets; Help text needs an
  iOS pass.
- **Permissions, only for features that exist:** Local Network (`NSLocalNetworkUsageDescription`) when LAN Ollama is
  offered. Nothing for files (picker grants access). Microphone only if recording is added later; Photos only if
  direct Photos import is added later. Do not add either now.

## 19. Background execution and large files

Facts from the code (none of these use `beginActivity`, background tasks or background URL sessions; there are
no `scenePhase` observers):

| Operation | Owner | On background/suspend | On termination |
| --- | --- | --- | --- |
| Cloud transcription (split + upload) | `RecordingViewModel.task`, library-held | Task frozen; foreground ephemeral session request fails or stalls; multipart body is in memory so a background session cannot be adopted | Lost. `GenerationRecord.inProgress` → `cancelled` at launch. Temp parts orphaned. |
| Local Whisper | same | Core ML inference frozen/killed; 120 s windows | Lost |
| Summary (incl. hierarchical) | `SummaryViewModel.task` | Stream/session dies | Lost; usage reconciled |
| Chat streaming | `ChatViewModel`/`ProjectChatViewModel` | Stream dies | Saved as `.interrupted` with Retry (good recovery model) |
| Retrieval indexing | `ContextRetriever` actor | Paused; in-memory, rebuilt lazily | Rebuilt |
| OCR / source processing | `SourcesViewModel.tasks` | Paused | Sources stuck `processing` → `failed` at launch |
| Model download | `LocalAISettingsViewModel` | Ephemeral session dies | Staging orphaned (no sweep) |
| Project import queue | library-owned | Paused | Not persisted |
| Export | detached worker, atomic write | Paused | Atomic write: no partial file |

Do not promise macOS-style unlimited background execution. Plan: foreground-first. M16 baseline = keep the idle
timer disabled while a long operation runs, a short `UIApplication` background-task grace period for orderly
cancel/cleanup, honest UI ("Keep AudioNotes open"), and an `interrupted` state with Retry modelled on chat.
True background transcription would need file-backed uploads on a background `URLSession`, persisted job state
and `AfterFirstUnlock` keychain access — post-M16.

Large files: `Data(contentsOf:)` for text sources (≤ 64 MB, ~2–3× memory when decoded); multipart upload ≤ 25 MB in
memory per part (acceptable); audio import copies up to 512 MB (needs free-space handling on iOS); Whisper
models up to 1.64 GB (disk plus memory); PDF page renders up to 2,200 px. Do not add speculative limits yet;
measure on device in M16.9.

## 20. Interaction patterns

- **Hover:** none in the codebase (no `onHover`/`pointerStyle`). `.help()` (30 uses) is tooltip-only on iPadOS
  with a pointer; several carry real information (e.g. why Chat is disabled) → also expose as accessibility
  hints or inline text.
- **Context-menu-only actions** (need touch alternatives — swipe actions, row "…" menus or edit mode):
  project row (Rename, Delete); sidebar recording (Rename, Delete); All Recordings row (Rename, Delete, Move to
  Project); project recording row (Move, Export, Delete); project source row (Rename, Delete); recording source
  row (Rename, Reprocess, Remove). "Reveal in Finder" has no iOS equivalent (drop it). This is the same debt
  recorded in M14.4.
- **Drag and drop:** `RecordingDragItem` (`Transferable`, exported UTI `com.audionotes.recording-reference`),
  project sidebar drops, project workspace drop, library file-URL drop. All work on iPad (UTI must be declared in
  the iOS plist); on iPhone use menus.
- **Toolbar:** Library (activity popover, view menu, new project, import), Recording detail (usage, export, chat
  toggle), Project (import activity). iPhone: consolidate to Import + More; iPad: keep close to macOS.
- **Commands / menu bar / shortcuts:** macOS presentation. Actions (new project, import, export, toggle chat) are
  reusable; iPad can attach `.keyboardShortcut` to buttons or a `Commands` set later.
- **Accessibility:** all M14.4 semantics are plain SwiftUI modifiers and carry over (labels, hints, values,
  identifiers, grouping, `AccessibilityNotification.Announcement`). Only three AppKit calls (composer
  label/identifier/placeholder) need iOS equivalents. VoiceOver behaviour on iOS (rotor, focus order, hint
  speech, announcement queueing, Dynamic Type growth) must be re-validated physically; do not assume the macOS
  design transfers.
- **Previews:** `PreviewCatalog`/`PreviewFixtures` are `#if DEBUG`, in-memory, mock-provider and
  platform-neutral; they use macOS-sized frames and one preview pulls in the AppKit composer. They can seed
  iPhone/iPad previews after the frames and composer are swapped. The DEBUG fixture app delegate is macOS-only.

## 21. Dependency matrix

| Dependency | macOS | iOS | Simulator | Notes |
| --- | --- | --- | --- | --- |
| WhisperKit / ArgmaxCore 1.1.0 | yes | declared iOS 16+ | arm64 slice builds; no ANE | Not linked in M16.1–6; platform-gate `isSupported`. |
| Sparkle 2.10.0 | yes (macOS 12+) | **no** | n/a | macOS-only release infrastructure; never linked on iOS. |
| swift-argument-parser | yes | yes | yes | Transitive only. |
| Markdown | n/a — first-party (`MarkdownDocument`, Foundation `AttributedString`) | yes | yes | No third-party Markdown dependency. |
| AI/provider SDKs | none — hand-written URLSession clients | yes | yes | |
| Tokenization / embeddings | tokenizer vendored in ArgmaxCore; no embedding provider | — | — | |
| PDF / OCR / audio | Apple frameworks (PDFKit, Vision, ImageIO, AVFoundation) | yes | yes (results unverified) | |
| CryptoKit / Security / Network / SQLite3 | system | yes | yes | |

No new dependency is needed for M16.

## 22. Tests

Counts from the audit (431 tests): **A platform-neutral ≈ 321**, **B shared logic touching Apple frameworks ≈ 77**
(AVFoundation, PDFKit, ImageIO, Vision, SQLite3, one `getrusage`), **C macOS-only ≈ 33** (Claude CLI 21,
AppKit chat-editor/hosting 6, `PDFExporter` ~6), **D needing iOS-equivalent tests: none exist yet**
(~10 would be replaced, plus new tests for iOS adapters).

Needs care on the Simulator: `V1MigrationFixtureTests` reads the SQLite fixture through `#filePath` (works on
the Simulator, not a device → make it a bundle resource); `MultiSourceTestSupport` fixtures use
`NSFont/NSColor` via AppKit (swap to CoreText/CGColor); `ChatPresentationTests`/`PerformanceBaselineTests` call
default `LibraryStorage()` read-only; tests spawn `/bin/sh` (Claude CLI only); about 22 `UserDefaults(suiteName:)`
sites leave plists; a few tests rely on DEBUG-only fixtures, so the iOS test target must build Debug. No test
uses the real Keychain, real sockets or `UserDefaults.standard`.

Strategy (do not duplicate): second test target `AudioNotesTests-iOS` that **shares the existing synchronized
`AudioNotesTests` folder**, with a per-target exception set excluding class-C files, `#if os(macOS)` around the
split files' macOS parts, `TEST_HOST = $(BUILT_PRODUCTS_DIR)/AudioNotes.app/AudioNotes` (flat iOS bundle),
`@executable_path/Frameworks` rpaths. The XCTest-host guard in `LibraryStartup`/`WelcomeView` already exists.
Rejected: a SwiftPM test target (models cannot leave the app module while v1 migration guarantees depend on
them) and duplicate test folders. Do not restructure test targets before M16.2.

## 23. Feature matrix

| Feature | macOS | iPhone | iPad | Basis |
| --- | --- | --- | --- | --- |
| Library | yes | planned (M16.2) | planned | shared view models |
| Projects | yes | planned (M16.5) | planned | |
| Audio import | yes | planned (M16.3) | planned | `.fileImporter`; copy-in-scope already correct |
| PDF import | yes | planned (M16.5) | planned | PDFKit extraction portable; thumbnail path to fix |
| Image import | yes | planned (M16.5) | planned | Vision/ImageIO portable |
| Transcription (cloud, OpenAI) | yes | planned (M16.4), foreground | planned | background limits |
| Local Whisper | yes (Apple Silicon) | not initial; investigate | not initial; investigate | §13 |
| Summary | yes | planned (M16.4) | planned | OpenAI only |
| Recording Chat | yes | planned (M16.4) | planned | iOS composer |
| Project Chat | yes | planned (M16.5) | planned | |
| Citations / source navigation | yes | planned (M16.5) | planned | shared semantics, UIKit PDF view |
| OpenAI (API key) | yes | yes | yes | |
| Anthropic | Claude CLI only | **unavailable** | **unavailable** | no API client exists |
| Gemini | not implemented | unavailable | unavailable | |
| Ollama / llama.cpp | yes | LAN server only (M16.7) | LAN only | local-network permission; no on-device Ollama |
| Account sign-in (ChatGPT/Google) | yes | not in M16 | not in M16 | loopback flows; unverified redirects |
| Markdown export | yes | share sheet (M16.6) | share sheet | |
| PDF export | yes | share sheet (M16.6) | share sheet | `PDFExporter` port |
| Usage & cost | yes | planned | planned | shared |
| Presets / settings | yes | planned (M16.2/4) | planned | iOS settings presentation |
| Drag and drop | yes | no (menus) | yes (M16.8) | |
| Keyboard shortcuts | yes | n/a | yes (M16.8) | |
| Sparkle updates | yes | N/A | N/A | macOS-only |
| iCloud / sync | no | no | no | future, out of M16 |

## 24. Source-sharing matrix

| Subsystem / file group | Share directly | Adapt | Platform-specific |
| --- | --- | --- | --- |
| `Models/` (11 `@Model`) | all | — | — |
| `Services/Release/{LibrarySchema,LibraryStartup,MetadataBackup,ManagedFileDeletion}` | all | `LibraryStorage` root/CloudKit decision | — |
| `AppStorageLocations` | — | — | macOS (gate) |
| `Services/Projects`, `ProjectChat`, `Retrieval`, `Usage`, `Logging` (≈ 18 files) | all | — | — |
| `Services/Sources` (12) | most | `SourceProcessingService` PDF thumbnail | — |
| `Services/LLM` (35) excluding CLI | ≈ 31 | resolver/config platform filter, LocalAI copy | `ClaudeCLI/*` (4) |
| `Services/Transcription` (16) | ≈ 13 | splitter/upload for background, Whisper `isSupported` | — |
| `Services/ChatGPT` (10) | tokens/clients/JWKS | `ChatGPTAuthService` browser seam | `ChatGPTLoopbackListener` use |
| `Services/Credentials` | yes | accessibility decision, copy | — |
| `Services/Export` (5) | 4 | `PDFExporter` | — |
| `Services/AudioImport/Playback` | import | playback needs `AVAudioSession` | — |
| `Services/Release/UpdateService`, `ReleaseIdentity` update config | — | — | macOS (Sparkle) |
| `Utilities/` (15) | most | `MarkdownDocument` shared | `AppStorageLocations`, DEBUG AppKit |
| `Features/*ViewModel`, state, progress models | all | — | — |
| Shared SwiftUI (chat rows, Markdown view, thumbnails, progress, transcripts, summary view) | ≈ 60 % | colors, `SettingsLink`, `.link`, `.help`, fixed sizes | — |
| `Features/Library`, `RecordingDetail`, `Projects` shells | models | — | iOS shells (new) |
| `Features/Settings` | models | — | iOS settings screens; macOS Claude CLI views |
| `Platform/macOS/AppKit` (6) | — | — | macOS; iOS counterparts in `AudioNotesiOS/` |
| `App/AudioNotesApp.swift` | `AppServices` | — | macOS scenes/commands; iOS `@main` |
| Tests (80 files) | ≈ 70 files | split files | ≈ 6 macOS-only + ~10 iOS new |

## 25. Risk matrix (technical implementation risk)

**HIGH**

1. **Background execution / suspension.** All long operations are in-memory tasks over foreground ephemeral
   sessions; multipart upload is in-memory `Data`; no resumable job state; temp/staging directories have no
   launch sweep. Directly affects the core value (long-recording transcription).
2. **Provider coverage and auth.** Anthropic is CLI-only, Gemini has no provider, and both OAuth flows are
   loopback/system-browser. iOS cloud AI is OpenAI-only; account sign-in is not portable as written.
3. **Local Whisper on iOS.** Unmeasured memory, 1.5 GB models, foreground-only downloads, macOS-verified
   tokenizer override, arm64-simulator `isSupported` trap.

**MEDIUM**

4. **Project file / CI.** New targets under Xcode 27 rewrite `objectVersion`; shared synchronized groups across
   targets and exception sets must work in Xcode 16 CI; scheme isolation.
5. **`PDFExporter` AppKit port** — risk of changing macOS PDF output (4 tests).
6. **Navigation redesign** — `RecordingDetailView`/`LibraryView`/`ProjectWorkspaceView`/Settings are the largest,
   most macOS-shaped views (≈ 3 k lines).
7. **iOS chat composer and scroll behaviour** — IME/marked text, keyboard avoidance, follow-intent on touch.
8. **Ollama LAN** — Local Network permission, ATS for DNS hosts, `localhost` semantics, Local Only policy.
9. **Audio session and interruptions** — none implemented.
10. **Keychain accessibility while locked** — blocks background use; change needs migration.
11. **File-provider imports** — scope lifetime, iCloud download, large copies; disk space.
12. **Test portability** — hosted-test path, fixtures using `NSFont`, `#filePath` fixture.

**LOW**

13. SwiftData models/migration compile (no macOS API; empty stage list) — *low likelihood, high consequence;
    verify first.*
14. Provider clients, usage/cost, pricing, presets, retrieval, citations, Markdown, logging.
15. PDF text extraction and OCR (Vision/PDFKit/ImageIO are available).
16. Accessibility modifiers and previews (shared SwiftUI).
17. UserDefaults semantics (separate containers per platform).

## 26. Proposed M16 sub-milestones

Adjusted from the expected shape: import moves ahead of transcription (a vertical slice needs it), export
gets its own step because of the PDF port, and a compile-only spike opens M16.1 to replace assumptions with
evidence.

- **M16.0 — Audit** (this document).
- **M16.1 — Shared/platform boundary preparation, zero behaviour change on macOS.** First a throwaway
  compile-only iOS spike (not committed) to list real compile errors for Models/Services. Then: gate
  `AppStorageLocations` legacy code; platform filter for provider availability and Claude CLI exclusion;
  `UpdateChecking` seam so shared views do not name Sparkle; `OpenProviderSettings` action replacing `SettingsLink`;
  neutral colors for the three `nsColor` sites; small modifiers for `.link`/`.radioGroup`; CGContext PDF-page
  thumbnail; protocol seams where shared code calls the platform (clipboard, external URL, file import/export
  presentation, audio session). Full macOS tests/Release must stay green; no schema/target/signing changes.
- [x] **M16.2 — iOS target + library/navigation shell.** Target, scheme, plist, assets, shared membership,
  `AudioNotesiOSApp` entry, adaptive iPhone NavigationStack / iPad NavigationSplitView, native Settings sheet, zero macOS regressions (see `docs/IOS_TARGET_AND_NAVIGATION.md`).
- **M16.3 — Audio import + recording detail.** `.fileImporter`, copy-in-scope import, playback with
  `AVAudioSession`, header/player/tabs, transcript view.
- **M16.4 — Cloud AI + chats (OpenAI).** Foreground transcription with progress/cancel/interrupted states,
  summaries, Recording Chat with the iOS composer, usage/cost.
- **M16.5 — Projects, sources, citations.** Project workspace, PDF/image/text import, iOS `PDFView` wrapper,
  OCR, Project Chat, touch alternatives to context-menu-only actions.
- **M16.6 — Export and sharing.** Markdown/PDF generation shared, `ShareLink`/`.fileExporter`, `PDFExporter`
  port decision with macOS regression checks, diagnostics sharing.
- **M16.7 — Local capabilities.** LAN Ollama/llama.cpp settings, permission and copy; Whisper feasibility spike
  with memory/RAM measurement (integration only if the spike supports it).
- **M16.8 — iPad polish.** Split layout, inspector, keyboard shortcuts, drag/drop, pointer, multitasking sizes.
- **M16.9 — iOS QA.** Test target + shared tests, accessibility/Dynamic Type/VoiceOver on device, background and
  low-memory behaviour, privacy strings, performance, documentation. App Store work remains out of scope
  (M15 is separate and untouched).

## 27. Non-goals and constraints carried forward

No Catalyst; the macOS app stays native and unchanged (Developer ID/Sparkle configuration untouched); no
CloudKit/iCloud/sync; no AudioNotesCore package or module move until evidence supports it; no schema or
migration change; no paid-program prerequisite; no App Store/TestFlight/signing/provisioning work; no
permissions for features that do not exist; no new providers.

## 28. Evidence limits

Static reading only. Not verified: that any file compiles for iOS; Simulator behaviour of Vision/HEIC/Core ML;
device behaviour of local network, Keychain-while-locked and background; provider redirect rules for ChatGPT
and Google on iOS; WhisperKit memory; shared synchronized groups across two targets in Xcode 16 and 27.
Counts and percentages are heuristic.
