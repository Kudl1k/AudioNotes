import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

from preview_release import check_candidate, fetch_feed, publish




class PreviewCandidateTests(unittest.TestCase):
    def test_bootstrap_only_without_previous_previews(self):
        error = urllib.error.HTTPError("https://example.org", 404, "missing", {}, None)
        with patch("preview_release.https_download", side_effect=error), patch("preview_release.run", return_value="v1.0.0"):
            self.assertIsNone(fetch_feed("owner/repo", Path("unused")))
        for tags in ["preview-v1.0.0-b1", "preview-feed"]:
            with patch("preview_release.https_download", side_effect=error), patch("preview_release.run", return_value=tags):
                with self.assertRaises(ValueError):
                    fetch_feed("owner/repo", Path("unused"))

    def test_transient_feed_failure_is_not_bootstrap(self):
        error = urllib.error.HTTPError("https://example.org", 503, "unavailable", {}, None)
        with patch("preview_release.https_download", side_effect=error):
            with self.assertRaises(urllib.error.HTTPError):
                fetch_feed("owner/repo", Path("unused"))

    def test_publish_uses_prereleases_and_verifies_assets_before_channel(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            (folder / "appcast.xml").write_bytes(b"feed")
            manifest = {"revision": "abc", "previous_feed_sha256": None,
                        "hashes": {"appcast.xml": hashlib.sha256(b"feed").hexdigest()}}
            events = []
            def command(*args, **kwargs):
                events.append(args)
                return "key"
            calls = 0
            def download(url, destination, limit):
                nonlocal calls
                calls += 1
                if calls == 1:
                    raise urllib.error.HTTPError(url, 404, "missing", {}, None)
                destination.write_bytes(b"feed")
            with patch("preview_release.check_candidate", return_value=manifest), \
                 patch("preview_release.run", side_effect=command), \
                 patch("preview_release.release_info", return_value=None), \
                 patch("preview_release.https_download", side_effect=download), \
                 patch("preview_release.validate", side_effect=lambda *a, **k: events.append(("validated",))):
                publish(folder, "owner/repo", "1.0.0", "1")
            creates = [event for event in events if event[:3] == ("gh", "release", "create")]
            self.assertEqual([event[3] for event in creates], ["preview-v1.0.0-b1", "preview-feed"])
            for event in creates:
                self.assertIn("--prerelease", event)
                self.assertIn("--latest=false", event)
            self.assertLess(events.index(("validated",)), events.index(creates[1]))

    def test_publish_rejects_feed_changed_since_packaging(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            manifest = {"revision": "abc", "previous_feed_sha256": None, "hashes": {"appcast.xml": "different"}}
            with patch("preview_release.check_candidate", return_value=manifest), \
                 patch("preview_release.run", return_value="key") as command, \
                 patch("preview_release.https_download", side_effect=lambda url, path, limit: path.write_bytes(b"newer feed")):
                with self.assertRaises(ValueError):
                    publish(folder, "owner/repo", "1.0.0", "1")
                self.assertFalse(any(call.args[:2] == ("gh", "release") for call in command.call_args_list))

    def test_candidate_rejects_rehearsals_stale_source_and_changed_artifacts(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            files = ["Soniquill-1.0.0-b1-preview.dmg", "appcast.xml", "INSTALL.txt", "release-notes.md", "SHA256SUMS"]
            for name in files:
                (folder / name).write_bytes(b"fixture")
            manifest = {"repository": "owner/repo", "version": "1.0.0", "build": "1", "revision": "abc",
                        "public_key": "key", "rehearsal": False,
                        "hashes": {name: hashlib.sha256(b"fixture").hexdigest() for name in files}}
            def save():
                (folder / "candidate.json").write_text(json.dumps(manifest))
            save()
            with patch("preview_release.validate"), patch("preview_release.newest_build", return_value=1):
                self.assertEqual(check_candidate(folder, "owner/repo", "1.0.0", "1", "key", "abc"), manifest)
                for field, value in [("rehearsal", True), ("revision", "old"), ("public_key", "other")]:
                    original = manifest[field]
                    manifest[field] = value
                    save()
                    with self.assertRaises(ValueError):
                        check_candidate(folder, "owner/repo", "1.0.0", "1", "key", "abc")
                    manifest[field] = original
                save()
                (folder / "appcast.xml").write_bytes(b"modified")
                with self.assertRaises(ValueError):
                    check_candidate(folder, "owner/repo", "1.0.0", "1", "key", "abc")


if __name__ == "__main__":
    unittest.main()
