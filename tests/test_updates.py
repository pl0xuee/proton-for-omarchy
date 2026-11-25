import asyncio
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))

import protocol  # noqa: E402
import updates  # noqa: E402
from profiles import ProfileStore  # noqa: E402


def make_root(version="1.1.0", homepage="https://github.com/acme/proton-for-omarchy", git=False):
    root = tempfile.mkdtemp()
    with open(os.path.join(root, "manifest.json"), "w") as fh:
        json.dump({"version": version, "homepage": homepage}, fh)
    if git:
        os.mkdir(os.path.join(root, ".git"))
    return root


class ParsingTests(unittest.TestCase):
    def test_versions(self):
        self.assertEqual(updates.parse_version("v1.2.3"), (1, 2, 3))
        self.assertEqual(updates.parse_version("1.10.0"), (1, 10, 0))
        for bad in ("", "1.2", "v1.2.3-beta", "1.2.3; rm", None, "<b>1.2.3</b>"):
            self.assertIsNone(updates.parse_version(bad))

    def test_plugin_version_reads_manifest(self):
        self.assertEqual(updates.plugin_version(make_root("1.3.0")), "1.3.0")
        self.assertEqual(updates.plugin_version(make_root("1.3.0; rm -rf")), "")
        self.assertEqual(updates.plugin_version(tempfile.mkdtemp()), "")
        with open(os.path.join(os.path.dirname(__file__), "..", "manifest.json")) as fh:
            self.assertEqual(updates.plugin_version(), json.load(fh)["version"])

    def test_releases_url_only_for_github_repos(self):
        self.assertEqual(updates.releases_url("https://github.com/acme/repo"),
                         "https://api.github.com/repos/acme/repo/releases/latest")
        for bad in ("http://github.com/acme/repo", "https://evil.com/acme/repo",
                    "https://github.com/acme/repo/../x", "https://github.com/acme/..", ""):
            self.assertEqual(updates.releases_url(bad), "", bad)

    def test_latest_tag_ignores_drafts_prereleases_and_junk(self):
        self.assertEqual(updates.latest_tag(b'{"tag_name":"v2.0.0"}'), "2.0.0")
        self.assertEqual(updates.latest_tag(b'{"tag_name":"v2.0.0","prerelease":true}'), "")
        self.assertEqual(updates.latest_tag(b'{"tag_name":"v2.0.0","draft":true}'), "")
        self.assertEqual(updates.latest_tag(b'{"tag_name":"nightly"}'), "")
        self.assertEqual(updates.latest_tag(b'[]'), "")


class CheckTests(unittest.TestCase):
    def run_check(self, latest, **kw):
        root = make_root(**{k: v for k, v in kw.items() if k != "dismissed"})
        with mock.patch.object(updates, "_fetch", return_value=latest):
            return asyncio.run(updates.check(kw.get("dismissed", ""), root=root))

    def test_newer_release_is_reported(self):
        result = self.run_check("1.2.0", git=True)
        self.assertEqual((result["available"], result["latest"], result["gitInstall"]), (True, "1.2.0", True))

    def test_same_or_older_is_not(self):
        self.assertFalse(self.run_check("1.1.0")["available"])
        self.assertFalse(self.run_check("1.0.9")["available"])
        self.assertEqual(self.run_check("1.0.9")["latest"], "")

    def test_dismissed_version(self):
        self.assertTrue(self.run_check("1.2.0", dismissed="1.2.0")["dismissed"])
        self.assertFalse(self.run_check("1.3.0", dismissed="1.2.0")["dismissed"])

    def test_network_failure_is_a_quiet_protocol_error(self):
        root = make_root()
        with mock.patch.object(updates, "_fetch", side_effect=OSError("offline")):
            with self.assertRaises(protocol.ProtocolError) as ctx:
                asyncio.run(updates.check(root=root))
        self.assertEqual(ctx.exception.code, "update_check_failed")

    def test_no_release_source(self):
        with self.assertRaises(protocol.ProtocolError):
            asyncio.run(updates.check(root=make_root(homepage="https://example.com")))


class DismissStorageTests(unittest.TestCase):
    def test_dismissed_update_persists_and_is_validated(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "state.json")
            store = ProfileStore(path)
            store.dismiss_update("1.2.0")
            self.assertEqual(ProfileStore(path).dismissed_update, "1.2.0")
            with self.assertRaises(protocol.ProtocolError):
                store.dismiss_update("1.2.0; rm -rf")

    def test_commands_registered(self):
        self.assertIn("check_update", protocol.COMMANDS)
        self.assertIn("dismiss_update", protocol.COMMANDS)


if __name__ == "__main__":
    unittest.main()
