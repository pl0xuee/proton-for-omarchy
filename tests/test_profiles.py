import json
import os
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))

from profiles import MAX_FAVORITES, MAX_RECENTS, ProfileStore  # noqa: E402
from protocol import ProtocolError  # noqa: E402


class ProfileStoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "sub", "state.json")

    def tearDown(self):
        self.tmp.cleanup()

    def test_toggle_and_persist_private(self):
        store = ProfileStore(self.path)
        self.assertTrue(store.toggle_favorite("Switzerland", {"targetType": "country", "country": "CH"}))
        mode = stat.S_IMODE(os.stat(self.path).st_mode)
        self.assertEqual(mode, 0o600)
        again = ProfileStore(self.path)
        self.assertEqual(len(again.favorites), 1)
        self.assertEqual(again.favorites[0]["key"], "country:CH")
        self.assertFalse(again.toggle_favorite("Switzerland", {"targetType": "country", "country": "CH"}))
        self.assertEqual(ProfileStore(self.path).favorites, [])

    def test_no_temp_files_left(self):
        store = ProfileStore(self.path)
        store.toggle_favorite("x", {"targetType": "server", "serverName": "CH#1"})
        self.assertEqual(os.listdir(os.path.dirname(self.path)), ["state.json"])

    def test_corrupt_file_recovers(self):
        os.makedirs(os.path.dirname(self.path))
        with open(self.path, "w") as fh:
            fh.write("{not json")
        store = ProfileStore(self.path)
        self.assertEqual(store.favorites, [])
        self.assertTrue(os.path.exists(self.path + ".corrupt"))

    def test_invalid_entries_dropped(self):
        os.makedirs(os.path.dirname(self.path))
        with open(self.path, "w") as fh:
            json.dump({"favorites": [
                {"label": "ok", "target": {"targetType": "country", "country": "SE"}},
                {"label": "bad", "target": {"targetType": "server", "serverName": "a;b"}},
                "junk",
                {"label": "dup", "target": {"targetType": "country", "country": "se"}},
            ]}, fh)
        store = ProfileStore(self.path)
        self.assertEqual([f["key"] for f in store.favorites], ["country:SE"])

    def test_favorite_limit(self):
        store = ProfileStore(self.path)
        for i in range(MAX_FAVORITES):
            store.favorites.append({"id": str(i), "key": f"server:X#{i}", "label": "x", "detail": "",
                                    "target": {"targetType": "server", "serverName": f"X#{i}", "features": []}, "ts": 0})
        with self.assertRaises(ProtocolError):
            store.toggle_favorite("new", {"targetType": "country", "country": "CH"})

    def test_recents_bounded_and_deduped(self):
        store = ProfileStore(self.path)
        for cc in ["CH", "SE", "NL", "US", "DE", "IS", "CH"]:
            store.add_recent(cc, {"targetType": "country", "country": cc, "features": []})
        self.assertEqual(len(store.recents), MAX_RECENTS)
        self.assertEqual(store.recents[0]["key"], "country:CH")
        self.assertEqual(len({r["key"] for r in store.recents}), MAX_RECENTS)

    def test_save_and_delete_profile(self):
        store = ProfileStore(self.path)
        entry = store.save_profile({"name": "P2P Zurich", "target": {"targetType": "city", "country": "CH",
                                                                   "city": "Zurich", "features": ["p2p"]}})
        self.assertEqual(store.find(entry["id"])["label"], "P2P Zurich")
        self.assertTrue(store.delete_profile(entry["id"]))
        self.assertIsNone(store.find(entry["id"]))
        with self.assertRaises(ProtocolError):
            store.save_profile({"name": "", "target": {"targetType": "fastest"}})


if __name__ == "__main__":
    unittest.main()
