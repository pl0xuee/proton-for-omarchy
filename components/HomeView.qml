import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../Model.js" as Model
import "ViewUtil.js" as ViewUtil

// Tab 1: everyday use in one click or keystroke.
Item {
  id: root

  property var svc: null
  property var tr: null
  property var theme: null
  property real maxHeight: Style.space(440)
  property bool shown: false

  signal requestTab(int index)
  signal requestSetting(string key)
  signal nameRequested(string title, string initial, var onSave)

  readonly property alias cursor: cursorModel
  readonly property var st: svc ? svc.vpnSettings : null
  readonly property bool connectedish: svc && (svc.connectionState === "connected" || svc.connectionState === "connecting")
  readonly property bool isConnected: svc && svc.connectionState === "connected"
  readonly property bool hasError: svc && svc.realState === "error"
  readonly property bool permanentKsBlocking: svc && st && st.killswitch === 2 && svc.connectionState === "disconnected"
  readonly property bool needsReconnect: isConnected && svc.requiresReconnect.length > 0
  readonly property string ipText: svc && svc.details ? String(svc.details.vpnIp || svc.details.serverIpv4 || "") : ""
  readonly property string portText: svc && svc.forwardedPort ? String(svc.forwardedPort) : ""
  readonly property bool canSwitchFaster: svc !== null && svc.loggedIn && !bridgeProblem
                                          && (svc.connectionState === "connected" || svc.connectionState === "error")
  readonly property bool bridgeProblem: svc && (svc.bridgeFailed || (svc.snapshotLoaded && svc.deps && svc.deps.protonApi === false))

  property real nowMs: Date.now()

  // The live connection can be saved as a named profile unless it already is one.
  readonly property var saveable: isConnected && svc.currentTarget && svc.currentTarget.target
                                  && !svc.isFavorite(svc.currentTarget.target) ? svc.currentTarget : null

  // Context hint for the strip under the panel.
  readonly property string hint: {
    var key = cursorModel.active ? cursorModel.currentId : ""
    if (key.indexOf("fav:") === 0) return t("hints.favorite", "Enter connect · n rename · x remove")
    if (key.indexOf("rec:") === 0) return t("hints.recent", "Enter connect · n save as profile · f favorite")
    return ""
  }

  implicitHeight: Math.min(column.implicitHeight, maxHeight)

  function t(key, fallback) { return tr ? tr.t(key, fallback) : fallback }

  // ------------------------------------------------------------- cursor rows

  CursorModel {
    id: cursorModel
    rows: root.buildRows()
    onMoved: Qt.callLater(root.scrollToCursor)
  }

  function buildRows() {
    var rows = []
    if (!svc) return rows
    if (bridgeProblem) { rows.push(svc.depsMissing ? ["installDeps", "restartBridge"] : ["restartBridge"]); return rows }
    if (!svc.loggedIn) { rows.push(["signIn"]); return rows }
    if (needsReconnect) rows.push(["reconnect"])
    if (hasError) rows.push(["errRetry", "errDisconnect"])
    if (permanentKsBlocking) rows.push(["ksConnect", "ksOff"])
    if (isConnected) {
      var copyRow = []
      if (ipText !== "") copyRow.push("copyIp")
      if (portText !== "") copyRow.push("copyPort")
      if (copyRow.length) rows.push(copyRow)
    }
    if (connectedish) rows.push(["disconnect", "change"])
    if (canSwitchFaster) rows.push(["faster"])
    if (!connectedish) {
      rows.push(["quick"])
      rows.push(["p2p", "sc", "random"])
    }
    if (st !== null && !bridgeProblem) rows.push(["netshield", "killswitch", "split"])
    if (svc.updateAvailable) rows.push(["runUpdate", "dismissUpdate"])
    if (saveable) rows.push(["saveCurrent"])
    for (var i = 0; i < svc.favorites.length; i++) rows.push(["fav:" + svc.favorites[i].id])
    for (var j = 0; j < svc.recents.length; j++) rows.push(["rec:" + svc.recents[j].id])
    return rows
  }

  function scrollToCursor() {
    ViewUtil.ensureVisible(flick, ViewUtil.findKey(column, cursorModel.currentId), Style.space(6))
  }

  function moveCursor(dx, dy) { return cursorModel.move(dx, dy) }

  function activate() {
    if (!cursorModel.active) return false
    activateKey(cursorModel.currentId)
    return true
  }

  function back() { return false }

  function deleteCurrent() {
    var key = cursorModel.currentId
    if (key.indexOf("fav:") === 0) { svc.deleteProfile(key.substring(4)); return true }
    return false
  }

  function textKey(text) {
    if (text === "c" || text === "C") { if (ipText !== "") svc.copyText(ipText, t("home.vpnIp", "VPN IP")); return true }
    if (text === "p" || text === "P") { if (portText !== "") svc.copyText(portText, t("home.port", "Port")); return true }
    if (text === "s" || text === "S") { if (canSwitchFaster && !svc.switching) svc.switchToFastest(); return true }
    var key = cursorModel.active ? cursorModel.currentId : ""
    if (text === "n" || text === "N") {
      if (key.indexOf("fav:") === 0) { renameFavorite(key.substring(4)); return true }
      if (key.indexOf("rec:") === 0) { saveRecent(key.substring(4)); return true }
      if (key === "saveCurrent") { saveCurrent(); return true }
    }
    if ((text === "f" || text === "F") && key.indexOf("rec:") === 0) {
      var rec = entryFor(svc.recents, key.substring(4))
      if (rec) svc.toggleFavorite(rec.label, rec.target, rec.detail)
      return true
    }
    return false
  }

  function saveCurrent() {
    var cur = saveable
    if (!cur) return
    nameRequested(t("profiles.saveTitle", "Save this connection as"), cur.label, function(name) {
      root.svc.saveProfile(name, cur.target, "")
    })
  }

  function renameFavorite(id) {
    var fav = entryFor(svc.favorites, id)
    if (!fav) return
    nameRequested(t("profiles.renameTitle", "Rename profile"), fav.label, function(name) {
      root.svc.saveProfile(name, fav.target, fav.id)
    })
  }

  function saveRecent(id) {
    var rec = entryFor(svc.recents, id)
    if (!rec) return
    nameRequested(t("profiles.saveTitle", "Save this connection as"), rec.label, function(name) {
      root.svc.saveProfile(name, rec.target, "")
    })
  }

  function entryFor(list, id) {
    for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i]
    return null
  }

  function cycleNetShield() {
    if (!st) return
    if (svc.freeTier) { svc.offerUpgrade(); return }
    svc.setSetting("netshield", (Number(st.netshield) + 1) % 3)
  }

  function activateKey(key) {
    if (!svc) return
    if (key === "restartBridge") svc.restartBridge()
    else if (key === "installDeps") svc.installDeps()
    else if (key === "runUpdate") svc.runUpdate()
    else if (key === "dismissUpdate") svc.dismissUpdate()
    else if (key === "signIn") requestTab(3)
    else if (key === "reconnect") svc.reconnect()
    else if (key === "errRetry") svc.reconnect()
    else if (key === "errDisconnect") svc.disconnect()
    else if (key === "ksConnect") svc.quickConnect()
    else if (key === "ksOff") svc.setSetting("killswitch", 0)
    else if (key === "copyIp") svc.copyText(ipText, t("home.vpnIp", "VPN IP"))
    else if (key === "copyPort") svc.copyText(portText, t("home.port", "Port"))
    else if (key === "disconnect") svc.toggleConnection()
    else if (key === "change") requestTab(1)
    else if (key === "faster") { if (!svc.switching) svc.switchToFastest() }
    else if (key === "quick") svc.quickConnect()
    else if (key === "p2p") connectFeature("p2p", t("home.fastestP2P", "Fastest P2P"))
    else if (key === "sc") connectFeature("secure_core", t("home.secureCore", "Secure Core"))
    else if (key === "random") {
      if (svc.loggedIn) svc.connectTarget({ targetType: "random" }, t("home.random", "Random"))
    }
    else if (key === "netshield") cycleNetShield()
    else if (key === "killswitch") requestSetting("killswitch")
    else if (key === "split") requestSetting("split_tunneling")
    else if (key === "saveCurrent") saveCurrent()
    else if (key.indexOf("fav:") === 0) {
      var fav = entryFor(svc.favorites, key.substring(4))
      if (fav) svc.connectTarget(fav.target, fav.label)
    } else if (key.indexOf("rec:") === 0) {
      var rec = entryFor(svc.recents, key.substring(4))
      if (rec) svc.connectTarget(rec.target, rec.label)
    }
  }

  function connectFeature(feature, label) {
    if (svc.freeTier) { svc.offerUpgrade(); return }
    svc.connectTarget({ targetType: "feature", features: [feature] }, label)
  }

  function netShieldLabel(v) {
    if (v === 1) return t("netshield.malware", "Malware")
    if (v === 2) return t("netshield.adsTrackers", "Ads & trackers")
    return t("common.off", "Off")
  }

  function killSwitchLabel(v) {
    if (v === 1) return t("killswitch.standard", "Standard")
    if (v === 2) return t("killswitch.permanent", "Permanent")
    return t("common.off", "Off")
  }

  function splitLabel() {
    var s = Model.splitTunnelSummary(st ? st.splitTunneling : null)
    if (!s.enabled) return t("common.off", "Off")
    var mode = s.mode === "include" ? t("split.includeShort", "Include") : t("split.excludeShort", "Exclude")
    return mode + " (" + (s.apps + s.ips) + ")"
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.shown && root.isConnected
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
  }

  // ---------------------------------------------------------------- layout

  Flickable {
    id: flick
    anchors.fill: parent
    contentWidth: width
    contentHeight: column.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    Column {
      id: column
      width: flick.width
      spacing: Style.spacing.panelGap

      // Backend problems first: nothing else works without the bridge.
      Banner {
        visible: root.bridgeProblem
        width: parent.width
        tone: "danger"
        text: root.svc && root.svc.bridgeFailed ? root.svc.bridgeError
              : (root.svc && root.svc.deps ? String(root.svc.deps.error || "") : "")
        actions: root.svc && root.svc.depsMissing
                 ? [{ key: "installDeps", label: root.t("home.installDeps", "Install requirements") },
                    { key: "restartBridge", label: root.t("home.restartBackend", "Restart backend") }]
                 : [{ key: "restartBridge", label: root.t("home.restartBackend", "Restart backend") }]
      }

      // Signed out.
      Card {
        visible: !root.bridgeProblem && root.svc && root.svc.snapshotLoaded && !root.svc.loggedIn
        width: parent.width

        Column {
          width: parent.width
          spacing: Style.space(10)

          PlainText {
            width: parent.width
            text: root.t("home.signedOutTitle", "Sign in to Proton VPN")
            color: root.theme.text
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          PlainText {
            width: parent.width
            text: root.t("home.signedOutBody", "Your session stays in the system keyring, never in the plugin's files.")
            color: root.theme.dim
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
          Chip {
            cursorKey: "signIn"
            theme: root.theme
            primary: true
            text: root.t("account.signIn", "Sign in")
            iconText: "󰍂"
            hasCursor: cursorModel.has("signIn")
            onHovered: cursorModel.setId("signIn")
            onClicked: root.activateKey("signIn")
          }
        }
      }

      Banner {
        visible: root.needsReconnect
        width: parent.width
        tone: "warning"
        text: root.t("home.reconnectNeeded", "Changes take effect after reconnecting")
        actions: [{ key: "reconnect", label: root.t("home.reconnect", "Reconnect") }]
      }

      Banner {
        visible: root.hasError
        width: parent.width
        tone: "danger"
        text: root.svc ? (root.svc.errorMessage || root.t("home.connectionFailed", "The VPN connection failed")) : ""
        actions: [{ key: "errRetry", label: root.t("home.retry", "Retry") },
                  { key: "errDisconnect", label: root.t("home.disconnect", "Disconnect") }]
      }

      Banner {
        visible: root.permanentKsBlocking
        width: parent.width
        tone: "danger"
        text: root.t("home.permanentKs", "Permanent Kill Switch is blocking internet access")
        actions: [{ key: "ksConnect", label: root.t("home.connect", "Connect") },
                  { key: "ksOff", label: root.t("home.turnOffKs", "Turn off Kill Switch") }]
      }

      Banner {
        visible: root.svc && root.svc.actionError !== ""
        width: parent.width
        tone: "danger"
        text: root.svc ? root.svc.actionError : ""
        actions: []
      }

      // ------------------------------------------------- telemetry card
      Card {
        id: telemetry
        visible: root.svc && root.svc.loggedIn && root.connectedish
        width: parent.width

        Column {
          width: parent.width
          spacing: Style.space(8)

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            PlainText {
              Layout.fillWidth: true
              text: {
                if (!root.svc) return ""
                if (root.svc.connectionState === "connecting" && !root.svc.server)
                  return root.svc.pendingLabel || root.t("state.connecting", "Connecting…")
                return Model.locationLabel(root.svc.server) || (root.svc.server ? root.svc.server.name : "")
              }
              color: root.theme.text
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            FeatureBadge {
              visible: root.svc && root.svc.server && root.svc.server.secureCore
              theme: root.theme
              text: "SC"
              strong: true
              tint: Commons.Color.accent
            }

            LoadIndicator {
              visible: root.svc && root.svc.server && root.svc.server.load !== null && root.svc.server.load !== undefined
              theme: root.theme
              load: root.svc && root.svc.server && root.svc.server.load ? root.svc.server.load : 0
            }
          }

          InfoRow {
            width: parent.width
            label: root.t("home.server", "Server")
            value: root.svc && root.svc.server ? root.svc.server.name : "—"
            badge: root.svc && root.svc.server ? String(root.svc.server.protocolLabel || "") : ""
          }

          InfoRow {
            visible: root.isConnected
            width: parent.width
            label: root.t("home.vpnIp", "VPN IP")
            value: root.ipText !== "" ? root.ipText : "—"
            copyKey: root.ipText !== "" ? "copyIp" : ""
          }

          InfoRow {
            visible: root.isConnected && root.portText !== ""
            width: parent.width
            label: root.t("home.forwardedPort", "Forwarded port")
            value: root.portText
            copyKey: "copyPort"
          }

          // Live traffic & uptime.
          RowLayout {
            visible: root.isConnected
            width: parent.width
            spacing: Style.space(14)

            PlainText {
              text: "↓ " + (root.svc && root.svc.traffic ? Model.formatRate(root.svc.traffic.rxBytesPerSec) : "—")
              color: root.theme.text
              font.pixelSize: Style.font.bodySmall
              font.features: { "tnum": 1 }
            }
            PlainText {
              text: "↑ " + (root.svc && root.svc.traffic ? Model.formatRate(root.svc.traffic.txBytesPerSec) : "—")
              color: root.theme.text
              font.pixelSize: Style.font.bodySmall
              font.features: { "tnum": 1 }
            }
            Item { Layout.fillWidth: true }
            PlainText {
              text: root.svc && root.svc.connectedSinceMs > 0
                    ? Model.formatDuration((root.nowMs - root.svc.connectedSinceMs) / 1000) : ""
              color: root.theme.dim
              font.pixelSize: Style.font.bodySmall
              font.features: { "tnum": 1 }
            }
          }
        }
      }

      // ------------------------------------------------- primary actions
      Column {
        visible: root.svc && root.svc.loggedIn && !root.bridgeProblem
        width: parent.width
        spacing: Style.space(8)

        RowLayout {
          visible: root.connectedish
          width: parent.width
          spacing: Style.space(8)

          Chip {
            Layout.fillWidth: true
            cursorKey: "disconnect"
            theme: root.theme
            primary: true
            tint: Commons.Color.urgent
            iconText: root.svc && root.svc.connectionState === "connecting" ? "󰜺" : "󰅛"
            text: root.svc && root.svc.connectionState === "connecting" ? root.t("home.cancel", "Cancel") : root.t("home.disconnect", "Disconnect")
            hasCursor: cursorModel.has("disconnect")
            onHovered: cursorModel.setId("disconnect")
            onClicked: root.activateKey("disconnect")
          }
          Chip {
            Layout.fillWidth: true
            cursorKey: "change"
            theme: root.theme
            iconText: "󰒍"
            text: root.t("home.changeServer", "Change server")
            hasCursor: cursorModel.has("change")
            onHovered: cursorModel.setId("change")
            onClicked: root.activateKey("change")
          }
        }

        // Current server slow or misbehaving: hop to the fastest other server.
        Chip {
          visible: root.canSwitchFaster
          width: parent.width
          cursorKey: "faster"
          theme: root.theme
          iconText: "󱐋"
          enabled: !(root.svc && root.svc.switching)
          text: root.svc && root.svc.switching ? root.t("home.switchingFastest", "Finding a faster server…")
                                                : root.t("home.switchFastest", "Switch to the fastest server")
          tooltipText: root.t("home.switchFastestTip", "Refreshes server loads and moves you off the current server")
          hasCursor: cursorModel.has("faster")
          onHovered: cursorModel.setId("faster")
          onClicked: root.activateKey("faster")
        }

        Chip {
          visible: !root.connectedish
          width: parent.width
          cursorKey: "quick"
          theme: root.theme
          primary: true
          iconText: "󱐋"
          text: root.t("home.connectFastest", "Connect to fastest")
          hasCursor: cursorModel.has("quick")
          onHovered: cursorModel.setId("quick")
          onClicked: root.activateKey("quick")
        }

        RowLayout {
          visible: !root.connectedish
          width: parent.width
          spacing: Style.space(8)

          Repeater {
            model: [
              { key: "p2p", label: root.t("home.fastestP2P", "Fastest P2P"), icon: "󰁆", paid: true },
              { key: "sc", label: root.t("home.secureCore", "Secure Core"), icon: "󰒃", paid: true },
              { key: "random", label: root.t("home.random", "Random"), icon: "󰒝", paid: false }
            ]
            Chip {
              required property var modelData
              Layout.fillWidth: true
              cursorKey: modelData.key
              theme: root.theme
              iconText: modelData.icon
              text: modelData.label
              locked: modelData.paid && root.svc && root.svc.freeTier
              hasCursor: cursorModel.has(modelData.key)
              onHovered: cursorModel.setId(modelData.key)
              onClicked: root.activateKey(modelData.key)
            }
          }
        }
      }

      // ------------------------------------------------- security strip
      Column {
        visible: root.svc && root.svc.loggedIn && root.st !== null && !root.bridgeProblem
        width: parent.width
        spacing: Style.space(8)

        PanelSectionHeader {
          text: root.t("home.security", "Security")
          foreground: root.theme.text
        }

        RowLayout {
          width: parent.width
          spacing: Style.space(8)

          StatusPill {
            Layout.fillWidth: true
            cursorKey: "netshield"
            label: root.t("settings.netshield", "NetShield")
            value: root.st ? root.netShieldLabel(Number(root.st.netshield)) : ""
            on: root.st && Number(root.st.netshield) > 0
            tooltip: root.t("home.netshieldCycle", "Click to cycle")
          }
          StatusPill {
            Layout.fillWidth: true
            cursorKey: "killswitch"
            label: root.t("settings.killswitch", "Kill Switch")
            value: root.st ? root.killSwitchLabel(Number(root.st.killswitch)) : ""
            on: root.st && Number(root.st.killswitch) > 0
            alert: root.st && Number(root.st.killswitch) === 2
          }
          StatusPill {
            Layout.fillWidth: true
            cursorKey: "split"
            label: root.t("home.splitTunnel", "Split tunnel")
            value: root.splitLabel()
            on: root.st && root.st.splitTunneling && root.st.splitTunneling.enabled
          }
        }
      }

      // ------------------------------------------------- plugin update
      Banner {
        visible: root.svc && root.svc.updateAvailable && !root.bridgeProblem
        width: parent.width
        tone: "info"
        text: root.svc ? root.t("home.updateAvailable", "Proton for Omarchy %1 is available").arg(root.svc.update.latest) : ""
        actions: [{ key: "runUpdate", label: root.svc && root.svc.update.gitInstall
                                             ? root.t("home.updateNow", "Update")
                                             : root.t("home.copyUpdateCommand", "Copy update command") },
                  { key: "dismissUpdate", label: root.t("home.dismiss", "Dismiss") }]
      }

      // ------------------------------------------------- favorites
      Column {
        visible: root.svc && root.svc.loggedIn && !root.bridgeProblem
        width: parent.width
        spacing: Style.space(4)

        PanelSectionHeader {
          text: root.t("home.favorites", "Favorites")
          foreground: root.theme.text
        }

        Chip {
          visible: root.saveable !== null
          width: parent.width
          cursorKey: "saveCurrent"
          theme: root.theme
          iconText: "󰆓"
          text: root.t("profiles.saveCurrent", "Save this connection as a profile")
          tooltipText: root.saveable ? String(root.saveable.label || "") : ""
          hasCursor: cursorModel.has("saveCurrent")
          onHovered: cursorModel.setId("saveCurrent")
          onClicked: root.activateKey("saveCurrent")
        }

        PlainText {
          visible: root.svc && root.svc.favorites.length === 0
          width: parent.width
          text: root.t("home.noFavorites", "No favorites yet. Press f on any country, city or server to pin it.")
          color: root.theme.dim
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Repeater {
          model: root.svc ? root.svc.favorites : []
          ServerRow {
            required property var modelData
            width: parent.width
            cursorKey: "fav:" + modelData.id
            theme: root.theme
            badgeText: "󰓎"
            badgeIsGlyph: true
            title: String(modelData.label || "")
            subtitle: String(modelData.detail || "") !== title ? String(modelData.detail || "") : ""
            showRemove: true
            showRename: true
            renameTooltip: root.t("profiles.rename", "Rename (n)")
            connectTooltip: root.t("home.connect", "Connect")
            hasCursor: cursorModel.has(cursorKey)
            onHovered: cursorModel.setId(cursorKey)
            onActivated: root.activateKey(cursorKey)
            onConnectClicked: root.activateKey(cursorKey)
            onRenameClicked: root.renameFavorite(modelData.id)
            onRemoveClicked: root.svc.deleteProfile(modelData.id)
          }
        }
      }

      // ------------------------------------------------- recents
      Column {
        visible: root.svc && root.svc.loggedIn && root.svc.recents.length > 0 && !root.bridgeProblem
        width: parent.width
        spacing: Style.space(4)

        PanelSectionHeader {
          text: root.t("home.recents", "Recent")
          foreground: root.theme.text
        }

        Repeater {
          model: root.svc ? root.svc.recents : []
          ServerRow {
            required property var modelData
            width: parent.width
            cursorKey: "rec:" + modelData.id
            theme: root.theme
            badgeText: "󰋚"
            badgeIsGlyph: true
            title: String(modelData.label || "")
            subtitle: String(modelData.detail || "")
            showFavorite: true
            favorite: root.svc ? root.svc.isFavorite(modelData.target) : false
            connectTooltip: root.t("home.connect", "Connect")
            hasCursor: cursorModel.has(cursorKey)
            onHovered: cursorModel.setId(cursorKey)
            onActivated: root.activateKey(cursorKey)
            onConnectClicked: root.activateKey(cursorKey)
            onFavoriteClicked: root.svc.toggleFavorite(modelData.label, modelData.target, modelData.detail)
          }
        }
      }
    }
  }

  // ------------------------------------------------------- inline pieces

  component Card: BorderSurface {
    id: card
    default property alias contentData: inner.data
    color: root.theme ? root.theme.cardFill : "transparent"
    radius: Style.cornerRadius
    borderSpec: Border.flat(root.theme ? root.theme.hairline : "transparent", 1)
    implicitHeight: inner.childrenRect.height + Style.space(24)

    Item {
      id: inner
      x: Style.space(12)
      y: Style.space(12)
      width: card.width - Style.space(24)
      height: childrenRect.height
    }
  }

  component Banner: BorderSurface {
    id: banner
    property string text: ""
    property string tone: "warning"
    property var actions: []
    readonly property color toneColor: tone === "danger" ? root.theme.danger
                                     : (tone === "info" ? Commons.Color.accent : root.theme.warning)
    color: Util.alpha(toneColor, 0.12)
    radius: Style.cornerRadius
    borderSpec: Border.flat(Util.alpha(toneColor, 0.45), 1)
    implicitHeight: bannerCol.implicitHeight + Style.space(20)

    Column {
      id: bannerCol
      x: Style.space(10)
      y: Style.space(10)
      width: banner.width - Style.space(20)
      spacing: Style.space(8)

      RowLayout {
        width: parent.width
        spacing: Style.space(8)
        PlainText {
          text: banner.tone === "danger" ? "󰀦" : (banner.tone === "info" ? "󰚰" : "󰋼")
          color: banner.toneColor
          font.pixelSize: Style.font.icon
          Layout.alignment: Qt.AlignTop
        }
        PlainText {
          Layout.fillWidth: true
          text: banner.text
          color: root.theme.text
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }

      Row {
        visible: banner.actions.length > 0
        spacing: Style.space(8)
        Repeater {
          model: banner.actions
          Chip {
            required property var modelData
            cursorKey: modelData.key
            theme: root.theme
            text: modelData.label
            hasCursor: cursorModel.has(modelData.key)
            onHovered: cursorModel.setId(modelData.key)
            onClicked: root.activateKey(modelData.key)
          }
        }
      }
    }
  }

  component InfoRow: RowLayout {
    id: info
    property string label: ""
    property string value: ""
    property string badge: ""
    property string copyKey: ""
    spacing: Style.space(8)

    PlainText {
      text: info.label
      color: root.theme.dim
      font.pixelSize: Style.font.bodySmall
      Layout.preferredWidth: Style.space(110)
    }
    PlainText {
      Layout.fillWidth: true
      text: info.value
      color: root.theme.text
      font.pixelSize: Style.font.body
      font.features: { "tnum": 1 }
    }
    FeatureBadge {
      visible: info.badge !== ""
      theme: root.theme
      text: info.badge
    }
    PanelActionButton {
      property string cursorKey: info.copyKey
      visible: info.copyKey !== ""
      iconText: "󰆏"
      tooltipText: root.t("home.copy", "Copy")
      foreground: root.theme.text
      hasCursor: cursorModel.has(info.copyKey)
      onHovered: function(isHovered) { if (isHovered) cursorModel.setId(info.copyKey) }
      onClicked: root.activateKey(info.copyKey)
    }
  }

  component StatusPill: CursorSurface {
    id: pill
    property string cursorKey: ""
    property string label: ""
    property string value: ""
    property bool on: false
    property bool alert: false
    property string tooltip: ""
    foreground: root.theme.text
    bordered: true
    hasCursor: cursorModel.has(cursorKey)
    implicitHeight: pillCol.implicitHeight + Style.space(14)
    radius: Style.cornerRadius

    Column {
      id: pillCol
      anchors.verticalCenter: parent.verticalCenter
      x: Style.space(10)
      width: pill.width - Style.space(20)
      spacing: Style.space(2)
      PlainText {
        width: parent.width
        text: pill.label
        color: root.theme.dim
        font.pixelSize: Style.font.caption
      }
      Row {
        width: parent.width
        spacing: Style.space(6)
        Rectangle {
          width: Style.space(6)
          height: width
          radius: width / 2
          anchors.verticalCenter: parent.verticalCenter
          color: pill.alert ? root.theme.danger : (pill.on ? root.theme.success : root.theme.faint)
        }
        PlainText {
          width: parent.width - Style.space(12)
          text: pill.value
          color: root.theme.text
          font.pixelSize: Style.font.bodySmall
          font.bold: pill.on
        }
      }
    }

    MouseArea {
      id: pillMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) cursorModel.setId(pill.cursorKey)
      onClicked: root.activateKey(pill.cursorKey)
    }

    PanelToolTip {
      visible: pill.tooltip !== "" && pillMouse.containsMouse
      text: pill.tooltip
    }
  }
}
