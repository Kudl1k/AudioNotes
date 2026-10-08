# Soniquill release checklist

For the authorized unnotarized preview path, use [PREVIEW_RELEASE.md](PREVIEW_RELEASE.md).
The checklist below applies to the Developer ID/notarized stable release.

## One-time setup

- [x] Confirm public repository and permanent Soniquill bundle identity (see SONIQUILL_RENAME.md); verify the Developer ID signing team when installing its certificate.
- [x] Enable GitHub Pages with source **GitHub Actions** (verified 2026-10-08).
- [ ] Install a valid Developer ID Application certificate and verify it is not expired/revoked.
- [ ] Configure and test a notarytool Keychain profile; store only its profile name locally.
- [x] Existing Sparkle Keychain key matches repository Actions variable `SPARKLE_PUBLIC_ED_KEY` (verified 2026-10-08). Retain this key.
- [ ] Publish and verify a real signed/notarized DMG and signed appcast; verify exact enclosure asset length/signature, HTTPS Pages URL and download URL.
- [ ] Install an older signed release, create a project/recording/transcript/summary/chat/settings and download a model, then verify a signed update and every item after relaunch.
- [ ] Archive the v1.0.0 migration fixture, actual signed artifacts, dSYMs and checksums.
- [ ] Review the final Privacy and Third-Party Licenses notice, model revisions/licenses, OAuth configuration and production logs.

## Workstation signing setup

Use the Apple Developer team that owns Soniquill. For direct DMG distribution the
required certificate is **Developer ID Application**. Apple Development, Apple
Distribution and Mac Installer Distribution do not substitute for it. Apple
requires the Account Holder to create a local Developer ID certificate; see
[Apple's certificate instructions](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).
Create the certificate signing request on the release Mac, upload the CSR through
the developer portal, then install the downloaded `.cer` on that Mac so its private
key stays in Keychain. Do not revoke existing development/distribution certificates.

If no notarization profile exists, run this interactively in your own Terminal and
follow its prompts (never paste its credentials into chat or source files):

```sh
xcrun notarytool store-credentials Soniquill-release
```

The profile name is non-secret. Set `NOTARY_PROFILE=Soniquill-release` and
`DEVELOPER_ID_APPLICATION` to the exact installed certificate name when invoking
release.sh. Retrieve the existing public Sparkle key with
`DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -p` and set
`SPARKLE_PUBLIC_ED_KEY` to it. Compare it with the repository Actions variable;
do not generate a replacement key for this release. `release.sh --check` reports
local blockers and verifies the notary profile when provided.

## Each candidate

- [ ] Update `Configuration/Version.xcconfig`; semantic version and build are unique/increasing.
- [ ] Add `docs/release/<version>.md`; use tag `v<version>` and title `Soniquill <version>`.
- [ ] Check `origin` resolves to the intended GitHub owner/repository; ensure a clean checkout.
- [ ] Run Debug suite and release-tool tests; build optimized Release.
- [ ] Review warnings, concurrency issues, secrets, release-only fixture/UI/logs, outbound hosts, Keychain services, entitlements and third-party/model notices.
- [ ] Confirm arm64, macOS minimum, bundle ID/display name/version/build/copyright/category/icon, empty production entitlements and Hardened Runtime.
- [ ] Verify the app does not record audio or request microphone access. Test import, source validation, OpenAI/local large-audio cancellation and temporary file cleanup.
- [ ] Test corrupt store preservation/retry/backup recovery, deletion semantics, restart/interrupted work and migration fixture.
- [ ] Run core recording/project/local/cloud workflows where configured; Local Only and prompt injection boundaries; costs, citations, Markdown/PDF/Czech text; graceful provider/Ollama-offline failure.
- [ ] Test clean account without Xcode, Homebrew, providers, Ollama or development settings. Install from DMG and launch with quarantine.
- [ ] Check onboarding skip/setup, permissions, VoiceOver, keyboard, Light/Dark, narrow/full-screen layout, Help/About/build, privacy screen and diagnostics content.
- [ ] Measure launch/idle CPU/network/memory and profile long transcript/project/chat/export; run stability session. Record real values; component stress tests do not substitute for desktop measurements.
- [ ] Build/sign app; inspect nested code; verify Developer ID and Hardened Runtime. Notarize, staple, verify `codesign`, `spctl`, and stapler on the final app and DMG.
- [ ] Generate Sparkle EdDSA appcast from the signed versioned DMG, retain prior entries and real release notes, verify signatures and SHA-256.
- [ ] Test actual Sparkle 1.0.0 → 1.0.1 (then each supported update path), corrupt signature, offline feed, relaunch, all user data/settings/Keychain/model persistence.
- [ ] Complete a local acceptance JSON bound to this exact source revision, version/build and DMG hash. Resolve every P0/P1.
- [ ] Publish only after gates pass. Verify GitHub Release title/tag/assets and public Pages appcast+GitHub download enclosures. Install/update once more using the actual public URLs. Keep previous signed release for recovery.

## Blocker severity

P0: user data loss/corruption, credential/privacy/security breach, app fails to launch, invalid/unsafe installer or updater. P1: core import/transcription/chat/project workflow broken, repeatable crash, serious disclosure/privacy issue, signed update fails. Do not distribute with an unresolved P0/P1.

## Current status (2026-10-08)

Pages and the existing Sparkle signing key are ready. No releases exist and the feed
still returns 404. Developer ID Application signing is unavailable on this Mac; the
notarytool profile has not been supplied/verified. Signed packaging, exact-candidate
manual acceptance and public deployment remain open. See [M13 preparation](M13_IMPLEMENTATION.md).

## Historical status (2026-10-01)

Historical macOS direct-distribution audit (2026-10-01; not the current iOS release state): repository-side custom Actions Pages deployment and signed-feed validator are prepared. One-time Pages setting is still off. Public appcast and v1 DMG are 404/not yet published. No Developer ID identity, notarytool profile or Sparkle private signing key is available on the release Mac. Full release, notarization, clean-machine, production provider, accessibility/performance, live update, bug-bash and distribution checks remain open. These macOS direct-distribution checks do not negate the confirmed iOS App Store Connect upload/TestFlight distribution of Soniquill 1.0.0 build 1. See [the established release baseline](SONIQUILL_RENAME.md#established-apple-release-state).
