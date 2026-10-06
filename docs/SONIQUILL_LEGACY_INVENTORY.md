# Remaining legacy-name inventory

Rename implementation case-insensitive text audit (recorded before the release-state correction below; line locations/counts are historical and may shift). Searches AudioNotes/AudioNotesiOS/audionotes/audio-notes/audio_notes/Audio Notes/AUDIONOTES/AUDIO_NOTES. Binaries and ignored build outputs are excluded. The three rename/audit documents are excluded from counts because they explicitly describe legacy compatibility; their references are intentional. Table counts are matching lines, not individual words.

## Documentation of internal paths/commands, stable URLs, and milestone history

| File | Matching lines | Locations |
| --- | ---: | --- |
| `README.md` | 12 | 5, 7, 11, 12, 13, 14, 15, 16, 17, 19, 24, 28 |
| `docs/ACCESSIBILITY_AND_QA.md` | 9 | 15, 157, 208, 209, 210, 211, 212, 224, 231 |
| `docs/CHAT_RENDERING.md` | 17 | 27, 28, 29, 30, 31, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 56 |
| `docs/GOOGLE_OAUTH.md` | 1 | 3 |
| `docs/IOS_ACCOUNT_AUTH.md` | 10 | 3, 13, 16, 24, 28, 36, 38, 58, 69, 75 |
| `docs/IOS_AUDIO_AND_RECORDING.md` | 3 | 20, 59, 71 |
| `docs/IOS_CLOUD_AI.md` | 13 | 3, 13, 65, 66, 67, 68, 81, 90, 135, 136, 146, 152, 155 |
| `docs/IOS_LOCAL_AI.md` | 1 | 135 |
| `docs/IOS_PLATFORM_BOUNDARIES.md` | 11 | 9, 12, 14, 77, 84, 86, 88, 90, 100, 102, 104 |
| `docs/IOS_PORT_AUDIT.md` | 29 | 3, 48, 49, 53, 54, 55, 126, 169, 170, 171, 175, 176, 179, 181, 182, 218, 219, 220, 221, 222, 486, 505, 550, 551, 552, 607, 608, 661, 680 |
| `docs/IOS_PROJECT_SOURCES_AND_CHAT.md` | 1 | 203 |
| `docs/IOS_TARGET_AND_NAVIGATION.md` | 21 | 3, 7, 11, 34, 35, 41, 42, 47, 48, 55, 59, 137, 138, 139, 143, 153, 158, 163, 171, 175, 193 |
| `docs/IOS_UX_AND_PROJECTS.md` | 7 | 47, 80, 81, 82, 213, 214, 215 |
| `docs/LOCAL_AI.md` | 8 | 26, 28, 46, 47, 48, 123, 157, 169 |
| `docs/M13_IMPLEMENTATION.md` | 2 | 3, 5 |
| `docs/MULTI_SOURCE.md` | 5 | 47, 227, 231, 246, 247 |
| `docs/OPENAI_TRANSCRIPTION.md` | 2 | 30, 70 |
| `docs/PROJECTS.md` | 20 | 215, 249, 250, 251, 252, 253, 254, 255, 256, 257, 258, 259, 260, 261, 267, 268, 269, 270, 271, 272 |
| `docs/PROJECT_CHAT.md` | 21 | 67, 85, 86, 87, 88, 89, 90, 91, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107 |
| `docs/PROJECT_RETRIEVAL.md` | 12 | 228, 229, 230, 231, 232, 233, 234, 235, 236, 241, 242, 243 |
| `docs/RELEASE_AUDIT.md` | 6 | 3, 9, 15, 18, 20, 21 |
| `docs/RELEASING.md` | 6 | 9, 11, 19, 23, 25, 36 |
| `docs/ROADMAP.md` | 1 | 435 |
| `docs/SWIFTUI_MIGRATION.md` | 5 | 9, 12, 166, 211, 320 |
| `docs/TRANSCRIPTION.md` | 1 | 5 |
| `docs/UI_PERFORMANCE.md` | 35 | 25, 26, 28, 30, 32, 34, 37, 38, 65, 72, 286, 287, 288, 289, 290, 291, 292, 293, 294, 295, 296, 297, 298, 304, 305, 306, 307, 308, 309, 310, 311, 312, 313, 314, 315 |
| `docs/USAGE_COST.md` | 10 | 10, 11, 12, 13, 14, 15, 16, 23, 35, 178 |
| `docs/UX_LAYOUT_AND_PROGRESS.md` | 7 | 183, 184, 185, 187, 265, 268, 279 |

