import os
import stat
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))

import bridge  # noqa: E402
import protocol  # noqa: E402
from profiles import target_key  # noqa: E402


class BootMarkerTests(unittest.TestCase):
    def test_claims_once_per_runtime_dir(self):
        with tempfile.TemporaryDirectory() as runtime, mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": runtime}):
            self.assertTrue(bridge.claim_boot_marker())
            self.assertFalse(bridge.claim_boot_marker())
            mode = os.stat(os.path.join(runtime, "proton-for-omarchy-autoconnect")).st_mode
            self.assertEqual(stat.S_IMODE(mode), 0o600)

    def test_no_runtime_dir_never_claims(self):
        with mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": ""}):
            self.assertFalse(bridge.claim_boot_marker())

    def test_command_is_registered(self):
        self.assertIn("claim_boot_autoconnect", protocol.COMMANDS)


class ProtocolEdgeTests(unittest.TestCase):
    def test_unknown_command_keeps_request_id(self):
        with self.assertRaises(protocol.ProtocolError) as ctx:
            protocol.parse_line('{"id":"7","cmd":"nope"}')
        self.assertEqual(getattr(ctx.exception, "req_id", ""), "7")

    def test_avoid_current_only_for_pooled_targets(self):
        self.assertTrue(protocol.connect_target({"targetType": "fastest", "avoidCurrent": True})["avoidCurrent"])
        self.assertNotIn("avoidCurrent", protocol.connect_target({"targetType": "fastest"}))
        city = protocol.connect_target({"targetType": "server", "serverName": "CH#1", "avoidCurrent": True})
        self.assertNotIn("avoidCurrent", city)

    def test_get_int_rejects_non_finite(self):
        for bad in (float("nan"), float("inf"), float("-inf")):
            with self.assertRaises(protocol.ProtocolError):
                protocol.get_int({"n": bad}, "n", 0, 0, 10)


class TargetKeyTests(unittest.TestCase):
    def test_features_are_part_of_identity(self):
        plain = target_key({"targetType": "country", "country": "DE"})
        p2p = target_key({"targetType": "country", "country": "DE", "features": ["tor", "p2p"]})
        self.assertEqual(plain, "country:DE")
        self.assertEqual(p2p, "country:DE+p2p,tor")
        self.assertEqual(target_key({"targetType": "fastest", "features": ["p2p"]}), "fastest+p2p")
        self.assertEqual(target_key({"targetType": "fastest"}), "fastest")

    def test_avoid_current_never_saved_in_favorites(self):
        from profiles import ProfileStore
        with tempfile.TemporaryDirectory() as d:
            store = ProfileStore(os.path.join(d, "state.json"))
            store.toggle_favorite("P2P", {"targetType": "feature", "features": ["p2p"], "avoidCurrent": True})
            self.assertNotIn("avoidCurrent", store.favorites[0]["target"])


class ModifiedTimeTests(unittest.TestCase):
    def test_parses_http_date(self):
        try:
            import proton_client
        except Exception as exc:  # noqa: BLE001 - optional system dependency
            self.skipTest(f"proton_client unavailable: {exc}")
        self.assertEqual(proton_client._parse_modified("Tue, 24 Nov 2026 12:00:00 GMT"), 1795521600000)
        epoch = proton_client._parse_modified("Thu, 01 Jan 1970 00:00:00 GMT")
        self.assertGreater(epoch, 1795521600000 - 10**12)


if __name__ == "__main__":
    unittest.main()
