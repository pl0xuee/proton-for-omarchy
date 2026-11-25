"""NDJSON wire protocol between omarchy-shell (Service.qml) and bridge.py.

Every message is one UTF-8 JSON object per line. This module owns framing,
size bounds, request validation, error serialization and secret redaction so
the rest of the bridge never touches raw untrusted text.
"""

from __future__ import annotations

import ipaddress
import json
import logging
import re
from typing import Any

MAX_IN_LINE = 64 * 1024
MAX_OUT_LINE = 2 * 1024 * 1024
MAX_STRING = 512

SECRET_KEYS = frozenset({"password", "code", "pin", "token", "private_key", "secret", "passphrase"})
REDACTED = "«redacted»"

COUNTRY_RE = re.compile(r"^[A-Z]{2}$")
SERVER_RE = re.compile(r"^[A-Za-z0-9#._-]{1,64}$")
CITY_RE = re.compile(r"^[^\x00-\x1f\x7f<>]{1,96}$")
PROFILE_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")

TARGET_TYPES = ("fastest", "random", "country", "city", "server", "secure_core", "profile", "feature")
FEATURES = ("all", "secure_core", "p2p", "tor", "streaming", "free")
SORTS = ("alpha", "fastest", "load")

COMMANDS = frozenset({
    "get_snapshot", "connect", "disconnect", "reconnect", "cancel_connect",
    "query_servers", "refresh_servers", "set_setting", "set_panel_open", "set_auto_refresh",
    "list_apps", "save_profile", "delete_profile", "toggle_favorite",
    "auth_login", "auth_2fa_totp", "auth_2fa_fido2_start", "auth_2fa_fido2_pin",
    "auth_2fa_fido2_cancel", "auth_logout", "auth_refresh_account",
    "diagnostics", "copy_clipboard", "ping", "claim_boot_autoconnect",
    "check_update", "dismiss_update", "clear_history", "set_history", "measure_latency",
})


