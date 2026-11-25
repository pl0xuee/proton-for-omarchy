import json
import os
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))

from profiles import MAX_FAVORITES, MAX_HISTORY, MAX_RECENTS, ProfileStore  # noqa: E402
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

    def test_rename_onto_existing_target_drops_duplicate(self):
        store = ProfileStore(self.path)
        a = store.save_profile({"name": "Work", "target": {"targetType": "country", "country": "CH"}})
        store.save_profile({"name": "Home", "target": {"targetType": "country", "country": "SE"}})
        # Edit "Work" so it points at SE: the old SE entry must not survive as a duplicate.
        store.save_profile({"id": a["id"], "name": "Work", "target": {"targetType": "country", "country": "SE"}})
        self.assertEqual([f["label"] for f in store.favorites], ["Work"])
        store.save_profile({"id": store.favorites[0]["id"], "name": "Renamed",
                            "target": {"targetType": "country", "country": "SE"}})
        self.assertEqual([f["label"] for f in ProfileStore(self.path).favorites], ["Renamed"])

    def test_history_bounded_validated_and_cleared(self):
        store = ProfileStore(self.path)
        for i in range(MAX_HISTORY + 5):
            store.add_history({"server": f"CH#{i}", "label": "Zurich", "country": "CH",
                               "start": 1_700_000_000 + i, "end": 1_700_000_100 + i, "rx": 10, "tx": 5})
        store.add_history({"server": "", "start": 1, "end": 2})          # no server
        store.add_history({"server": "X#1", "start": 10, "end": 5})      # ends before start
        again = ProfileStore(self.path)
        self.assertEqual(len(again.history), MAX_HISTORY)
        self.assertEqual(again.history[0]["server"], f"CH#{MAX_HISTORY + 4}")
        again.clear_history()
        self.assertEqual(ProfileStore(self.path).history, [])

    def test_tampered_history_dropped(self):
        os.makedirs(os.path.dirname(self.path))
        with open(self.path, "w") as fh:
            json.dump({"history": [{"server": "CH#1", "start": "x", "end": 3}, 5,
                                   {"server": "CH#2", "country": "../", "start": 1, "end": 2,
                                    "rx": float("inf"), "tx": -4}]}, fh)
        store = ProfileStore(self.path)
        store.add_history({"server": "CH#3", "start": 1, "end": 2, "rx": 3 * 2 ** 40, "tx": 1})
        self.assertEqual(ProfileStore(self.path).history[0]["rx"], 3 * 2 ** 40)  # > 1 TB is kept
        hist = ProfileStore(self.path).history[1:]
        self.assertEqual(len(hist), 1)
        self.assertEqual((hist[0]["country"], hist[0]["rx"], hist[0]["tx"]), ("", 0, 0))


if __name__ == "__main__":
    unittest.main()
