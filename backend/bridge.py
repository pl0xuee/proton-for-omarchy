#!/usr/bin/env python3
"""Proton for Omarchy backend bridge.

Spawned by Service.qml as `python3 -u -s backend/bridge.py`. Reads NDJSON
requests on stdin, writes NDJSON replies/events on stdout, logs (redacted) to
stderr, and exits as soon as stdin closes so the shell never leaks a process.
"""

from __future__ import annotations

import asyncio
import os
import shutil
import signal
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import protocol  # noqa: E402
import split_tunnel  # noqa: E402
import updates  # noqa: E402
from profiles import ProfileStore, default_state_path  # noqa: E402
from protocol import ProtocolError  # noqa: E402

log = protocol.install_redacting_logger()

# Commands that change VPN/account/settings state run one at a time.
SERIALIZED = {"connect", "disconnect", "reconnect", "set_setting", "auth_login", "auth_2fa_totp",
              "auth_2fa_fido2_start", "auth_logout", "auth_refresh_account", "refresh_servers"}
CLIPBOARD_MAX = 256  # per line
CLIPBOARD_TOTAL_MAX = 2048  # whole copy (diagnostics are several lines)



def claim_boot_marker() -> bool:
    """True exactly once per login session. XDG_RUNTIME_DIR is a tmpfs that is
    emptied at logout and reboot, so shell or plugin reloads do not reconnect."""
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    if not runtime or not os.path.isdir(runtime):
        return False
    try:
        fd = os.open(os.path.join(runtime, "proton-for-omarchy-autoconnect"),
                     os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except OSError:
        return False
    os.close(fd)
    return True

class Bridge:
    def __init__(self) -> None:
        self.out = sys.stdout
        self.lock = asyncio.Lock()
        try:
            self.profiles = ProfileStore()
        except Exception:  # noqa: BLE001 - a bad state file must never stop the bridge
            log.warning("state file unreadable; starting with empty favorites")
            self.profiles = ProfileStore.__new__(ProfileStore)
            self.profiles.path, self.profiles.favorites, self.profiles.recents = default_state_path(), [], []
            self.profiles.dismissed_update, self.profiles.history = "", []
        from proton_client import ProtonClient  # noqa: PLC0415 - imports only stdlib + local modules
        self.client = ProtonClient(self.emit, self.profiles)
        self.tasks: set[asyncio.Task] = set()
        self.ready = asyncio.Event()

    # -------------------------------------------------------------- output

    def write(self, message: dict) -> None:
        try:
            self.out.write(protocol.encode(message))
            self.out.flush()
        except (BrokenPipeError, ValueError):
            # The shell went away; stdin EOF will end the loop shortly.
            pass

    def emit(self, kind: str, data) -> None:
        self.write(protocol.event(kind, data))

    # ------------------------------------------------------------ dispatch

    async def handle(self, raw: bytes) -> None:
        req_id = ""
        try:
            msg = protocol.parse_line(raw)
            req_id = msg["id"]
            cmd, params = msg["cmd"], msg["params"]
            if cmd not in ("ping", "diagnostics", "copy_clipboard", "check_update", "dismiss_update"):
                await self.ready.wait()
            if cmd in SERIALIZED:
                superseding = cmd == "connect" and self.client.connect_in_progress()
                if superseding:
                    # A second connect supersedes a hung one instead of queueing behind it.
                    # The cleanup disconnect runs under the lock so it cannot hit a newer connect.
                    self.client.abort_connect()
                async with self.lock:
                    if superseding:
                        await self.client.settle_after_abort()
                    data = await self.dispatch(cmd, params)
            else:
                data = await self.dispatch(cmd, params)
            self.write(protocol.reply(req_id, data))
        except ProtocolError as exc:
            req_id = req_id or getattr(exc, "req_id", "")
            if req_id:
                self.write(protocol.error_reply(req_id, exc.code, exc.message))
            else:
                self.emit("protocol_error", {"code": exc.code, "message": exc.message})
        except asyncio.CancelledError:
            if req_id:
                self.write(protocol.error_reply(req_id, "cancelled", "Cancelled"))
        except Exception as exc:  # noqa: BLE001 - the bridge must survive any single request
            log.exception("command failed")
            if req_id:
                self.write(protocol.error_reply(req_id, "internal", protocol.scrub_text(str(exc)) or "Internal error"))

    async def dispatch(self, cmd: str, p: dict):
        c = self.client
        if cmd == "ping":
            return {"pong": True, "pid": os.getpid()}
        if cmd == "get_snapshot":
            return await c.snapshot()
        if cmd == "connect":
            return await c.connect(protocol.connect_target(p), protocol.get_bool(p, "waitForNetwork"))
        if cmd == "disconnect":
            return await c.disconnect()
        if cmd == "reconnect":
            return await c.reconnect()
        if cmd == "cancel_connect":
            return await c.cancel_connect()
        if cmd == "query_servers":
            return c.query_servers({
                "query": protocol.get_str(p, "query", max_len=96).strip(),
                "feature": protocol.get_choice(p, "feature", protocol.FEATURES, "all"),
                "sort": protocol.get_choice(p, "sort", protocol.SORTS, "alpha"),
                "countryCode": protocol.country_code(p.get("countryCode"), required=False),
                "entryCountry": protocol.country_code(p.get("entryCountry"), required=False),
                "city": protocol.city_name(p.get("city"), required=False),
                "includeServers": protocol.get_bool(p, "includeServers"),
                "secureCore": protocol.get_bool(p, "secureCore"),
                "limit": protocol.get_int(p, "limit", 300, 1, 300),
            })
        if cmd == "refresh_servers":
            return await c.refresh_servers(protocol.get_bool(p, "force"))
        if cmd == "set_setting":
            key = protocol.get_str(p, "key", required=True, max_len=40)
            if "value" not in p:
                raise ProtocolError("missing_param", "Missing parameter 'value'")
            return await c.set_setting(key, p["value"], protocol.get_bool(p, "forceDisconnect"),
                                       protocol.get_bool(p, "resolveConflict"))
        if cmd == "claim_boot_autoconnect":
            return {"claimed": claim_boot_marker()}
        if cmd == "set_auto_refresh":
            return await c.set_auto_refresh(protocol.get_bool(p, "enabled"))
        if cmd == "set_panel_open":
            c.set_panel_open(protocol.get_bool(p, "open"))
            return {"open": c.panel_open}
        if cmd == "list_apps":
            query = protocol.get_str(p, "query", max_len=64)
            return {"apps": await asyncio.to_thread(split_tunnel.list_apps, query)}
        if cmd == "save_profile":
            entry = self.profiles.save_profile(p.get("profile"), describe=lambda t: c._target_label(t, None)[0])
            self.emit("profiles", self.profiles.snapshot())
            return entry
        if cmd == "measure_latency":
            raw = p.get("servers")
            if not isinstance(raw, list) or len(raw) > 30:
                raise ProtocolError("bad_param", "servers must be a list of up to 30 names")
            return await c.measure_latency([protocol.server_name(n) for n in raw])
        if cmd == "clear_history":
            self.profiles.clear_history()
            self.emit("profiles", self.profiles.snapshot())
            return {"cleared": True}
        if cmd == "set_history":
            c.set_history_enabled(protocol.get_bool(p, "enabled"))
            return {"enabled": c.history_enabled}
        if cmd == "delete_profile":
            removed = self.profiles.delete_profile(protocol.get_str(p, "id", required=True, max_len=64))
            self.emit("profiles", self.profiles.snapshot())
            return {"removed": removed}
        if cmd == "toggle_favorite":
            target = p.get("target")
            if not isinstance(target, dict):
                raise ProtocolError("bad_param", "target must be an object")
            pinned = self.profiles.toggle_favorite(protocol.get_str(p, "label", max_len=120), target,
                                                   protocol.get_str(p, "detail", max_len=120))
            self.emit("profiles", self.profiles.snapshot())
            return {"pinned": pinned}
        if cmd == "auth_login":
            username = protocol.get_str(p, "username", required=True, max_len=256).strip()
            password = protocol.get_str(p, "password", required=True, max_len=1024)
            p.pop("password", None)
            return await c.login(username, password)
        if cmd == "auth_2fa_totp":
            code = protocol.get_str(p, "code", required=True, max_len=64).strip().replace(" ", "")
            p.pop("code", None)
            return await c.submit_totp(code)
        if cmd == "auth_2fa_fido2_start":
            return await c.fido2_start()
        if cmd == "auth_2fa_fido2_pin":
            pin = protocol.get_str(p, "pin", max_len=128)
            p.pop("pin", None)
            return c.fido2_pin(pin)
        if cmd == "auth_2fa_fido2_cancel":
            return c.fido2_cancel()
        if cmd == "auth_logout":
            return await c.logout()
        if cmd == "auth_refresh_account":
            return await c.refresh_account()
        if cmd == "diagnostics":
            return await c.diagnostics()
        if cmd == "check_update":
            return await updates.check(self.profiles.dismissed_update)
        if cmd == "dismiss_update":
            self.profiles.dismiss_update(protocol.get_str(p, "version", required=True, max_len=16))
            return {"dismissed": True}
        if cmd == "copy_clipboard":
            return await self.copy_clipboard(protocol.get_str(p, "text", required=True, max_len=CLIPBOARD_TOTAL_MAX))
        raise ProtocolError("unknown_command", "Unknown command")

    async def copy_clipboard(self, text: str) -> dict:
        # Keep line breaks (diagnostics are multi-line); drop other control characters.
        text = "\n".join(protocol.clean_text(line, CLIPBOARD_MAX) for line in text.splitlines())
        text = text.strip()[:CLIPBOARD_TOTAL_MAX]
        if not text:
            raise ProtocolError("bad_param", "Nothing to copy")
        exe = shutil.which("wl-copy")
        if not exe:
            raise ProtocolError("missing_tool", "wl-copy is not installed (wl-clipboard)")
        # Text goes over stdin, never argv; stdout/stderr detached because
        # wl-copy forks a daemon that would otherwise hold our pipes open.
        proc = await asyncio.create_subprocess_exec(
            exe, "--", stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
        try:
            await asyncio.wait_for(proc.communicate(text.encode("utf-8")), 5)
        except asyncio.TimeoutError as exc:
            proc.kill()
            raise ProtocolError("clipboard_failed", "Copying timed out") from exc
        if proc.returncode != 0:
            raise ProtocolError("clipboard_failed", "Could not copy to the clipboard")
        return {"copied": True}

    # ---------------------------------------------------------------- loop

    def spawn(self, coro) -> None:
        task = asyncio.get_running_loop().create_task(coro)
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)

    async def startup(self) -> None:
        try:
            await self.client.start()
        except Exception:  # noqa: BLE001
            log.exception("startup failed")
        finally:
            self.ready.set()
        try:
            self.emit("snapshot", await self.client.snapshot())
        except Exception:  # noqa: BLE001
            log.exception("initial snapshot failed")

    async def run(self) -> None:
        loop = asyncio.get_running_loop()
        reader = asyncio.StreamReader(limit=protocol.MAX_IN_LINE + 2)
        await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
        self.spawn(self.startup())
        while True:
            try:
                line = await reader.readuntil(b"\n")
            except asyncio.IncompleteReadError as exc:
                if exc.partial.strip():
                    self.spawn(self.handle(exc.partial))
                break  # EOF: the shell closed our stdin.
            except asyncio.LimitOverrunError:
                # Drain the oversized line, reply with a framing error.
                while True:
                    try:
                        await reader.readuntil(b"\n")
                        break
                    except asyncio.LimitOverrunError as exc:
                        await reader.readexactly(exc.consumed)
                    except asyncio.IncompleteReadError:
                        return
                self.emit("protocol_error", {"code": "too_large", "message": "Request exceeds 64 KB"})
                continue
            if line.strip():
                self.spawn(self.handle(line))

    async def close(self) -> None:
        for task in list(self.tasks):
            task.cancel()
        try:
            await asyncio.wait_for(self.client.shutdown(), 3)
        except Exception:  # noqa: BLE001
            pass


async def main() -> int:
    bridge = Bridge()
    loop = asyncio.get_running_loop()
    stop = asyncio.Event()
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        try:
            loop.add_signal_handler(sig, stop.set)
        except (NotImplementedError, RuntimeError):
            pass
    runner = loop.create_task(bridge.run())
    stopper = loop.create_task(stop.wait())
    await asyncio.wait({runner, stopper}, return_when=asyncio.FIRST_COMPLETED)
    stopper.cancel()
    runner.cancel()
    await bridge.close()
    return 0


if __name__ == "__main__":
    # Never let library chatter reach stdout: it is the protocol channel.
    _proto_out = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")
    os.dup2(2, 1)
    sys.stdout = _proto_out
    try:
        code = asyncio.run(main())
    except KeyboardInterrupt:
        code = 0
    os._exit(code)
