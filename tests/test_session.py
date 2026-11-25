import asyncio
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))

from profiles import ProfileStore  # noqa: E402
from proton_client import ProtonClient  # noqa: E402
from protocol import ProtocolError  # noqa: E402


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.events = []
        self.store = ProfileStore(os.path.join(self.tmp.name, "state.json"))
        self.client = ProtonClient(lambda t, d: self.events.append((t, d)), self.store)

    def tearDown(self):
        self.tmp.cleanup()

    def test_current_target_falls_back_to_server(self):
        server = {"name": "CH#12", "country": "CH"}
        self.assertEqual(self.client._current_target(server)["target"]["serverName"], "CH#12")
        self.client.last_target = {"target": {"targetType": "country", "country": "CH", "features": []},
                                   "server": "CH#12"}
        self.assertEqual(self.client._current_target(server)["target"]["targetType"], "country")
        # Connected elsewhere (another server): the remembered target is stale.
        self.assertEqual(self.client._current_target({"name": "SE#3", "country": "SE"})["target"],
                         {"targetType": "server", "serverName": "SE#3", "features": []})
        self.client.last_target = {"target": {"targetType": "fastest", "features": [], "avoidCurrent": True},
                                   "server": "CH#12"}
        self.assertNotIn("avoidCurrent", self.client._current_target(server)["target"])

    def test_session_recorded_unless_disabled(self):
        self.client._start_session({"name": "CH#12", "country": "CH"}, {"label": "Zurich"})
        self.client._finish_session()
        self.assertEqual(self.store.history[0]["server"], "CH#12")
        self.assertEqual(self.store.history[0]["label"], "Zurich")
        self.client.set_history_enabled(False)
        self.assertEqual(self.store.history, [])
        self.client._start_session({"name": "CH#13", "country": "CH"}, None)
        self.client._finish_session()
        self.assertEqual(self.store.history, [])

    def test_session_marker_round_trip(self):
        import proton_client
        old = os.environ.get("XDG_RUNTIME_DIR")
        os.environ["XDG_RUNTIME_DIR"] = self.tmp.name
        try:
            proton_client._write_session_marker("CH#12", 1_700_000_000_000)
            path = os.path.join(self.tmp.name, proton_client.SESSION_MARKER)
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            self.assertEqual(proton_client._read_session_marker("CH#12"), 1_700_000_000_000)
            self.assertEqual(proton_client._read_session_marker("SE#1"), 0)  # another server
            with open(path, "w") as fh:
                fh.write("[1, 2]")
            self.assertEqual(proton_client._read_session_marker("CH#12"), 0)
            proton_client._write_session_marker("", 0)
            self.assertFalse(os.path.exists(path))
        finally:
            if old is None:
                os.environ.pop("XDG_RUNTIME_DIR", None)
            else:
                os.environ["XDG_RUNTIME_DIR"] = old

    def test_smaller_counters_never_replace_session_totals(self):
        import proton_client
        self.client._session = {"server": "CH#1", "rx": 5_000, "tx": 900, "iface": "proton0"}
        original = proton_client.read_totals
        proton_client.read_totals = lambda iface: (12, 3)  # a fresh tunnel took the name
        try:
            self.client._read_session_bytes()
        finally:
            proton_client.read_totals = original
        self.assertEqual((self.client._session["rx"], self.client._session["tx"]), (5_000, 900))

    def test_latency_requires_login(self):
        with self.assertRaises(ProtocolError):
            asyncio.run(self.client.measure_latency(["CH#1"]))


if __name__ == "__main__":
    unittest.main()
