"""Settings reads and writes against the installed Proton VPN library.

proton-vpn-api-core 6.x replaced split tunneling's config_by_mode dict with
fixed exclude/include groups, made settings groups read-only slots and dropped
Settings.default(). These tests drive the plugin's own code paths on real
library objects (nothing is saved). Skipped when the library is not installed.
"""
import asyncio
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))

from profiles import ProfileStore  # noqa: E402
from proton_client import ProtonClient  # noqa: E402

try:
    from proton.vpn.core.settings import (CustomDNSEntry, NetShield, Settings,  # noqa: E402
                                          SplitTunnelingConfig, SplitTunnelingMode)
    from proton.vpn.core.settings.custom_dns import CustomDNS  # noqa: E402
except Exception:  # noqa: BLE001 - library missing on CI
    Settings = None

SAVED = {
    "protocol": "wireguard", "killswitch": 0,
    "custom_dns": {"enabled": True, "ip_list": [{"ip": "9.9.9.9", "enabled": True}]},
    "features": {"netshield": 1, "split_tunneling": {
        "enabled": False, "mode": "exclude",
        "config_by_mode": {"exclude": {"mode": "exclude", "app_paths": ["/usr/bin/foo"],
                                       "ip_ranges": ["10.0.0.0/8"]}}}},
}


class FakeConnector:
    is_connection_active = False
    is_connected = False
    is_split_tunneling_available = True

    def iter_available_protocols(self, group):
        return []


class FakeApi:
    user_tier = 2

    def __init__(self, data):
        self.data = data
        self.saved = None

    def is_user_logged_in(self):
        return True

    async def load_settings(self):
        s = Settings.from_dict(self.data)
        if hasattr(s, "set_defaults"):
            s.set_defaults(self.user_tier, False)
        return s

    async def save_settings(self, settings):
        self.saved = settings
        self.data = settings.to_dict()  # like the library: the next load reads what was saved


@unittest.skipIf(Settings is None, "Proton VPN library not installed")
class SettingsCompatTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        store = ProfileStore(os.path.join(self.tmp.name, "state.json"))
        self.client = ProtonClient(lambda t, d: None, store)
        self.client.api = FakeApi(SAVED)
        self.client.connector = FakeConnector()
        self.client.mods = {"CustomDNSEntry": CustomDNSEntry, "CustomDNS": CustomDNS, "NetShield": NetShield,
                            "SplitTunnelingConfig": SplitTunnelingConfig, "SplitTunnelingMode": SplitTunnelingMode}

    def tearDown(self):
        self.tmp.cleanup()

    def run_async(self, coro):
        return asyncio.run(coro)

    def test_reads_saved_settings(self):
        d = self.client._settings_dict(self.run_async(self.client.api.load_settings()))
        self.assertEqual(d["splitTunneling"]["exclude"], {"apps": ["/usr/bin/foo"], "ips": ["10.0.0.0/8"]})
        self.assertEqual(d["splitTunneling"]["include"], {"apps": [], "ips": []})
        self.assertEqual(d["customDns"]["ips"], [{"ip": "9.9.9.9", "enabled": True}])
        self.assertEqual(d["netshield"], 1)

    def test_split_tunneling_write(self):
        self.run_async(self.client.set_setting(
            "split_tunneling", {"enabled": True, "mode": "include", "apps": [], "ips": ["192.168.0.0/16"]},
            False, False))
        saved = self.client._settings_dict(self.client.api.saved)
        self.assertTrue(saved["splitTunneling"]["enabled"])
        self.assertEqual(saved["splitTunneling"]["mode"], "include")
        self.assertEqual(saved["splitTunneling"]["include"]["ips"], ["192.168.0.0/16"])
        self.assertEqual(saved["splitTunneling"]["exclude"]["apps"], ["/usr/bin/foo"])  # other mode kept
        # It must also survive the library's own round trip to disk.
        again = Settings.from_dict(self.client.api.saved.to_dict())
        self.assertEqual(self.client._settings_dict(again)["splitTunneling"], saved["splitTunneling"])

    def test_custom_dns_write(self):
        self.run_async(self.client.set_setting(
            "custom_dns", {"enabled": True, "ips": [{"ip": "1.1.1.1"}, {"ip": "2606:4700::1111", "enabled": False}]},
            False, False))
        dns = self.client._settings_dict(self.client.api.saved)["customDns"]
        self.assertEqual(dns, {"enabled": True, "ips": [{"ip": "1.1.1.1", "enabled": True},
                                                         {"ip": "2606:4700::1111", "enabled": False}]})
        again = Settings.from_dict(self.client.api.saved.to_dict())
        self.assertEqual(self.client._settings_dict(again)["customDns"], dns)

    def test_recommended_keeps_rules_but_switches_them_off(self):
        self.run_async(self.client.set_setting("recommended", None, False, False))
        d = self.client._settings_dict(self.client.api.saved)
        self.assertFalse(d["customDns"]["enabled"])
        self.assertEqual(d["customDns"]["ips"], [{"ip": "9.9.9.9", "enabled": True}])
        self.assertFalse(d["splitTunneling"]["enabled"])
        self.assertEqual(d["splitTunneling"]["exclude"]["apps"], ["/usr/bin/foo"])

    def test_netshield_and_bool_writes(self):
        self.run_async(self.client.set_setting("netshield", 2, False, False))
        self.run_async(self.client.set_setting("ipv6", False, False, False))
        d = self.client._settings_dict(self.run_async(self.client.api.load_settings()))
        self.assertEqual((d["netshield"], d["ipv6"]), (2, False))


if __name__ == "__main__":
    unittest.main()
