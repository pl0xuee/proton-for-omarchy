"""Favorites, recents and custom connection profiles.

Stored in one small private JSON file written atomically (mkstemp in the same
directory -> 0600 -> fsync -> os.replace) so a crash or power loss can never
leave a half-written file, and other users can never read location history.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import tempfile
import time
from typing import Any

from protocol import ProtocolError, clean_text, connect_target

MAX_FAVORITES = 50
MAX_RECENTS = 5
MAX_HISTORY = 30
MAX_STATE_BYTES = 1 << 20
_VERSION_RE = re.compile(r"^\d{1,4}\.\d{1,4}\.\d{1,4}$")
_COUNTRY_RE = re.compile(r"^[A-Z]{2}$")


def _safe_ts(value: Any) -> int:
    """A sane unix timestamp or 0; tolerates NaN/Infinity from a tampered file."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0
    if value != value or not 0 <= value < 2 ** 40:
        return 0
    return int(value)


def _safe_bytes(value: Any) -> int:
    """A sane byte count or 0 (up to 2**53, so it stays exact in JSON and QML)."""
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value != value:
        return 0
    return int(value) if 0 <= value <= 2 ** 53 else 0


STATE_VERSION = 1


def default_state_path() -> str:
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    path = os.path.join(base, "omarchy", "proton-for-omarchy-state.json")
    legacy = os.path.join(base, "omarchy", "protonarchy-state.json")  # name before 1.0 release
    try:
        if not os.path.lexists(path) and os.path.isfile(legacy) and not os.path.islink(legacy):
            os.replace(legacy, path)
    except OSError:
        pass
    return path


def target_key(target: dict) -> str:
    """Stable identity of a connection target, used to dedupe favorites/recents."""
    kind = target.get("targetType", "fastest")
    feats = sorted(target.get("features") or [])
    if feats and kind in ("country", "city", "server", "secure_core", "fastest", "random"):
        return target_key({**target, "features": []}) + "+" + ",".join(feats)
    if kind == "country":
        return "country:" + target.get("country", "")
    if kind == "city":
        return "city:" + target.get("country", "") + ":" + target.get("city", "")
    if kind == "server":
        return "server:" + target.get("serverName", "")
    if kind == "secure_core":
        return "sc:" + target.get("entryCountry", "") + ":" + target.get("country", "")
    if kind == "feature":
        return "feature:" + ",".join(sorted(target.get("features") or []))
    if kind == "profile":
        return "profile:" + target.get("profileId", "")
    return kind


def key_to_id(key: str) -> str:
    return hashlib.sha1(key.encode("utf-8")).hexdigest()[:16]


