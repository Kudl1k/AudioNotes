#!/bin/bash
# Local release tooling. Never run with bash -x; secrets remain in Keychain.
set -euo pipefail
umask 077
mode="${1:---check}"
case "$mode" in --check|--dry-run|--package|--publish) ;; *) echo 'Usage: release.sh [--check|--dry-run|--package|--publish]'; exit 2 ;; esac
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
# Only an actual GitHub remote supplies hosting identity; no guessed owner/repo.
repository="$(python3 - <<'PY'
import re,subprocess
remote=subprocess.check_output(['git','remote','get-url','origin'],text=True).strip()
m=re.fullmatch(r'(?:https://github.com/|git@github.com:)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?',remote)
if not m: raise SystemExit('origin must be a GitHub repository')
print(m[1])
PY
)"
owner="${repository%%/*}"
repo_name="${repository#*/}"
feed="https://$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]').github.io/$repo_name/appcast.xml"
version="$(awk '/^MARKETING_VERSION = / {print $3}' Configuration/Version.xcconfig)"
build="$(awk '/^CURRENT_PROJECT_VERSION = / {print $3}' Configuration/Version.xcconfig)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid authoritative version/build.'; exit 1; }
output="$root/release-artifacts/$version-$build"
derived="$output/DerivedData"
printf 'Repository: %s\nVersion: %s (%s)\nExpected Pages feed: %s\n' "$repository" "$version" "$build" "$feed"
if [[ "$mode" == --check ]]; then
    identities="$(security find-identity -v -p codesigning)"
    if ! printf '%s\n' "$identities" | grep 'Developer ID Application:'; then
        echo 'BLOCKED: no Developer ID Application signing identity installed.'
    fi
    if [[ -z "${NOTARY_PROFILE:-}" ]]; then
        echo 'BLOCKED: NOTARY_PROFILE is not configured in this shell.'
    else
        xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null
        echo 'Notarization Keychain profile verified.'
    fi
    [[ -z "$(git status --porcelain)" ]] || echo 'BLOCKED: signed packaging requires a clean validated checkout.'
    echo 'Packaging requires DEVELOPER_ID_APPLICATION (certificate name), NOTARY_PROFILE (Keychain profile name), and SPARKLE_PUBLIC_ED_KEY (public key).'
    echo 'No private key/password is accepted or printed by this script.'
    exit 0
fi
if [[ "$mode" == --publish ]]; then
    command -v gh >/dev/null || { echo 'GitHub CLI must be installed and authenticated on the release workstation.'; exit 1; }
    : "${SPARKLE_PUBLIC_ED_KEY:?Set the existing Sparkle public key}"
    : "${RELEASE_ACCEPTANCE_FILE:?Path to the human acceptance JSON for this exact candidate}"
    [[ -f "$output/Soniquill-$version.dmg" && -f "$output/feed/appcast.xml" ]] || { echo 'Run --package and complete acceptance before publishing.'; exit 1; }
    [[ "$(cat "$output/source-revision.txt")" == "$(git rev-parse HEAD)" && -z "$(git status --porcelain)" ]] || { echo 'Candidate source no longer matches clean checkout.'; exit 1; }
    (cd "$output" && shasum -a 256 -c SHA256SUMS)
    python3 - "$RELEASE_ACCEPTANCE_FILE" "$output" "$version" "$build" <<'PYACCEPT'
import hashlib,json,pathlib,sys
accept=json.load(open(sys.argv[1])); folder=pathlib.Path(sys.argv[2]); version,build=sys.argv[3:]
expected={"version":version,"build":build,"source_revision":(folder/"source-revision.txt").read_text().strip(),"dmg_sha256":hashlib.sha256((folder/f"Soniquill-{version}.dmg").read_bytes()).hexdigest()}
if any(accept.get(k)!=v for k,v in expected.items()): raise SystemExit('Acceptance record does not identify this exact candidate')
for check in ['clean_machine','quarantine','signed_update','data_preserved','models_preserved','voiceover','bug_bash','no_p0_p1']:
 if accept.get(check) is not True: raise SystemExit('Incomplete human release acceptance: '+check)
