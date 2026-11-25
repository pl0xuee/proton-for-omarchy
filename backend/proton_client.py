"""Adapter between python-proton-vpn-api-core and the Proton for Omarchy bridge.

Everything here runs on the bridge's single asyncio loop. `proton.*` is
imported lazily inside `ProtonClient.start()` so the bridge can still answer
`ping`/`diagnostics` (and report a missing dependency) when the Proton stack is
absent or broken.

The client never logs or stores credentials: login/2FA secrets are passed
straight into the API call and the local references are dropped.
"""

from __future__ import annotations

import asyncio
import ipaddress
import json
import logging
import os
import threading
import time
from typing import Any, Callable

import split_tunnel
from protocol import ProtocolError, clean_text, connect_target, scrub_text
from server_index import FEATURE_BITS, Record, ServerIndex, feature_tags
from telemetry import TrafficMeter, detect_interface, read_totals
from updates import plugin_version

log = logging.getLogger("proton-for-omarchy.client")

CONNECT_TIMEOUT = 40.0
DISCONNECT_TIMEOUT = 20.0
FIDO2_TIMEOUT = 120.0
MAX_DNS = 10

STATE_NAMES = {0: "disconnected", 1: "connecting", 2: "connected", 3: "disconnecting", 4: "error"}

ERROR_EVENTS = {
    "TwoFARequired": ("twofa_required", "Traffic blocked: hardware key authentication required"),
    "MaximumSessionsReached": ("max_sessions", "Maximum number of VPN sessions reached for your plan"),
    "AuthDenied": ("auth_denied", "The VPN server rejected the connection credentials"),
    "Timeout": ("timeout", "The VPN server did not respond in time"),
    "ExpiredCertificate": ("expired_certificate", "The VPN certificate expired; reconnect to refresh it"),
    "NotYetValidCertificate": ("clock_skew", "The VPN certificate is not valid yet; check the system clock"),
    "TunnelSetupFailed": ("tunnel_failed", "Could not set up the VPN tunnel"),
    "DeviceDisconnected": ("device_disconnected", "The VPN network device disappeared"),
    "UnexpectedError": ("unexpected", "Unexpected VPN error"),
}

# Settings that only take effect on a new connection.
RECONNECT_KEYS = {"protocol", "ipv6", "custom_dns"}
PAID_KEYS = {"netshield", "vpn_accelerator", "moderate_nat", "port_forwarding", "custom_dns", "split_tunneling"}
BOOL_FEATURE_KEYS = {"vpn_accelerator": "vpn_accelerator", "moderate_nat": "moderate_nat",
                     "port_forwarding": "port_forwarding"}


def _parse_modified(value) -> int:
    """ServerList.last_modified_time is an HTTP date string (or a number)."""
    try:
        if isinstance(value, (int, float)) and value > 0:
            return int(value * 1000)
        if isinstance(value, str) and value:
            from email.utils import parsedate_to_datetime
            ms = int(parsedate_to_datetime(value).timestamp() * 1000)
            if ms > 86_400_000:  # the library uses the epoch as "never fetched"
                return ms
    except Exception:  # noqa: BLE001
        pass
    return _now_ms()

MAX_LATENCY = 30
LATENCY_CONCURRENCY = 8
LATENCY_TIMEOUT = 1.0


def _now_ms() -> int:
    return int(time.time() * 1000)


SESSION_MARKER = "proton-for-omarchy-session.json"


def _session_marker_path() -> str:
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    return os.path.join(runtime, SESSION_MARKER) if runtime and os.path.isdir(runtime) else ""


def _read_session_marker(server: str) -> int:
    """Start time (ms) of the connection to `server` recorded this login session, or 0."""
    path = _session_marker_path()
    if not path or not server:
        return 0
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "r", encoding="utf-8") as fh:
            data = json.loads(fh.read(4096))
    except (OSError, ValueError):
        return 0
    if not isinstance(data, dict) or data.get("server") != server:
        return 0
    since = data.get("sinceMs")
    if type(since) is not int or not 0 < since <= _now_ms():
        return 0
    return since


def _write_session_marker(server: str, since_ms: int) -> None:
    path = _session_marker_path()
    if not path:
        return
    try:
        if not server:
            os.unlink(path)
            return
        tmp = f"{path}.{os.getpid()}.tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(json.dumps({"server": server, "sinceMs": since_ms}))
        os.replace(tmp, path)
    except OSError:
        pass


def _error_text(exc: BaseException) -> str:
    message = getattr(exc, "message", None) or str(exc) or exc.__class__.__name__
    return clean_text(scrub_text(str(message)), 240)


class _Fido2Interaction:
    """proton UserInteraction bridged to NDJSON events.

    prompt_up/request_pin/request_uv run on a worker thread (the fido2 lib's
    `get_assertion` is executed via asyncio.to_thread); request_key_selection
    runs on the loop thread.
    """

    def __init__(self, client: "ProtonClient", loop: asyncio.AbstractEventLoop):
        self.client = client
        self.loop = loop

    def _emit(self, kind: str) -> None:
        if threading.current_thread() is threading.main_thread():
            self.client.emit("fido2_prompt", {"kind": kind})
        else:
            self.loop.call_soon_threadsafe(self.client.emit, "fido2_prompt", {"kind": kind})

    def prompt_up(self) -> None:
        self._emit("touch")

    def request_key_selection(self) -> None:
        self._emit("select_key")

    def request_uv(self, *args, **kwargs) -> bool:
        self._emit("touch")
        return True

    def request_pin(self, *args, **kwargs):
        future = asyncio.run_coroutine_threadsafe(self.client._wait_for_pin(), self.loop)
        try:
            return future.result(timeout=FIDO2_TIMEOUT) or None
        except Exception:  # noqa: BLE001 - timeout/cancel both mean "no PIN"
            future.cancel()
            return None


