"""Live tunnel throughput from /sys/class/net/<iface>/statistics.

Only sampled while the panel is open and connected, so the bridge costs
nothing in the background.
"""

from __future__ import annotations

import os
import time

SYS_NET = "/sys/class/net"
CANDIDATES = ("proton0", "pvpn0", "tun0")


def _read_int(path: str) -> int | None:
    try:
        with open(path, "r", encoding="ascii") as fh:
            return int(fh.read().strip() or 0)
    except (OSError, ValueError):
        return None


def detect_interface(preferred: str = "", sys_net: str = SYS_NET) -> str:
    """Best guess at the active Proton tunnel interface."""
    names = []
    if preferred:
        names.append(preferred)
    names.extend(CANDIDATES)
    try:
        listing = sorted(os.listdir(sys_net))
    except OSError:
        listing = []
    names.extend(n for n in listing if n.startswith("proton") or n.startswith("pvpn"))
    for name in names:
        if "intrf" in name:  # kill switch / IPv6 leak dummies, not the tunnel
            continue
        if os.path.isdir(os.path.join(sys_net, name)):
            return name
    return ""


def read_totals(iface: str, sys_net: str = SYS_NET) -> tuple[int, int] | None:
    """Session byte counters (rx, tx) of a tunnel interface, or None."""
    if not iface or "/" in iface or iface.startswith("."):
        return None
    stats = os.path.join(sys_net, iface, "statistics")
    rx = _read_int(os.path.join(stats, "rx_bytes"))
    tx = _read_int(os.path.join(stats, "tx_bytes"))
    return None if rx is None or tx is None else (rx, tx)


class TrafficMeter:
    def __init__(self, sys_net: str = SYS_NET):
        self.sys_net = sys_net
        self.iface = ""
        self._last: tuple[float, int, int] | None = None
        self._base: tuple[int, int] | None = None

    def reset(self, iface: str = "") -> None:
        self.iface = iface
        self._last = None
        self._base = None

    def sample(self, now: float | None = None) -> dict | None:
        if not self.iface or not os.path.isdir(os.path.join(self.sys_net, self.iface)):
            self.iface = detect_interface(self.iface, self.sys_net)
            self._last = None
            self._base = None
        if not self.iface:
            return None
        stats = os.path.join(self.sys_net, self.iface, "statistics")
        rx = _read_int(os.path.join(stats, "rx_bytes"))
        tx = _read_int(os.path.join(stats, "tx_bytes"))
        if rx is None or tx is None:
            return None
        now = time.monotonic() if now is None else now
        if self._base is None:
            self._base = (rx, tx)
        rx_rate = tx_rate = 0.0
        if self._last is not None:
            dt = now - self._last[0]
            if dt > 0:
                rx_rate = max(0.0, (rx - self._last[1]) / dt)
                tx_rate = max(0.0, (tx - self._last[2]) / dt)
        self._last = (now, rx, tx)
        return {
            "iface": self.iface,
            "rxBytesPerSec": round(rx_rate),
            "txBytesPerSec": round(tx_rate),
            # Interface counters start at zero when the tunnel comes up, so
            # they are the session totals.
            "totalRxBytes": rx,
            "totalTxBytes": tx,
        }
