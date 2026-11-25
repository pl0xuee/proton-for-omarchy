import json
import logging
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))

import protocol  # noqa: E402
import split_tunnel  # noqa: E402
from profiles import ProfileStore  # noqa: E402


class StateFileTests(unittest.TestCase):
    def test_non_finite_timestamp_does_not_crash(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "state.json")
            with open(path, "w") as fh:
                fh.write('{"favorites":[{"target":{"targetType":"country","country":"DE"},"ts":Infinity},'
                         '{"target":{"targetType":"country","country":"CH"},"ts":NaN}]}')
            store = ProfileStore(path)
            self.assertEqual([f["ts"] for f in store.favorites], [0, 0])

    def test_failed_save_keeps_memory_in_sync(self):
        with tempfile.TemporaryDirectory() as d:
            store = ProfileStore(os.path.join(d, "missing", "state.json"))
            os.chmod(d, 0o500)
            try:
                with self.assertRaises(protocol.ProtocolError) as ctx:
                    store.toggle_favorite("DE", {"targetType": "country", "country": "DE"})
                self.assertEqual(ctx.exception.code, "save_failed")
                self.assertNotIn(d, ctx.exception.message)
                self.assertEqual(store.favorites, [])
            finally:
                os.chmod(d, 0o700)

    def test_oversized_state_is_quarantined(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "state.json")
            with open(path, "w") as fh:
                json.dump({"favorites": [], "pad": "x" * (2 << 20)}, fh)
            store = ProfileStore(path)
            self.assertEqual(store.favorites, [])
            self.assertTrue(os.path.exists(path + ".corrupt"))


class AddressTests(unittest.TestCase):
    def test_dns_rejects_scoped_loopback_multicast_unspecified(self):
        for bad in ("fe80::1%eth0", "127.0.0.1", "::1", "0.0.0.0", "224.0.0.1"):
            with self.assertRaises(protocol.ProtocolError, msg=bad):
                protocol.ip_address(bad)
        self.assertEqual(protocol.ip_address("9.9.9.9"), "9.9.9.9")

    def test_split_range_rejects_catch_all(self):
        for bad in ("0.0.0.0/0", "::/0", "fe80::1%eth0"):
            with self.assertRaises(protocol.ProtocolError, msg=bad):
                protocol.ip_network(bad)
        self.assertEqual(protocol.ip_network("10.0.0.0/8"), "10.0.0.0/8")

    def test_app_paths_must_be_absolute(self):
        with self.assertRaises(protocol.ProtocolError):
            split_tunnel.validate_app_path("ls")

    def test_malformed_trusted_paths_are_dropped(self):
        apps, _ = split_tunnel.validate_rules(["relative/app", "/gone/app"], [],
                                              trusted=("relative/app", "/gone/app"))
        self.assertEqual(apps, ["/gone/app"])


class RedactionTests(unittest.TestCase):
    def test_error_reply_scrubs_secrets(self):
        reply = protocol.error_reply("1", "auth_failed", 'bad request {"password": "hunter2"}')
        self.assertNotIn("hunter2", reply["error"]["message"])

    def test_tracebacks_are_scrubbed(self):
        fmt = protocol._RedactingFormatter("%(message)s")
        try:
            raise RuntimeError("password=hunter2")
        except RuntimeError:
            record = logging.LogRecord("x", logging.ERROR, __file__, 1, "boom", None, sys.exc_info())
        self.assertNotIn("hunter2", fmt.format(record))


if __name__ == "__main__":
    unittest.main()
