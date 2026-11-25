.pragma library

// Pure helpers shared by Service.qml, Panel.qml and components. No QML
// imports so tests/test_model.mjs can exercise them under node.

var CONTROL_RE = /[\u0000-\u0008\u000b-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g

// Bounded plain text with markup neutralized. Used for anything that can
// reach a tooltip, notification body, or rich-text-capable surface.
function sanitizeText(value, maxLen) {
  var limit = maxLen === undefined ? 240 : maxLen
  var text = value === undefined || value === null ? "" : String(value)
  text = text.replace(/[\r\n\t]+/g, " ").replace(CONTROL_RE, "")
  // Without < and > no tag can form; entities then only ever render as text.
  text = text.replace(/</g, "\u2039").replace(/>/g, "\u203a")
  text = text.trim()
  if (text.length > limit) text = text.substring(0, Math.max(0, limit - 1)) + "\u2026"
  return text
}

function formatBytes(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n < 0) n = 0
  var units = ["B", "KB", "MB", "GB", "TB"]
  var i = 0
  while (n >= 1000 && i < units.length - 1) { n /= 1000; i++ }
  var digits = i === 0 || n >= 100 ? 0 : (n >= 10 ? 1 : 2)
  return n.toFixed(digits) + " " + units[i]
}

function formatRate(bytesPerSec) {
  return formatBytes(bytesPerSec) + "/s"
}

function pad2(n) { return (n < 10 ? "0" : "") + n }

function formatDuration(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds) || 0))
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  var sec = s % 60
  return pad2(h) + ":" + pad2(m) + ":" + pad2(sec)
}

// Compact elapsed time for the bar tooltip: "<1 min", "12 min", "2 h 05 min".
function shortDuration(seconds) {
  var m = Math.floor(Math.max(0, Number(seconds) || 0) / 60)
  if (m < 1) return "<1 min"
  if (m < 60) return m + " min"
  return Math.floor(m / 60) + " h " + pad2(m % 60) + " min"
}

// 0 = low, 1 = medium, 2 = high. Matches Proton's own 75/90 thresholds.
function loadLevel(load) {
  var n = Number(load)
  if (!isFinite(n)) return 0
  if (n >= 90) return 2
  if (n >= 75) return 1
  return 0
}

function clampLoad(load) {
  var n = Math.round(Number(load) || 0)
  return Math.max(0, Math.min(100, n))
}

// WCAG relative luminance of a Qt color-like object ({r,g,b} in 0..1) or a
// "#rrggbb" string.
function luminance(color) {
  var r, g, b
  if (typeof color === "string") {
    var hex = color.replace("#", "")
    if (hex.length === 8) hex = hex.substring(2)
    if (hex.length !== 6) return 0
    r = parseInt(hex.substring(0, 2), 16) / 255
    g = parseInt(hex.substring(2, 4), 16) / 255
    b = parseInt(hex.substring(4, 6), 16) / 255
  } else if (color) {
    r = Number(color.r); g = Number(color.g); b = Number(color.b)
  } else {
    return 0
  }
  function lin(c) { return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4) }
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
}

function isLightColor(color) {
  return luminance(color) > 0.45
}

// Parse `color2 = "#a6e3a1"` style lines out of an Omarchy colors.toml.
function parseThemeColor(text, key) {
  if (!text) return ""
  var re = new RegExp("^\\s*" + key + "\\s*=\\s*[\"']?(#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?)[\"']?\\s*(?:#.*)?$", "m")
  var m = re.exec(String(text))
  return m ? m[1] : ""
}

var STATE_KEYS = ["disconnected", "connecting", "connected", "disconnecting", "error"]

function isActiveState(state) {
  return state === "connected" || state === "connecting"
}

function locationLabel(server) {
  if (!server) return ""
  var parts = []
  if (server.secureCore && server.entryName) return server.entryName + " \u2192 " + (server.countryName || server.country || "")
  if (server.city) parts.push(server.city)
  if (server.countryName) parts.push(server.countryName)
  else if (server.country) parts.push(server.country)
  return parts.join(", ")
}

