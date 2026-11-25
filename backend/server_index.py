"""Fast in-memory index over Proton's logical server list.

Works on plain normalized records (see `Record`) so it can be unit-tested
without the Proton API; proton_client adapts LogicalServer objects into it.
All queries run against precomputed lowercase haystacks and per-country
buckets, so a search across ~18k servers stays in the low milliseconds.
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field

# proton.vpn.session.servers.types.ServerFeatureEnum bit values.
SECURE_CORE = 1
TOR = 2
P2P = 4
STREAMING = 8
IPV6 = 16

FEATURE_BITS = {"secure_core": SECURE_CORE, "tor": TOR, "p2p": P2P, "streaming": STREAMING, "ipv6": IPV6}
MAX_ROWS = 300


def feature_tags(bits: int) -> list[str]:
    tags = []
    if bits & SECURE_CORE:
        tags.append("SC")
    if bits & P2P:
        tags.append("P2P")
    if bits & TOR:
        tags.append("TOR")
    if bits & STREAMING:
        tags.append("STR")
    if bits & IPV6:
        tags.append("IPv6")
    return tags


@dataclass
class Record:
    name: str
    exit_country: str
    entry_country: str
    exit_name: str
    entry_name: str
    city: str
    load: int
    score: float
    tier: int
    enabled: bool
    features: int
    smart_routing: bool = False
    exit_ips: dict = field(default_factory=dict, repr=False)  # entry IP -> exit IP
    hay: str = field(default="", repr=False)

    def __post_init__(self) -> None:
        self.hay = " ".join((self.name, self.city, self.exit_country, self.exit_name)).lower()

    @property
    def secure_core(self) -> bool:
        return bool(self.features & SECURE_CORE)


def _matches_feature(rec: Record, feature: str) -> bool:
    if feature in ("", "all"):
        return not rec.secure_core
    if feature == "secure_core":
        return rec.secure_core
    if feature == "free":
        return rec.tier == 0 and not rec.secure_core
    bit = FEATURE_BITS.get(feature, 0)
    return bool(rec.features & bit) and not rec.secure_core


def _server_row(rec: Record, user_tier: int) -> dict:
    return {
        "kind": "server",
        "name": rec.name,
        "country": rec.exit_country,
        "countryName": rec.exit_name,
        "entryCountry": rec.entry_country,
        "entryName": rec.entry_name,
        "city": rec.city,
        "load": rec.load,
        "score": round(rec.score, 3),
        "tier": rec.tier,
        "locked": rec.tier > user_tier,
        "maintenance": not rec.enabled,
        "features": feature_tags(rec.features),
        "smartRouting": rec.smart_routing,
        "secureCore": rec.secure_core,
    }


def _summary(records: list[Record], user_tier: int) -> dict:
    enabled = [r for r in records if r.enabled]
    usable = [r for r in enabled if r.tier <= user_tier]
    bits = 0
    for r in records:
        bits |= r.features
    best = min((r.load for r in (usable or enabled)), default=100)
    return {
        "serverCount": len(records),
        "bestLoad": best,
        "features": feature_tags(bits & ~SECURE_CORE),
        "minTier": min((r.tier for r in records), default=0),
        "locked": not usable,
        "maintenance": not enabled,
    }


class ServerIndex:
    def __init__(self, records: list[Record] | None = None):
        self.records: list[Record] = []
        self.by_name: dict[str, Record] = {}
        self.by_country: dict[str, list[Record]] = {}
        self.country_names: dict[str, str] = {}
        self.updated_at_ms = 0
        if records:
            self.rebuild(records)

    def rebuild(self, records: list[Record], updated_at_ms: int = 0) -> None:
        self.records = list(records)
        self.by_name = {r.name.upper(): r for r in self.records}
        self.by_country = {}
        self.country_names = {}
        for r in self.records:
            self.by_country.setdefault(r.exit_country, []).append(r)
            if r.exit_name:
                self.country_names.setdefault(r.exit_country, r.exit_name)
            if r.entry_name:
                self.country_names.setdefault(r.entry_country, r.entry_name)
        self.updated_at_ms = updated_at_ms

    def update_loads(self, loads: dict[str, tuple[int, float, bool]]) -> None:
        for name, (load, score, enabled) in loads.items():
            rec = self.by_name.get(name.upper())
            if rec:
                rec.load, rec.score, rec.enabled = load, score, enabled

    def country_name(self, code: str) -> str:
        return self.country_names.get(code, code)

    @property
    def country_count(self) -> int:
        return len(self.by_country)

    # --- listing -----------------------------------------------------------

    def countries(self, feature: str = "all", sort: str = "alpha", user_tier: int = 2) -> list[dict]:
        rows = []
        for code, recs in self.by_country.items():
            matching = [r for r in recs if _matches_feature(r, feature)]
            if not matching:
                continue
            row = {"kind": "country", "code": code, "name": self.country_name(code),
                   "cityCount": len({r.city for r in matching if r.city}),
                   "hasSecureCore": any(r.secure_core for r in recs)}
            row.update(_summary(matching, user_tier))
            rows.append(row)
        return self._sort(rows, sort, user_tier)

    def _sort(self, rows: list[dict], sort: str, user_tier: int) -> list[dict]:
        if sort == "load" or sort == "fastest":
            rows.sort(key=lambda r: (r.get("locked", False), r.get("maintenance", False),
                                     r.get("bestLoad", r.get("load", 100)), r.get("name", "")))
        else:
            # Free users see what they can use first, then the rest A-Z.
            if user_tier == 0:
                rows.sort(key=lambda r: (r.get("locked", False), r.get("name", "").lower()))
            else:
                rows.sort(key=lambda r: r.get("name", "").lower())
        return rows

    def country_detail(self, code: str, feature: str = "all", sort: str = "alpha", user_tier: int = 2) -> dict:
        recs = self.by_country.get(code, [])
        cities: dict[str, list[Record]] = {}
        sc: dict[str, list[Record]] = {}
        for r in recs:
            if r.secure_core:
                sc.setdefault(r.entry_country, []).append(r)
            elif _matches_feature(r, feature if feature != "secure_core" else "all"):
                cities.setdefault(r.city or "", []).append(r)
        city_rows = []
        if feature != "secure_core":
            for city, group in cities.items():
                row = {"kind": "city", "country": code, "countryName": self.country_name(code),
                       "city": city, "name": city or self.country_name(code)}
                row.update(_summary(group, user_tier))
                city_rows.append(row)
        sc_rows = []
        for entry, group in sc.items():
            row = {"kind": "secure_core", "country": code, "countryName": self.country_name(code),
                   "entryCountry": entry, "entryName": self.country_name(entry),
                   "name": self.country_name(entry) + " → " + self.country_name(code)}
            row.update(_summary(group, user_tier))
            sc_rows.append(row)
        return {
            "country": code,
            "countryName": self.country_name(code),
            "cities": self._sort(city_rows, sort, user_tier),
            "secureCore": self._sort(sc_rows, "load" if sort != "alpha" else "alpha", user_tier),
        }

    def city_servers(self, code: str, city: str, feature: str = "all", sort: str = "fastest",
                     user_tier: int = 2, limit: int = MAX_ROWS) -> list[dict]:
        recs = [r for r in self.by_country.get(code, [])
                if (r.city or "") == city and _matches_feature(r, feature if feature != "secure_core" else "all")]
        return self._server_rows(recs, sort, user_tier, limit)

    def secure_core_servers(self, code: str, entry: str, user_tier: int = 2, limit: int = MAX_ROWS) -> list[dict]:
        recs = [r for r in self.by_country.get(code, []) if r.secure_core and (not entry or r.entry_country == entry)]
        return self._server_rows(recs, "fastest", user_tier, limit)

    def _server_rows(self, recs: list[Record], sort: str, user_tier: int, limit: int) -> list[dict]:
        if sort == "alpha":
            recs = sorted(recs, key=lambda r: _natural_key(r.name))
        elif sort == "load":
            recs = sorted(recs, key=lambda r: (not r.enabled, r.tier > user_tier, r.load, r.score))
        else:
            recs = sorted(recs, key=lambda r: (not r.enabled, r.tier > user_tier, r.score))
        return [_server_row(r, user_tier) for r in recs[:limit]]

    # --- search ------------------------------------------------------------

    def search(self, query: str, feature: str = "all", user_tier: int = 2, limit: int = MAX_ROWS) -> dict:
        q = query.strip().lower()
        if not q:
            return {"countries": [], "cities": [], "servers": []}
        q_upper = q.upper()
        countries = []
        for code, recs in self.by_country.items():
            name = self.country_name(code).lower()
            if code.lower() == q or name.startswith(q) or (len(q) > 2 and q in name):
                matching = [r for r in recs if _matches_feature(r, feature)]
                if not matching:
                    continue
                row = {"kind": "country", "code": code, "name": self.country_name(code),
                       "cityCount": len({r.city for r in matching if r.city}),
                       "hasSecureCore": any(r.secure_core for r in recs),
                       "rank": 0 if code.lower() == q or name == q else (1 if name.startswith(q) else 2)}
                row.update(_summary(matching, user_tier))
                countries.append(row)
        countries.sort(key=lambda r: (r["rank"], r["name"]))

        city_groups: dict[tuple[str, str], list[Record]] = {}
        servers: list[tuple[int, Record]] = []
        for r in self.records:
            if not _matches_feature(r, feature):
                continue
            if r.city and q in r.city.lower():
                city_groups.setdefault((r.exit_country, r.city), []).append(r)
            upper = r.name.upper()
            if upper == q_upper:
                servers.append((0, r))
            elif upper.startswith(q_upper):
                servers.append((1, r))
            elif len(q) >= 3 and q_upper in upper:
                servers.append((2, r))
        cities = []
        for (code, city), group in city_groups.items():
            row = {"kind": "city", "country": code, "countryName": self.country_name(code), "city": city,
                   "name": city, "rank": 0 if city.lower().startswith(q) else 1}
            row.update(_summary(group, user_tier))
            cities.append(row)
        cities.sort(key=lambda r: (r["rank"], r["name"]))
        servers.sort(key=lambda t: (t[0], not t[1].enabled, _natural_key(t[1].name)))
        return {
            "countries": countries[:50],
            "cities": cities[:50],
            "servers": [_server_row(r, user_tier) for _, r in servers[:min(limit, 100)]],
        }

    # --- selection ---------------------------------------------------------

    def pick(self, target: dict, user_tier: int, exclude: str = "") -> Record | None:
        """Choose the best server for a validated connect target."""
        kind = target.get("targetType", "fastest")
        features = target.get("features") or []
        want_sc = kind == "secure_core" or "secure_core" in features
        if kind == "server":
            return self.by_name.get(str(target.get("serverName", "")).upper())
        if kind in ("country", "city", "secure_core"):
            pool = self.by_country.get(target.get("country", ""), [])
        else:
            pool = self.records
        candidates = []
        for r in pool:
            if not r.enabled or r.tier > user_tier or r.name == exclude:
                continue
            if r.secure_core != want_sc:
                continue
            if kind == "city" and (r.city or "") != target.get("city", ""):
                continue
            if kind == "secure_core" and target.get("entryCountry") and r.entry_country != target["entryCountry"]:
                continue
            if any(f != "secure_core" and not (r.features & FEATURE_BITS.get(f, 0)) for f in features):
                continue
            candidates.append(r)
        if not candidates:
            return None
        if kind == "random":
            return random.choice(candidates)
        return min(candidates, key=lambda r: (r.score, r.load))


def _natural_key(name: str) -> tuple:
    prefix, _, num = name.partition("#")
    try:
        return (prefix, int(num))
    except ValueError:
        return (prefix, 0, num)