## Historical reports, capture tooling and release notes

| File | Matching lines | Locations |
| --- | ---: | --- |
| `docs/release/1.0.0.md` | 2 | 1, 12 |
| `docs/review/M16.5.1/README.md` | 1 | 37 |
| `docs/review/M16.5.1/capture.py` | 3 | 2, 8, 27 |
| `docs/review/M16.6/README.md` | 1 | 39 |
| `docs/review/M16.6/capture.py` | 2 | 9, 32 |
| `docs/review/M16.7/capture.py` | 1 | 8 |

## Internal logging/signpost/dispatch identities

| File | Matching lines | Locations |
| --- | ---: | --- |
| `AudioNotes/Services/ChatGPT/ChatGPTLoopbackListener.swift` | 1 | 64 |
| `AudioNotes/Services/Logging/PerformanceSignposts.swift` | 1 | 5 |
| `AudioNotes/Services/Logging/ReleaseLog.swift` | 3 | 5, 6, 7 |

## Internal project/target/scheme/test/module identifiers

| File | Matching lines | Locations |
| --- | ---: | --- |
| `AudioNotes.xcodeproj/project.pbxproj` | 80 | 23, 30, 35, 40, 45, 50, 52, 55, 61, 63, 145, 150, 153, 155, 158, 161, 162, 164, 202, 203, 214, 215, 230, 232, 244, 246, 247, 248, 251, 253, 262, 264, 272, 274, 286, 288, 289, 290, 293, 295, 304, 306, 334, 352, 353, 354, 355, 411, 416, 422, 434, 441, 453, 460, 471, 482, 495, 505, 518, 528, 592, 648, 666, 681, 699, 717, 720, 721, 725, 728, 729, 733, 736, 737, 741, 744, 745, 749, 752, 753 |
| `AudioNotes.xcodeproj/xcshareddata/xcschemes/AudioNotes.xcscheme` | 9 | 19, 20, 36, 37, 38, 59, 60, 76, 77 |
| `AudioNotes.xcodeproj/xcshareddata/xcschemes/AudioNotesiOS.xcscheme` | 7 | 19, 20, 32, 52, 53, 69, 70 |

## Internal temporary file/multipart protocol prefixes

| File | Matching lines | Locations |
| --- | ---: | --- |
| `AudioNotes/Services/LLM/ClaudeCLI/ClaudeCLIRunner.swift` | 1 | 59 |
| `AudioNotes/Services/Transcription/OpenAI/OpenAIAudioSplitter.swift` | 1 | 88 |
| `AudioNotes/Services/Transcription/OpenAI/OpenAIAudioUpload.swift` | 1 | 40 |

## Internal types, comments, schema labels and exported drag UTI

| File | Matching lines | Locations |
| --- | ---: | --- |
| `.github/workflows/publish-appcast.yml` | 1 | 19 |
| `.github/workflows/validate.yml` | 3 | 1, 20, 22 |
| `.gitignore` | 1 | 9 |
| `AudioNotes/App/AudioNotesApp.swift` | 1 | 6 |
| `AudioNotes/Features/Library/RecordingDragItem.swift` | 2 | 10, 15 |
| `AudioNotes/Features/Shared/UserFacingError.swift` | 1 | 4 |
| `AudioNotes/Platform/iOS/AudioNotesiOSApp.swift` | 1 | 6 |
| `AudioNotes/Services/LLM/OnDevice/SystemLocalLLMRuntime.swift` | 1 | 91 |

## Keychain lookup identity

| File | Matching lines | Locations |
| --- | ---: | --- |
| `AudioNotes/Services/ChatGPT/ChatGPTCredentialStore.swift` | 1 | 14 |
| `AudioNotes/Services/Credentials/KeychainService.swift` | 1 | 51 |
| `AudioNotes/Services/LLM/GoogleGeminiOAuthService.swift` | 1 | 25 |

