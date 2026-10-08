# M13 macOS Sparkle release

## Authorized unnotarized previews — 2026-10-08

The owner explicitly authorized a second release pipeline without Developer ID or
notarization. See [PREVIEW_RELEASE.md](PREVIEW_RELEASE.md) for the one-command local
build/publish path, separate GitHub prerelease feed, ad-hoc signing tradeoff and
manual acceptance limits. The complete preview packaging rehearsal passed with
483 native tests and 13 tooling tests, actual DMG and Sparkle signature verification;
no preview has been published. The stable release gates below still apply to notarized
production distribution, not to this preview path.

## Current preparation — 2026-10-08

The first direct macOS release is still **unpublished**. The production identity is
Soniquill, `cz.kudladev.soniquill`; preserve the existing signing configuration,
Keychain services and data. iOS TestFlight remains a separate established release.

Verified on this workstation and with the authenticated GitHub API:

- Public repository: `Kudl1k/AudioNotes`; GitHub Pages is enabled with GitHub Actions.
- No GitHub Releases exist; `https://kudl1k.github.io/AudioNotes/appcast.xml` returns 404.
- The existing Sparkle Keychain public key matches repository variable
  `SPARKLE_PUBLIC_ED_KEY`. No replacement key was generated or private key exported.
- No Developer ID Application signing identity is installed. `NOTARY_PROFILE` is
  unset in the current shell; an existing profile name has not been supplied/tested.
- Version/build remain 1.0.0/1. An earlier incomplete local rehearsal already occupies
  `release-artifacts/1.0.0-1`; preserve it outside that destination before packaging
  again. Do not delete it automatically or increment the shared iOS version merely
  to bypass an output-directory collision.

Release tooling now uses `Soniquill-1.0.0.dmg` consistently for packaging, signatures,
acceptance hashes, GitHub assets and appcast validation. No historical published
AudioNotes assets exist to migrate. It also checks the exported app's actual feed
and public key before notarization and runs native tests serially, matching the
previous validation strategy. Normal development builds retain the unset updater
configuration; signed packaging injects the feed and existing public key.

Next: install the production team's Developer ID Application certificate, provide
and verify the notarytool Keychain profile, validate a clean source revision, package
and notarize, complete exact-artifact native acceptance, then publish the DMG and
Pages feed. The first-install candidate must already contain the future feed URL;
it cannot depend on that first appcast being public before it is built. Verify the
public feed and enclosures after deployment and before announcing availability.
Use a separately signed/notarized predecessor in an isolated test account/feed for
bootstrap update acceptance; never modify a signed bundle in place or claim the
first release's update test has passed without running it.

Validation on 2026-10-08: Debug build and all **483 tests in 84 suites** passed
serially; optimized macOS Release build passed with signing disabled. All **6
release-tool tests**, shell syntax and `git diff --check` passed. No compiler
warnings were reported; Xcode emitted the existing App Intents metadata warning.
This is build/test evidence only, not Developer ID, notarization or native update
acceptance. Pre-existing edits to README.md and SourceProcessingTests.swift were
retained and were included in the tested working tree.

## Historical implementation status — 2026-10-01

The following records the original milestone audit; its identity, hosting and key
availability statements are superseded by the current preparation above.

Prepared release infrastructure and correctness work, but this is not a completed or distributable release. Public repository `Kudl1k/AudioNotes`; expected stable feed `https://kudl1k.github.io/AudioNotes/appcast.xml`. GitHub currently reports Pages disabled (`has_pages=false`, Settings API 404); current feed is 404; no actual v1 Release asset exists. Enable Settings → Pages → Build and deployment → Source: GitHub Actions. After publishing the first verified release, verify feed and DMG URL over HTTPS, then build the app with the actual verified feed/key. Never ship the current blank feed configuration as a release updater.

Permanent ID `cz.stepankudlacek.audionotes`, user name AudioNotes, version 1.0.0/build 1, copyright `© 2026 Štěpán Kudláček`, macOS 15.0 and arm64 only are set in build configuration. Personal developer team ID `829XTK67RJ`. Existing data root fallback and previous nonsecret preference restoration preserve `cz.kudladev.AudioNotes` stores; provider Keychain service names remain stable. Production app sandbox off, Hardened Runtime on, no production entitlements/exception flags; Debug has only library-validation disable for local ad-hoc Sparkle loading. NSLocalNetworkUsageDescription is present; import-only product has no microphone prompt. Specific development ATS exception removed.

Sparkle 2.10.0 official package is embedded and configured with `SPUStandardUpdaterController`, optional stable HTTPS feed/public-key configuration, Ed25519 verification-before-extraction, standard checks/menu and Settings preference. Pages workflow validates actual release artifacts and signatures before deployment, uses GitHub Actions Pages artifact/deploy actions, verifies the deployed bytes and links, and rejects empty feeds. No Sparkle public/private key was found/configured; no Developer ID certificate or notarytool profile exists. GitHub CLI unavailable. `--check` is safe; package/publish correctly stop without the named release credentials. DMG/release publishing and notarization have not been run.

Persistence has a declared v1 schema baseline, generated synthetic on-disk database fixture and reopen/migration test. Existing-store pre-v1 metadata snapshots use SQLite online backup with integrity checking, DELETE-mode single-file output, WAL support, private permissions and no audio-copy. Store failure shows Retry/open/reveal and preserves the original. Managed recording/project/source deletion uses a write-ahead file journal and conservative crash recovery. Interrupted source processing is marked failed/retryable; generation/chat already recover existing state. Keychain/API configurations audited, no credentials copied to diagnostics. Debug log shim records no messages in production; provider content/error bodies removed from logs.

Native Welcome/setup-later, privacy/help/licenses, About version/build, updater Settings/menu, data-folder reveal and allowlisted diagnostic export are implemented. Local text explains source/provider boundaries and backup limitations. Analytics/crash reporter are not added. Third-party license notices include upstream Sparkle/WhisperKit/ArgumentParser/Whisper texts; verify all currently pinned model-card licenses and OAuth configuration before any shipment.

Validation on macOS 27 / Xcode 27: Debug build succeeded; generic arm64 Release build succeeded; Release bundle identity, version/build, minimum macOS, copyright, productivity category and custom icon were inspected; no GoogleOAuth.json ships in Release. Serial Debug suite passed **373 tests in 70 suites**. Sparkle enclosure tooling passed **6/6** synthetic-signature tests, focused persistence/migration tests passed **9/9**, and isolated Whisper settings tests passed **7/7**. A first concurrent 373-test run timed out three settings-condition tests under load; all passed with serialized full suite and in isolation. No Swift compiler warnings were emitted; Xcode emitted its expected App Intents metadata-extraction warning because no App Intents extension is used. Test-host OS `linkd`/Vision diagnostics were seen. `git diff --check`, release shell syntax and Python compilation passed.

No Developer ID archive, notarization, staple, Gatekeeper, clean account/quarantine, actual DMG, public appcast, Sparkle install update, accessibility/performance/long-session, or clean offline provider acceptance has occurred. Pages remains disabled and final public URLs cannot be verified; user must enable GitHub Pages. Developer ID certificate, notarytool profile and Sparkle signing key are absent. These required gates remain open and mean v1 is not ready to ship.
