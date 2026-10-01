import base64
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

from validate_appcast import SPARKLE, validate


class AppcastValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        cls.asset = cls.root / "AudioNotes-1.0.0.dmg"
        # Synthetic bytes are only temporary test input, never a production feed.
        cls.asset.write_bytes(b"release validation fixture")
        script = cls.root / "sign.swift"
        script.write_text('''import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
print(key.publicKey.rawRepresentation.base64EncodedString())
print(try key.signature(for: data).base64EncodedString())
''')
        cls.key, cls.signature = subprocess.check_output(["swift", str(script), str(cls.asset)], text=True).splitlines()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def feed(self, **overrides):
        root = ET.Element("rss", version="2.0")
        channel = ET.SubElement(root, "channel")
        item = ET.SubElement(channel, "item")
        attrs = {"url": "https://github.com/Kudl1k/AudioNotes/releases/download/v1.0.0/AudioNotes-1.0.0.dmg",
                 "length": str(self.asset.stat().st_size), f"{{{SPARKLE}}}shortVersionString": "1.0.0",
                 f"{{{SPARKLE}}}version": "1", f"{{{SPARKLE}}}edSignature": self.signature}
        attrs.update(overrides)
        ET.SubElement(item, "enclosure", attrs)
        path = self.root / "feed.xml"
        path.write_bytes(ET.tostring(root))
        return path

    def test_signed_real_artifact_passes_offline(self):
        self.assertEqual(validate(self.feed(), "Kudl1k/AudioNotes", self.key, self.root), 1)

    def test_wrong_repository_http_and_nonexistent_naming_rejected(self):
        for url in ["http://github.com/Kudl1k/AudioNotes/releases/download/v1.0.0/AudioNotes-1.0.0.dmg",
                    "https://github.com/attacker/AudioNotes/releases/download/v1.0.0/AudioNotes-1.0.0.dmg",
                    "https://github.com/Kudl1k/AudioNotes/releases/download/v1.0.1/AudioNotes-1.0.0.dmg"]:
            with self.subTest(url=url), self.assertRaises(ValueError):
                validate(self.feed(url=url), "Kudl1k/AudioNotes", self.key, self.root)

    def test_corrupt_signature_and_length_rejected(self):
        with self.assertRaises(subprocess.CalledProcessError):
            validate(self.feed(**{f"{{{SPARKLE}}}edSignature": base64.b64encode(b"x" * 64).decode()}), "Kudl1k/AudioNotes", self.key, self.root)
        with self.assertRaises(ValueError):
            validate(self.feed(length="999"), "Kudl1k/AudioNotes", self.key, self.root)

    def test_public_validation_downloads_and_verifies(self):
        with patch("validate_appcast.https_download", side_effect=lambda url, path, limit: path.write_bytes(self.asset.read_bytes())) as download:
            self.assertEqual(validate(self.feed(), "Kudl1k/AudioNotes", self.key), 1)
            download.assert_called_once()

    def test_missing_public_asset_blocks_deployment(self):
        with patch("validate_appcast.https_download", side_effect=FileNotFoundError("no release asset")):
            with self.assertRaises(FileNotFoundError):
                validate(self.feed(), "Kudl1k/AudioNotes", self.key)

    def test_empty_or_entity_feed_cannot_deploy(self):
        path = self.root / "empty.xml"
        for data in [b"<rss><channel/></rss>", b'<!DOCTYPE rss [<!ENTITY x SYSTEM "file:///etc/passwd">]><rss/>']:
            path.write_bytes(data)
            with self.assertRaises(ValueError):
                validate(path, "Kudl1k/AudioNotes", self.key)


if __name__ == "__main__":
    unittest.main()
