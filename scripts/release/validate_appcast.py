#!/usr/bin/env python3
"""Release tooling only: validate real GitHub enclosures + Ed25519 signatures.

No credentials, private keys or application data are read. --offline-artifacts
is for packaging validation before upload; Pages always downloads real assets.
"""
import argparse
import base64
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
VERSION = r"[0-9]+\.[0-9]+\.[0-9]+"


def https_download(url, destination, limit):
    request = urllib.request.Request(url, headers={"User-Agent": "Soniquill-release-validation"})
    with urllib.request.urlopen(request, timeout=60) as response:
        if urllib.parse.urlsplit(response.url).scheme != "https":
            raise ValueError("Download redirected away from HTTPS")
        with open(destination, "wb") as output:
            count = 0
            while chunk := response.read(1024 * 1024):
                count += len(chunk)
                if count > limit:
                    raise ValueError("Download exceeds validation limit")
                output.write(chunk)


def verify_signature(path, public_key, signature):
    key = base64.b64decode(public_key, validate=True)
    sig = base64.b64decode(signature, validate=True)
    if len(key) != 32 or len(sig) != 64:
        raise ValueError("Invalid Ed25519 key/signature length")
    if sys.platform == "darwin":
        subprocess.run(["swift", str(Path(__file__).with_name("verify-signature.swift")),
                        str(path), public_key, signature], check=True, capture_output=True)
    else:
        # RFC 8410 SubjectPublicKeyInfo for a raw Ed25519 public key.
        with tempfile.TemporaryDirectory() as folder:
            key_path, sig_path = Path(folder) / "public.der", Path(folder) / "signature"
            key_path.write_bytes(bytes.fromhex("302a300506032b6570032100") + key)
            sig_path.write_bytes(sig)
            subprocess.run(["openssl", "pkeyutl", "-verify", "-rawin", "-pubin", "-keyform", "DER",
                            "-inkey", str(key_path), "-sigfile", str(sig_path), "-in", str(path)],
                           check=True, capture_output=True)


def validate(feed, repository, public_key, offline_artifacts=None, channel="stable"):
    if channel not in ("stable", "preview"):
        raise ValueError("Unknown release channel")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid GitHub repository identity")
    data = Path(feed).read_bytes()
    if len(data) > 1024 * 1024 or b"<!DOCTYPE" in data.upper() or b"<!ENTITY" in data.upper():
        raise ValueError("Appcast must be bounded XML without external entities")
    root = ET.fromstring(data)
    items = root.findall("./channel/item")
    if root.tag != "rss" or not items:
        raise ValueError("No published release entries; refusing to deploy a fake/empty production feed")
    seen = set()
    for item in items:
        enclosures = item.findall("enclosure")
        if len(enclosures) != 1:
            raise ValueError("Each release must have exactly one full DMG enclosure")
        enclosure = enclosures[0]
        version = enclosure.get(f"{{{SPARKLE}}}shortVersionString") or item.findtext(f"{{{SPARKLE}}}shortVersionString")
        build = enclosure.get(f"{{{SPARKLE}}}version") or item.findtext(f"{{{SPARKLE}}}version")
        if not version or not re.fullmatch(VERSION, version) or not build or not re.fullmatch(r"[1-9][0-9]*", build):
            raise ValueError("Missing semantic version or positive numeric build")
        if int(build) in seen:
            raise ValueError("Duplicate build number")
        seen.add(int(build))
        if channel == "preview":
            name = f"Soniquill-{version}-b{build}-preview.dmg"
            tag = f"preview-v{version}-b{build}"
        else:
            name = f"Soniquill-{version}.dmg"
            tag = f"v{version}"
        expected = f"https://github.com/{repository}/releases/download/{tag}/{name}"
        if enclosure.get("url") != expected:
            raise ValueError("Enclosure must reference the corresponding real GitHub Release DMG")
        length = int(enclosure.get("length", "0"))
        if not 0 < length <= 2 * 1024**3:
            raise ValueError("Invalid enclosure byte length")
        signature = enclosure.get(f"{{{SPARKLE}}}edSignature", "")
        with tempfile.TemporaryDirectory() as folder:
            artifact = Path(folder) / name
            local = Path(offline_artifacts) / name if offline_artifacts else None
            if local is not None and local.is_file():
                artifact = local
            else:
                https_download(expected, artifact, length)
            if artifact.stat().st_size != length:
                raise ValueError("Release asset length differs from signed appcast")
            verify_signature(artifact, public_key, signature)
        print(f"Verified v{version} build {build}: {expected}")
    return len(items)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("feed")
    parser.add_argument("--repository", required=True)
    parser.add_argument("--public-key", default=os.environ.get("SPARKLE_PUBLIC_ED_KEY"))
    parser.add_argument("--offline-artifacts")
    parser.add_argument("--channel", choices=["stable", "preview"], default="stable")
    parser.add_argument("--compare", help="Require downloaded feed to match the deployed file exactly")
    args = parser.parse_args()
    try:
        if not args.public_key:
            raise ValueError("SPARKLE_PUBLIC_ED_KEY must contain the public update key")
        if args.compare and Path(args.feed).read_bytes() != Path(args.compare).read_bytes():
            raise ValueError("Public feed differs from validated deployment artifact")
        validate(args.feed, args.repository, args.public_key, args.offline_artifacts, args.channel)
    except Exception as error:
        # Never dump HTTP headers, environments, auth/configuration or subprocess output.
        print(f"Appcast validation failed: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