// English one-liner for the IPC `status` call (never localized: scripts parse it).
function statusLine(state, server, details) {
  var s = String(state || "disconnected")
  if (s === "connected") {
    var name = server && server.name ? server.name : "?"
    var loc = server ? [server.city, server.country].filter(function(x) { return !!x }).join(", ") : ""
    var ip = details && details.vpnIp ? " " + details.vpnIp : ""
    return "Connected: " + name + (loc ? " (" + loc + ")" : "") + ip
  }
  if (s === "connecting") return "Connecting" + (server && server.name ? ": " + server.name : "")
  if (s === "disconnecting") return "Disconnecting"
  if (s === "error") return "Error"
  return "Disconnected"
}

// Normalized description of what a connect target is, for favorites keys.
function targetKey(target) {
  if (!target) return ""
  var t = target.targetType
  var feats = (target.features || []).slice().sort()
  if (feats.length > 0 && (t === "country" || t === "city" || t === "server" || t === "secure_core" || t === "fastest" || t === "random")) {
    var base = {}
    for (var k in target) base[k] = target[k]
    base.features = []
    return targetKey(base) + "+" + feats.join(",")
  }
  if (t === "country") return "country:" + target.country
  if (t === "city") return "city:" + target.country + ":" + target.city
  if (t === "server") return "server:" + String(target.serverName || "")
  if (t === "secure_core") return "sc:" + (target.entryCountry || "") + ":" + target.country
  if (t === "feature") return "feature:" + (target.features || []).slice().sort().join(",")
  if (t === "profile") return "profile:" + (target.profileId || "")
  return t || ""
}

function favoriteKeys(favorites) {
  var out = {}
  for (var i = 0; i < (favorites || []).length; i++) out[favorites[i].key] = favorites[i].id
  return out
}

function splitTunnelSummary(st) {
  if (!st || !st.enabled) return { enabled: false, mode: "", apps: 0, ips: 0 }
  return { enabled: true, mode: st.mode || "exclude", apps: (st.apps || []).length, ips: (st.ips || []).length }
}

function dnsSummary(dns) {
  if (!dns || !dns.enabled) return ""
  var ips = []
  for (var i = 0; i < (dns.ips || []).length; i++) if (dns.ips[i].enabled !== false) ips.push(dns.ips[i].ip)
  return ips.join(", ")
}

// Validators mirroring backend/protocol.py so the UI can reject input early.
// The bridge re-validates everything.
function isIpAddress(text) {
  var s = String(text || "").trim()
  if (/^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$/.test(s)) return true
  if (s.indexOf(":") >= 0 && /^[0-9a-fA-F:.]+$/.test(s) && s.length <= 45) {
    var dbl = s.split("::").length - 1
    if (dbl > 1) return false
    var groups = s.split(":").filter(function(g) { return g !== "" })
    return groups.length <= 8 && groups.every(function(g) { return g.length <= 4 || g.indexOf(".") >= 0 })
  }
  return false
}

function isIpNetwork(text) {
  var s = String(text || "").trim()
  var slash = s.indexOf("/")
  if (slash < 0) return isIpAddress(s)
  var ip = s.substring(0, slash)
  var bits = s.substring(slash + 1)
  if (!/^\d{1,3}$/.test(bits)) return false
  var n = parseInt(bits, 10)
  if (!isIpAddress(ip)) return false
  return ip.indexOf(":") >= 0 ? n <= 128 : n <= 32
}

function isAbsolutePath(text) {
  var s = String(text || "")
  return s.length > 1 && s.length <= 4096 && s.charAt(0) === "/" && !/[\u0000\n\r]/.test(s)
}

function basename(path) {
  var s = String(path || "")
  var i = s.lastIndexOf("/")
  return i >= 0 ? s.substring(i + 1) : s
}

function clamp(value, lo, hi) {
  return Math.max(lo, Math.min(hi, value))
}