class ProtocolError(Exception):
    """A request that must be rejected with a structured error reply."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


# --- redaction -------------------------------------------------------------

def redact(value: Any, depth: int = 0) -> Any:
    """Deep-copy `value` with every secret-named key replaced."""
    if depth > 8:
        return "…"
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            if isinstance(key, str) and key.lower() in SECRET_KEYS:
                out[key] = REDACTED
            else:
                out[key] = redact(item, depth + 1)
        return out
    if isinstance(value, (list, tuple)):
        return [redact(item, depth + 1) for item in value]
    return value


_SECRET_INLINE = re.compile(
    r"(?i)(\"?(?:password|passphrase|code|pin|token|private_key|secret)\"?\s*[:=]\s*)(\"[^\"]*\"|'[^']*'|\S+)"
)


def scrub_text(text: str) -> str:
    """Redact `key=value` / `"key": "value"` secret fragments inside free text."""
    return _SECRET_INLINE.sub(lambda m: m.group(1) + REDACTED, str(text))


class RedactingFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        try:
            message = record.getMessage()
        except Exception:  # noqa: BLE001 - a bad format string must not crash logging
            message = str(record.msg)
        record.msg = scrub_text(message)
        record.args = None
        return True


class _RedactingFormatter(logging.Formatter):
    """Tracebacks are formatted after filters run, so scrub them here too."""

    def formatException(self, ei) -> str:  # noqa: N802 - logging API name
        return scrub_text(super().formatException(ei))


def install_redacting_logger(level: int = logging.WARNING) -> logging.Logger:
    """Route all logging to stderr through the secret filter."""
    handler = logging.StreamHandler()
    handler.setFormatter(_RedactingFormatter("proton-for-omarchy: %(levelname)s %(name)s: %(message)s"))
    handler.addFilter(RedactingFilter())
    root = logging.getLogger()
    for existing in list(root.handlers):
        root.removeHandler(existing)
    root.addHandler(handler)
    root.setLevel(level)
    return logging.getLogger("proton-for-omarchy")


# --- framing ---------------------------------------------------------------

def parse_line(line: str | bytes) -> dict:
    """Parse one request line. Raises ProtocolError on anything malformed."""
    if isinstance(line, bytes):
        if len(line) > MAX_IN_LINE:
            raise ProtocolError("too_large", "Request exceeds 64 KB")
        try:
            line = line.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ProtocolError("bad_encoding", "Request is not UTF-8") from exc
    if len(line.encode("utf-8")) > MAX_IN_LINE:
        raise ProtocolError("too_large", "Request exceeds 64 KB")
    line = line.strip()
    if not line:
        raise ProtocolError("empty", "Empty request")
    try:
        msg = json.loads(line)
    except (ValueError, RecursionError) as exc:
        raise ProtocolError("bad_json", "Request is not valid JSON") from exc
    if not isinstance(msg, dict):
        raise ProtocolError("bad_request", "Request must be a JSON object")
    req_id = msg.get("id", "")
    if not isinstance(req_id, (str, int)) or not REQUEST_ID_RE.match(str(req_id)):
        raise ProtocolError("bad_id", "Request id is missing or invalid")
    cmd = msg.get("cmd")
    if not isinstance(cmd, str) or cmd not in COMMANDS:
        exc = ProtocolError("unknown_command", "Unknown command")
        exc.req_id = str(req_id)
        raise exc
    params = msg.get("params", {})
    if params is None:
        params = {}
    if not isinstance(params, dict):
        exc = ProtocolError("bad_params", "params must be an object")
        exc.req_id = str(req_id)
        raise exc
    return {"id": str(req_id), "cmd": cmd, "params": params}


def encode(message: dict) -> str:
    """Serialize one outgoing event; oversized payloads become an error event."""
    text = json.dumps(message, ensure_ascii=False, separators=(",", ":"), default=str)
    if len(text.encode("utf-8")) > MAX_OUT_LINE:
        fallback = {"type": message.get("type", "reply"), "ok": False,
                    "error": {"code": "too_large", "message": "Response exceeded 2 MB"}}
        if "id" in message:
            fallback["id"] = message["id"]
        text = json.dumps(fallback, separators=(",", ":"))
    return text + "\n"


def reply(req_id: str, data: Any = None) -> dict:
    return {"type": "reply", "id": req_id, "ok": True, "data": data}


def error_reply(req_id: str, code: str, message: str) -> dict:
    return {"type": "reply", "id": req_id, "ok": False,
            "error": {"code": str(code)[:64], "message": clean_text(scrub_text(message), 300)}}


def event(kind: str, data: Any) -> dict:
    return {"type": kind, "data": data}


# --- value validation ------------------------------------------------------

_CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")


def clean_text(value: Any, max_len: int = MAX_STRING) -> str:
    """Bounded, control-free text for anything leaving the bridge."""
    text = _CONTROL.sub("", str(value if value is not None else ""))
    text = text.replace("\n", " ").strip()
    if len(text) > max_len:
        text = text[: max_len - 1] + "…"
    return text


def get_str(params: dict, key: str, *, required: bool = False, max_len: int = MAX_STRING,
            default: str = "") -> str:
    value = params.get(key, None)
    if value is None or value == "":
        if required:
            raise ProtocolError("missing_param", f"Missing parameter '{key}'")
        return default
    if not isinstance(value, str):
        raise ProtocolError("bad_param", f"Parameter '{key}' must be a string")
    if len(value) > max_len or "\x00" in value:
        raise ProtocolError("bad_param", f"Parameter '{key}' is invalid")
    return value


def get_bool(params: dict, key: str, default: bool = False) -> bool:
    value = params.get(key, default)
    if not isinstance(value, bool):
        raise ProtocolError("bad_param", f"Parameter '{key}' must be a boolean")
    return value


def get_int(params: dict, key: str, default: int, lo: int, hi: int) -> int:
    value = params.get(key, default)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value != value \
            or value in (float("inf"), float("-inf")):
        raise ProtocolError("bad_param", f"Parameter '{key}' must be a number")
    return max(lo, min(hi, int(value)))


def get_choice(params: dict, key: str, choices: tuple, default: str) -> str:
    value = params.get(key, default)
    if value not in choices:
        raise ProtocolError("bad_param", f"Parameter '{key}' is not one of {', '.join(choices)}")
    return value


def country_code(value: Any, *, required: bool = True) -> str:
    if value in (None, "") and not required:
        return ""
    code = str(value or "").strip().upper()
    if code == "UK":
        code = "GB"
    if not COUNTRY_RE.match(code):
        raise ProtocolError("bad_country", "Invalid country code")
    return code


def server_name(value: Any) -> str:
    name = str(value or "").strip()
    if not SERVER_RE.match(name):
        raise ProtocolError("bad_server", "Invalid server name")
    return name


def city_name(value: Any, *, required: bool = True) -> str:
    if value in (None, "") and not required:
        return ""
    city = str(value or "").strip()
    if not CITY_RE.match(city):
        raise ProtocolError("bad_city", "Invalid city name")
    return city


def ip_address(value: Any) -> str:
    """A DNS server address: a plain, routable-looking unicast IP."""
    text = str(value or "").strip()
    try:
        if "%" in text:  # scoped IPv6 ("fe80::1%eth0") is not a portable DNS server
            raise ValueError(text)
        addr = ipaddress.ip_address(text)
    except ValueError as exc:
        raise ProtocolError("bad_ip", "Invalid IP address") from exc
    if addr.is_unspecified or addr.is_multicast or addr.is_loopback:
        raise ProtocolError("bad_ip", "That address cannot be used as a DNS server")
    return str(addr)


def ip_network(value: Any) -> str:
    text = str(value or "").strip()
    if not text or len(text) > 64 or "\x00" in text or "%" in text:
        raise ProtocolError("bad_ip", "Invalid IP address or subnet")
    try:
        if "/" in text:
            net = ipaddress.ip_network(text, strict=False)
            if net.prefixlen == 0:
                raise ProtocolError("bad_ip", "A /0 range would cover every address")
            return str(net)
        return str(ipaddress.ip_address(text))
    except ValueError as exc:
        raise ProtocolError("bad_ip", "Invalid IP address or subnet") from exc


def features_list(value: Any) -> list[str]:
    if value in (None, ""):
        return []
    if not isinstance(value, list) or len(value) > 5:
        raise ProtocolError("bad_param", "features must be a short list")
    out = []
    for item in value:
        if item not in ("p2p", "tor", "streaming", "secure_core"):
            raise ProtocolError("bad_param", "Unknown feature")
        if item not in out:
            out.append(item)
    return out


def connect_target(params: dict) -> dict:
    """Validate a connect request into a normalized target description."""
    kind = get_choice(params, "targetType", TARGET_TYPES, "fastest")
    target: dict = {"targetType": kind, "features": features_list(params.get("features"))}
    if kind in ("country", "city", "secure_core"):
        target["country"] = country_code(params.get("country"))
    if kind == "city":
        target["city"] = city_name(params.get("city"))
    if kind == "secure_core":
        target["entryCountry"] = country_code(params.get("entryCountry"), required=False)
    if kind == "server":
        target["serverName"] = server_name(params.get("serverName"))
    if kind == "profile":
        pid = str(params.get("profileId") or "")
        if not PROFILE_ID_RE.match(pid):
            raise ProtocolError("bad_param", "Invalid profile id")
        target["profileId"] = pid
    if kind == "feature" and not target["features"]:
        raise ProtocolError("bad_param", "A feature connection needs a feature")
    if kind in ("fastest", "random", "feature") and get_bool(params, "avoidCurrent"):
        target["avoidCurrent"] = True  # "switch to a better server": skip the one in use
    return target
