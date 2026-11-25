import os
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))

import split_tunnel  # noqa: E402
from protocol import ProtocolError  # noqa: E402


class SplitTunnelTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.bin = os.path.join(self.tmp.name, "myapp")
        with open(self.bin, "w") as fh:
            fh.write("#!/bin/sh\n")
        os.chmod(self.bin, stat.S_IRWXU)
        self.apps = os.path.join(self.tmp.name, "applications")
        os.makedirs(self.apps)

    def tearDown(self):
        self.tmp.cleanup()

    def write_desktop(self, name, body):
        with open(os.path.join(self.apps, name), "w") as fh:
            fh.write(body)

    def test_list_apps(self):
        self.write_desktop("a.desktop", f"[Desktop Entry]\nType=Application\nName=My App\nExec=env A=1 {self.bin} %U\n")
        self.write_desktop("hidden.desktop", f"[Desktop Entry]\nName=Hidden\nNoDisplay=true\nExec={self.bin}\n")
        self.write_desktop("broken.desktop", "[Desktop Entry]\nName=Broken\nExec=/does/not/exist\n")
        self.write_desktop("junk.desktop", "\x00garbage")
        apps = split_tunnel.list_apps(dirs=[self.apps])
        self.assertEqual([a["name"] for a in apps], ["My App"])
        self.assertEqual(apps[0]["binaryPath"], os.path.realpath(self.bin))
        self.assertEqual(split_tunnel.list_apps("nomatch", dirs=[self.apps]), [])

    def test_validate_app_path(self):
        self.assertEqual(split_tunnel.validate_app_path(self.bin), os.path.realpath(self.bin))
        for bad in ("", self.tmp.name, "/does/not/exist", "/bin/sh\x00", "a\nb"):
            with self.assertRaises(ProtocolError):
                split_tunnel.validate_app_path(bad)

    def test_validate_rules(self):
        apps, nets = split_tunnel.validate_rules([self.bin, self.bin], ["192.168.1.0/24", "10.0.0.1", "10.0.0.1"])
        self.assertEqual(apps, [os.path.realpath(self.bin)])
        self.assertEqual(nets, ["192.168.1.0/24", "10.0.0.1"])
        with self.assertRaises(ProtocolError):
            split_tunnel.validate_rules([], ["999.1.1.1"])
        with self.assertRaises(ProtocolError):
            split_tunnel.validate_rules([], ["10.0.0.1"] * 201)
        with self.assertRaises(ProtocolError):
            split_tunnel.validate_rules("x", [])


if __name__ == "__main__":
    unittest.main()
