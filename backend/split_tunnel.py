"""Split Tunneling helpers: installed-app discovery and rule validation."""

from __future__ import annotations

import configparser
import os
import shlex
import shutil

from protocol import ProtocolError, clean_text, ip_network

MAX_RULES = 200
MAX_APPS_RESULT = 60


def application_dirs() -> list[str]:
    home = os.path.expanduser("~")
    data_home = os.environ.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share")
    data_dirs = (os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":")
    dirs = [os.path.join(data_home, "applications")]
    dirs += [os.path.join(d, "applications") for d in data_dirs if d]
    dirs.append("/var/lib/flatpak/exports/share/applications")
    out = []
    for d in dirs:
        if d not in out and os.path.isdir(d):
            out.append(d)
    return out


def resolve_exec(exec_line: str) -> str:
    """Resolve the first token of a desktop Exec= line to a real binary path."""
    if not exec_line or "\x00" in exec_line:
        return ""
    try:
        tokens = shlex.split(exec_line)
    except ValueError:
        return ""
    # Skip env assignments like `env FOO=1 app` / `FOO=1 app`.
    while tokens and (tokens[0] == "env" or ("=" in tokens[0] and not tokens[0].startswith("/"))):
        tokens.pop(0)
    if not tokens:
        return ""
    first = tokens[0]
    if first.startswith("%"):
        return ""
    path = first if os.path.isabs(first) else (shutil.which(first) or "")
    if not path:
        return ""
    real = os.path.realpath(path)
    if os.path.isfile(real) and os.access(real, os.X_OK):
        return real
    return ""


def parse_desktop_file(path: str) -> dict | None:
    parser = configparser.RawConfigParser(strict=False, interpolation=None)
    parser.optionxform = str  # keep key case
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            parser.read_file(fh)
    except (OSError, configparser.Error):
        return None
    if not parser.has_section("Desktop Entry"):
        return None
    entry = parser["Desktop Entry"]
    if entry.get("Type", "Application") != "Application":
        return None
    if entry.get("NoDisplay", "false").lower() == "true" or entry.get("Hidden", "false").lower() == "true":
        return None
    binary = resolve_exec(entry.get("TryExec", "") or "") or resolve_exec(entry.get("Exec", "") or "")
    if not binary:
        return None
    name = clean_text(entry.get("Name", "") or os.path.basename(binary), 80)
    return {"name": name, "icon": clean_text(entry.get("Icon", ""), 120), "binaryPath": binary}


def list_apps(query: str = "", dirs: list[str] | None = None) -> list[dict]:
    query = (query or "").strip().lower()
    seen: dict[str, dict] = {}
    for directory in dirs if dirs is not None else application_dirs():
        try:
            names = sorted(os.listdir(directory))
        except OSError:
            continue
        for name in names:
            if not name.endswith(".desktop"):
                continue
            app = parse_desktop_file(os.path.join(directory, name))
            if not app or app["binaryPath"] in seen:
                continue
            if query and query not in app["name"].lower() and query not in app["binaryPath"].lower():
                continue
            seen[app["binaryPath"]] = app
    apps = sorted(seen.values(), key=lambda a: a["name"].lower())
    return apps[:MAX_APPS_RESULT]


def validate_app_path(value: object) -> str:
    text = str(value or "").strip()
    if not text or len(text) > 4096 or "\x00" in text or "\n" in text:
        raise ProtocolError("bad_app", "Invalid application path")
    if not os.path.isabs(text):
        # No PATH lookup: a user-writable PATH entry could shadow a real app.
        raise ProtocolError("bad_app", "Application path must be absolute")
    real = os.path.realpath(text)
    if not os.path.isfile(real) or not os.access(real, os.X_OK):
        raise ProtocolError("bad_app", "Not an executable file")
    return real


def validate_rules(app_paths: object, ip_ranges: object, trusted: object = ()) -> tuple[list[str], list[str]]:
    """`trusted` holds paths already stored in Proton's settings; they are kept
    verbatim so an uninstalled app does not block unrelated edits."""
    if app_paths is None:
        app_paths = []
    if ip_ranges is None:
        ip_ranges = []
    if not isinstance(app_paths, list) or not isinstance(ip_ranges, list):
        raise ProtocolError("bad_param", "Rules must be lists")
    if len(app_paths) + len(ip_ranges) > MAX_RULES:
        raise ProtocolError("limit", "Too many split tunneling rules (max 200)")
    apps: list[str] = []
    for path in app_paths:
        if isinstance(path, str) and path in trusted:
            # Already stored: keep it even if the app is gone, but only if well formed.
            if not os.path.isabs(path) or "\x00" in path or "\n" in path or len(path) > 4096:
                continue
            real = path
        else:
            real = validate_app_path(path)
        if real not in apps:
            apps.append(real)
    nets: list[str] = []
    for item in ip_ranges:
        net = ip_network(item)
        if net not in nets:
            nets.append(net)
    return apps, nets
