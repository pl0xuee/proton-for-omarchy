"""Check GitHub for a newer release of this plugin.

One HTTPS request to the GitHub releases API for the repository named in
manifest.json's homepage. Only the release tag is read; release notes and
other text are never shown. Nothing about the user or the VPN is sent.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import urllib.request

from protocol import ProtocolError

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERSION_RE = re.compile(r"^v?(\d{1,4})\.(\d{1,4})\.(\d{1,4})$")
HOMEPAGE_RE = re.compile(r"^https://github\.com/([A-Za-z0-9-]{1,39})/([A-Za-z0-9._-]{1,100})/?$")
MAX_BYTES = 256 * 1024
TIMEOUT = 10


def parse_version(value: object) -> tuple[int, int, int] | None:
    match = VERSION_RE.match(str(value or "").strip())
    return tuple(int(part) for part in match.groups()) if match else None  # type: ignore[return-value]


def _manifest(root: str = ROOT) -> dict:
    try:
        with open(os.path.join(root, "manifest.json"), encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def plugin_version(root: str = ROOT) -> str:
    """Installed version from manifest.json, "" if missing or malformed."""
    current = parse_version(_manifest(root).get("version"))
    return ".".join(map(str, current)) if current else ""


def releases_url(homepage: object) -> str:
    match = HOMEPAGE_RE.match(str(homepage or ""))
    if not match or match.group(2) in (".", ".."):
        return ""
    return f"https://api.github.com/repos/{match.group(1)}/{match.group(2)}/releases/latest"


def latest_tag(body: bytes) -> str:
    """The newest stable version in a releases/latest response, or ""."""
    data = json.loads(body.decode("utf-8"))
    if not isinstance(data, dict) or data.get("draft") or data.get("prerelease"):
        return ""
    version = parse_version(data.get("tag_name"))
    return ".".join(map(str, version)) if version else ""


def _fetch(url: str) -> str:
    request = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "proton-for-omarchy-update-check",
    })
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:  # noqa: S310 - fixed https URL
        body = response.read(MAX_BYTES + 1)
    if len(body) > MAX_BYTES:
        raise ValueError("response too large")
    return latest_tag(body)


async def check(dismissed: str = "", root: str = ROOT) -> dict:
    manifest = _manifest(root)
    current = parse_version(manifest.get("version"))
    url = releases_url(manifest.get("homepage"))
    if not current or not url:
        raise ProtocolError("update_check_failed", "This install has no release source")
    try:
        latest = await asyncio.get_running_loop().run_in_executor(None, _fetch, url)
    except Exception as exc:  # noqa: BLE001 - offline, blocked by Kill Switch, rate limited
        raise ProtocolError("update_check_failed", "Could not check for updates") from exc
    newer = bool(latest) and parse_version(latest) > current
    return {
        "current": ".".join(map(str, current)),
        "latest": latest if newer else "",
        "available": newer,
        "dismissed": newer and latest == dismissed,
        # `omarchy plugin update` only works on git checkouts (`omarchy plugin add`).
        "gitInstall": os.path.isdir(os.path.join(root, ".git")),
    }