## Legacy storage/database/preferences and visible compatibility explanations

| File | Matching lines | Locations |
| --- | ---: | --- |
| `AudioNotes/Features/Release/LibraryRecoveryView.swift` | 1 | 9 |
| `AudioNotes/Platform/macOS/MacOSLegacyStorage.swift` | 3 | 7, 8, 25 |
| `AudioNotes/Resources/Help.txt` | 3 | 20, 22, 31 |
| `AudioNotes/Services/LibraryStorage.swift` | 1 | 7 |
| `AudioNotes/Services/Release/LibraryStartup.swift` | 3 | 12, 31, 32 |
| `AudioNotes/Utilities/AppStorageLocations.swift` | 2 | 37, 60 |

## Retained module, OAuth legacy bundle binding, update variable names and drag UTI

| File | Matching lines | Locations |
| --- | ---: | --- |
| `Configuration/App.xcconfig` | 3 | 8, 9, 13 |
| `Configuration/AudioNotes-Info.plist` | 3 | 27, 29, 42 |
| `Configuration/iOS-Info.plist` | 1 | 6 |
| `Configuration/iOS.xcconfig` | 1 | 38 |

## Stable DEBUG fixture roots/suites

| File | Matching lines | Locations |
| --- | ---: | --- |
| `AudioNotes/App/AppServices.swift` | 2 | 25, 26 |
| `AudioNotes/Utilities/Development/OperationSettingsFixtures.swift` | 2 | 12, 13 |
| `AudioNotes/Utilities/Development/PreviewFixtures.swift` | 1 | 11 |

## Stable release asset names/URLs, archived build paths, validator fixtures and internal schemes

| File | Matching lines | Locations |
| --- | ---: | --- |
| `scripts/release/release.sh` | 15 | 37, 43, 48, 49, 50, 52, 75, 78, 79, 80, 82, 87, 100, 127, 144 |
| `scripts/release/test_appcast.py` | 12 | 17, 38, 48, 51, 52, 53, 55, 59, 61, 65, 71, 78 |
| `scripts/release/validate_appcast.py` | 2 | 25, 80 |

## Stable test imports, fixtures, protocol headers and compatibility expectations

