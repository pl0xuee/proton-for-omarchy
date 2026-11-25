// Unit tests for Model.js (QML `.pragma library`), run with: node tests/test_model.mjs
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import path from "node:path"
import vm from "node:vm"
import assert from "node:assert/strict"
import test from "node:test"

const here = path.dirname(fileURLToPath(import.meta.url))
const source = readFileSync(path.join(here, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const M = {}
vm.runInNewContext(source, M)

test("sanitizeText strips markup, controls and bounds length", () => {
  assert.equal(M.sanitizeText("<b>hi</b>"), "‹b›hi‹/b›")
  assert.equal(M.sanitizeText("a\u0000b‮c\nd"), "abc d")
  assert.equal(M.sanitizeText(null), "")
  assert.equal(M.sanitizeText("x".repeat(20), 10).length, 10)
  assert.equal(M.sanitizeText("Tom & Jerry"), "Tom & Jerry")
})

test("formatting helpers", () => {
  assert.equal(M.formatBytes(0), "0 B")
  assert.equal(M.formatBytes(1500), "1.50 KB")
  assert.equal(M.formatBytes(4_200_000), "4.20 MB")
  assert.equal(M.formatRate(310_000), "310 KB/s")
  assert.equal(M.formatBytes(-5), "0 B")
  assert.equal(M.formatDuration(5058), "01:24:18")
  assert.equal(M.formatDuration("bad"), "00:00:00")
})

test("load levels follow 75/90 thresholds", () => {
  assert.equal(M.loadLevel(10), 0)
  assert.equal(M.loadLevel(75), 1)
  assert.equal(M.loadLevel(90), 2)
  assert.equal(M.clampLoad(140), 100)
  assert.equal(M.clampLoad(-3), 0)
})

test("theme colors", () => {
  assert.ok(M.isLightColor("#eff1f5"))
  assert.ok(!M.isLightColor("#1e1e2e"))
  assert.ok(M.isLightColor({ r: 1, g: 1, b: 1 }))
  const toml = 'background = "#1e1e2e"\ngreen = "#a6e3a1"\ncolor3 = \'#f9e2af\' # yellow\n'
  assert.equal(M.parseThemeColor(toml, "green"), "#a6e3a1")
  assert.equal(M.parseThemeColor(toml, "color3"), "#f9e2af")
  assert.equal(M.parseThemeColor(toml, "color2"), "")
  assert.equal(M.parseThemeColor("green = \"red\"", "green"), "")
})

test("location and status lines", () => {
  const ch = { name: "CH#12", city: "Zurich", country: "CH", countryName: "Switzerland" }
  assert.equal(M.locationLabel(ch), "Zurich, Switzerland")
  assert.equal(M.locationLabel({ secureCore: true, entryName: "Iceland", countryName: "Switzerland" }), "Iceland → Switzerland")
  assert.equal(M.statusLine("connected", ch, { vpnIp: "203.0.113.42" }), "Connected: CH#12 (Zurich, CH) 203.0.113.42")
  assert.equal(M.statusLine("disconnected"), "Disconnected")
  assert.equal(M.statusLine("connecting", ch), "Connecting: CH#12")
})

test("targetKey matches backend/profiles.py target_key", () => {
  assert.equal(M.targetKey({ targetType: "country", country: "US" }), "country:US")
  assert.equal(M.targetKey({ targetType: "city", country: "US", city: "New York" }), "city:US:New York")
  assert.equal(M.targetKey({ targetType: "fastest", features: ["p2p"] }), "fastest+p2p")
  assert.equal(M.targetKey({ targetType: "server", serverName: "US-NY#42" }), "server:US-NY#42")
  assert.equal(M.targetKey({ targetType: "secure_core", country: "CH", entryCountry: "IS" }), "sc:IS:CH")
  assert.equal(M.targetKey({ targetType: "feature", features: ["tor", "p2p"] }), "feature:p2p,tor")
  assert.equal(M.targetKey({ targetType: "fastest" }), "fastest")
  assert.equal(M.targetKey({ targetType: "country", country: "DE", features: ["tor", "p2p"] }), "country:DE+p2p,tor")
  const keys = M.favoriteKeys([{ key: "country:US", id: "a1" }])
  assert.equal(keys["country:US"], "a1")
})

test("summaries", () => {
  assert.deepEqual(JSON.parse(JSON.stringify(M.splitTunnelSummary(null))), { enabled: false, mode: "", apps: 0, ips: 0 })
  const s = M.splitTunnelSummary({ enabled: true, mode: "include", apps: ["/usr/bin/a"], ips: ["10.0.0.0/8", "1.1.1.1"] })
  assert.equal(s.mode, "include"); assert.equal(s.apps, 1); assert.equal(s.ips, 2)
  assert.equal(M.dnsSummary({ enabled: true, ips: [{ ip: "1.1.1.1" }, { ip: "9.9.9.9", enabled: false }, { ip: "8.8.8.8" }] }), "1.1.1.1, 8.8.8.8")
  assert.equal(M.dnsSummary({ enabled: false, ips: [{ ip: "1.1.1.1" }] }), "")
})

test("IP validators", () => {
  for (const ok of ["1.1.1.1", "255.255.255.255", "::1", "2001:db8::1", "fe80::1:2:3:4"]) assert.ok(M.isIpAddress(ok), ok)
  for (const bad of ["256.1.1.1", "1.1.1", "01.1.1.1x", "abc", "1::2::3", "", "1.1.1.1; rm -rf /"]) assert.ok(!M.isIpAddress(bad), bad)
  assert.ok(M.isIpNetwork("10.0.0.0/8"))
  assert.ok(M.isIpNetwork("2001:db8::/32"))
  assert.ok(M.isIpNetwork("192.168.1.10"))
  assert.ok(!M.isIpNetwork("10.0.0.0/33"))
  assert.ok(!M.isIpNetwork("10.0.0.0/"))
  assert.ok(!M.isIpNetwork("2001:db8::/129"))
})

test("paths", () => {
  assert.ok(M.isAbsolutePath("/usr/bin/firefox"))
  assert.ok(!M.isAbsolutePath("firefox"))
  assert.ok(!M.isAbsolutePath("/"))
  assert.ok(!M.isAbsolutePath("/usr/bin/a\nb"))
  assert.equal(M.basename("/usr/bin/firefox"), "firefox")
  assert.equal(M.clamp(5, 0, 3), 3)
})
