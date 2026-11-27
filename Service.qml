import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// Owns the single backend bridge process and mirrors its state as plain QML
// properties. Loaded either by the shell (service kind, on the trusted stock
// bar) or inline by Panel.qml when the bar cannot hand over a service. The
// bridge only starts once something claims the service (`active`), so a
// shell-level instance nobody uses costs nothing.
Item {
  id: root

  // Injected by the shell for service plugins; unused but accepted.
  property var shell: null
  property var settings: ({})
  property bool active: false

  // ---------------------------------------------------------------- bridge
  readonly property string bridgePath: decodeURIComponent(String(Qt.resolvedUrl("backend/bridge.py")).replace(/^file:\/\//, ""))
  readonly property string depsScriptPath: decodeURIComponent(String(Qt.resolvedUrl("scripts/install-deps.sh")).replace(/^file:\/\//, ""))
  // Proton's libraries are not installed (or failed to import): offer the installer.
  readonly property bool depsMissing: snapshotLoaded && deps && deps.protonApi === false
  property int _depsChecks: 0
  property bool bridgeRunning: false
  property bool bridgeReady: false
  property bool bridgeFailed: false
  property string bridgeError: ""
  property int crashCount: 0
  property real bridgeStartedAt: 0
  property int _seq: 0
  property var _pending: ({})

  // ----------------------------------------------------------------- state
  property var deps: ({ protonApi: true, error: "", splitTunnelDaemon: false })
  property var auth: ({ loggedIn: false, twofaPending: false, accountName: "", planTitle: "", tier: 0, maxConnections: 0, supportsFido2: false })
  property string realState: "disconnected"
  property var server: null
  property var details: null
  property var forwardedPort: null
  property real connectedSinceMs: 0
  property string errorCode: ""
  property string errorMessage: ""
  property var requiresReconnect: []
  property var vpnSettings: null
  property var capabilities: ({ protocols: [], splitTunneling: false, fido2: false })
  property string pluginVersion: ""
  property var favorites: []
  property var recents: []
  property var history: []
  // What the live connection was asked for ({target, label, detail}); saved as a profile.
  property var currentTarget: null
  property var countries: []
  property int serverCount: 0
  property int countryCount: 0
  property real serversUpdatedAt: 0
  property var traffic: null
  property bool snapshotLoaded: false

  // Auth flow.
  property string authStep: "credentials"  // credentials | 2fa
  property bool authBusy: false
  property string authError: ""
  property string fido2Prompt: ""
  property bool fido2Running: false

  // Transient feedback for the panel ("Copied", errors from actions).
  property string actionError: ""
  property string toast: ""

  // Optimistic connect/disconnect: "" follows reality, otherwise the state the
  // user just asked for so the switch throws instantly.
  property string _desired: ""
  property string pendingLabel: ""
  property bool switching: false   // "Switch to fastest" in flight (loads refresh + reconnect)
  readonly property real _startedAtMs: Date.now()
  readonly property string connectionState: {
    if (_desired === "connected" && realState !== "connected" && realState !== "error") return "connecting"
    if (_desired === "disconnected" && realState !== "disconnected") return "disconnecting"
    return realState
  }
  readonly property bool connected: connectionState === "connected"
  readonly property bool busy: connectionState === "connecting" || connectionState === "disconnecting"
  readonly property bool switchOn: _desired !== "" ? _desired === "connected" : (realState === "connected" || realState === "connecting")
  readonly property bool loggedIn: auth && auth.loggedIn === true
  readonly property int tier: auth && auth.tier ? auth.tier : 0
  readonly property bool freeTier: loggedIn && tier < 1
  readonly property string statusText: Model.statusLine(connectionState, server, details)

  // Bar hover tooltip: the essentials without opening the panel. Refreshed
  // every 30 s while connected so the elapsed time stays roughly current.
  property real _tooltipTick: 0
  Timer {
    interval: 30000
    repeat: true
    running: root.active && root.connected
    onTriggered: root._tooltipTick = Date.now()
  }
  readonly property string tooltipText: {
    var tick = _tooltipTick
    var title = "Proton VPN"
    if (bridgeFailed || depsMissing) return title + "\n" + strings.t("tooltip.problem", "Backend problem: open the panel for details")
    if (snapshotLoaded && !loggedIn) return title + "\n" + strings.t("tooltip.signedOut", "Signed out: click to sign in")
    var st = connectionState
    var name = server && server.name ? String(server.name) : ""
    if (st === "connected") {
      var lines = [title + " · " + strings.t("tooltip.connected", "Connected")]
      lines.push([name, Model.locationLabel(server)].filter(function(x) { return x !== "" }).join(" · "))
      if (details && details.vpnIp) lines.push(strings.t("tooltip.vpnIp", "VPN IP %1").arg(details.vpnIp))
      var meta = []
      if (server && server.protocolLabel) meta.push(String(server.protocolLabel))
      if (connectedSinceMs > 0) meta.push(Model.shortDuration((Date.now() - connectedSinceMs) / 1000))
      if (meta.length) lines.push(meta.join(" · "))
      return lines.join("\n")
    }
    if (st === "connecting") return title + " · " + strings.t("tooltip.connecting", "Connecting…") + (name ? "\n" + name : "")
    if (st === "disconnecting") return title + " · " + strings.t("tooltip.disconnecting", "Disconnecting…")
    if (st === "error") return title + " · " + strings.t("tooltip.error", "Connection problem") + (errorMessage ? "\n" + errorMessage : "")
    return title + " · " + strings.t("tooltip.disconnected", "Disconnected") + "\n"
           + strings.t("tooltip.disconnectedHint", "Right-click to connect to the fastest server")
  }
  readonly property bool panelOpenWanted: _panelOpen && setting("bandwidthPolling", true)
  property bool _panelOpen: false

  // ----------------------------------------------------------- links
  // Constant Proton URLs only; nothing user-controlled is ever opened.
  readonly property string pricingUrl: "https://protonvpn.com/pricing"
  readonly property string signupUrl: "https://account.protonvpn.com/signup"
  signal upgradeOffered(string reason)
  // Panel open: offer the plans page. Closed (bar click, IPC, startup): a plain
  // error, so a modal does not pop up out of context the next time it opens.
  function offerUpgrade(reason) {
    var text = String(reason || strings.t("common.plusRequired", "Requires VPN Plus")).replace(/[.\s]+$/, "")
    if (_panelOpen) upgradeOffered(text)
    else _actionFailed({ message: text })
  }
  function openPricing() { Qt.openUrlExternally(pricingUrl) }
  function openSignup() { Qt.openUrlExternally(signupUrl) }

  // ----------------------------------------------------------- updates
  readonly property bool checkForUpdates: setting("checkForUpdates", true)
  property var update: ({ latest: "", gitInstall: false, dismissed: false })
  readonly property bool updateAvailable: checkForUpdates && update.latest !== "" && !update.dismissed

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // ------------------------------------------------------------- requests

  function request(cmd, params, callback, timeoutMs) {
    if (!bridge.running) {
      if (callback) callback(false, null, { code: "bridge_down", message: strings.t("error.bridgeDown", "Backend is not running") })
      return ""
    }
    _seq += 1
    var id = "q" + _seq
    var entry = { cb: callback || null, deadline: Date.now() + (timeoutMs || 15000) }
    var next = Object.assign({}, _pending)
    next[id] = entry
    _pending = next
    bridge.write(JSON.stringify({ id: id, cmd: cmd, params: params || {} }) + "\n")
    return id
  }

  function _resolve(id, ok, data, error) {
    var entry = _pending[id]
    if (!entry) return
    var next = Object.assign({}, _pending)
    delete next[id]
    _pending = next
    if (entry.cb) {
      try { entry.cb(ok, data, error) } catch (e) { console.warn("proton-for-omarchy: callback failed", e) }
    }
  }

  function _failAllPending(message) {
    var ids = Object.keys(_pending)
    for (var i = 0; i < ids.length; i++) _resolve(ids[i], false, null, { code: "bridge_down", message: message })
  }

  Timer {
    interval: 1000
    repeat: true
    running: Object.keys(root._pending).length > 0
    onTriggered: {
      var now = Date.now()
      var ids = Object.keys(root._pending)
      for (var i = 0; i < ids.length; i++) {
        if (root._pending[ids[i]] && root._pending[ids[i]].deadline < now)
          root._resolve(ids[i], false, null, { code: "timeout", message: strings.t("error.timeout", "The backend did not answer in time") })
      }
    }
  }

  // --------------------------------------------------------------- events

  function _handleLine(line) {
    if (!line || line.length === 0) return
    var msg
    try { msg = JSON.parse(line) } catch (e) { console.warn("proton-for-omarchy: bad bridge line"); return }
    if (!msg || typeof msg !== "object") return
    var type = String(msg.type || "")
    if (type === "reply") {
      _resolve(String(msg.id || ""), msg.ok === true, msg.data, msg.error || null)
      return
    }
    var data = msg.data
    if (type === "snapshot") _applySnapshot(data)
    else if (type === "state") _applyState(data)
    else if (type === "settings") vpnSettings = data
    else if (type === "traffic") traffic = data
    else if (type === "profiles") _applyProfiles(data)
    else if (type === "servers_updated") _applyServers(data)
    else if (type === "fido2_prompt") fido2Prompt = String((data && data.kind) || "")
    else if (type === "auth") _applyAuthEvent(data)
  }

  function _applySnapshot(s) {
    if (!s) return
    var wasReady = bridgeReady
    bridgeReady = true
    crashCount = 0
    if (!wasReady && panelOpenWanted) request("set_panel_open", { open: true })
    if (!wasReady && !autoRefreshWanted) request("set_auto_refresh", { enabled: false })
    if (!wasReady && !historyWanted) request("set_history", { enabled: false })
    deps = s.deps || deps
    auth = s.auth || auth
    if (s.state) _applyState(s.state)
    vpnSettings = s.settings || null
    capabilities = s.capabilities || capabilities
    pluginVersion = String((s.bridge && s.bridge.version) || pluginVersion)
    _applyProfiles(s.profiles)
    _applyServers(s.servers)
    if (auth.loggedIn) {
      authStep = "credentials"
      authError = ""
      fido2Running = false
      fido2Prompt = ""
    } else if (auth.twofaPending) {
      authStep = "2fa"
    }
    snapshotLoaded = true
    _maybeStartupConnect()
  }

  function _applyState(st) {
    if (!st) return
    var prev = realState
    realState = String(st.connectionState || "disconnected")
    server = st.server || null
    currentTarget = realState === "connected" ? (st.target || null) : null
    details = st.connectionDetails || (realState === "connected" ? details : null)
    forwardedPort = st.forwardedPort || null
    connectedSinceMs = Number(st.connectedSinceMs || 0)
    errorCode = String(st.errorCode || "")
    errorMessage = String(st.errorMessage || "")
    requiresReconnect = st.requiresReconnectFlags || []
    if (realState !== "connected") traffic = null
    // Optimistic intent is satisfied (or overruled by an error).
    if (_desired === realState || realState === "error") _desired = ""
    if (_desired === "connected" && prev === "connecting" && realState === "disconnected") _desired = ""
    if (snapshotLoaded && prev !== realState) _notifyTransition(prev, realState)
  }

  function _applyProfiles(p) {
    if (!p) return
    favorites = p.favorites || []
    recents = p.recents || []
    history = p.history || []
  }

  function _applyServers(s) {
    if (!s) return
    countries = s.countries || []
    serverCount = Number(s.serverCount || 0)
    countryCount = Number(s.countryCount || 0)
    serversUpdatedAt = Number(s.updatedAtMs || 0)
  }

  function _applyAuthEvent(a) {
    if (!a) return
    fido2Running = false
    fido2Prompt = ""
    authBusy = false
    if (a.status === "ok") { authError = ""; authStep = "credentials" }
    else if (a.status === "error") {
      authError = Model.sanitizeText(a.message || "")
      if (a.code === "session_expired") authStep = "credentials"
    }
  }

  // --------------------------------------------------------- notifications

  function notify(title, body, urgent) {
    if (!setting("showNotifications", true)) return
    var args = ["notify-send", "-a", "Proton for Omarchy", "-i", "network-vpn"]
    if (urgent) args.push("-u", "critical")
    // notify-send bodies are markup: neutralize & on top of sanitizeText.
    args.push("--", Model.sanitizeText(title, 80), Model.sanitizeText(body, 200).replace(/&/g, "&amp;"))
    Quickshell.execDetached(args)
  }

  function _notifyTransition(prev, next) {
    if (next === "connected" && prev !== "connected") {
      var where = Model.locationLabel(server)
      notify(strings.t("notify.connected", "Proton VPN connected"),
             (server && server.name ? server.name : "") + (where ? " · " + where : ""), false)
    } else if (next === "disconnected" && prev === "connected" && _desired !== "connected" && !switching) {
      notify(strings.t("notify.disconnected", "Proton VPN disconnected"), strings.t("notify.disconnectedBody", "Traffic is no longer protected by the VPN"), false)
    } else if (next === "error" && !_startupConnecting) {
      notify(strings.t("notify.error", "Proton VPN connection problem"), errorMessage, true)
    }
  }

  // --------------------------------------------------------------- actions

  function _actionFailed(error) {
    var message = error && error.message ? error.message : strings.t("error.generic", "Something went wrong")
    actionError = Model.sanitizeText(message)
    actionErrorTimer.restart()
  }

  function showToast(text) {
    toast = Model.sanitizeText(text, 80)
    toastTimer.restart()
  }

  function connectTarget(target, label, done, waitForNetwork) {
    if (!loggedIn) return
    if (!waitForNetwork) _cancelStartupConnect()  // the user took over
    _desired = "connected"
    pendingLabel = label || ""
    actionError = ""
    var params = target
    if (waitForNetwork) {
      params = {}
      for (var k in target) params[k] = target[k]
      params.waitForNetwork = true
    }
    // Waiting for the network can take up to a minute before connecting starts.
    request("connect", params, function(ok, data, error) {
      pendingLabel = ""
      if (!ok) {
        // A superseded request replies "cancelled"; whoever superseded it owns _desired now.
        if (!error || error.code !== "cancelled") _desired = ""
        if (error && error.code === "upgrade_required" && !(done && done(false, error))) offerUpgrade(Model.sanitizeText(error.message || "", 120))
        else if (error && error.code !== "cancelled" && !(done && done(false, error))) _actionFailed(error)
      } else if (done) done(true, null)
    }, waitForNetwork ? 150000 : 60000)
  }

  // ------------------------------------------------- connect on startup
  // "off" | "fastest" | "last". Runs once per login session: the bridge
  // claims a marker in XDG_RUNTIME_DIR, so shell or plugin reloads never
  // reconnect behind the user's back.
  readonly property string startupConnect: {
    var v = String(setting("connectOnStartup", "off"))
    return v === "fastest" || v === "last" ? v : "off"
  }
  property bool _startupChecked: false
  property int _startupAttempts: 0
  property bool _startupUseFastest: false
  // True while connect-at-login is still trying: its failures retry quietly
  // instead of raising a critical notification.
  property bool _startupConnecting: false
  onStartupConnectChanged: { if (startupConnect === "off") _cancelStartupConnect(); else _maybeStartupConnect() }
  onLoggedInChanged: { if (!loggedIn) _cancelStartupConnect(); else _maybeStartupConnect() }

  // Any explicit user action (connect, disconnect, cancel, sign out, option off)
  // ends connect-at-login: a pending quiet retry must never override it.
  function _cancelStartupConnect() {
    startupRetry.stop()
    _startupConnecting = false
  }

  function _maybeStartupConnect() {
    if (_startupChecked || startupConnect === "off" || !snapshotLoaded || !loggedIn) return
    _startupChecked = true
    // Turning the option on mid-session must not connect right away; it applies
    // from the next login. Five minutes covers a slow keyring unlock at login.
    if (Date.now() - _startedAtMs > 300000) return
    request("claim_boot_autoconnect", {}, function(ok, data) {
      if (!ok) { _startupChecked = false; return }  // bridge not answering yet: try again on the next snapshot
      if (!data || !data.claimed) return
      if (realState !== "disconnected" && realState !== "error") return  // already connected, e.g. by Proton itself
      _startupConnectNow()
    }, 10000)
  }

  function _startupConnectNow() {
    if (!loggedIn || (realState !== "disconnected" && realState !== "error")) { _startupConnecting = false; return }
    _startupAttempts++
    var last = startupConnect === "last" && recents.length > 0 && !_startupUseFastest ? recents[0] : null
    var target = last ? last.target : { targetType: "fastest" }
    var label = last ? last.label : strings.t("home.fastest", "Fastest server")
    _startupConnecting = true
    connectTarget(target, label, function(ok, error) {
      // Only errors from the startup request itself are quiet, not ones in the gaps between retries.
      _startupConnecting = false
      if (ok) return false
      // The network is often not up yet right after login: retry quietly.
      var code = error ? String(error.code || "") : ""
      // The last-used server is gone or full: protect the user on the fastest one instead.
      if (last && /^(not_found|no_server|maintenance|upgrade_required)$/.test(code) && _startupAttempts < 4) {
        _startupUseFastest = true
        Qt.callLater(_startupConnectNow)
        return true
      }
      var fatal = /^(upgrade_required|not_found|no_server|maintenance|not_logged_in|cancelled)$/.test(code)
      if (!fatal && _startupAttempts < 4) { startupRetry.restart(); return true }
      if (code !== "cancelled")
        notify(strings.t("notify.startupFailed", "Proton VPN could not connect at login"),
               error && error.message ? error.message : "", true)
      return false
    }, true)
  }

  Timer {
    id: startupRetry
    interval: 15000
    onTriggered: root._startupConnectNow()
  }

  // Leave a slow or broken server for the fastest *other* one, using fresh loads.
  function switchToFastest() {
    if (switching) return
    switching = true
    connectTarget({ targetType: "fastest", avoidCurrent: true }, strings.t("home.fastest", "Fastest server"),
                  function() { root.switching = false; return false })
  }

  function quickConnect() { connectTarget({ targetType: "fastest" }, strings.t("home.fastest", "Fastest server")) }

  function disconnect() {
    _cancelStartupConnect()
    _desired = "disconnected"
    actionError = ""
    request("disconnect", {}, function(ok, data, error) {
      if (!ok) { _desired = ""; _actionFailed(error) }
    }, 30000)
  }

  function cancelConnect() {
    _cancelStartupConnect()
    _desired = "disconnected"
    request("cancel_connect", {}, function(ok) { if (!ok) _desired = "" }, 30000)
  }

  function toggleConnection() {
    if (!loggedIn) return
    if (connectionState === "connecting") cancelConnect()
    else if (connectionState === "connected" || connectionState === "error") disconnect()
    else if (connectionState === "disconnected") quickConnect()
  }

  function reconnect() {
    _desired = "connected"
    request("reconnect", {}, function(ok, data, error) {
      if (!ok) { _desired = ""; _actionFailed(error) }
    }, 90000)
  }

  function queryServers(params, callback) {
    return request("query_servers", params, callback, 10000)
  }

  function refresh(force) {
    if (!bridge.running) { restartBridge(); return }
    request("get_snapshot", {}, function(ok, data) { if (ok) _applySnapshot(data) }, 20000)
    if (loggedIn) request("refresh_servers", { force: force === true }, function(ok, data, error) {
      if (!ok && force) _actionFailed(error)
    }, 60000)
  }

  function setSetting(key, value, options, callback) {
    var params = { key: key, value: value }
    if (options && options.forceDisconnect) params.forceDisconnect = true
    if (options && options.resolveConflict) params.resolveConflict = true
    request("set_setting", params, function(ok, data, error) {
      if (!ok && !(error && /^(conflict_|requires_disconnect)/.test(error.code || ""))) _actionFailed(error)
      if (callback) callback(ok, data, error)
    }, 45000)
  }

  function setPanelOpen(open) {
    _panelOpen = open
  }
  onPanelOpenWantedChanged: if (bridgeReady) request("set_panel_open", { open: panelOpenWanted })
  readonly property bool autoRefreshWanted: setting("autoRefreshServers", true) !== false
  onAutoRefreshWantedChanged: if (bridgeReady) request("set_auto_refresh", { enabled: autoRefreshWanted })

  function listApps(query, callback) { request("list_apps", { query: query || "" }, callback, 10000) }

  function toggleFavorite(label, target, detail, callback) {
    request("toggle_favorite", { label: label || "", target: target, detail: detail || "" }, function(ok, data, error) {
      if (!ok) _actionFailed(error)
      if (callback) callback(ok, data, error)
    })
  }

  readonly property bool historyWanted: setting("connectionHistory", true) !== false
  onHistoryWantedChanged: if (bridgeReady) request("set_history", { enabled: historyWanted })

  function clearHistory() {
    request("clear_history", {}, function(ok, data, error) { if (!ok) _actionFailed(error) })
  }

  // Up to 30 server names; the callback gets {name: ms or null}.
  function measureLatency(names, callback) {
    request("measure_latency", { servers: names.slice(0, 30) }, function(ok, data) {
      callback(ok && data ? (data.latency || {}) : {})
    }, 15000)
  }

  // Save (or, with id, rename/repoint) a named profile.
  function saveProfile(name, target, id, detail, callback) {
    var profile = { name: name, target: target, detail: detail || "" }
    if (id) profile.id = id
    request("save_profile", { profile: profile }, function(ok, data, error) {
      if (!ok) _actionFailed(error)
      else showToast(strings.t("profiles.saved", "Saved as “%1”").arg(Model.sanitizeText(name, 80)))
      if (callback) callback(ok, data, error)
    })
  }

  function deleteProfile(id) {
    request("delete_profile", { id: id }, function(ok, data, error) { if (!ok) _actionFailed(error) })
  }

  function isFavorite(target) {
    var key = Model.targetKey(target)
    for (var i = 0; i < favorites.length; i++) if (favorites[i].key === key) return true
    return false
  }

  function login(username, password) {
    if (authBusy) return
    authBusy = true
    authError = ""
    request("auth_login", { username: username, password: password }, function(ok, data, error) {
      authBusy = false
      if (!ok) { authError = Model.sanitizeText(error ? error.message : ""); return }
      if (data && data.status === "2fa_required") {
        authStep = "2fa"
        auth = Object.assign({}, auth, { twofaPending: true, supportsFido2: data.supportsFido2 === true })
      }
    }, 60000)
  }

  function submitTotp(code) {
    if (authBusy) return
    authBusy = true
    authError = ""
    request("auth_2fa_totp", { code: code }, function(ok, data, error) {
      authBusy = false
      if (!ok) {
        authError = Model.sanitizeText(error ? error.message : "")
        if (error && error.code === "session_expired") authStep = "credentials"
      }
    }, 60000)
  }

  function startFido2() {
    authError = ""
    fido2Running = true
    fido2Prompt = "insert"
    request("auth_2fa_fido2_start", {}, function(ok, data, error) {
      if (!ok) { fido2Running = false; fido2Prompt = ""; authError = Model.sanitizeText(error ? error.message : "") }
    }, 20000)
  }

  function submitFido2Pin(pin) {
    fido2Prompt = "touch"
    request("auth_2fa_fido2_pin", { pin: pin }, null, 10000)
  }

  function cancelFido2() {
    request("auth_2fa_fido2_cancel", {}, null, 10000)
    fido2Running = false
    fido2Prompt = ""
  }

  function backToCredentials() {
    if (fido2Running) cancelFido2()
    authStep = "credentials"
    authError = ""
  }

  function logout() {
    request("auth_logout", {}, function(ok, data, error) { if (!ok) _actionFailed(error) }, 45000)
  }

  function refreshAccount() {
    request("auth_refresh_account", {}, function(ok, data, error) {
      if (ok) showToast(strings.t("account.refreshed", "Plan refreshed"))
      else _actionFailed(error)
    }, 30000)
  }

  function diagnostics(callback) { request("diagnostics", {}, callback, 15000) }

  function copyText(text, label) {
    var value = String(text || "")
    if (value === "") return
    request("copy_clipboard", { text: value }, function(ok, data, error) {
      if (ok) showToast(strings.t("toast.copied", "Copied %1").arg(label || value))
      else _actionFailed(error)
    }, 8000)
  }

  // Opens a terminal running scripts/install-deps.sh (pacman needs sudo, so it
  // must be interactive), then keeps re-checking until the libraries load.
  function installDeps() {
    var path = depsScriptPath
    // The launcher runs its argument through bash: only allow a plain path.
    if (!/^\/[A-Za-z0-9._\/-]+$/.test(path)) {
      showToast(strings.t("deps.manual", "Run scripts/install-deps.sh from the plugin folder"))
      return
    }
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", "'" + path + "'"])
    _depsChecks = 0
    depsRecheck.restart()
  }

  Timer {
    id: depsRecheck
    interval: 10000
    repeat: true
    onTriggered: {
      if (!root.depsMissing || ++root._depsChecks > 30) { stop(); return }
      root.restartBridge()
    }
  }

  function checkUpdate() {
    if (!checkForUpdates) return
    // Silent on failure: offline or blocked by the Kill Switch is normal.
    request("check_update", {}, function (ok, data) {
      if (ok && data) update = { latest: String(data.latest || ""), gitInstall: data.gitInstall === true,
                                 dismissed: data.dismissed === true }
    }, 20000)
  }

  function dismissUpdate() {
    var version = update.latest
    if (version === "") return
    update = { latest: version, gitInstall: update.gitInstall, dismissed: true }
    request("dismiss_update", { version: version })
  }

  // Opens a terminal that shows the diff, asks, updates, then restarts the
  // shell so the new panel files load. Only constant strings reach bash.
  function runUpdate() {
    if (!update.gitInstall) {
      copyText("scripts/install-local.sh", strings.t("update.localCommand", "Update command"))
      return
    }
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
                             "omarchy plugin update pl0xuee.proton-for-omarchy && omarchy-restart-shell"])
  }

  // First check a minute after start (keeps login quiet), then twice a day.
  Timer {
    id: updateTimer
    interval: root.update.latest === "" && !root._updateCheckedOnce ? 60000 : 12 * 3600 * 1000
    repeat: true
    running: root.active && root.bridgeReady && root.checkForUpdates
    onTriggered: { root._updateCheckedOnce = true; root.checkUpdate() }
  }
  property bool _updateCheckedOnce: false

  function restartBridge() {
    crashCount = 0
    bridgeFailed = false
    bridgeError = ""
    restartTimer.stop()
    if (bridge.running) bridge.running = false
    else _startBridge()
  }

  function _startBridge() {
    if (!active || bridge.running) return
    bridgeReady = false
    bridgeStartedAt = Date.now()
    bridge.running = true
  }

  // ---------------------------------------------------------------- process

  onActiveChanged: {
    if (active) _startBridge()
    else if (bridge.running) bridge.running = false
  }
  Component.onCompleted: if (active) _startBridge()
  Component.onDestruction: {
    restartTimer.stop()
    bridge.running = false
  }

  Process {
    id: bridge
    command: ["python3", "-I", "-u", root.bridgePath]
    stdinEnabled: true
    running: false

    stdout: SplitParser {
      onRead: function(line) { root._handleLine(line) }
    }
    stderr: SplitParser {
      onRead: function(line) { console.warn("proton-for-omarchy bridge:", Model.sanitizeText(line, 400)) }
    }

    onRunningChanged: {
      root.bridgeRunning = running
      if (running) return
      root.bridgeReady = false
      root._failAllPending(strings.t("error.bridgeDown", "Backend is not running"))
      if (!root.active) return
      var lived = Date.now() - root.bridgeStartedAt
      root.crashCount = lived > 60000 ? 1 : root.crashCount + 1
      if (root.crashCount > 5) {
        root.bridgeFailed = true
        root.bridgeError = strings.t("error.bridgeCrashed", "The backend keeps stopping. Use Restart backend to try again.")
        return
      }
      restartTimer.interval = Math.min(30000, 1000 * Math.pow(2, Math.max(0, root.crashCount - 1)))
      restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    repeat: false
    onTriggered: root._startBridge()
  }

  Timer {
    id: actionErrorTimer
    interval: 8000
    onTriggered: root.actionError = ""
  }

  Timer {
    id: toastTimer
    interval: 1800
    onTriggered: root.toast = ""
  }
}