| File | Matching lines | Locations |
| --- | ---: | --- |
| `AudioNotesTests/SoniquillIdentityTests.swift` | 8 | 4, 9, 11, 23, 28, 43, 53, 90 |
| `AudioNotesTests/AIPresetTests.swift` | 1 | 4 |
| `AudioNotesTests/AudioImportServiceTests.swift` | 1 | 3 |
| `AudioNotesTests/AudioPlaybackServiceTests.swift` | 1 | 3 |
| `AudioNotesTests/AudioRecordingJourneyTests.swift` | 1 | 4 |
| `AudioNotesTests/AudioTimeTests.swift` | 1 | 3 |
| `AudioNotesTests/ChatContextBuilderTests.swift` | 1 | 3 |
| `AudioNotesTests/ChatGPTAuthTests.swift` | 1 | 3 |
| `AudioNotesTests/ChatPresentationTests.swift` | 1 | 5 |
| `AudioNotesTests/ChatRenderingTests.swift` | 1 | 4 |
| `AudioNotesTests/ChatStreamingParserTests.swift` | 1 | 3 |
| `AudioNotesTests/ChatUXTests.swift` | 1 | 4 |
| `AudioNotesTests/ChatViewModelTests.swift` | 1 | 5 |
| `AudioNotesTests/ClaudeCLIModelsTests.swift` | 1 | 4 |
| `AudioNotesTests/ClaudeCLITests.swift` | 3 | 4, 260, 296 |
| `AudioNotesTests/ExportTests.swift` | 1 | 4 |
| `AudioNotesTests/FinalQATests.swift` | 1 | 4 |
| `AudioNotesTests/GeminiTranscriptionTests.swift` | 1 | 3 |
| `AudioNotesTests/GenerationProviderSelectionTests.swift` | 1 | 4 |
| `AudioNotesTests/GoogleGeminiOAuthTests.swift` | 3 | 3, 7, 81 |
| `AudioNotesTests/HierarchicalSummaryGeneratorTests.swift` | 1 | 3 |
| `AudioNotesTests/HybridRetrievalTests.swift` | 1 | 3 |
| `AudioNotesTests/IOSAudioRecordingTests.swift` | 1 | 6 |
| `AudioNotesTests/IOSCloudAITests.swift` | 1 | 5 |
| `AudioNotesTests/IOSLocalAITests.swift` | 1 | 4 |
| `AudioNotesTests/IOSUXAndProjectsTests.swift` | 1 | 4 |
| `AudioNotesTests/LLMModelCapabilitiesTests.swift` | 1 | 3 |
| `AudioNotesTests/LegacyM11Schema.swift` | 1 | 3 |
| `AudioNotesTests/LegacyM8Schema.swift` | 1 | 3 |
| `AudioNotesTests/LibraryStorageTests.swift` | 1 | 4 |
| `AudioNotesTests/LibraryViewModelTests.swift` | 1 | 4 |
| `AudioNotesTests/LlamaCppTests.swift` | 1 | 3 |
| `AudioNotesTests/LocalAILiveTests.swift` | 12 | 4, 6, 10, 12, 13, 23, 25, 26, 39, 41, 47, 63 |
| `AudioNotesTests/LocalAITests.swift` | 1 | 5 |
| `AudioNotesTests/M11StabilityTests.swift` | 1 | 5 |
| `AudioNotesTests/M166LargeProjectMeasurementTests.swift` | 1 | 4 |
| `AudioNotesTests/MockCredentialStore.swift` | 1 | 2 |
| `AudioNotesTests/MockLLMProviderTests.swift` | 1 | 3 |
| `AudioNotesTests/MockTranscriptionProviderTests.swift` | 1 | 3 |
| `AudioNotesTests/MultiSourceTestSupport.swift` | 1 | 8 |
| `AudioNotesTests/OllamaProviderIntegrationTests.swift` | 1 | 4 |
| `AudioNotesTests/OllamaTests.swift` | 1 | 3 |
| `AudioNotesTests/OpenAIAudioSplitPlanTests.swift` | 1 | 4 |
| `AudioNotesTests/OpenAIAudioUploadTests.swift` | 1 | 3 |
| `AudioNotesTests/OpenAIHTTPErrorTests.swift` | 1 | 3 |
| `AudioNotesTests/OpenAILLMProviderTests.swift` | 1 | 3 |
| `AudioNotesTests/OpenAINetworkStub.swift` | 2 | 86, 100 |
| `AudioNotesTests/OpenAIResponseTests.swift` | 1 | 3 |
| `AudioNotesTests/OpenAISummaryDTOTests.swift` | 1 | 3 |
| `AudioNotesTests/OpenAITranscriptionProviderTests.swift` | 2 | 4, 140 |
| `AudioNotesTests/OperationProgressTests.swift` | 1 | 4 |
| `AudioNotesTests/PerformanceBaselineTests.swift` | 1 | 5 |
| `AudioNotesTests/PlatformBoundaryTests.swift` | 1 | 4 |
| `AudioNotesTests/PresentationBoundaryTests.swift` | 1 | 4 |
| `AudioNotesTests/ProjectChatPerformanceTests.swift` | 2 | 4, 38 |
| `AudioNotesTests/ProjectChatTests.swift` | 1 | 5 |
| `AudioNotesTests/ProjectFoundationTests.swift` | 1 | 4 |
| `AudioNotesTests/ProjectImportTests.swift` | 1 | 4 |
| `AudioNotesTests/ProjectMigrationTests.swift` | 1 | 4 |
| `AudioNotesTests/ProjectPerformanceTests.swift` | 1 | 4 |
| `AudioNotesTests/ProjectRetrievalTests.swift` | 1 | 4 |
| `AudioNotesTests/ProviderConfigurationTests.swift` | 3 | 3, 8, 31 |
| `AudioNotesTests/ProviderSettingsTests.swift` | 1 | 4 |
| `AudioNotesTests/RecordingViewModelTests.swift` | 1 | 4 |
| `AudioNotesTests/ReleaseEngineeringTests.swift` | 7 | 5, 11, 12, 91, 94, 95, 100 |
| `AudioNotesTests/RetrievalEngineTests.swift` | 1 | 4 |
| `AudioNotesTests/RetrievalPerformanceTests.swift` | 1 | 4 |
| `AudioNotesTests/SmallContextSummaryTests.swift` | 1 | 3 |
| `AudioNotesTests/SourceContextTests.swift` | 1 | 4 |
| `AudioNotesTests/SourceImportTests.swift` | 1 | 4 |
| `AudioNotesTests/SourceMultimodalTests.swift` | 1 | 4 |
| `AudioNotesTests/SourcePersistenceTests.swift` | 1 | 4 |
| `AudioNotesTests/SourceProcessingTests.swift` | 1 | 4 |
| `AudioNotesTests/SourceWorkflowTests.swift` | 1 | 5 |
| `AudioNotesTests/SummaryLayoutTests.swift` | 1 | 5 |
| `AudioNotesTests/SummaryPresetTests.swift` | 1 | 3 |
| `AudioNotesTests/SummaryPromptBuilderTests.swift` | 1 | 3 |
| `AudioNotesTests/SummaryRepositoryTests.swift` | 1 | 4 |
| `AudioNotesTests/SummaryViewModelTests.swift` | 1 | 4 |
| `AudioNotesTests/TestWorkspace.swift` | 1 | 4 |
| `AudioNotesTests/TranscriptChunkingTests.swift` | 1 | 3 |
| `AudioNotesTests/TranscriptReferenceResolverTests.swift` | 1 | 3 |
| `AudioNotesTests/TranscriptRepositoryTests.swift` | 1 | 4 |
| `AudioNotesTests/TranscriptionProgressModelTests.swift` | 1 | 3 |
| `AudioNotesTests/TranscriptionStateTests.swift` | 1 | 2 |
| `AudioNotesTests/TranscriptionTestSupport.swift` | 1 | 3 |
| `AudioNotesTests/UsageCostTests.swift` | 1 | 4 |
| `AudioNotesTests/V1MigrationFixtureTests.swift` | 4 | 4, 12, 43, 73 |
| `AudioNotesTests/WhisperModelDownloadTests.swift` | 1 | 3 |