PYACCEPT
    xcrun stapler validate "$output/Soniquill-$version.dmg"
    codesign --verify --verbose=2 "$output/Soniquill-$version.dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$output/Soniquill-$version.dmg"
    python3 scripts/release/validate_appcast.py "$output/feed/appcast.xml" --repository "$repository" --offline-artifacts "$output/feed"
    gh release create "v$version" --repo "$repository" --target "$(git rev-parse HEAD)" --title "Soniquill $version" --notes-file "docs/release/$version.md" --draft "$output/Soniquill-$version.dmg" "$output/SHA256SUMS" "$output/feed/appcast.xml"
    gh release edit "v$version" --repo "$repository" --draft=false
    gh workflow run publish-appcast.yml --repo "$repository" --ref main -f "release_tag=v$version"
    echo 'Release published; Pages dispatched. Verify the public feed and actual installed update before announcing.'
    exit 0
fi
[[ ! -e "$output" ]] || { echo 'Output directory already exists. Retain it or choose a new build number; refusing to overwrite.'; exit 1; }
if [[ "$mode" != --dry-run ]]; then
    : "${DEVELOPER_ID_APPLICATION:?Set the existing Developer ID Application certificate name}"
    : "${NOTARY_PROFILE:?Set the existing notarytool Keychain profile name}"
    : "${SPARKLE_PUBLIC_ED_KEY:?Set the existing Sparkle public Ed25519 key}"
    [[ "$DEVELOPER_ID_APPLICATION" == 'Developer ID Application:'* ]] || { echo 'Production cannot use ad-hoc/Apple Development signing.'; exit 1; }
    security find-identity -v -p codesigning | grep -F -- "\"$DEVELOPER_ID_APPLICATION\"" >/dev/null || { echo 'Developer ID identity unavailable.'; exit 1; }
    # The paid Developer Program team is the certificate's own "(TEAMID)" suffix;
    # personal Xcode teams cannot issue Developer ID certificates.
    team="${DEVELOPER_ID_APPLICATION##*(}"; team="${team%)}"
    [[ "$team" =~ ^[A-Z0-9]{10}$ ]] || { echo 'Developer ID certificate name must end with its (TEAMID).'; exit 1; }
    echo "Signing team: $team"
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null
    [[ -z "$(git status --porcelain)" ]] || { echo 'Use a clean validated source revision for signed release packaging.'; exit 1; }
fi
mkdir -p "$output"
# Debug and Release are built separately; all native offline tests are required.
xcodebuild -project AudioNotes.xcodeproj -scheme AudioNotes -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES -parallel-testing-enabled NO test > "$output/tests.log" 2>&1
python3 -m unittest discover -s scripts/release -p 'test_*.py' > "$output/tooling-tests.log" 2>&1
if [[ "$mode" == --dry-run ]]; then
    xcodebuild -project AudioNotes.xcodeproj -scheme AudioNotes -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$derived" -archivePath "$output/AudioNotes.xcarchive" CODE_SIGNING_ALLOWED=NO archive > "$output/archive.log" 2>&1
    app="$output/AudioNotes.xcarchive/Products/Applications/Soniquill.app"
    dmg="$output/UNSIGNED-DO-NOT-DISTRIBUTE-Soniquill-$version.dmg"
