#!/usr/bin/env python3
"""Build/publish unnotarized, ad-hoc signed macOS previews. No Apple credentials needed."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error

from validate_appcast import SPARKLE, https_download, validate
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
CHANNEL_TAG = "preview-feed"


def run(*args, log=None):
    if log:
        with Path(log).open("w") as stream:
            subprocess.run(args, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, check=True)
        return ""
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def identity(build_override=None):
    config = (ROOT / "Configuration/Version.xcconfig").read_text()
    version = re.search(r"^MARKETING_VERSION = (\S+)$", config, re.M)[1]
    build = build_override or re.search(r"^CURRENT_PROJECT_VERSION = (\S+)$", config, re.M)[1]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) or not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("Expected semantic version and positive integer build")
    remote = run("git", "remote", "get-url", "origin")
    match = re.fullmatch(r"(?:https://github.com/|git@github.com:)([\w.-]+/[\w.-]+?)(?:\.git)?", remote)
    if not match:
        raise ValueError("origin must be a GitHub repository")
    return version, build, match[1]


def feed_url(repository):
    return f"https://github.com/{repository}/releases/download/{CHANNEL_TAG}/appcast.xml"


def fetch_feed(repository, destination):
    try:
        https_download(feed_url(repository), destination, 1024 * 1024)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        # Distinguish first bootstrap from a missing/deleted feed for existing users.
        releases = run("gh", "api", "--paginate", f"repos/{repository}/releases", "--jq",
                       '.[] | select(.draft == false) | .tag_name').splitlines()
        if any(tag.startswith("preview-v") or tag == CHANNEL_TAG for tag in releases):
            raise ValueError("Preview releases exist but their feed is missing; restore it first") from error
        return None
    return digest(destination)


def newest_build(feed):
    return max(int(item.findtext(f"{{{SPARKLE}}}version") or
                   item.find("enclosure").get(f"{{{SPARKLE}}}version"))
               for item in ET.parse(feed).findall("./channel/item"))


def check_candidate(folder, repository, version, build, public_key, revision):
    manifest = json.loads((folder / "candidate.json").read_text())
    expected = {"repository": repository, "version": version, "build": build,
                "revision": revision, "public_key": public_key, "rehearsal": False}
    if any(manifest.get(key) != value for key, value in expected.items()):
        raise ValueError("Candidate must match this clean revision, build and Sparkle key; rehearsals cannot publish")
    required = {f"Soniquill-{version}-b{build}-preview.dmg", "appcast.xml", "INSTALL.txt", "release-notes.md", "SHA256SUMS"}
    if set(manifest.get("hashes", {})) != required:
        raise ValueError("Incomplete candidate manifest")
    for name, expected_hash in manifest["hashes"].items():
        if digest(folder / name) != expected_hash:
            raise ValueError(f"Candidate artifact changed: {name}")
    validate(folder / "appcast.xml", repository, public_key, folder, channel="preview")
    if newest_build(folder / "appcast.xml") != int(build):
        raise ValueError("Candidate is not the newest preview build")
    return manifest


def release_info(repository, tag):
    result = subprocess.run(["gh", "api", f"repos/{repository}/releases/tags/{tag}"],
                            cwd=ROOT, text=True, capture_output=True)
    if result.returncode == 0:
        return json.loads(result.stdout)
    if "HTTP 404" in result.stderr:
        return None
    raise RuntimeError("Cannot query GitHub release; check gh authentication/connectivity")


def package(folder, repository, version, build, rehearsal):
    if folder.exists():
        raise ValueError(f"Refusing to overwrite {folder}; retain it elsewhere or use a new --build")
    notes = ROOT / f"docs/release/{version}.md"
    if not notes.is_file():
        raise ValueError(f"Missing release notes: {notes}")
    source_revision = run("git", "rev-parse", "HEAD")
    folder.mkdir(parents=True)
    print(f"Preparing preview in {folder}", flush=True)
    # Reuse compilation caches without altering global signing or iOS configuration.
    derived = ROOT / "DerivedData"
    base = ["xcodebuild", "-project", "AudioNotes.xcodeproj", "-scheme", "AudioNotes",
            "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(derived)]
    print("Running native and release-tool tests…", flush=True)
    run(*base, "-configuration", "Debug", "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=YES",
        "-parallel-testing-enabled", "NO", "test", log=folder / "tests.log")
    run(sys.executable, "-m", "unittest", "discover", "-s", "scripts/release", "-p", "test_*.py",
        log=folder / "tooling-tests.log")
    sparkle = derived / "SourcePackages/artifacts/sparkle/Sparkle/bin"
    public_key = run(str(sparkle / "generate_keys"), "-p")
    configured_key = os.environ.get("SPARKLE_PUBLIC_ED_KEY")
    if configured_key and configured_key != public_key:
        raise ValueError("Configured Sparkle public key differs from the existing Keychain key")
    previous = folder / "previous-appcast.xml"
    previous_hash = fetch_feed(repository, previous)
    if previous_hash:
        validate(previous, repository, public_key, channel="preview")
        if int(build) <= newest_build(previous):
            raise ValueError("--build must exceed all previously published preview builds")
    print("Building optimized, ad-hoc signed macOS app…", flush=True)
    run(*base, "-configuration", "Release", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES",
        "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=YES",
        "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO",
        f"CODE_SIGN_ENTITLEMENTS={ROOT / 'Configuration/Preview.entitlements'}", f"CURRENT_PROJECT_VERSION={build}",
        f"AUDIONOTES_UPDATE_FEED_URL={feed_url(repository)}", f"AUDIONOTES_UPDATE_PUBLIC_KEY={public_key}",
        "build", log=folder / "build.log")
    staging = folder / "dmg-root"
    staging.mkdir()
    app = staging / "Soniquill.app"
    run("ditto", str(derived / "Build/Products/Release/Soniquill.app"), str(app))
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    for key, value in {"CFBundleIdentifier": "cz.kudladev.soniquill", "CFBundleShortVersionString": version,
                       "CFBundleVersion": build, "SUFeedURL": feed_url(repository), "SUPublicEDKey": public_key,
                       "SUVerifyUpdateBeforeExtraction": True}.items():
        if info.get(key) != value:
            raise ValueError(f"Unexpected built bundle value: {key}")
    if run("lipo", "-archs", str(app / "Contents/MacOS/Soniquill")) != "arm64":
        raise ValueError("Preview must target Apple Silicon")
    run("codesign", "--verify", "--deep", "--strict", str(app))
    signature = subprocess.run(["codesign", "-dv", str(app)], text=True, capture_output=True, check=True)
    if "Signature=adhoc" not in signature.stderr:
        raise ValueError("Expected ad-hoc preview signature")
    entitlements = plistlib.loads(run("codesign", "-d", "--entitlements", "-", "--xml", str(app)).encode())
    allowed_entitlements = {"com.apple.security.cs.disable-library-validation",
                            "com.apple.security.files.user-selected.read-write",
                            "com.apple.security.network.client", "com.apple.security.network.server"}
    if (entitlements.get("com.apple.security.cs.disable-library-validation") is not True
            or not set(entitlements).issubset(allowed_entitlements)):
        raise ValueError("Unexpected preview entitlements (debugger access must not be enabled)")
    install = ("Soniquill — UNNOTARIZED PREVIEW\n\n"
               "Requires an Apple Silicon Mac running macOS 15 or later.\n"
               "Quit any running Soniquill, then drag Soniquill.app to Applications.\n"
               "This preview has no Apple Developer ID signature or notarization.\n"
               "After a blocked launch, use System Settings > Privacy & Security > Open Anyway\n"
               "if you trust this download. Managed Macs may prohibit this exception.\n"
               "Do not disable Gatekeeper globally.\n\n"
               "This uses the same Soniquill library, preferences and Keychain as your existing app.\n"
               "It replaces the installed app; it is not a separate sandbox. Back up valuable data.\n"
               "Sparkle checks a separate preview feed and verifies Ed25519 download signatures.\n"
               "Cross-machine launch and live Sparkle update acceptance remain manual checks.\n"
               "A later stable installation must have a higher build number.\n")
    (folder / "INSTALL.txt").write_text(install)
    (staging / "INSTALL.txt").write_text(install)
    (staging / "Applications").symlink_to("/Applications")
    name = f"Soniquill-{version}-b{build}-preview.dmg"
    dmg = folder / name
    print("Creating DMG and signing the Sparkle update…", flush=True)
    run("hdiutil", "create", "-volname", "Soniquill Preview", "-srcfolder", str(staging), "-format", "UDZO", str(dmg),
        log=folder / "dmg.log")
    run("hdiutil", "verify", str(dmg), log=folder / "dmg-verify.log")
    release_notes = "# Unnotarized preview\n\n" + install + "\n\n" + notes.read_text()
    (folder / "release-notes.md").write_text(release_notes)
    feed_dir = folder / "feed"
    feed_dir.mkdir()
    # A hard link avoids another large copy; generated feed is checked against the final DMG.
    os.link(dmg, feed_dir / name)
    (feed_dir / name.replace(".dmg", ".md")).write_text(release_notes)
    if previous_hash:
        shutil.copyfile(previous, feed_dir / "appcast.xml")
    tag = f"preview-v{version}-b{build}"
    run(str(sparkle / "generate_appcast"), "--versions", build, "--maximum-deltas", "0",
        "--maximum-versions", "0", "--embed-release-notes", "--download-url-prefix",
        f"https://github.com/{repository}/releases/download/{tag}/", str(feed_dir), log=folder / "appcast.log")
    shutil.copyfile(feed_dir / "appcast.xml", folder / "appcast.xml")
    validate(folder / "appcast.xml", repository, public_key, folder, channel="preview")
    (folder / "SHA256SUMS").write_text(f"{digest(dmg)}  {name}\n")
    files = [name, "appcast.xml", "INSTALL.txt", "release-notes.md", "SHA256SUMS"]
    if not rehearsal and (run("git", "rev-parse", "HEAD") != source_revision or run("git", "status", "--porcelain")):
        raise ValueError("Source changed during packaging; rebuild from a clean revision")
    manifest = {"repository": repository, "version": version, "build": build, "revision": source_revision,
                "public_key": public_key, "rehearsal": rehearsal, "previous_feed_sha256": previous_hash,
                "hashes": {name: digest(folder / name) for name in files}}
    (folder / "candidate.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Prepared {dmg}\n" + ("Rehearsal only; cannot publish this candidate." if rehearsal else
          f"Publish with: scripts/release/preview.sh --publish --build {build}"), flush=True)


def publish(folder, repository, version, build):
    public_key = run(str(ROOT / "DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys"), "-p")
    manifest = check_candidate(folder, repository, version, build, public_key, run("git", "rev-parse", "HEAD"))
    tag = f"preview-v{version}-b{build}"
    # Check the remote commit exists before allowing gh to create the release tag.
    run("gh", "api", f"repos/{repository}/commits/{manifest['revision']}", "--jq", ".sha")
    with tempfile.TemporaryDirectory() as temp:
        current = Path(temp) / "appcast.xml"
        # A retry after uploading the channel feed is safe and needs no mutations.
        try:
            https_download(feed_url(repository), current, 1024 * 1024)
            current_hash = digest(current)
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
            current_hash = None
        if current_hash == manifest["hashes"]["appcast.xml"]:
            validate(current, repository, public_key, channel="preview")
            print("Preview already published and public feed verified.")
            return
        if current_hash != manifest["previous_feed_sha256"]:
            raise ValueError("Preview feed changed since packaging; rebuild against the current feed")
        existing = release_info(repository, tag)
        if existing:
            if not existing["prerelease"]:
                raise ValueError("Existing tag is not a preview prerelease")
            # Never overwrite an existing candidate. A retry must match every uploaded byte.
            download = Path(temp) / "candidate"
            download.mkdir()
            for name in manifest["hashes"]:
                run("gh", "release", "download", tag, "--repo", repository, "--pattern", name, "--dir", str(download))
                if digest(download / name) != manifest["hashes"][name]:
                    raise ValueError("Existing release assets differ; use a new build")
        else:
            run("gh", "release", "create", tag, "--repo", repository, "--target", manifest["revision"],
                "--title", f"Soniquill {version} ({build}) — unnotarized preview", "--notes-file", str(folder / "release-notes.md"),
                "--prerelease", "--latest=false", "--draft", *[str(folder / name) for name in manifest["hashes"]])
        run("gh", "release", "edit", tag, "--repo", repository, "--draft=false", "--prerelease", "--latest=false")
        validate(folder / "appcast.xml", repository, public_key, channel="preview")
        channel = release_info(repository, CHANNEL_TAG)
        if channel is None:
            run("gh", "release", "create", CHANNEL_TAG, "--repo", repository, "--target", manifest["revision"],
                "--title", "Soniquill preview update feed", "--notes", "Update feed for unnotarized previews. Download a versioned preview release to install.",
                "--prerelease", "--latest=false", str(folder / "appcast.xml"))
        else:
            if channel["draft"] or not channel["prerelease"]:
                raise ValueError("Preview feed tag must be a published prerelease")
            run("gh", "release", "upload", CHANNEL_TAG, "--repo", repository, "--clobber", str(folder / "appcast.xml"))
        https_download(feed_url(repository), current, 1024 * 1024)
        if digest(current) != manifest["hashes"]["appcast.xml"]:
            raise ValueError("Public feed does not match candidate; retry --publish after CDN propagation")
        validate(current, repository, public_key, channel="preview")
    print(f"Published https://github.com/{repository}/releases/tag/{tag}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    for mode in ("package", "publish", "release", "rehearse"):
        modes.add_argument(f"--{mode}", action="store_true")
    parser.add_argument("--build", help="Mac preview build override; must increase for each distributed preview")
    args = parser.parse_args()
    os.umask(0o077)
    version, build, repository = identity(args.build)
    if not args.rehearse and run("git", "status", "--porcelain"):
        raise ValueError("Commit changes first. Use --rehearse for a local, unpublishable working-tree package.")
    folder = ROOT / "release-artifacts" / (f"preview-{version}-{build}" + ("-rehearsal" if args.rehearse else ""))
    lock = ROOT / "release-artifacts/.preview-lock"
    lock.parent.mkdir(exist_ok=True)
    try:
        lock.mkdir()
    except FileExistsError as error:
        raise ValueError("Another preview command is running. Remove .preview-lock only if it was interrupted.") from error
    try:
        if args.package or args.release or args.rehearse:
            package(folder, repository, version, build, args.rehearse)
        if args.publish or args.release:
            publish(folder, repository, version, build)
    finally:
        lock.rmdir()


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"Preview release stopped: {error}", file=sys.stderr)
        sys.exit(1)