No unexplained current user-facing product branding remains. Historical screenshots/reports are not rebranded. Current Help/recovery text names the actual AudioNotes compatibility folders; diagnostic subsystem names, generated-schema type names and source-file/module names are internal. Existing capture scripts under earlier milestone folders target historical bundle IDs and should not be used for the new app; M16.7.0 uses its own new-ID script. No generated/build artifact was edited.

## Current rename capture tooling

`docs/review/M16.7.0/capture.py` retains only the existing isolated `AudioNotes-M11-Fixtures` temporary-root name. `docs/review/M16.7.0/README.md` explicitly explains old-name historical screenshots. Both are current compatibility references, not historical product branding.

## Production compatibility decision (2026-10-06)

The final product is Soniquill, bundle ID `cz.kudladev.soniquill`. Apple Developer
setup, App Store Connect creation, archive/upload of 1.0.0 build 1, TestFlight
configuration and initial tester installation/testing are confirmed by the owner.
Physical iPhone installation is confirmed; unrecorded feature tests remain open.

Preserve legacy implementation identifiers: module/targets/schemes/test imports and
source paths `AudioNotes`/`AudioNotesiOS`, managed `AudioNotes` storage folders,
provider and ChatGPT Keychain services `cz.kudladev.AudioNotes.provider-credentials`
and `cz.kudladev.AudioNotes.chatgpt-credentials`, preference/provider IDs, exported
`com.audionotes.recording-reference` UTI, diagnostic/temporary prefixes, and existing
repository/feed/asset URLs. These are compatibility identifiers, not product branding.

`cz.stepankudlacek.audionotes.ios` denotes the previous development installation;
do not migrate its sandbox automatically. The Google iOS OAuth declaration no longer uses that old bundle: the owner confirmed
the Console registration change and the local declaration now matches
`cz.kudladev.soniquill`. Client/project IDs and reversed callback scheme are retained.
Configuration alignment is complete; live OAuth verification remains open. See
[the rename report](SONIQUILL_RENAME.md#authentication-and-url-schemes).
The current Soniquill/TestFlight installation is the baseline for future storage,
preferences, Keychain/OAuth and imported-file continuity. Signing and v1 schema/
migration remain unchanged during finalization.