else
    sparkle="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin"
    [[ "$("$sparkle/generate_keys" -p)" == "$SPARKLE_PUBLIC_ED_KEY" ]] || { echo 'Existing Sparkle Keychain key does not match the configured public key.'; exit 1; }
    xcodebuild -project AudioNotes.xcodeproj -scheme AudioNotes -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$derived" -archivePath "$output/AudioNotes.xcarchive" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" DEVELOPMENT_TEAM="$team" AUDIONOTES_UPDATE_FEED_URL="$feed" AUDIONOTES_UPDATE_PUBLIC_KEY="$SPARKLE_PUBLIC_ED_KEY" archive > "$output/archive.log" 2>&1
    /usr/libexec/PlistBuddy -c 'Add :method string developer-id' "$output/ExportOptions.plist"
    /usr/libexec/PlistBuddy -c 'Add :signingStyle string manual' "$output/ExportOptions.plist"
    /usr/libexec/PlistBuddy -c "Add :signingCertificate string $DEVELOPER_ID_APPLICATION" "$output/ExportOptions.plist"
    /usr/libexec/PlistBuddy -c "Add :teamID string $team" "$output/ExportOptions.plist"
    xcodebuild -exportArchive -archivePath "$output/AudioNotes.xcarchive" -exportPath "$output/export" -exportOptionsPlist "$output/ExportOptions.plist" > "$output/export.log" 2>&1
    app="$output/export/Soniquill.app"
    codesign --verify --deep --strict --verbose=2 "$app"
    codesign -dv "$app" 2>&1 | grep -F 'Authority=Developer ID Application:' >/dev/null
    codesign -dv "$app" 2>&1 | grep 'flags=.*runtime' >/dev/null
    codesign -dv "$app" 2>&1 | grep -Fx "TeamIdentifier=$team" >/dev/null || { echo 'Exported app is not signed by the Developer ID team.'; exit 1; }
    # Verify the actual exported updater configuration before notarization.
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$app/Contents/Info.plist")" == "$feed" ]] || { echo 'Exported app has the wrong Sparkle feed.'; exit 1; }
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")" == "$SPARKLE_PUBLIC_ED_KEY" ]] || { echo 'Exported app has the wrong Sparkle public key.'; exit 1; }
    # Notarize and staple the app first so the dragged application works offline.
    ditto -c -k --keepParent "$app" "$output/notarize-app.zip"
    xcrun notarytool submit "$output/notarize-app.zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$output/app-notarization.json"
    python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))["status"] != "Accepted")' "$output/app-notarization.json"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
    dmg="$output/Soniquill-$version.dmg"
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == cz.kudladev.soniquill ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$version" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" == "$build" ]]
[[ "$(lipo -archs "$app/Contents/MacOS/Soniquill")" == arm64 ]]
[[ -f "$app/Contents/Resources/AppIcon.icns" ]] || { echo 'Compiled macOS fallback icon missing.'; exit 1; }
mkdir "$output/dmg-root"
ditto "$app" "$output/dmg-root/Soniquill.app"
ln -s /Applications "$output/dmg-root/Applications"
hdiutil create -volname Soniquill -srcfolder "$output/dmg-root" -format UDZO "$dmg"
hdiutil verify "$dmg"
if [[ "$mode" == --dry-run ]]; then
    echo "Unsigned packaging rehearsal only: $dmg"
    exit 0
fi
codesign --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$output/dmg-notarization.json"
python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))["status"] != "Accepted")' "$output/dmg-notarization.json"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
codesign --verify --verbose=2 "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
mkdir "$output/feed"
cp "$dmg" "$output/feed/"
notes="docs/release/$version.md"
[[ -f "$notes" ]] || { echo 'Missing versioned release notes.'; exit 1; }
cp "$notes" "$output/feed/Soniquill-$version.md"
# Preserve old entries for supported older clients. 404 is allowed only for
# the initial bootstrap; other feed failures are hard errors.
status="$(curl --silent --show-error --proto '=https' --tlsv1.2 -o "$output/previous-appcast.xml" -w '%{http_code}' "$feed")"
case "$status" in
  200) cp "$output/previous-appcast.xml" "$output/feed/appcast.xml" ;;
  404) [[ "$build" == 1 ]] || { echo 'Existing feed missing; refusing to lose historical entries.'; exit 1; } ;;
  *) echo 'Existing feed could not be fetched; stop before publishing.'; exit 1 ;;
esac
sparkle="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin"
"$sparkle/sign_update" "$dmg" > "$output/sparkle-signature.txt"
"$sparkle/generate_appcast" --versions "$build" --maximum-deltas 0 --maximum-versions 0 --embed-release-notes --download-url-prefix "https://github.com/$repository/releases/download/v$version/" "$output/feed"
# This verifies the embedded public key against the DMG signature, including
# any previous entries against their real public assets after publishing.
# Locally the new artifact is available in feed; previous artifacts must be
# retained/copied there when packaging a subsequent release.
python3 scripts/release/validate_appcast.py "$output/feed/appcast.xml" --repository "$repository" --offline-artifacts "$output/feed"
(cd "$output" && shasum -a 256 "Soniquill-$version.dmg" > SHA256SUMS)
git rev-parse HEAD > "$output/source-revision.txt"
echo "Signed/notarized candidate prepared at $output. Complete exact-artifact manual acceptance, then run --publish."
