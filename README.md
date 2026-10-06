# Soniquill

A native AI-assisted audio and document workspace for macOS, iPhone, and iPad, built with Swift 6, SwiftUI, SwiftData, and AVFoundation. Import recordings and documents, transcribe audio, generate summaries, chat with recording or project evidence, and export results. Provider selection, local execution, and cloud credentials stay separate from the UI.

Open `AudioNotes.xcodeproj`. The retained **AudioNotes** scheme builds macOS; **AudioNotesiOS** builds iPhone/iPad. Both products are `Soniquill.app`, display **Soniquill**, and use the final production bundle ID `cz.kudladev.soniquill`. Apple Developer setup and App Store Connect are established; version 1.0.0 build 1 was archived/uploaded and TestFlight is active with initial testers. Physical iPhone installation is confirmed; individual feature acceptance requires separate evidence. Preserve the working signing configuration. Use My Mac or a Simulator for local validation without provisioning updates.

Soniquill was previously developed under the name AudioNotes. Internal targets/modules and the `AudioNotes` managed-data directory remain for compatibility. macOS startup reuses existing desktop/legacy sandbox libraries and restores known non-secret preferences without replacing current choices. Existing Soniquill TestFlight installations are the compatibility baseline for data, preferences, imported files and credentials. Do not automatically migrate the old `cz.stepankudlacek.audionotes.ios` development sandbox; that transfer is not an M16.7.0 blocker. See [identity and compatibility details](docs/SONIQUILL_RENAME.md), including Google OAuth follow-up and production Keychain caveats.

## Structure

- `AudioNotes/App`: app lifecycle and composition.
- `AudioNotes/Models`: shared SwiftData models, frozen v1 schema and migration plan.
- `AudioNotes/Services`: storage, importing, retrieval, providers, authentication, exports, and usage.
- `AudioNotes/Features`: feature-based MVVM and shared native SwiftUI UI.
- `AudioNotes/Platform`: iOS UI and small native platform adapters.
- `AudioNotes/Utilities`: formatting and isolated DEBUG fixtures.
- `AudioNotesTests`: offline service, persistence, provider, and compatibility tests.

Production startup opens `default.store` in the resolved Application Support directory. Managed audio, documents, and models remain beneath its `AudioNotes` folder; original imports are copied locally. Test helpers may explicitly use `AudioNotes/Library.store` or temporary roots. Secrets remain in Keychain, never in the database or preferences.

## Validation

```sh
xcodebuild -project AudioNotes.xcodeproj -scheme AudioNotes \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test

xcodebuild -project AudioNotes.xcodeproj -scheme AudioNotesiOS \
  -configuration Debug -destination 'platform=iOS Simulator,id=<simulator-uuid>' \
  CODE_SIGNING_ALLOWED=NO -collect-test-diagnostics never test
```

macOS tests use a local ad-hoc host signature; Simulator builds need no production registration. Do not pass `-allowProvisioningUpdates`. Native interaction, live-provider and signed credential-continuity acceptance are tracked separately from offline tests; Apple signing/installation and TestFlight distribution are already established.

See the [roadmap](docs/ROADMAP.md), [project architecture](docs/PROJECTS.md), [retrieval](docs/PROJECT_RETRIEVAL.md), [project chat](docs/PROJECT_CHAT.md), [iOS platform boundaries](docs/IOS_PLATFORM_BOUNDARIES.md), and [Local AI architecture](docs/LOCAL_AI.md).
