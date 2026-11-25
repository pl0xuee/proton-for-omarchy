import json
import logging
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))

import protocol  # noqa: E402
from protocol import ProtocolError  # noqa: E402


class ParseLineTests(unittest.TestCase):
    def test_valid_request(self):
        msg = protocol.parse_line('{"id":"7","cmd":"connect","params":{"targetType":"fastest"}}')
        self.assertEqual(msg, {"id": "7", "cmd": "connect", "params": {"targetType": "fastest"}})

    def test_missing_params_defaults_to_empty(self):
        self.assertEqual(protocol.parse_line('{"id":1,"cmd":"ping"}')["params"], {})

    def test_rejects_garbage(self):
        for line in ["", "not json", "[1,2]", '{"cmd":"ping"}', '{"id":"a b","cmd":"ping"}',
                     '{"id":"1","cmd":"rm -rf"}', '{"id":"1","cmd":"ping","params":[]}']:
            with self.assertRaises(ProtocolError, msg=line):
                protocol.parse_line(line)

    def test_rejects_oversized(self):
        big = '{"id":"1","cmd":"ping","params":{"x":"' + "a" * (70 * 1024) + '"}}'
        with self.assertRaises(ProtocolError) as ctx:
            protocol.parse_line(big)
        self.assertEqual(ctx.exception.code, "too_large")

    def test_rejects_bad_utf8(self):
        with self.assertRaises(ProtocolError):
            protocol.parse_line(b'{"id":"1","cmd":"ping","x":"\xff"}')

    def test_deep_nesting_does_not_crash(self):
        with self.assertRaises(ProtocolError):
            protocol.parse_line("[" * 100000)


class EncodeTests(unittest.TestCase):
    def test_single_line(self):
        out = protocol.encode(protocol.event("state", {"text": "a\nb"}))
        self.assertTrue(out.endswith("\n"))
        self.assertEqual(out.count("\n"), 1)
        self.assertEqual(json.loads(out)["data"]["text"], "a\nb")

    def test_oversized_output_becomes_error(self):
        out = json.loads(protocol.encode({"type": "reply", "id": "1", "data": "x" * (3 * 1024 * 1024)}))
        self.assertFalse(out["ok"])
        self.assertEqual(out["id"], "1")


class RedactionTests(unittest.TestCase):
    def test_redact_nested(self):
        data = {"username": "me", "password": "hunter2", "nested": [{"PIN": "1234", "code": "999999"}]}
        red = protocol.redact(data)
        self.assertEqual(red["username"], "me")
        self.assertNotIn("hunter2", json.dumps(red))
        self.assertNotIn("1234", json.dumps(red))
        self.assertNotIn("999999", json.dumps(red))

    def test_scrub_text(self):
        text = protocol.scrub_text('failed {"password": "hunter2", "pin": 4321} token=abc')
        for secret in ("hunter2", "4321", "abc"):
            self.assertNotIn(secret, text)

    def test_logger_filter(self):
        record = logging.LogRecord("x", logging.WARNING, __file__, 1, "login password=%s", ("hunter2",), None)
        protocol.RedactingFilter().filter(record)
        self.assertNotIn("hunter2", record.getMessage())

    def test_error_reply_is_clean(self):
        r = protocol.error_reply("1", "x", "line1\nline2\x07" + "y" * 1000)
        self.assertNotIn("\n", r["error"]["message"])
        self.assertLessEqual(len(r["error"]["message"]), 300)


class ValidationTests(unittest.TestCase):
    def test_country(self):
        self.assertEqual(protocol.country_code("ch"), "CH")
        self.assertEqual(protocol.country_code("uk"), "GB")
        for bad in ("", "CHE", "1A", "C;"):
            with self.assertRaises(ProtocolError):
                protocol.country_code(bad)

    def test_server(self):
        self.assertEqual(protocol.server_name("US-NY#42"), "US-NY#42")
        for bad in ("", "a b", "x" * 65, "US;rm"):
            with self.assertRaises(ProtocolError):
                protocol.server_name(bad)

    def test_ip(self):
        self.assertEqual(protocol.ip_address("1.1.1.1"), "1.1.1.1")
        self.assertEqual(protocol.ip_network("10.0.0.5/8"), "10.0.0.0/8")
        self.assertEqual(protocol.ip_network("2001:db8::1"), "2001:db8::1")
        for bad in ("1.1.1", "abc", "1.1.1.1/40", ""):
            with self.assertRaises(ProtocolError):
                protocol.ip_network(bad)

    def test_connect_target(self):
        t = protocol.connect_target({"targetType": "secure_core", "country": "ch", "entryCountry": "is"})
        self.assertEqual(t, {"targetType": "secure_core", "features": [], "country": "CH", "entryCountry": "IS"})
        with self.assertRaises(ProtocolError):
            protocol.connect_target({"targetType": "nope"})
        with self.assertRaises(ProtocolError):
            protocol.connect_target({"targetType": "feature"})
        with self.assertRaises(ProtocolError):
            protocol.connect_target({"targetType": "fastest", "features": ["evil"]})

    def test_get_helpers(self):
        self.assertEqual(protocol.get_int({"n": 5000}, "n", 1, 1, 300), 300)
        with self.assertRaises(ProtocolError):
            protocol.get_bool({"b": "yes"}, "b")
        with self.assertRaises(ProtocolError):
            protocol.get_str({"s": 5}, "s")


if __name__ == "__main__":
    unittest.main()