class ProfileStore:
    def __init__(self, path: str | None = None):
        self.path = path or default_state_path()
        self.favorites: list[dict] = []
        self.recents: list[dict] = []
        self.dismissed_update = ""
        self.load()

    # --- persistence -------------------------------------------------------

    def load(self) -> None:
        try:
            info = os.stat(self.path)
            if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_STATE_BYTES:
                raise ValueError("not a small regular file")
            with open(self.path, "r", encoding="utf-8") as fh:
                raw = json.load(fh)
        except FileNotFoundError:
            raw = {}
        except (ValueError, RecursionError):
            # Corrupt: keep a copy for the user, start clean.
            try:
                os.replace(self.path, self.path + ".corrupt")
            except OSError:
                pass
            raw = {}
        except OSError:
            # Unreadable right now (permissions, I/O): leave the file alone.
            raw = {}
        if not isinstance(raw, dict):
            raw = {}
        self.favorites = self._sanitize_list(raw.get("favorites"), MAX_FAVORITES)
        self.recents = self._sanitize_list(raw.get("recents"), MAX_RECENTS)
        dismissed = raw.get("dismissedUpdate")
        self.dismissed_update = dismissed if isinstance(dismissed, str) and _VERSION_RE.match(dismissed) else ""
        self.history = self._sanitize_history(raw.get("history"))

    @staticmethod
    def _history_entry(item: Any) -> dict | None:
        if not isinstance(item, dict):
            return None
        start, end = _safe_ts(item.get("start")), _safe_ts(item.get("end"))
        server = clean_text(item.get("server") or "", 64)
        if not start or end < start or not server:
            return None
        country = str(item.get("country") or "")
        return {
            "server": server,
            "label": clean_text(item.get("label") or server, 96),
            "country": country if _COUNTRY_RE.match(country) else "",
            "start": start,
            "end": end,
            "rx": _safe_bytes(item.get("rx")),
            "tx": _safe_bytes(item.get("tx")),
        }

    def _sanitize_history(self, items: Any) -> list[dict]:
        if not isinstance(items, list):
            return []
        out = [e for e in (self._history_entry(i) for i in items[:MAX_HISTORY]) if e]
        return out[:MAX_HISTORY]

    def _sanitize_list(self, items: Any, limit: int) -> list[dict]:
        out: list[dict] = []
        if not isinstance(items, list):
            return out
        seen = set()
        for item in items:
            if not isinstance(item, dict):
                continue
            try:
                target = connect_target(item.get("target") or {})
            except Exception:  # noqa: BLE001 - any malformed entry is dropped, never fatal
                continue
            target.pop("avoidCurrent", None)
            if target["targetType"] == "profile":
                continue
            key = target_key(target)
            if key in seen:
                continue
            seen.add(key)
            out.append({
                "id": key_to_id(key),
                "key": key,
                "label": clean_text(item.get("label") or key, 80),
                "detail": clean_text(item.get("detail") or "", 120),
                "target": target,
                "ts": _safe_ts(item.get("ts")),
            })
            if len(out) >= limit:
                break
        return out

    def save(self) -> None:
        try:
            self._write()
        except OSError as exc:
            # Never surface the OSError text: it carries the home directory path.
            raise ProtocolError("save_failed", "Could not save favorites") from exc

    def _commit(self, favorites: list[dict]) -> None:
        """Persist first, then adopt, so a failed write leaves memory and disk in sync."""
        previous = self.favorites
        self.favorites = favorites
        try:
            self.save()
        except ProtocolError:
            self.favorites = previous
            raise

    def _write(self) -> None:
        directory = os.path.dirname(self.path)
        os.makedirs(directory, mode=0o700, exist_ok=True)
        payload = json.dumps({"version": STATE_VERSION, "favorites": self.favorites,
                              "recents": self.recents, "dismissedUpdate": self.dismissed_update,
                              "history": self.history},
                             indent=1, ensure_ascii=False)
        fd, tmp = tempfile.mkstemp(prefix=".proton-for-omarchy-", suffix=".tmp", dir=directory)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(payload)
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, self.path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    # --- operations --------------------------------------------------------

    def snapshot(self) -> dict:
        return {"favorites": list(self.favorites), "recents": list(self.recents),
                "history": list(self.history)}

    def is_favorite(self, key: str) -> bool:
        return any(f["key"] == key for f in self.favorites)

    def toggle_favorite(self, label: str, target_params: dict, detail: str = "") -> bool:
        target = connect_target(target_params)
        target.pop("avoidCurrent", None)  # a one-off switch hint, never part of a saved target
        if target["targetType"] == "profile":
            raise ProtocolError("bad_param", "Cannot pin a profile reference")
        key = target_key(target)
        for i, fav in enumerate(self.favorites):
            if fav["key"] == key:
                self._commit(self.favorites[:i] + self.favorites[i + 1:])
                return False
        if len(self.favorites) >= MAX_FAVORITES:
            raise ProtocolError("limit", "Favorites are full (50)")
        self._commit(self.favorites + [{"id": key_to_id(key), "key": key, "label": clean_text(label or key, 80),
                                        "detail": clean_text(detail, 120), "target": target,
                                        "ts": int(time.time())}])
        return True

    def save_profile(self, profile: dict, describe=None) -> dict:
        """Save a named profile. `describe(target)` gives the "what it connects to"
        line shown under the name, so it stays right after a rename."""
        if not isinstance(profile, dict):
            raise ProtocolError("bad_param", "profile must be an object")
        target = connect_target(profile.get("target") or {})
        target.pop("avoidCurrent", None)
        if target["targetType"] == "profile":
            raise ProtocolError("bad_param", "Cannot nest profiles")
        name = clean_text(profile.get("name") or "", 80)
        if not name:
            raise ProtocolError("missing_param", "Profile needs a name")
        key = target_key(target)
        detail = describe(target) if callable(describe) else profile.get("detail")
        entry = {"id": key_to_id(key), "key": key, "label": name,
                 "detail": clean_text(detail or "", 120), "target": target, "ts": int(time.time())}
        # Replace the profile being edited (by id) or the one already saved for this
        # target; if both exist and differ, the edit wins and the duplicate is dropped.
        pid = profile.get("id")
        at = next((i for i, f in enumerate(self.favorites) if pid and f["id"] == pid), None)
        if at is None:
            at = next((i for i, f in enumerate(self.favorites) if f["key"] == key), None)
        if at is not None:
            kept = [f for i, f in enumerate(self.favorites) if i == at or f["key"] != key]
            at = next(i for i, f in enumerate(kept) if f is self.favorites[at])
            self._commit(kept[:at] + [entry] + kept[at + 1:])
            return entry
        if len(self.favorites) >= MAX_FAVORITES:
            raise ProtocolError("limit", "Favorites are full (50)")
        self._commit(self.favorites + [entry])
        return entry

    def delete_profile(self, profile_id: str) -> bool:
        kept = [f for f in self.favorites if f["id"] != profile_id]
        if len(kept) == len(self.favorites):
            return False
        self._commit(kept)
        return True

    def dismiss_update(self, version: str) -> None:
        if not _VERSION_RE.match(version):
            raise ProtocolError("bad_param", "Invalid version")
        previous = self.dismissed_update
        self.dismissed_update = version
        try:
            self.save()
        except ProtocolError:
            self.dismissed_update = previous
            raise

    def add_history(self, session: dict) -> None:
        entry = self._history_entry(session)
        if entry is None:
            return
        previous = self.history
        self.history = [entry] + self.history[:MAX_HISTORY - 1]
        try:
            self.save()
        except ProtocolError:
            self.history = previous

    def clear_history(self) -> None:
        previous = self.history
        self.history = []
        try:
            self.save()
        except ProtocolError:
            self.history = previous
            raise

    def find(self, profile_id: str) -> dict | None:
        for item in self.favorites + self.recents:
            if item["id"] == profile_id:
                return item
        return None

    def add_recent(self, label: str, target: dict, detail: str = "") -> None:
        if target.get("targetType") in ("profile", "fastest", "random"):
            return
        key = target_key(target)
        self.recents = [r for r in self.recents if r["key"] != key]
        self.recents.insert(0, {"id": key_to_id(key), "key": key, "label": clean_text(label or key, 80),
                                "detail": clean_text(detail, 120), "target": target, "ts": int(time.time())})
        del self.recents[MAX_RECENTS:]
        try:
            self.save()
        except ProtocolError:
            pass
