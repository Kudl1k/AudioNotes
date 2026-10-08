# M16.7.0 — Soniquill product identity

AudioNotes → **Soniquill** on macOS, iPhone and iPad. The final, production-established
bundle ID is **`cz.kudladev.soniquill`** on both platforms. Preserve it without
platform suffixes. The distributed TestFlight installation is the compatibility baseline.

## Established Apple release state

Release-state correction supplied by the owner on 2026-10-06: Soniquill has been
signed and installed on a physical iPhone, configured under Apple Developer,
created in App Store Connect, archived, uploaded successfully, distributed through
TestFlight, and installed/tested by initial testers. The App Store Connect product
is **Soniquill**, bundle ID **`cz.kudladev.soniquill`**, initial uploaded version
**1.0.0**, build **1**. TestFlight is active/configured and initial testers exist.
Transient processing/review statuses are not architectural state.

Physical installation is confirmed. This report has no evidence identifying the
individual features tested by those testers; feature-specific device acceptance,
including live OAuth, Keychain refresh/relaunch, audio and VoiceOver, remains open.
This task performs no upload and makes no App Store Connect or signing changes.

## Baseline and scope

Branch `m14-swiftui-first`; starting HEAD `3ef3d665bf9b7f0c0f86fa3701745686313d8691`;
working tree clean. M16.6 is committed at `d27ffaf`. The user explicitly authorized
using current HEAD, preserving its existing Local AI implementation and project
`objectVersion = 110` (instead of the supplied brief's M16.6/77 baseline).
No new Local AI work is part of this rename. M16.7 Local AI may continue after
M16.7.0 final validation and commit.

Previous effective macOS identity: product/module `AudioNotes`, bundle ID
`cz.stepankudlacek.audionotes`, effective team unchanged. Previous iOS identity:
product/module `AudioNotes`, bundle ID `cz.stepankudlacek.audionotes.ios`, target
`AudioNotesiOS`. Shared schemes are `AudioNotes` and `AudioNotesiOS`.
M16.6's recorded validation: macOS 456 passed / 6 expected skips (462 total),
iPhone and iPad 50 passed each; macOS Release and iOS Debug/Release Simulator
builds passed. These are historical baseline results, not reruns of M16.6.

## Visible and internal identity

Both apps build as `Soniquill.app`, executable `Soniquill`, with `PRODUCT_NAME`,
`CFBundleDisplayName`, and `CFBundleName` set to **Soniquill**. Both use the final production
bundle ID `cz.kudladev.soniquill`. Product references, scheme buildable names and test-host paths
follow the renamed product. `PRODUCT_MODULE_NAME = AudioNotes` is pinned explicitly
so model runtime names and `@testable import AudioNotes` remain compatible.

Updated visible branding covers library/window/navigation titles, chat assistant
labels/status, Settings/About/Help/onboarding, provider/network/privacy descriptions,
Keychain denial text, sign-in browser completion pages, AI assistant identity,
PDF generated-by footer, diagnostics filename/identity, license heading, mock content,
and development-window title. User project names and normal export filenames are unchanged.
PDF and Markdown continue to use shared ExportContent; no schema/export redesign.

Retain `AudioNotes.xcodeproj`, app targets/schemes `AudioNotes` / `AudioNotesiOS`,
test targets `AudioNotesTests` / `AudioNotesTests-iOS`, module `AudioNotes`, source
folders/app entry types and asset names. Their build/test/package/script references
are established; changing them would add cosmetic churn and model-name risk.

## Data and SwiftData compatibility

**Zero model/schema/migration changes.** `LibrarySchemaV1`, `LibraryMigrationPlan`
and all model declarations/relationships retain their original bytes. No cosmetic
storage migration. Production metadata remains `<resolved Application Support>/default.store`,
with existing WAL/SHM and managed files under `AudioNotes/{Recordings,Sources,Models,Backups}`.
`LibraryStorage`'s explicit/test default `AudioNotes/Library.store` also remains unchanged.
Soniquill currently retains the legacy AudioNotes storage location for backwards compatibility.

macOS still resolves the old development sandbox `cz.kudladev.AudioNotes` first,
then the previous bundle `cz.stepankudlacek.audionotes`, then its current container.
This retains pre-rename selection precedence. Outside those containers the standard
desktop Application Support fallback remains unchanged. Existing files stay in place;
there is no copy, reimport, empty replacement or new database path based on product name.
Tests create and reopen actual temporary SwiftData stores with a retained recording
and managed audio for both legacy bundle IDs. Existing graph/migration tests cover
projects, transcripts, summaries, chat and generation/cost history.

Caches remain OS-derived disposable locations; the new bundle may receive a separate
OS cache namespace. Managed thumbnails/model data remain under the existing root.
Internal upload/temp/fixture prefixes remain unchanged; generated/build outputs are
outside the repository. No user's real library was opened for acceptance.

**Compatibility decision:** existing Soniquill/TestFlight installations under
`cz.kudladev.soniquill` are the production baseline. Future changes must preserve
SwiftData, sandbox data, projects, recordings, sources, transcripts, summaries,
chats, presets, preferences, Keychain credentials, OAuth state and imported files
where applicable. Retain the module, schema, managed paths and credential identities.

The previous `cz.stepankudlacek.audionotes.ios` installation was a development
identity. **Do not implement automatic migration from its sandbox.** It may remain
untouched; its data transfer is not an M16.7.0 acceptance blocker. Changing identities
created separate iOS sandboxes, but that historical development identity is outside
the production compatibility baseline.

## Preferences

Persisted keys, provider IDs/models, settings/presets, Local AI choices, account metadata
and fixture suites are retained. macOS restores known non-secret preferences from
previous desktop and sandbox plist domains, newest previous identity first. Current
choices win; a dedicated `storage.soniquillPreferencesRestored.v1` marker makes it
idempotent independently of the old restoration marker. The existing desktop migration
behavior remains for old callers. Namespaces: `llm.`, `transcription.`, `ai.`;
explicit account session/host ID, library cost visibility, onboarding and Sparkle
check preferences are included. Secret-like keys are excluded; generation `.max_tokens`
ceilings are non-secret and preserved. DEBUG fixtures/test hosts skip automatic real
preference restoration. Tests use temporary plists and disposable defaults suites only.

The `library.selection` SceneStorage key is unchanged; OS-managed window/scene restoration across bundle IDs has not been manually accepted.

Old iOS defaults are inside the inaccessible old sandbox; keys are unchanged but domain
transfer is not automatic. No reset or deletion of the old domain was performed.

## Keychain

Stable lookup services (verified by tests without invoking Security APIs):

- `cz.kudladev.AudioNotes.provider-credentials`: API keys and Google OAuth.
- `cz.kudladev.AudioNotes.chatgpt-credentials`: ChatGPT OAuth tokens.

Account identifiers remain `openai-api-key`, `anthropic-api-key`, `gemini-api-key`,
`google-gemini-oauth`, `google-gemini-oauth-client-secret`, `chatgpt.oauth.access_token`,
`chatgpt.oauth.refresh_token`, `chatgpt.oauth.id_token`. No access-group, accessibility,
synchronization, save/read/delete or token refresh behavior changed. Named default
service constants make the preserved constructor identity testable. No real credentials
were inspected, printed, mutated, removed or recreated for acceptance.

Lookup identity is preserved; macOS Keychain may request access for a different signed
application. iOS Keychain default groups and device-only item accessibility depend on
signing entitlements and team/bundle identity. Unsigned/Simulator/static tests cannot
prove production signed credential continuity. Feature-specific signed credential-continuity
acceptance remains open; physical installation alone does not prove it. Preserve
the established signing identity and both legacy service identifiers.

## Authentication and URL schemes

ChatGPT uses its existing loopback/native callback implementation, PKCE/state/nonce,
issued client ID, refresh, model discovery and disconnect paths. The Apple bundle ID
is not used to construct that callback or OAuth client. Only display/agent-name hints
and the completion-page branding changed. Credential service/account identities and
opaque persisted host ID remain unchanged. No live authorization was performed.

Google macOS Desktop client configuration/loopback flow remains unchanged;
`GoogleOAuth.json` is ignored developer configuration and not printed or modified.
The owner confirmed on 2026-10-06 that the existing Google iOS OAuth client's
bundle ID was changed in Google Cloud Console to `cz.kudladev.soniquill`.
`Configuration/iOS-Info.plist` now declares the same production identity in
`GoogleOAuthClientBundleIdentifier`. The existing client ID, Cloud project ID
and reversed callback scheme are retained, including `CFBundleURLTypes` and
xcconfig values. The bundle-mismatch guard remains in place. Automated tests verify
that the built iOS app loads this configuration and uses the matching native scheme.
No Google Cloud credentials were modified by this task; the Console change was
performed manually by the owner and has not been independently inspected here.

Google OAuth status: **configuration aligned**, based on the owner's Console
confirmation and the local bundle declaration. **Live signed-device acceptance
remains OPEN**: sign in on Soniquill, verify callback/state, relaunch/Keychain
persistence, token refresh, inference and disconnect. Existing TestFlight build 1
is not replaced by this task; this local declaration is for the next separately
authorized build. If a different client is issued later, update the client ID and
its reversed scheme together in the plist/URL types/xcconfig, keeping the production
bundle declaration. Do not change Cloud credentials automatically.

URL scheme classification: Google reversed client scheme is provider-controlled;
ChatGPT/Google desktop loopbacks are protocol-controlled, not product URL schemes.
No independent product-controlled custom scheme needs renaming. The exported drag UTI
`com.audionotes.recording-reference` is compatibility-controlled and remains unchanged;
its visible description is now Soniquill recording reference.

## Release infrastructure

Sparkle package/version, updater implementation, feed/public key values, signing keys
and update preferences remain compatible locally. Product identity supplies updater
branding. No key generation, rotation, appcast publication or production update.
Production signed old-ID → new-ID update acceptance remains open; a built framework
and unchanged feed do not prove cross-identity upgrade behavior.

Repository slug and stable infrastructure URLs remain:
`Kudl1k/AudioNotes`, `https://kudl1k.github.io/AudioNotes/appcast.xml`, existing GitHub
release enclosure URLs and `AudioNotes-<version>.dmg` assets/release-note names.
Packaging uses the new `.app`, executable and bundle ID; DMG volume and future release
title use Soniquill. Old asset filenames remain for validator/feed compatibility.
No release script publishing/signing operation was run. Offline validator tests cover
existing enclosure/signature handling; shell syntax is checked. No GitHub operations.

## Old-name inventory

[Pre-change classification](SONIQUILL_OLD_NAME_AUDIT.md) records all 703 original
matching tracked lines before edits. Remaining references are grouped in the final
[final inventory](SONIQUILL_LEGACY_INVENTORY.md); literal internal paths/commands in current documentation are intentional.
Historical milestone reports and their existing screenshots are retained, not rebranded.
Current authoritative documentation uses Soniquill prose or an identity note; user-visible
old-name text only explains actual legacy backup/storage compatibility.

## Established signing baseline and completion

Current effective Xcode app settings (Debug and Release):

| Setting | macOS | iOS device |
| --- | --- | --- |
| DEVELOPMENT_TEAM | `829XTK67RJ` | `MTYBUX7QS6` |
| CODE_SIGN_STYLE | Automatic | Automatic |
| CODE_SIGN_IDENTITY | Apple Development | Apple Development |
| CODE_SIGN_ENTITLEMENTS | Debug: `Configuration/Debug.entitlements`; Release: `Configuration/Release.entitlements` | No explicit file |
| PRODUCT_BUNDLE_IDENTIFIER | `cz.kudladev.soniquill` | `cz.kudladev.soniquill` |

These are the resolved local settings, not a new certificate/provisioning decision.
The iOS target's team overrides the fallback team in iOS.xcconfig. Preserve both
existing values and the configuration precedence. Simulator identity remains `-`.
No DEVELOPMENT_TEAM, certificate, App ID, entitlement, capability or provisioning
strategy was changed during finalization. Tests use local macOS ad-hoc signing and
unsigned Simulator builds through command-line overrides only.

M16.7.0 is **COMPLETE**: final validation below passed; finalized in the
`chore(app): rename AudioNotes to Soniquill` commit containing this report. No push or upload is
part of this task. Google OAuth live verification and feature-specific manual/live
acceptance remain explicit follow-ups, not a reason to migrate the old development
sandbox or change the established Apple identity. M16.7 Local AI may then continue.

## Validation and captures

Final rerun: **2026-10-06**, Xcode 27.0 (27A266a), macOS 27.0.1. Full suites ran serially with no test
filters; the final iPhone/iPad runs include the aligned Google OAuth declaration.
An intermediate run correctly failed the old mismatch expectation after the
owner's Console correction; that expectation was replaced with configuration-load
checks and the entire iPhone suite rerun successfully. Counts below are logical
tests; parameterized invocations are not counted as separate logical tests.
Raw logs and xcresults are local-only in `/tmp/Soniquill-M16.7.0-final`.


| Validation | Result |
| --- | --- |
| macOS Debug full suite | 483 total: **477 passed, 6 expected skips, 0 failures**, 84 suites |
| iPhone 17e, iOS 26.5 Simulator | **75 passed**, 13 suites, 0 skips/failures |
| iPad Pro 11-inch M5, iOS 26.5 Simulator | **75 passed**, 13 suites, 0 skips/failures |
| macOS Release arm64 | Build succeeded, unsigned |
| iOS Debug Simulator arm64 | Build/test succeeded |
| iOS Release Simulator arm64 + x86_64 | Build succeeded, unsigned |
| Release/appcast validators | **6 passed**, shell syntax passed |
| Swift compiler warnings | **0** in the requested builds/tests |
| Other build warnings | Existing AppIntents metadata-extraction notice (no framework dependency) |
| Runtime diagnostics | macOS SourceProcessingTests QoS priority-inversion notice also present in prior rename result; no iPhone/iPad runtime warnings |
| Diff whitespace | `git diff --check` passed |

Debug and Release app Info.plists on both platforms were inspected: bundle ID
`cz.kudladev.soniquill`, display/name/executable `Soniquill`. Sparkle.framework is present
in the macOS Release bundle. Baseline icon asset remains `AppIcon`; packaging now
checks the actual `AppIcon.icns` output rather than its stale old-name expectation.

[Capture inventory and limitations](review/M16.7.0/README.md) covers standard and small
iPhone, iPad, macOS Library/project, native About/Help and isolated local Settings.
Native menus were inspected via Accessibility: About Soniquill, Hide Soniquill and
Quit Soniquill. Captures use synthetic in-memory libraries and temporary managed roots;
no live sign-in/provider requests or real credential reads. The product-native device
tool reported access disabled; existing Simulator fixture launch flags and simctl were
used instead. Representative Light/Dark and accessibility Dynamic Type screens were
reviewed without a visual redesign. macOS general/account Settings live inspection is
deferred to avoid reading real Keychain credentials; the isolated local Settings view
and source/tests establish its rename. Desktop native gestures, physical VoiceOver, live OAuth, signed credential
continuity and macOS Sparkle update acceptance remain open. Apple registration,
physical installation and TestFlight distribution are confirmed by the owner;
old development-iOS-container transfer is not required. Fixture screenshots do not close those acceptance items.

Project `objectVersion = 110` is unchanged by explicit user instruction. All
DEVELOPMENT_TEAM, CODE_SIGN_STYLE, code-sign entitlements, v1 schema/model/migration
plan, package resolutions, Google client/scheme values, Sparkle keys/feed values and
icon assets are unchanged. SourceCompatibilityMigration changes only interrupted-work
message branding; its logic is unchanged. The Google client bundle declaration is
aligned with the owner-confirmed Console update. No generated build products, secrets or unrelated Local AI logic
are included in the diff. The only Local AI edits are product-name strings in current
UI/error/documentation text. Apple registration and distribution predate this finalization. This task does not
push, upload or modify external release configuration.

Final command matrix (retained internal scheme names):

- macOS tests: `AudioNotes`, Debug, `platform=macOS,arch=arm64`, `CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES`, `-parallel-testing-enabled NO`.
- iPhone tests: `AudioNotesiOS`, Debug, iPhone 17e iOS 26.5 (`77A79DA6-CC59-4957-AACD-B78DB6E5955A`), unsigned, serial.
- iPad tests: `AudioNotesiOS`, Debug, iPad Pro 11-inch M5 iOS 26.5 (`652D97EB-6AE6-4A23-A757-2353BE2EDFBD`), unsigned, serial.
- macOS Release build: `AudioNotes`, `platform=macOS,arch=arm64`, `CODE_SIGNING_ALLOWED=NO`.
- iOS Debug and Release builds: `AudioNotesiOS`, `generic/platform=iOS Simulator`, `CODE_SIGNING_ALLOWED=NO`.
- Offline release validators: `python3 scripts/release/test_appcast.py`; syntax: `bash -n scripts/release/release.sh`; whitespace: `git diff --check`.

No provisioning-update flag, upload, App Store Connect operation or push was used.