class ProtonClient:
    def __init__(self, emit: Callable[[str, Any], None], profiles):
        self.emit = emit
        self.profiles = profiles
        self.api = None
        self.connector = None
        self.mods: dict[str, Any] = {}
        self.import_error = ""
        self.index = ServerIndex()
        self.meter = TrafficMeter()
        self.panel_open = False
        self.connected_since_ms = 0
        self.last_state: dict = {"connectionState": "disconnected"}
        self.last_target: dict | None = None
        self.pending_target: dict | None = None
        self.requires_reconnect: set[str] = set()
        self.twofa_pending = False
        self.refresher_enabled = False
        self.auto_refresh = True
        self._refresher_task = None
        self._traffic_task: asyncio.Task | None = None
        self._session: dict | None = None  # the connection being timed for history
        self._session_task: asyncio.Task | None = None
        self.history_enabled = True
        self._connect_task: asyncio.Task | None = None
        self._fido2_task: asyncio.Task | None = None
        self._fido2_cancel: threading.Event | None = None
        self._pin_future: asyncio.Future | None = None
        self._state_waiters: list[list] = []  # [types, future, old_conn, seen_new_connecting]
        self._settings_cache: dict | None = None
        self.started_ms = _now_ms()

    # ------------------------------------------------------------------ setup

    @property
    def available(self) -> bool:
        return self.api is not None

    async def start(self) -> None:
        if not os.environ.get("XDG_RUNTIME_DIR"):
            self.import_error = "XDG_RUNTIME_DIR is not set"
            return
        try:
            from proton.vpn.connection import events, states  # noqa: PLC0415
            from proton.vpn.core.api import ProtonVPNAPI  # noqa: PLC0415
            from proton.vpn.core.session_holder import ClientTypeMetadata  # noqa: PLC0415
            from proton.vpn.core.settings import (  # noqa: PLC0415
                CustomDNSEntry, NetShield, SplitTunnelingConfig, SplitTunnelingMode)
            from proton.vpn.core.settings.custom_dns import CustomDNS  # noqa: PLC0415
            from proton.session import exceptions as session_exc  # noqa: PLC0415
            from proton.vpn.session import exceptions as vpn_session_exc  # noqa: PLC0415
        except Exception as exc:  # noqa: BLE001 - missing/broken dependency is reported, not fatal
            self.import_error = clean_text(f"Proton VPN libraries unavailable: {exc}", 240)
            log.warning("%s", self.import_error)
            return
        self.mods = {
            "events": events, "states": states, "CustomDNSEntry": CustomDNSEntry, "CustomDNS": CustomDNS,
            "NetShield": NetShield, "SplitTunnelingConfig": SplitTunnelingConfig,
            "SplitTunnelingMode": SplitTunnelingMode, "session_exc": session_exc,
            "vpn_session_exc": vpn_session_exc,
        }
        try:
            self.api = ProtonVPNAPI(ClientTypeMetadata(type="cli"))
            self.connector = await self.api.get_vpn_connector()
            self.connector.register(self)
        except Exception as exc:  # noqa: BLE001 - keyring/D-Bus failures surface in the snapshot
            self.import_error = _error_text(exc)
            log.warning("Proton VPN init failed: %s", self.import_error)
            self.api = None
            self.connector = None
            return
        self._record_state(self.connector.current_state, initial=True)
        if self._logged_in():
            await self._after_login(initial=True)
            # Re-derive server details now that the index exists.
            self._record_state(self.connector.current_state, initial=True)

    async def shutdown(self) -> None:
        self.set_panel_open(False)
        if self._fido2_cancel:
            self._fido2_cancel.set()
        if self.connector:
            try:
                self.connector.unregister(self)
            except Exception:  # noqa: BLE001
                pass
        if self.api and self.refresher_enabled:
            try:
                await asyncio.wait_for(self.api.refresher.disable(), 2)
            except Exception:  # noqa: BLE001
                pass

    def _logged_in(self) -> bool:
        if not self.api:
            return False
        try:
            return bool(self.api.is_user_logged_in())
        except Exception as exc:  # noqa: BLE001 - locked keyring
            log.warning("keyring check failed: %s", _error_text(exc))
            return False

    def _tier(self) -> int:
        try:
            return int(self.api.user_tier)
        except Exception:  # noqa: BLE001 - account data not loaded yet
            return 0

    async def _after_login(self, initial: bool = False) -> None:
        refresher = self.api.refresher
        try:
            server_list = await refresher.get_up_to_date_server_list()
            self._rebuild_index(server_list)
        except Exception as exc:  # noqa: BLE001 - offline start keeps whatever cache exists
            log.warning("server list refresh failed: %s", _error_text(exc))
            if self.api.server_list is not None:
                self._rebuild_index(self.api.server_list)
        refresher.set_server_list_updated_callback(self._on_servers_changed)
        refresher.set_server_loads_updated_callback(self._on_servers_changed)
        refresher.set_error_callback(self._on_refresher_error)
        await self._apply_refresher()
        await self._load_settings_cache()

    # The refresher keeps server loads, client config and the VPN certificate
    # fresh. With autoRefreshServers off it still runs while a connection is up
    # so certificates keep renewing; connect() refreshes them on demand anyway.
    def _refresher_wanted(self) -> bool:
        return self.auto_refresh or self.last_state.get("connectionState") in ("connecting", "connected")

    async def _apply_refresher(self) -> None:
        if not self.api or not self._logged_in():
            return
        want = self._refresher_wanted()
        if want == self.refresher_enabled:
            return
        try:
            if want:
                await self.api.refresher.enable()
            else:
                await self.api.refresher.disable()
            self.refresher_enabled = want
        except Exception as exc:  # noqa: BLE001
            log.warning("refresher %s failed: %s", "enable" if want else "disable", _error_text(exc))

    def _sync_refresher(self) -> None:
        if self._refresher_wanted() == self.refresher_enabled:
            return
        if self._refresher_task is not None and not self._refresher_task.done():
            return
        self._refresher_task = asyncio.get_running_loop().create_task(self._apply_refresher())

    async def set_auto_refresh(self, enabled: bool) -> dict:
        self.auto_refresh = bool(enabled)
        await self._apply_refresher()
        return {"autoRefresh": self.auto_refresh, "refresherEnabled": self.refresher_enabled}

    # ----------------------------------------------------------- server index

    def _rebuild_index(self, server_list) -> None:
        if server_list is None:
            return
        records = []
        for s in server_list.logicals:
            try:
                data = getattr(s, "_data", None) or {}
                bits = data.get("Features")
                if not isinstance(bits, int):
                    bits = 0
                    for f in s.features:
                        bits |= int(f)
                exit_ips = {}
                for phys in data.get("Servers") or []:
                    if isinstance(phys, dict) and phys.get("EntryIP"):
                        if phys.get("ExitIP"):  # never guess: an entry IP is not the egress address
                            exit_ips[str(phys["EntryIP"])] = str(phys["ExitIP"])
                records.append(Record(
                    name=s.name, exit_country=(s.exit_country or "").upper(),
                    entry_country=(s.entry_country or "").upper(), exit_name=s.exit_country_name,
                    entry_name=s.entry_country_name, city=s.city or "", load=int(s.load or 0),
                    score=float(s.score or 0), tier=int(s.tier), enabled=bool(s.enabled), features=bits,
                    smart_routing=bool(data.get("HostCountry")), exit_ips=exit_ips))
            except Exception:  # noqa: BLE001 - one malformed entry must not drop the list
                continue
        updated = _parse_modified(getattr(server_list, "last_modified_time", None))
        self.index.rebuild(records, updated or _now_ms())
        self._backfill_exit_ip()

    def _backfill_exit_ip(self) -> None:
        if self.last_state.get("connectionState") != "connected":
            return
        current = self.last_state.get("connectionDetails") or {}
        if current.get("vpnIp"):
            return
        conn = getattr(getattr(self, "connector", None), "current_connection", None)
        exit_ip = self._exit_ip(conn)
        if exit_ip:
            self.last_state = {**self.last_state, "connectionDetails": {**current, "vpnIp": exit_ip},
                               "server": self._server_info(conn)}
            self.emit("state", self.last_state)

    def _on_servers_changed(self) -> None:
        if self.api and self.api.server_list is not None:
            self._rebuild_index(self.api.server_list)
            self.emit("servers_updated", self.servers_summary())

    def _on_refresher_error(self, exc: Exception) -> None:
        log.warning("refresher error: %s", _error_text(exc))

    def servers_summary(self) -> dict:
        return {"countryCount": self.index.country_count, "serverCount": len(self.index.records),
                "updatedAtMs": self.index.updated_at_ms,
                "countries": self.index.countries(user_tier=self._tier())}

    async def _refresh_loads_quietly(self) -> None:
        """Fresh loads before picking a replacement server; best effort, bounded."""
        try:
            session = self.api._session_holder.session  # noqa: SLF001
            await asyncio.wait_for(session.update_server_loads(), 8)
            self._rebuild_index(self.api.server_list)
            self.emit("servers_updated", self.servers_summary())
        except Exception as exc:  # noqa: BLE001 - stale loads are still usable
            log.warning("could not refresh loads before switching: %s", _error_text(exc))

    async def refresh_servers(self, force: bool) -> dict:
        self._require_login()
        session = self.api._session_holder.session  # noqa: SLF001 - no public "force" refresh
        try:
            if force or self.api.server_list is None:
                await session.fetch_server_list()
            else:
                await session.update_server_loads()
        except Exception as exc:  # noqa: BLE001
            raise ProtocolError("refresh_failed", _error_text(exc)) from exc
        self._rebuild_index(self.api.server_list)
        summary = self.servers_summary()
        self.emit("servers_updated", summary)
        return {"countryCount": summary["countryCount"], "serverCount": summary["serverCount"],
                "updatedAtMs": summary["updatedAtMs"]}

    def query_servers(self, params: dict) -> dict:
        tier = self._tier()
        query = params["query"]
        feature, sort, limit = params["feature"], params["sort"], params["limit"]
        if query:
            return {"mode": "search", **self.index.search(query, feature, tier, limit)}
        country = params["countryCode"]
        if not country:
            return {"mode": "countries", "countries": self.index.countries(feature, sort, tier)}
        if params["entryCountry"] or (params["includeServers"] and params.get("secureCore")):
            return {"mode": "secure_core", "country": country, "countryName": self.index.country_name(country),
                    "entryCountry": params["entryCountry"],
                    "servers": self.index.secure_core_servers(country, params["entryCountry"], tier, limit)}
        if params["includeServers"]:
            return {"mode": "servers", "country": country, "countryName": self.index.country_name(country),
                    "city": params["city"],
                    "servers": self.index.city_servers(country, params["city"], feature, sort, tier, limit)}
        return {"mode": "country", **self.index.country_detail(country, feature, sort, tier)}

    # ------------------------------------------------------------ state feed

    def status_update(self, state) -> None:
        """VPNStateSubscriber callback (runs on the loop thread)."""
        try:
            self._record_state(state)
        except Exception:  # noqa: BLE001 - waiters below must still resolve
            log.exception("could not record VPN state")
        kind = int(state.type)
        conn = getattr(state.context, "connection", None)
        for waiter in list(self._state_waiters):
            types, future, old_conn = waiter[0], waiter[1], waiter[2]
            if future.done():
                continue
            if old_conn is not None and conn is old_conn and kind != 4:
                continue
            if kind == 1:
                waiter[3] = True
            # A connect attempt that falls back to Disconnected (closed elsewhere,
            # or the tunnel went down) ends the wait instead of timing out.
            if kind in types or kind == 4 or (kind == 0 and waiter[3] and 2 in types):
                future.set_result(state)

    def _record_state(self, state, initial: bool = False) -> None:
        if state is None:
            return
        kind = STATE_NAMES.get(int(state.type), "disconnected")
        ctx = state.context
        conn = getattr(ctx, "connection", None)
        event = getattr(ctx, "event", None)
        ev_ctx = getattr(event, "context", None)
        details = getattr(ev_ctx, "connection_details", None)
        prev = self.last_state.get("connectionState")
        data: dict = {"connectionState": kind, "server": None, "connectionDetails": None,
                      "forwardedPort": None, "connectedSinceMs": 0, "iface": "",
                      "errorCode": "", "errorMessage": "",
                      "requiresReconnectFlags": sorted(self.requires_reconnect)}
        if conn is not None:
            data["server"] = self._server_info(conn)
        if kind == "connected":
            if prev != "connected" or not self.connected_since_ms:
                # After a backend or shell restart, keep the real start time of a
                # connection that was already up instead of restarting the clock.
                name_now = (data["server"] or {}).get("name", "")
                since = _read_session_marker(name_now) if initial and not self.pending_target else 0
                self.connected_since_ms = since or _now_ms()
                _write_session_marker(name_now, self.connected_since_ms)
                self.requires_reconnect.clear()
                data["requiresReconnectFlags"] = []
                iface = detect_interface()
                self.meter.reset(iface)
                if self.pending_target:
                    self._remember_recent(self.pending_target, data["server"])
                    self.last_target = self.pending_target
                    self.pending_target = None
            current = self._current_target(data["server"])
            data["target"] = current
            name = (data["server"] or {}).get("name", "")
            if self._session and self._session["server"] != name:
                self._finish_session()
            if self._session is None and name:
                self._start_session(data["server"], current)
            data["connectedSinceMs"] = self.connected_since_ms
            data["iface"] = self.meter.iface or ""
            # details.device_ip is the user's own public IP, so it is never surfaced.
            exit_ip = self._exit_ip(conn)
            prev_details = self.last_state.get("connectionDetails") if prev == "connected" else None
            if details is not None or exit_ip or prev_details:
                prev_details = prev_details or {}
                agent_ip = clean_text(getattr(details, "server_ipv4", "") or "", 64) if details is not None else ""
                data["connectionDetails"] = {
                    # The local agent's server_ipv4 is the live egress address; the
                    # server list's ExitIP is the fallback until the agent reports.
                    "vpnIp": agent_ip or prev_details.get("vpnIp", "") or exit_ip,
                    "serverIpv4": agent_ip or prev_details.get("serverIpv4", ""),
                    "serverIpv6": (clean_text(getattr(details, "server_ipv6", "") or "", 64)
                                   if details is not None else "") or prev_details.get("serverIpv6", ""),
                }
            try:
                port = state.forwarded_port
                data["forwardedPort"] = int(port) if port else None
            except Exception:  # noqa: BLE001 - not every event carries a context
                data["forwardedPort"] = self.last_state.get("forwardedPort")
        else:
            if (self.connected_since_ms or initial) and kind in ("disconnected", "error"):
                _write_session_marker("", 0)
            self.connected_since_ms = 0
            if self._session:
                self._finish_session()
            if kind == "disconnected":
                self.meter.reset("")
            if kind in ("disconnected", "error") and self.requires_reconnect:
                self.requires_reconnect.clear()
                data["requiresReconnectFlags"] = []
        if kind == "error":
            code, message = ERROR_EVENTS.get(type(event).__name__ if event else "",
                                             ("error", "The VPN connection failed"))
            err = getattr(ev_ctx, "error", None)
            data["errorCode"] = code
            data["errorMessage"] = message if err is None else clean_text(f"{message} ({_error_text(err)})", 240)
        self.last_state = data
        if not initial:
            self.emit("state", data)
        self._sync_traffic()
        if not initial:
            self._sync_refresher()

    def _exit_ip(self, conn) -> str:
        if conn is None:
            return ""
        name = clean_text(getattr(conn, "server_name", "") or "", 64)
        entry = clean_text(getattr(conn, "server_ip", "") or "", 64)
        rec = self.index.by_name.get(name.upper()) if name else None
        if rec is None or not entry:
            return ""
        return clean_text(rec.exit_ips.get(entry, ""), 64)

    def _server_info(self, conn) -> dict:
        name = clean_text(getattr(conn, "server_name", "") or "", 64)
        rec = self.index.by_name.get(name.upper()) if name else None
        protocol = getattr(conn, "protocol", "") or ""
        label = getattr(conn, "ui_protocol", "") or self._protocol_label(protocol)
        info = {"name": name, "protocol": protocol, "protocolLabel": clean_text(label, 32),
                "country": "", "countryName": "", "entryCountry": "", "entryName": "", "city": "",
                "load": None, "features": [], "secureCore": False}
        if rec:
            info.update({"country": rec.exit_country, "countryName": rec.exit_name,
                         "entryCountry": rec.entry_country, "entryName": rec.entry_name, "city": rec.city,
                         "load": rec.load, "features": feature_tags(rec.features), "secureCore": rec.secure_core})
        return info

    async def _wait_state(self, types: set, timeout: float, old_conn=None):
        loop = asyncio.get_running_loop()
        future = loop.create_future()
        waiter = [types, future, old_conn, False]
        self._state_waiters.append(waiter)
        try:
            return await asyncio.wait_for(future, timeout)
        finally:
            self._state_waiters.remove(waiter)

    # --------------------------------------------------------------- traffic

    def set_panel_open(self, open_: bool) -> None:
        self.panel_open = open_
        self._sync_traffic()

    def _sync_traffic(self) -> None:
        want = self.panel_open and self.last_state.get("connectionState") == "connected"
        running = self._traffic_task is not None and not self._traffic_task.done()
        if want and not running:
            self._traffic_task = asyncio.get_running_loop().create_task(self._traffic_loop())
        elif not want and running:
            self._traffic_task.cancel()
            self._traffic_task = None

    async def _traffic_loop(self) -> None:
        try:
            while True:
                if not self.meter.iface:
                    self.meter.reset(detect_interface())
                sample = self.meter.sample()
                if sample and self._session and sample["totalRxBytes"] >= self._session["rx"] \
                        and sample["totalTxBytes"] >= self._session["tx"]:
                    self._session["rx"], self._session["tx"] = sample["totalRxBytes"], sample["totalTxBytes"]
                if sample:
                    sample["uptimeSec"] = max(0, (_now_ms() - self.connected_since_ms) // 1000) \
                        if self.connected_since_ms else 0
                    self.emit("traffic", sample)
                await asyncio.sleep(1)
        except asyncio.CancelledError:
            pass

    # --------------------------------------------------------------- history

    def _current_target(self, server: dict | None) -> dict | None:
        """What the current connection was asked for, so it can be saved as a profile.

        Falls back to the server itself when the connection was made elsewhere
        (Proton's own app) or the remembered target no longer matches it.
        """
        server = server or {}
        name = server.get("name", "")
        target = dict((self.last_target or {}).get("target") or {})
        target.pop("avoidCurrent", None)
        # The remembered target only describes this connection if it landed on this
        # very server; anything else was connected (or moved) outside the plugin.
        stale = (self.last_target or {}).get("server") != name
        if not target or stale:
            if not name:
                return None
            try:
                target = connect_target({"targetType": "server", "serverName": name})
            except ProtocolError:
                return None
        label, detail = self._target_label(target, server)
        return {"target": target, "label": label, "detail": detail}

    def _start_session(self, server: dict, current: dict | None) -> None:
        self._session = {"server": server.get("name", ""), "country": server.get("country", ""),
                         "label": (current or {}).get("label") or server.get("name", ""),
                         "start": (self.connected_since_ms // 1000) or int(time.time()), "rx": 0, "tx": 0}
        if self._session_task is None or self._session_task.done():
            try:
                self._session_task = asyncio.get_running_loop().create_task(self._session_loop())
            except RuntimeError:  # no loop (unit tests building state synchronously)
                self._session_task = None

    def _read_session_bytes(self) -> None:
        if not self._session:
            return
        iface = self._session.get("iface") or self.meter.iface or detect_interface()
        totals = read_totals(iface)
        # Counters only grow within one tunnel; smaller numbers mean a new tunnel
        # already took the interface name, so keep what this session measured.
        if totals and totals[0] >= self._session["rx"] and totals[1] >= self._session["tx"]:
            self._session["rx"], self._session["tx"] = totals
            self._session["iface"] = iface

    async def _session_loop(self) -> None:
        # Two small sysfs reads every 30 s while connected; the interface is gone
        # by the time the disconnect event arrives, so totals are kept as we go.
        try:
            while self._session:
                self._read_session_bytes()
                await asyncio.sleep(30)
        except asyncio.CancelledError:
            pass

    def _finish_session(self) -> None:
        self._read_session_bytes()  # the tunnel may still be up while disconnecting
        session, self._session = self._session, None
        if self._session_task is not None:
            self._session_task.cancel()
            self._session_task = None
        if not session or not self.history_enabled:
            return
        session["end"] = int(time.time())
        try:
            self.profiles.add_history(session)
            self.emit("profiles", self.profiles.snapshot())
        except Exception as exc:  # noqa: BLE001
            log.warning("could not store history: %s", _error_text(exc))

    def set_history_enabled(self, enabled: bool) -> None:
        self.history_enabled = enabled
        if not enabled and self.profiles.history:
            self.profiles.clear_history()
            self.emit("profiles", self.profiles.snapshot())

    # --------------------------------------------------------------- latency

    async def measure_latency(self, names: list[str]) -> dict:
        """TCP connect time to each server's entry IP on port 443, in ms (None = no answer).

        Bounded: at most MAX_LATENCY servers, LATENCY_CONCURRENCY at a time, 1 s each.
        Only Proton's own server addresses from the server list are contacted.
        """
        self._require_login()
        sem = asyncio.Semaphore(LATENCY_CONCURRENCY)

        async def one(name: str) -> tuple[str, int | None]:
            rec = self.index.by_name.get(name.upper())
            entry = sorted(rec.exit_ips)[0] if rec and rec.exit_ips else ""
            try:
                ip = str(ipaddress.ip_address(entry))
            except ValueError:
                return name, None
            async with sem:
                started = time.monotonic()
                try:
                    _, writer = await asyncio.wait_for(asyncio.open_connection(ip, 443), LATENCY_TIMEOUT)
                except (OSError, asyncio.TimeoutError):
                    return name, None
                elapsed = round((time.monotonic() - started) * 1000)
                writer.close()
            return name, max(1, elapsed)

        results = await asyncio.gather(*(one(n) for n in names[:MAX_LATENCY]))
        return {"latency": dict(results)}

    # --------------------------------------------------------------- connect

    def _require_login(self) -> None:
        if not self.available:
            raise ProtocolError("unavailable", self.import_error or "Proton VPN is unavailable")
        if not self._logged_in():
            raise ProtocolError("not_logged_in", "Sign in to Proton VPN first")

    def _resolve(self, target: dict, exclude: str = "") -> tuple[Any, dict]:
        tier = self._tier()
        if target["targetType"] == "profile":
            entry = self.profiles.find(target["profileId"])
            if not entry:
                raise ProtocolError("not_found", "That profile no longer exists")
            target = dict(entry["target"])
        features = target.get("features") or []
        if tier < 1 and (features or target["targetType"] in ("secure_core", "feature")):
            raise ProtocolError("upgrade_required", "This connection needs a paid Proton VPN plan")
        rec = self.index.pick(target, tier, exclude)
        if rec is None:
            if target["targetType"] == "server":
                raise ProtocolError("not_found", "Server not found")
            raise ProtocolError("no_server", "No available server matches that choice")
        if rec.tier > tier:
            raise ProtocolError("upgrade_required", "This server needs a paid Proton VPN plan")
        if not rec.enabled:
            raise ProtocolError("maintenance", "This server is under maintenance")
        try:
            logical = self.api.server_list.get_by_name(rec.name)
        except Exception as exc:  # noqa: BLE001
            raise ProtocolError("not_found", "Server not found") from exc
        return logical, target

    def connect_in_progress(self) -> bool:
        task = self._connect_task
        return task is not None and not task.done()

    async def connect(self, target: dict) -> dict:
        self._connect_task = asyncio.current_task()
        try:
            return await self._connect(target)
        finally:
            if self._connect_task is asyncio.current_task():
                self._connect_task = None

    async def _connect(self, target: dict) -> dict:
        self._require_login()
        target = dict(target)
        exclude = ""
        if target.pop("avoidCurrent", False):
            exclude = str((self.last_state.get("server") or {}).get("name") or "")
            await self._refresh_loads_quietly()
        if self.index.country_count == 0 and self.api.server_list is not None:
            self._rebuild_index(self.api.server_list)
        logical, resolved = self._resolve(target, exclude)
        refresher = self.api.refresher
        try:
            await refresher.update_certificate_if_necessary()
            client_config = await refresher.get_up_to_date_client_config()
            vpn_server = self.connector.get_vpn_server(logical, client_config)
            settings = await self.api.load_settings()
        except Exception as exc:  # noqa: BLE001
            raise ProtocolError("connect_failed", _error_text(exc)) from exc
        old_conn = self.connector.current_connection
        self.pending_target = {"target": resolved, "server": logical.name}
        waiter = asyncio.ensure_future(self._wait_state({2}, CONNECT_TIMEOUT, old_conn))
        try:
            await asyncio.sleep(0)
            await self.connector.connect(vpn_server, protocol=settings.protocol)
            state = await waiter
        except asyncio.TimeoutError as exc:
            self.pending_target = None
            await self._safe_disconnect()
            raise ProtocolError("timeout", "Connecting took too long and was cancelled") from exc
        except asyncio.CancelledError:
            self.pending_target = None
            raise
        except Exception as exc:  # noqa: BLE001
            self.pending_target = None
            await self._safe_disconnect()
            raise ProtocolError("connect_failed", _error_text(exc)) from exc
        finally:
            if not waiter.done():
                waiter.cancel()
        if int(state.type) == 0:
            self.pending_target = None
            raise ProtocolError("connect_failed", "The connection closed before it finished")
        if int(state.type) == 4:
            self.pending_target = None
            data = self.last_state
            raise ProtocolError(data.get("errorCode") or "connect_failed",
                                data.get("errorMessage") or "The VPN connection failed")
        return {"server": logical.name}

    def _remember_recent(self, pending: dict, server: dict | None) -> None:
        target = pending.get("target") or {}
        label, detail = self._target_label(target, server)
        try:
            self.profiles.add_recent(label, target, detail)
            self.emit("profiles", self.profiles.snapshot())
        except Exception as exc:  # noqa: BLE001
            log.warning("could not store recent: %s", _error_text(exc))

    def _target_label(self, target: dict, server: dict | None) -> tuple[str, str]:
        kind = target.get("targetType")
        feats = " ".join(f.upper() if f != "streaming" else "Streaming" for f in target.get("features") or [])
        if kind == "country":
            label = self.index.country_name(target["country"])
        elif kind == "city":
            label = f"{target['city']}, {self.index.country_name(target['country'])}"
        elif kind == "server":
            label = target["serverName"]
        elif kind == "secure_core":
            entry = target.get("entryCountry")
            label = (f"{self.index.country_name(entry)} → " if entry else "Secure Core → ") + \
                self.index.country_name(target["country"])
        elif kind == "feature":
            label = f"Fastest {feats}".strip()
        elif kind == "random":
            label = "Random server"
        else:
            label = "Fastest server"
        if feats and kind not in ("feature",):
            label = f"{label} · {feats}"
        detail = (server or {}).get("name", "")
        return clean_text(label, 96), clean_text(detail, 64)

    def abort_connect(self) -> None:
        """Cancel an in-flight connect task without touching the connector."""
        task = self._connect_task
        if task and not task.done():
            task.cancel()
        self.pending_target = None

    async def cancel_connect(self) -> dict:
        self.abort_connect()
        await self.settle_after_abort()
        return {"cancelled": True}

    async def settle_after_abort(self) -> None:
        await self._safe_disconnect()

    async def _safe_disconnect(self) -> None:
        try:
            await self.connector.disconnect()
        except Exception as exc:  # noqa: BLE001
            log.warning("disconnect cleanup failed: %s", _error_text(exc))

    async def disconnect(self) -> dict:
        if not self.available:
            raise ProtocolError("unavailable", self.import_error or "Proton VPN is unavailable")
        states = self.mods["states"]
        if isinstance(self.connector.current_state, states.Disconnected):
            return {"disconnected": True}
        # A Disconnecting state with a queued reconnection (a server switch)
        # ignores the Down event and lands on Connected; disconnect that too.
        for _attempt in range(2):
            waiter = asyncio.ensure_future(self._wait_state({0, 2}, DISCONNECT_TIMEOUT))
            await asyncio.sleep(0)
            try:
                await self.connector.disconnect()
                state = await waiter
            except asyncio.TimeoutError as exc:
                raise ProtocolError("timeout", "Disconnecting took too long") from exc
            except Exception as exc:  # noqa: BLE001
                raise ProtocolError("disconnect_failed", _error_text(exc)) from exc
            finally:
                if not waiter.done():
                    waiter.cancel()
            if int(state.type) != 2:
                break
        if int(state.type) == 2:
            raise ProtocolError("disconnect_failed", "The connection came back up; try again")
        if int(state.type) == 4:
            raise ProtocolError("disconnect_failed", self.last_state.get("errorMessage") or "Disconnecting failed")
        return {"disconnected": True}

    async def reconnect(self) -> dict:
        target = (self.last_target or {}).get("target")
        if not target:
            server = (self.last_state.get("server") or {}).get("name")
            if not server:
                raise ProtocolError("nothing_to_reconnect", "There is no previous connection to restore")
            target = {"targetType": "server", "serverName": server, "features": []}
        if self.connector.is_connection_active:
            await self.disconnect()
        return await self.connect(dict(target))

    # -------------------------------------------------------------- settings

    async def _load_settings_cache(self) -> dict:
        settings = await self.api.load_settings()
        self._settings_cache = self._settings_dict(settings)
        return self._settings_cache

    def _settings_dict(self, s) -> dict:
        st = s.features.split_tunneling

        def cfg(mode: str) -> dict:
            c = st.config_by_mode.get(mode)
            return {"apps": list(getattr(c, "app_paths", []) or []), "ips": list(getattr(c, "ip_ranges", []) or [])}

        mode = st.mode.value if hasattr(st.mode, "value") else str(st.mode)
        return {
            "protocol": s.protocol,
            "killswitch": int(s.killswitch),
            "netshield": int(s.features.netshield),
            "vpnAccelerator": bool(s.features.vpn_accelerator),
            "moderateNat": bool(s.features.moderate_nat),
            "portForwarding": bool(s.features.port_forwarding),
            "ipv6": bool(s.ipv6),
            "customDns": {"enabled": bool(s.custom_dns.enabled),
                          "ips": [{"ip": str(e.ip), "enabled": bool(e.enabled)} for e in s.custom_dns.ip_list]},
            "splitTunneling": {"enabled": bool(st.enabled), "mode": mode,
                               "exclude": cfg("exclude"), "include": cfg("include"), **cfg(mode)},
            "anonymousCrashReports": bool(s.anonymous_crash_reports),
            "telemetry": bool(getattr(s, "telemetry", False)),
        }

    def protocols(self) -> list[dict]:
        if not self.connector:
            return []
        out = []
        for group in ("generic", "protun"):
            try:
                for cls in self.connector.iter_available_protocols(group):
                    key = cls.get_key() if hasattr(cls, "get_key") else getattr(cls, "protocol", "")
                    if key and all(p["key"] != key for p in out):
                        out.append({"key": key, "label": clean_text(getattr(cls, "ui_protocol", key) or key, 32),
                                    "group": group})
            except Exception:  # noqa: BLE001 - a broken backend just isn't offered
                continue
        return out

    def _protocol_label(self, key: str) -> str:
        for p in self.protocols():
            if p["key"] == key:
                return p["label"]
        return {"wireguard": "WireGuard", "openvpn-udp": "OpenVPN (UDP)", "openvpn-tcp": "OpenVPN (TCP)",
                "protun-smart": "Smart", "protun-tls": "Stealth"}.get(key, key)

    async def set_setting(self, key: str, value: Any, force_disconnect: bool, resolve_conflict: bool) -> dict:
        self._require_login()
        tier = self._tier()
        if key in PAID_KEYS and tier < 1:
            raise ProtocolError("upgrade_required", "This setting needs a paid Proton VPN plan")
        settings = await self.api.load_settings()
        active = bool(self.connector.is_connection_active)
        connected = bool(self.connector.is_connected)
        st = settings.features.split_tunneling
        needs_disconnect = False
        reconnect_keys: set[str] = {key} if key in RECONNECT_KEYS else set()

        if key == "recommended":
            # Proton's own shipped defaults for this plan. Saved DNS servers and
            # split tunneling rules are kept but switched off, so nothing is lost.
            d = type(settings).default(tier)
            before = (settings.protocol, settings.ipv6, bool(settings.custom_dns.enabled))
            if d.protocol in [p["key"] for p in self.protocols()]:
                settings.protocol = d.protocol
            if int(settings.killswitch) != int(d.killswitch) and active:
                needs_disconnect = True
            settings.killswitch = d.killswitch
            settings.ipv6 = d.ipv6
            # Telemetry and crash reports are privacy choices: never re-enable them here.
            for attr in ("netshield", "moderate_nat", "vpn_accelerator", "port_forwarding"):
                setattr(settings.features, attr, getattr(d.features, attr))
            settings.custom_dns = self.mods["CustomDNS"](enabled=False, ip_list=settings.custom_dns.ip_list)
            st.enabled = False
            after = (settings.protocol, settings.ipv6, False)
            reconnect_keys = {k for k, b, a in zip(("protocol", "ipv6", "custom_dns"), before, after) if b != a}
        elif key == "netshield":
            if type(value) is not int or value not in (0, 1, 2):
                raise ProtocolError("bad_param", "NetShield must be 0, 1 or 2")
            settings.features.netshield = self.mods["NetShield"](value)
        elif key in BOOL_FEATURE_KEYS:
            setattr(settings.features, BOOL_FEATURE_KEYS[key], self._bool(value))
        elif key in ("ipv6", "anonymous_crash_reports", "telemetry"):
            setattr(settings, key, self._bool(value))
        elif key == "protocol":
            keys = [p["key"] for p in self.protocols()]
            if value not in keys:
                raise ProtocolError("bad_param", "That protocol is not available on this system")
            settings.protocol = value
        elif key == "killswitch":
            if type(value) is not int or value not in (0, 1, 2):
                raise ProtocolError("bad_param", "Kill switch must be 0, 1 or 2")
            if value > 0 and st.enabled:
                if not resolve_conflict:
                    raise ProtocolError("conflict_split_tunneling",
                                        "Kill Switch cannot run with Split Tunneling")
                st.enabled = False
            if int(settings.killswitch) != value and active:
                needs_disconnect = True
            settings.killswitch = value
        elif key == "custom_dns":
            settings.custom_dns = self._custom_dns(value)
        elif key == "split_tunneling":
            enabled = self._apply_split_tunneling(st, value)
            if enabled and int(settings.killswitch) > 0:
                if not resolve_conflict:
                    raise ProtocolError("conflict_kill_switch", "Split Tunneling cannot run with Kill Switch on")
                settings.killswitch = 0
                if active:
                    needs_disconnect = True
            if enabled and not self.connector.is_split_tunneling_available:
                raise ProtocolError("daemon_missing",
                                    "Split Tunneling needs proton.VPN.service: "
                                    "sudo systemctl enable --now proton.VPN.service")
        else:
            raise ProtocolError("bad_param", "Unknown setting")

        if needs_disconnect:
            if not force_disconnect:
                raise ProtocolError("requires_disconnect", "Disconnect to change the Kill Switch")
            await self.disconnect()
            active = connected = False

        try:
            await self.api.save_settings(settings)
        except Exception as exc:  # noqa: BLE001
            raise ProtocolError("save_failed", _error_text(exc)) from exc
        requires_reconnect = active and bool(reconnect_keys)
        if requires_reconnect:
            self.requires_reconnect.update(reconnect_keys)
            self.last_state["requiresReconnectFlags"] = sorted(self.requires_reconnect)
            self.emit("state", self.last_state)
        self._settings_cache = self._settings_dict(settings)
        self.emit("settings", self._settings_cache)
        return {"appliedLive": connected and not requires_reconnect and tier >= 1,
                "requiresReconnect": requires_reconnect, "disconnected": needs_disconnect}

    @staticmethod
    def _bool(value: Any) -> bool:
        if not isinstance(value, bool):
            raise ProtocolError("bad_param", "Value must be true or false")
        return value

    def _custom_dns(self, value: Any):
        if not isinstance(value, dict):
            raise ProtocolError("bad_param", "custom_dns must be an object")
        ips = value.get("ips", [])
        if not isinstance(ips, list) or len(ips) > MAX_DNS:
            raise ProtocolError("bad_param", f"Up to {MAX_DNS} DNS servers are allowed")
        entries, seen = [], set()
        from protocol import ip_address  # noqa: PLC0415
        for item in ips:
            ip = ip_address(item.get("ip") if isinstance(item, dict) else item)
            if ip in seen:
                continue
            seen.add(ip)
            enabled = item.get("enabled", True) if isinstance(item, dict) else True
            entries.append(self.mods["CustomDNSEntry"].new_from_string(ip, enabled=bool(enabled)))
        enabled = self._bool(value.get("enabled", False))
        if enabled and not entries:
            raise ProtocolError("bad_param", "Add at least one DNS server first")
        return self.mods["CustomDNS"](enabled=enabled, ip_list=entries)

    def _apply_split_tunneling(self, st, value: Any) -> bool:
        if not isinstance(value, dict):
            raise ProtocolError("bad_param", "split_tunneling must be an object")
        mode = value.get("mode", st.mode.value)
        if mode not in ("exclude", "include"):
            raise ProtocolError("bad_param", "Mode must be exclude or include")
        enabled = self._bool(value.get("enabled", st.enabled))
        current = st.config_by_mode.get(mode)
        apps = value.get("apps", list(getattr(current, "app_paths", []) or []))
        ips = value.get("ips", list(getattr(current, "ip_ranges", []) or []))
        stored = set()
        for cfg in st.config_by_mode.values():
            stored.update(str(p) for p in (getattr(cfg, "app_paths", []) or []))
        apps, nets = split_tunnel.validate_rules(apps, ips, stored)
        mode_enum = self.mods["SplitTunnelingMode"](mode)
        st.config_by_mode[mode] = self.mods["SplitTunnelingConfig"](mode=mode_enum, app_paths=apps, ip_ranges=nets)
        st.mode = mode_enum
        st.enabled = enabled
        return enabled

    # ------------------------------------------------------------------ auth

    async def login(self, username: str, password: str) -> dict:
        if not self.available:
            raise ProtocolError("unavailable", self.import_error or "Proton VPN is unavailable")
        if self._logged_in():
            raise ProtocolError("already_logged_in", "Already signed in")
        try:
            result = await self.api.login(username, password)
        except Exception as exc:  # noqa: BLE001
            raise self._auth_error(exc) from exc
        finally:
            password = ""  # noqa: F841 - drop the reference promptly
        if not result.authenticated:
            raise ProtocolError("bad_credentials", "Incorrect username or password")
        if result.twofa_required:
            self.twofa_pending = True
            return {"status": "2fa_required", "supportsFido2": self._supports_fido2()}
        await self._finish_login()
        return {"status": "ok"}

    def _supports_fido2(self) -> bool:
        try:
            return bool(self.api.supports_fido2)
        except Exception:  # noqa: BLE001
            return False

    async def submit_totp(self, code: str) -> dict:
        if not self.twofa_pending:
            raise ProtocolError("no_2fa", "Sign in again to continue")
        session_exc = self.mods["session_exc"]
        try:
            result = await self.api.submit_2fa_code(code)
        except session_exc.ProtonAPIAuthenticationNeeded as exc:
            self.twofa_pending = False
            raise ProtocolError("session_expired", "Too many attempts; sign in again") from exc
        except Exception as exc:  # noqa: BLE001
            raise self._auth_error(exc) from exc
        finally:
            code = ""  # noqa: F841
        if not result.success:
            raise ProtocolError("bad_code", "That code is not valid")
        await self._finish_login()
        return {"status": "ok"}

    async def fido2_start(self) -> dict:
        if not self.twofa_pending:
            raise ProtocolError("no_2fa", "Sign in again to continue")
        if not self._supports_fido2():
            raise ProtocolError("fido2_unsupported", "Security keys are not available for this sign-in")
        if self._fido2_task and not self._fido2_task.done():
            return {"started": True}
        self._fido2_cancel = threading.Event()
        self._fido2_task = asyncio.get_running_loop().create_task(self._fido2_flow(self._fido2_cancel))
        return {"started": True}

    async def _fido2_flow(self, cancel: threading.Event) -> None:
        exc_mod = self.mods["vpn_session_exc"]
        session_exc = self.mods["session_exc"]
        interaction = _Fido2Interaction(self, asyncio.get_running_loop())
        deadline = time.monotonic() + FIDO2_TIMEOUT
        try:
            while True:
                try:
                    assertion = await self.api.generate_2fa_fido2_assertion(interaction, cancel_assertion=cancel)
                    break
                except exc_mod.SecurityKeyNotFoundError:
                    if cancel.is_set() or time.monotonic() > deadline:
                        raise
                    self.emit("fido2_prompt", {"kind": "insert"})
                    await asyncio.sleep(1.5)
            if cancel.is_set():
                raise asyncio.CancelledError
            try:
                result = await self.api.submit_2fa_fido2(assertion)
            except session_exc.ProtonAPIAuthenticationNeeded:
                self.twofa_pending = False
                self.emit("auth", {"status": "error", "code": "session_expired",
                                   "message": "The sign-in session expired; sign in again"})
                return
            if not result.success:
                self.emit("auth", {"status": "error", "code": "key_rejected",
                                   "message": "The security key was rejected"})
                return
            await self._finish_login()
            self.emit("auth", {"status": "ok"})
        except asyncio.CancelledError:
            cancel.set()
            self.emit("auth", {"status": "cancelled"})
        except Exception as exc:  # noqa: BLE001
            code = {"SecurityKeyNotFoundError": "key_not_found", "SecurityKeyTimeoutError": "key_timeout",
                    "SecurityKeyPINInvalidError": "pin_invalid", "SecurityKeyPINNotSetError": "pin_not_set",
                    "InvalidSecurityKeyError": "key_invalid"}.get(type(exc).__name__, "fido2_failed")
            if cancel.is_set():
                self.emit("auth", {"status": "cancelled"})
            else:
                self.emit("auth", {"status": "error", "code": code, "message": _error_text(exc)})
        finally:
            if self._pin_future and not self._pin_future.done():
                self._pin_future.cancel()
            self._pin_future = None

    async def _wait_for_pin(self) -> str:
        self._pin_future = asyncio.get_running_loop().create_future()
        self.emit("fido2_prompt", {"kind": "pin"})
        return await self._pin_future

    def fido2_pin(self, pin: str) -> dict:
        if not self._pin_future or self._pin_future.done():
            raise ProtocolError("no_pin_request", "The security key is not asking for a PIN")
        self._pin_future.set_result(pin)
        return {"accepted": True}

    def fido2_cancel(self) -> dict:
        if self._fido2_cancel:
            self._fido2_cancel.set()
        if self._pin_future and not self._pin_future.done():
            self._pin_future.set_result("")
        if self._fido2_task and not self._fido2_task.done():
            self._fido2_task.cancel()
        return {"cancelled": True}

    def _auth_error(self, exc: BaseException) -> ProtocolError:
        name = type(exc).__name__
        if name in ("ProtonAPINotReachable", "TimeoutError", "ProtonAPINotAvailable"):
            return ProtocolError("offline", "Cannot reach Proton; check your internet connection")
        if name in ("KeyringLocked",):
            return ProtocolError("keyring_locked", "Unlock your keyring (Secret Service) and try again")
        if name.startswith("Keyring") or "keyring" in str(exc).lower():
            return ProtocolError("keyring", "No usable Secret Service keyring; install and unlock one")
        if name == "ProtonAPIHumanVerificationNeeded":
            return ProtocolError("human_verification",
                                 "Proton requires human verification; sign in once with the Proton VPN app")
        if name == "RuntimeError" and "U2F" in str(exc):
            return ProtocolError("fido2_unsupported", "Security key support (python-fido2) is not installed")
        return ProtocolError("auth_failed", _error_text(exc))

    async def _finish_login(self) -> None:
        self.twofa_pending = False
        await self._after_login()
        self.emit("snapshot", await self.snapshot())

    async def logout(self) -> dict:
        self._require_login()
        if self.connector.is_connection_active:
            await self.disconnect()
        try:
            await self.api.logout()
        except Exception as exc:  # noqa: BLE001
            raise ProtocolError("logout_failed", _error_text(exc)) from exc
        self.refresher_enabled = False
        self.index.rebuild([], 0)
        self._settings_cache = None
        self.last_target = None
        self.emit("snapshot", await self.snapshot())
        return {"loggedOut": True}

    async def refresh_account(self) -> dict:
        self._require_login()
        try:
            await self.api.refresh_vpn_info()
        except Exception as exc:  # noqa: BLE001
            raise ProtocolError("refresh_failed", _error_text(exc)) from exc
        snap = await self.snapshot()
        self.emit("snapshot", snap)
        return snap["auth"]

    # -------------------------------------------------------------- snapshot

    def _account(self) -> dict:
        logged_in = self._logged_in()
        out = {"loggedIn": logged_in, "twofaPending": self.twofa_pending, "accountName": "", "planName": "",
               "planTitle": "", "tier": 0, "maxConnections": 0, "delinquent": False,
               "supportsFido2": self._supports_fido2() if self.twofa_pending else False}
        if not logged_in:
            return out
        try:
            out["accountName"] = clean_text(self.api.account_name or "", 128)
        except Exception:  # noqa: BLE001
            pass
        acct = None
        try:
            acct = self.api.account_data
        except Exception:  # noqa: BLE001
            pass
        if acct is not None:
            for key, attr, conv in (("planName", "plan_name", str), ("planTitle", "plan_title", str),
                                    ("tier", "max_tier", int), ("maxConnections", "max_connections", int),
                                    ("delinquent", "delinquent", bool)):
                try:
                    value = getattr(acct, attr)
                    out[key] = clean_text(value, 64) if conv is str else conv(value)
                except Exception:  # noqa: BLE001
                    continue
        return out

    async def snapshot(self) -> dict:
        auth = self._account()
        settings = None
        if self.available and auth["loggedIn"]:
            try:
                settings = await self._load_settings_cache()
            except Exception as exc:  # noqa: BLE001
                log.warning("settings load failed: %s", _error_text(exc))
                settings = self._settings_cache
        split_ok = False
        if self.connector is not None:
            try:
                split_ok = bool(self.connector.is_split_tunneling_available)
            except Exception:  # noqa: BLE001
                pass
        return {
            "bridge": {"pid": os.getpid(), "startedMs": self.started_ms, "version": plugin_version()},
            "deps": {"protonApi": self.available, "error": self.import_error,
                     "splitTunnelDaemon": split_ok},
            "auth": auth,
            "state": self.last_state,
            "settings": settings,
            "capabilities": {"protocols": self.protocols(), "splitTunneling": split_ok,
                             "fido2": auth["supportsFido2"]},
            "profiles": self.profiles.snapshot(),
            "servers": self.servers_summary() if auth["loggedIn"] else
            {"countryCount": 0, "serverCount": 0, "updatedAtMs": 0, "countries": []},
        }

    async def diagnostics(self) -> dict:
        checks = []

        def add(key: str, ok: bool, detail: str = "", hint: str = "") -> None:
            checks.append({"key": key, "ok": bool(ok), "detail": clean_text(detail, 160),
                           "hint": clean_text(hint, 160)})

        runtime = os.environ.get("XDG_RUNTIME_DIR", "")
        add("runtimeDir", bool(runtime) and os.path.isdir(runtime), runtime or "unset")
        add("protonApi", self.available, self.import_error or "Loaded",
            "" if self.available else "Install proton-vpn-cli or python-proton-vpn-api-core")
        if self.available:
            try:
                nm = bool(self.api.validate_connection_availability())
            except Exception as exc:  # noqa: BLE001
                nm, err = False, _error_text(exc)
            else:
                err = "Ready" if nm else "No usable VPN backend"
            add("networkManager", nm, err, "" if nm else "Make sure NetworkManager is running")
            split_ok = False
            try:
                split_ok = bool(self.connector.is_split_tunneling_available)
            except Exception:  # noqa: BLE001
                pass
            add("splitTunnelDaemon", split_ok, "Active" if split_ok else "Inactive",
                "" if split_ok else "sudo systemctl enable --now proton.VPN.service")
            try:
                self.api.is_user_logged_in()
                add("keyring", True, "Secret Service OK")
            except Exception as exc:  # noqa: BLE001
                add("keyring", False, _error_text(exc), "Install and unlock a Secret Service keyring")
            protos = self.protocols()
            add("protocols", bool(protos), ", ".join(p["label"] for p in protos) or "None")
        add("bridge", True, f"PID {os.getpid()}, up {(_now_ms() - self.started_ms) // 1000}s")
        return {"checks": checks}
