import os
import random
import sys
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))

from server_index import P2P, SECURE_CORE, STREAMING, TOR, Record, ServerIndex  # noqa: E402

COUNTRIES = [("CH", "Switzerland", ["Zurich", "Geneva"]), ("US", "United States", ["New York", "Seattle", "Miami"]),
             ("SE", "Sweden", ["Stockholm"]), ("IS", "Iceland", ["Reykjavik"]), ("NL", "Netherlands", ["Amsterdam"]),
             ("DE", "Germany", ["Berlin", "Frankfurt"]), ("JP", "Japan", ["Tokyo"])]


def make_records(n=5000, seed=1):
    rng = random.Random(seed)
    names = {c: n_ for c, n_, _ in COUNTRIES}
    out = []
    counters = {}
    for i in range(n):
        code, cname, cities = COUNTRIES[i % len(COUNTRIES)]
        sc = i % 23 == 0 and code not in ("CH", "SE", "IS")
        entry = rng.choice(["CH", "SE", "IS"]) if sc else code
        counters[code] = counters.get(code, 0) + 1
        prefix = f"{entry}-{code}" if sc else code
        features = (SECURE_CORE if sc else 0) | (P2P if i % 3 == 0 else 0) | (TOR if i % 31 == 0 else 0) \
            | (STREAMING if i % 4 == 0 else 0)
        out.append(Record(name=f"{prefix}#{counters[code]}", exit_country=code, entry_country=entry, exit_name=cname,
                          entry_name=names[entry], city=rng.choice(cities), load=rng.randint(1, 99),
                          score=rng.random() * 5, tier=0 if i % 10 == 0 else 2, enabled=i % 97 != 0,
                          features=features))
    return out


class ServerIndexTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.records = make_records()
        cls.index = ServerIndex(cls.records)

    def test_countries(self):
        rows = self.index.countries()
        self.assertEqual({r["code"] for r in rows}, {c for c, _, _ in COUNTRIES})
        self.assertEqual([r["name"] for r in rows], sorted(r["name"] for r in rows))
        ch = next(r for r in rows if r["code"] == "CH")
        self.assertEqual(ch["cityCount"], 2)

    def test_secure_core_filter(self):
        rows = self.index.countries(feature="secure_core")
        self.assertTrue(rows)
        self.assertNotIn("CH", {r["code"] for r in rows})
        detail = self.index.country_detail("US", feature="secure_core")
        self.assertEqual(detail["cities"], [])
        self.assertTrue(detail["secureCore"])
        for hop in detail["secureCore"]:
            self.assertIn(hop["entryCountry"], ("CH", "SE", "IS"))

    def test_free_tier_locks(self):
        rows = self.index.countries(user_tier=0)
        self.assertTrue(all("locked" in r for r in rows))
        servers = self.index.city_servers("CH", "Zurich", user_tier=0)
        self.assertTrue(any(s["locked"] for s in servers))
        self.assertTrue(any(not s["locked"] for s in servers))
        pick = self.index.pick({"targetType": "fastest", "features": []}, user_tier=0)
        self.assertEqual(pick.tier, 0)

    def test_pick_respects_filters(self):
        r = self.index.pick({"targetType": "city", "country": "US", "city": "Seattle", "features": ["p2p"]}, 2)
        self.assertEqual((r.exit_country, r.city), ("US", "Seattle"))
        self.assertTrue(r.features & P2P)
        self.assertFalse(r.secure_core)
        sc = self.index.pick({"targetType": "secure_core", "country": "US", "entryCountry": "IS", "features": []}, 2)
        self.assertTrue(sc.secure_core)
        self.assertEqual(sc.entry_country, "IS")
        self.assertTrue(sc.enabled)
        self.assertIsNone(self.index.pick({"targetType": "country", "country": "ZZ", "features": []}, 2))
        self.assertEqual(self.index.pick({"targetType": "server", "serverName": "ch#1"}, 2).name, "CH#1")

    def test_search(self):
        res = self.index.search("swi")
        self.assertEqual(res["countries"][0]["code"], "CH")
        res = self.index.search("zur")
        self.assertEqual(res["cities"][0]["city"], "Zurich")
        res = self.index.search("ch#1")
        self.assertEqual(res["servers"][0]["name"], "CH#1")
        res = self.index.search("us")
        self.assertEqual(res["countries"][0]["code"], "US")

    def test_city_servers_sorted_and_bounded(self):
        rows = self.index.city_servers("US", "New York", limit=300)
        self.assertLessEqual(len(rows), 300)
        enabled_scores = [r["score"] for r in rows if not r["maintenance"] and not r["locked"]]
        self.assertEqual(enabled_scores, sorted(enabled_scores))

    def test_performance(self):
        big = ServerIndex(make_records(18000, seed=3))
        start = time.perf_counter()
        for q in ("swi", "new", "us-ny#4", "berlin", "x"):
            big.search(q)
        big.countries()
        big.country_detail("US")
        elapsed_ms = (time.perf_counter() - start) * 1000 / 7
        self.assertLess(elapsed_ms, 40, f"avg query {elapsed_ms:.1f} ms")


if __name__ == "__main__":
    unittest.main()
