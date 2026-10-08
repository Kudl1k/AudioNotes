# Unnotarized macOS preview releases

This is the explicitly authorized fast distribution path while Developer ID signing
is unavailable. It produces an optimized Apple Silicon / macOS 15+ Soniquill app,
an ad-hoc code signature, a DMG, SHA-256 checksums and a Sparkle Ed25519-signed update
archive. It does **not** notarize or claim Apple-verified developer identity.

## Build and publish

Run on the release Mac with Xcode 27, authenticated `gh`, and the existing Sparkle
private key in the login Keychain. No Apple Developer certificate, notarytool
profile, private-key export or GitHub Pages deployment is needed.

Commit and push the intended source revision first, then:

```sh
scripts/release/preview.sh --release --build 1
```

This runs serial native tests and tooling tests, builds Release, packages and
verifies the app/DMG, signs the Sparkle archive, publishes a GitHub prerelease, and
updates/verifies the preview feed. Use an increasing `--build` for every subsequent
preview, e.g. `--build 2`. This command-line override does not edit the shared iOS
version configuration. Marketing version comes from Configuration/Version.xcconfig.

To inspect the local candidate before publishing, use two commands:

```sh
scripts/release/preview.sh --package --build 1
scripts/release/preview.sh --publish --build 1
```

Outputs are in `release-artifacts/preview-1.0.0-1/`. Existing outputs are never
overwritten. Keep an unsuccessful output elsewhere before retrying the same build;
never reuse a build already distributed. A retry of `--publish` accepts only matching
existing assets. It rejects changed artifacts, a different source revision, an
unexpected Sparkle key, or a feed changed since packaging. Publish from one release
Mac at a time; GitHub release asset replacement does not offer compare-and-swap.

For a working tree with uncommitted changes:

```sh
scripts/release/preview.sh --rehearse --build 1
```

This exercises tests, build, real DMG packaging and Sparkle signing locally in a
separate `-rehearsal` directory. Its manifest prevents publication. It does not
publish releases or change the remote feed. No manually fabricated acceptance JSON
is required for previews; the signed stable pipeline retains its acceptance gates.

## Hosting and separation from stable releases

For this repository the versioned prerelease is `preview-v1.0.0-b1`, with asset
`Soniquill-1.0.0-b1-preview.dmg`. All preview releases use `--prerelease --latest=false`.
They do not consume `v1.0.0` or become GitHub's latest stable release.

The embedded preview feed is:

`https://github.com/Kudl1k/AudioNotes/releases/download/preview-feed/appcast.xml`

The `preview-feed` prerelease hosts only the mutable feed; versioned release assets
remain immutable. The pipeline verifies every public enclosure before updating the
feed, retains prior feed entries and rejects build rollback. A missing first feed
is allowed only when no published preview releases/feed tag exist. Interrupted
publication can be retried with `--publish` from the same candidate.

Stable `appcast.xml` on GitHub Pages and the Developer ID/notarized `release.sh`
workflow remain separate. The feed validator defaults to stable; preview URLs are
accepted only with `--channel preview` and cannot enter the stable Pages workflow.
Sparkle archive signature verification remains enabled before extraction.

## Installation and data

The DMG and GitHub notes explain that this is an unnotarized preview. Users quit
Soniquill, drag it to Applications, attempt to open it, then use System Settings →
Privacy & Security → Open Anyway if macOS permits and they trust the download.
Do not disable Gatekeeper globally or remove quarantine in release tooling.
[Apple documents this per-app exception](https://support.apple.com/en-gb/102445).
Managed Macs may prohibit it.

The app keeps `cz.kudladev.soniquill` and existing Keychain services; no suffix,
data migration or separate preview sandbox is introduced. It replaces the installed
app and uses the same library/preferences. Keep a backup of valuable data.

Only the preview command supplies `Configuration/Preview.entitlements`, allowing
ad-hoc code to load Sparkle without library validation. The optimized build is not
DEBUG; debug fixtures are not enabled. Production signing settings and Release
entitlements are unchanged. This is a deliberate preview security tradeoff.

A later stable app must have a higher build number than distributed previews.
Installing the notarized stable DMG manually changes the embedded feed back to
stable while preserving bundle identity and data. Automatic preview-to-stable
channel migration is not implemented.

## Validation limits

Automated checks cover bundle identity/version/architecture, nested code signatures,
DMG integrity, signed enclosure bytes, feed separation and candidate integrity.
First launch on a separate quarantined Mac and a real preview-to-preview Sparkle
installation remain manual acceptance; successful packaging does not prove those.
No claim is made that this is a notarized production release.

Validated on 2026-10-08 with Xcode 27: the full `--rehearse --build 1` command
completed successfully, including **483 native tests in 84 suites**, **13 tooling
tests**, optimized arm64 build, nested signature/entitlement checks (no debugger
access), DMG verification, appcast generation and Ed25519 verification against the
actual 1.0.0/1 DMG. Shell syntax and diff whitespace checks passed. No Swift compiler
warnings were introduced; macOS 27 emits a deprecation notice for the existing
`hdiutil create` interface, retained for older release-Mac compatibility. No GitHub
release or remote feed was created. Separate-Mac launch and live update acceptance
are still unverified.
