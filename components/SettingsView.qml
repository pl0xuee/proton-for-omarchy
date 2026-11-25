import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../Model.js" as Model
import "ViewUtil.js" as ViewUtil

// Tab 3: grouped Proton settings + plugin preferences. Multi-item editors
// (split tunneling, custom DNS) open as inline sub-sheets.
Item {
  id: root

  property var svc: null
  property var tr: null
  property var theme: null
  property real maxHeight: Style.space(440)
  property bool shown: false
  property var widgetSettings: ({})

  signal confirmRequested(string message, string confirmText, var onConfirm)
  signal widgetSettingChanged(string key, var value)
  signal releaseFocus()

  readonly property alias cursor: cursorModel
  readonly property var st: svc ? svc.vpnSettings : null
  readonly property bool paid: svc && !svc.freeTier
  readonly property bool isConnected: svc && svc.connectionState === "connected"
  // sheet: "" | "split" | "dns"
  property string sheet: ""
  readonly property Item activeSheet: sheet === "split" ? splitSheet : (sheet === "dns" ? dnsSheet : null)
  readonly property bool reorderable: sheet === "dns" && dnsSheet.reorderable
  readonly property bool editing: protocolDropdown.popupOpen || (activeSheet !== null && activeSheet.editing === true)

  // Inline status notes per setting ("Live", "Reconnect to apply", errors).
  property var notes: ({})
  property string busyKey: ""

  implicitHeight: Math.min(sheet === "" ? column.implicitHeight : activeSheet.implicitHeight, maxHeight)

  function t(key, fallback) { return tr ? tr.t(key, fallback) : fallback }

  // ------------------------------------------------------------ applying

  // notes[key] = { text, until } (until 0 = sticky until the next change).
  function setNote(key, text, ms) {
    var n = Object.assign({}, notes)
    if (text) n[key] = { text: text, until: ms ? Date.now() + ms : 0 }
    else delete n[key]
    notes = n
  }

  Timer {
    interval: 500
    repeat: true
    running: Object.keys(root.notes).length > 0
    onTriggered: {
      var now = Date.now(), n = {}, changed = false
      for (var k in root.notes) {
        var e = root.notes[k]
        if (e.until && e.until <= now) changed = true
        else n[k] = e
      }
      if (changed) root.notes = n
    }
  }

  // Reconnect notes go away once the backend no longer asks for a reconnect.
  Connections {
    target: root.svc
    function onRequiresReconnectChanged() {
      if (root.svc.requiresReconnect.length === 0) {
        var n = {}
        for (var k in root.notes) if (root.notes[k].until !== 0) n[k] = root.notes[k]
        root.notes = n
      }
    }
  }

  // Applies one setting, walking the user through conflicts with dialogs.
  function applySetting(key, value, opts, done) {
    if (!svc) return
    opts = opts || {}
    busyKey = key
    svc.setSetting(key, value, opts, function(ok, data, error) {
      root.busyKey = ""
      if (ok) {
        if (data && data.requiresReconnect) root.setNote(key, root.t("settings.reconnectToApply", "Reconnect to apply"), 0)
        else if (data && data.appliedLive) root.setNote(key, root.t("settings.live", "Live"), 2500)
        else root.setNote(key, root.t("settings.saved", "Saved"), 2500)
        if (done) done(true)
        return
      }
      var code = error ? String(error.code || "") : ""
      if (code === "conflict_split_tunneling") {
        root.confirmRequested(root.t("settings.ksConflict", "Kill Switch cannot run with Split Tunneling. Turn off Split Tunneling and enable Kill Switch?"),
                              root.t("settings.turnOffSplit", "Turn off Split Tunneling"),
                              function() { root.applySetting(key, value, Object.assign({}, opts, { resolveConflict: true }), done) })
      } else if (code === "conflict_kill_switch") {
        root.confirmRequested(root.t("settings.splitConflict", "Split Tunneling cannot run with Kill Switch. Turn off Kill Switch and enable Split Tunneling?"),
                              root.t("settings.turnOffKs", "Turn off Kill Switch"),
                              function() { root.applySetting(key, value, Object.assign({}, opts, { resolveConflict: true }), done) })
      } else if (code === "requires_disconnect") {
        root.confirmRequested(root.t("settings.disconnectForKs", "Disconnect temporarily to update the Kill Switch?"),
                              root.t("settings.disconnect", "Disconnect"),
                              function() {
                                // "Temporarily": reconnect to the same place once the change is saved.
                                root.applySetting(key, value, Object.assign({}, opts, { forceDisconnect: true }), function(saved) {
                                  if (saved && root.svc) root.svc.reconnect()
                                  if (done) done(saved)
                                })
                              })
      } else {
        root.setNote(key, error && error.message ? error.message : root.t("settings.failed", "Could not save"), 5000)
        if (done) done(false)
      }
    })
  }

  function setKillSwitch(v) {
    if (!st || Number(st.killswitch) === v) return
    if (v === 2) {
      confirmRequested(t("settings.permanentKsConfirm", "Permanent Kill Switch blocks all internet traffic outside the VPN, even when disconnected or after a reboot. Turn it on?"),
                       t("settings.enablePermanent", "Turn on Permanent"),
                       function() { root.applySetting("killswitch", 2) })
      return
    }
    applySetting("killswitch", v)
  }

  function setNetShield(v) {
    if (!st || Number(st.netshield) === v) return
    if (!paid) { svc.showToast(t("common.plusRequired", "Requires VPN Plus")); return }
    applySetting("netshield", v)
  }

  function toggleBool(key, current, needsPaid) {
    if (needsPaid && !paid) { svc.showToast(t("common.plusRequired", "Requires VPN Plus")); return }
    applySetting(key, !current)
  }

  function openSheet(name) {
    if ((name === "split" || name === "dns") && !paid) { svc.showToast(t("common.plusRequired", "Requires VPN Plus")); return }
    sheet = name
    var s = activeSheet
    if (s) { s.resetCursor(); s.cursor.move(0, 1) }
  }

  function closeSheet() {
    var back = sheet === "split" ? "split" : "dns"
    sheet = ""
    cursorModel.setId(back)
    Qt.callLater(scrollToCursor)
  }

  // Called from the Home security strip.
  function focusSetting(key) {
    if (key === "split_tunneling") { openSheet("split"); return }
    sheet = ""
    if (key === "killswitch" && st) cursorModel.setId("ks:" + Number(st.killswitch))
    else cursorModel.setId(key)
    Qt.callLater(scrollToCursor)
  }

  function widget(key, fallback) {
    var v = widgetSettings ? widgetSettings[key] : undefined
    return v === undefined || v === null ? fallback : v
  }

  // ------------------------------------------------------------- cursor

  readonly property var ksOptions: [
    { value: "0", label: t("common.off", "Off") },
    { value: "1", label: t("killswitch.standard", "Standard") },
    { value: "2", label: t("killswitch.permanent", "Permanent") }
  ]
  readonly property var nsOptions: [
    { value: "0", label: t("common.off", "Off") },
    { value: "1", label: t("netshield.malware", "Malware") },
    { value: "2", label: t("netshield.adsTrackers", "Ads & trackers") }
  ]
  readonly property var startOptions: [
    { value: "off", label: t("common.off", "Off") },
    { value: "fastest", label: t("settings.startFastest", "Fastest") },
    { value: "last", label: t("settings.startLast", "Last used") }
  ]
  readonly property var tintOptions: [
    { value: "accent", label: t("settings.tintAccent", "Accent") },
    { value: "foreground", label: t("settings.tintForeground", "Text") },
    { value: "semantic", label: t("settings.tintSemantic", "Green") }
  ]

  function buildRows() {
    if (!st) return []
    return [
      ["ks:0", "ks:1", "ks:2"],
      ["ns:0", "ns:1", "ns:2"],
      ["protocol"], ["start:0", "start:1", "start:2"], ["vpn_accelerator"], ["moderate_nat"], ["port_forwarding"], ["ipv6"],
      ["split"], ["dns"],
      ["pref:showCountryCode"], ["tint:0", "tint:1", "tint:2"],
      ["pref:showNotifications"], ["pref:bandwidthPolling"], ["pref:autoRefreshServers"], ["pref:checkForUpdates"], ["pref:connectionHistory"],
      ["anonymous_crash_reports"], ["telemetry"], ["recommended"]
    ]
  }

  CursorModel {
    id: cursorModel
    rows: root.buildRows()
    onMoved: Qt.callLater(root.scrollToCursor)
  }

  function groupIndex(prefix) {
    var id = cursorModel.currentId
    if (!cursorModel.active || id.indexOf(prefix + ":") !== 0) return -1
    return cursorModel.col
  }

  function scrollToCursor() {
    ViewUtil.ensureVisible(flick, ViewUtil.findKey(column, cursorModel.currentId), Style.space(6))
  }

  function resetCursor() { cursorModel.reset(); if (activeSheet) activeSheet.resetCursor() }

  function moveCursor(dx, dy) {
    if (activeSheet) return activeSheet.moveCursor(dx, dy)
    return cursorModel.move(dx, dy)
  }

  function activate() {
    if (activeSheet) return activeSheet.activate()
    if (!cursorModel.active) return false
    activateKey(cursorModel.currentId)
    return true
  }

  function back() {
    if (activeSheet) {
      if (activeSheet.back()) return true
      closeSheet()
      return true
    }
    return false
  }

  function textKey(text) {
    if (activeSheet) return activeSheet.textKey(text)
    return false
  }

  function deleteCurrent() {
    if (activeSheet) return activeSheet.deleteCurrent()
    return false
  }

  function reorder(dy) { return sheet === "dns" ? dnsSheet.reorder(dy) : false }

  function activateKey(key) {
    if (!st) return
    if (key.indexOf("ks:") === 0) setKillSwitch(Number(key.substring(3)))
    else if (key.indexOf("ns:") === 0) setNetShield(Number(key.substring(3)))
    else if (key === "protocol") protocolDropdown.open()
    else if (key === "vpn_accelerator") toggleBool(key, st.vpnAccelerator, true)
    else if (key === "moderate_nat") toggleBool(key, st.moderateNat, true)
    else if (key === "port_forwarding") toggleBool(key, st.portForwarding, true)
    else if (key === "ipv6") toggleBool(key, st.ipv6, false)
    else if (key === "split") openSheet("split")
    else if (key === "dns") openSheet("dns")
    else if (key === "anonymous_crash_reports") toggleBool(key, st.anonymousCrashReports, false)
    else if (key === "telemetry") toggleBool(key, st.telemetry, false)
    else if (key === "recommended") {
      confirmRequested(t("settings.recommendedConfirm", "Reset all VPN settings to Proton's defaults for your plan? Custom DNS and Split Tunneling are switched off; their entries are kept. Telemetry and crash report choices are not changed."),
                       t("settings.recommendedApply", "Apply"),
                       function() { root.applySetting("recommended", true) })
    }
    else if (key.indexOf("tint:") === 0) widgetSettingChanged("connectedIconTint", tintOptions[Number(key.substring(5))].value)
    else if (key.indexOf("start:") === 0) widgetSettingChanged("connectOnStartup", startOptions[Number(key.substring(6))].value)
    else if (key.indexOf("pref:") === 0) {
      var name = key.substring(5)
      if (name === "connectionHistory" && widget(name, true) && svc && svc.history.length > 0) {
        confirmRequested(t("history.offConfirm", "Turn off connection history? This clears the saved history."),
                         t("history.turnOff", "Turn off"),
                         function() { root.widgetSettingChanged("connectionHistory", false) })
        return
      }
      widgetSettingChanged(name, !widget(name, true))
    }
  }

  function noteFor(key) { return notes[key] ? notes[key].text : "" }
  function noteColorFor(key) {
    var n = noteFor(key)
    if (n === t("settings.live", "Live") || n === t("settings.saved", "Saved")) return theme.success
    if (n === t("settings.reconnectToApply", "Reconnect to apply")) return theme.warning
    return theme.danger
  }

  readonly property string splitSummaryText: {
    var s = Model.splitTunnelSummary(st ? st.splitTunneling : null)
    if (!s.enabled) return t("common.off", "Off")
    var mode = s.mode === "include" ? t("split.includeShort", "Include") : t("split.excludeShort", "Exclude")
    var parts = []
    if (s.apps > 0) parts.push((tr ? tr.tn("split.appCount", s.apps, "%1 apps") : "%1 apps").replace("%1", s.apps))
    if (s.ips > 0) parts.push((tr ? tr.tn("split.ipCount", s.ips, "%1 IPs") : "%1 IPs").replace("%1", s.ips))
    return mode + (parts.length ? " · " + parts.join(", ") : "")
  }

  readonly property string dnsSummaryText: {
    var d = Model.dnsSummary(st ? st.customDns : null)
    return d !== "" ? d : t("common.off", "Off")
  }

  // ------------------------------------------------------------- layout

  Flickable {
    id: flick
    visible: root.sheet === ""
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
      spacing: Style.space(4)

      PlainText {
        visible: !root.st
        width: parent.width
        text: root.svc && !root.svc.loggedIn ? root.t("settings.signInFirst", "Sign in to change Proton VPN settings")
                                             : root.t("settings.loading", "Loading settings…")
        color: root.theme.dim
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Column {
        visible: root.st !== null
        width: parent.width
        spacing: Style.space(4)

        // --------------------------------------------------- Security
        PanelSectionHeader { text: root.t("settings.security", "Security"); foreground: root.theme.text }

        SettingRow {
          width: parent.width
          cursorKey: "ks"
          theme: root.theme
          title: root.t("settings.killswitch", "Kill Switch")
          subtitle: root.t("settings.killswitchHelp", "Blocks traffic if the VPN drops")
          note: root.noteFor("killswitch")
          noteColor: root.noteColorFor("killswitch")
          hasCursor: false
        }
        GroupRow {
          prefix: "ks"
          options: root.ksOptions
          value: root.st ? String(root.st.killswitch) : "0"
          onPicked: function(v) { root.setKillSwitch(Number(v)) }
        }

        SettingRow {
          width: parent.width
          cursorKey: "ns"
          theme: root.theme
          title: root.t("settings.netshield", "NetShield")
          subtitle: root.st && root.st.customDns && root.st.customDns.enabled
                    ? root.t("settings.netshieldDnsWarning", "Custom DNS is on, so NetShield filtering is bypassed")
                    : root.t("settings.netshieldHelp", "Blocks malware, ads and trackers")
          locked: !root.paid
          note: root.noteFor("netshield")
          noteColor: root.noteColorFor("netshield")
          hasCursor: false
        }
        GroupRow {
          prefix: "ns"
          options: root.nsOptions
          value: root.st ? String(root.st.netshield) : "0"
          enabled: root.paid
          onPicked: function(v) { root.setNetShield(Number(v)) }
        }

        PanelSeparator { width: parent.width }

        // --------------------------------------------------- Connection
        PanelSectionHeader { text: root.t("settings.connection", "Connection"); foreground: root.theme.text }

        SettingRow {
          width: parent.width
          cursorKey: "protocol"
          theme: root.theme
          title: root.t("settings.protocol", "Protocol")
          note: root.noteFor("protocol")
          noteColor: root.noteColorFor("protocol")
          hasCursor: cursorModel.has("protocol")
          onHovered: cursorModel.setId("protocol")
          onActivated: root.activateKey("protocol")
          trailing: Dropdown {
            id: protocolDropdown
            width: Style.space(170)
            showLabel: false
            hasCursor: cursorModel.has("protocol")
            value: root.st ? String(root.st.protocol || "") : ""
            options: {
              var out = []
              var list = root.svc && root.svc.capabilities ? (root.svc.capabilities.protocols || []) : []
              for (var i = 0; i < list.length; i++) out.push({ value: list[i].key, label: list[i].label })
              return out
            }
            onChanged: function(v) { if (root.st && v !== root.st.protocol) root.applySetting("protocol", v) }
          }
        }

        SettingRow {
          width: parent.width
          cursorKey: "start"
          theme: root.theme
          title: root.t("settings.connectOnStartup", "Connect when you log in")
          subtitle: root.t("settings.connectOnStartupHelp", "Once per session, retried while the network comes up")
          hasCursor: false
        }
        GroupRow {
          prefix: "start"
          options: root.startOptions
          value: String(root.widget("connectOnStartup", "off"))
          onPicked: function(v) { root.widgetSettingChanged("connectOnStartup", v) }
        }

        ToggleRow {
          key: "vpn_accelerator"
          title: root.t("settings.vpnAccelerator", "VPN Accelerator")
          subtitle: root.t("settings.vpnAcceleratorHelp", "Faster speeds over long distances")
          checked: root.st ? root.st.vpnAccelerator : false
          needsPaid: true
        }
        ToggleRow {
          key: "moderate_nat"
          title: root.t("settings.moderateNat", "Moderate NAT")
          subtitle: root.t("settings.moderateNatHelp", "For gaming and P2P")
          checked: root.st ? root.st.moderateNat : false
          needsPaid: true
        }
        ToggleRow {
          key: "port_forwarding"
          title: root.t("settings.portForwarding", "Port Forwarding")
          subtitle: root.svc && root.svc.forwardedPort
                    ? root.t("settings.activePort", "Active port %1").replace("%1", String(root.svc.forwardedPort))
                    : root.t("settings.portForwardingHelp", "P2P servers only")
          checked: root.st ? root.st.portForwarding : false
          needsPaid: true
        }
        ToggleRow {
          key: "ipv6"
          title: root.t("settings.ipv6", "IPv6")
          subtitle: root.t("settings.ipv6Help", "Route IPv6 traffic through the VPN")
          checked: root.st ? root.st.ipv6 : false
        }

        PanelSeparator { width: parent.width }

        // --------------------------------------------------- Routing & DNS
        PanelSectionHeader { text: root.t("settings.routing", "Routing & DNS"); foreground: root.theme.text }

        SettingRow {
          width: parent.width
          cursorKey: "split"
          theme: root.theme
          title: root.t("settings.splitTunneling", "Split Tunneling")
          subtitle: root.splitSummaryText
          locked: !root.paid
          chevron: true
          note: root.noteFor("split_tunneling")
          noteColor: root.noteColorFor("split_tunneling")
          hasCursor: cursorModel.has("split")
          onHovered: cursorModel.setId("split")
          onActivated: root.activateKey("split")
        }
        SettingRow {
          width: parent.width
          cursorKey: "dns"
          theme: root.theme
          title: root.t("settings.customDns", "Custom DNS")
          subtitle: root.dnsSummaryText
          locked: !root.paid
          chevron: true
          note: root.noteFor("custom_dns")
          noteColor: root.noteColorFor("custom_dns")
          hasCursor: cursorModel.has("dns")
          onHovered: cursorModel.setId("dns")
          onActivated: root.activateKey("dns")
        }

        PanelSeparator { width: parent.width }

        // --------------------------------------------------- Plugin
        PanelSectionHeader { text: root.t("settings.plugin", "Bar widget & privacy"); foreground: root.theme.text }

        PrefRow {
          key: "showCountryCode"
          title: root.t("settings.showCountryCode", "Country code in the bar")
          fallback: true
        }
        SettingRow {
          width: parent.width
          cursorKey: "tint"
          theme: root.theme
          title: root.t("settings.iconTint", "Connected icon color")
          hasCursor: false
        }
        GroupRow {
          prefix: "tint"
          options: root.tintOptions
          value: String(root.widget("connectedIconTint", "accent"))
          onPicked: function(v) { root.widgetSettingChanged("connectedIconTint", v) }
        }
        PrefRow {
          key: "showNotifications"
          title: root.t("settings.showNotifications", "Desktop notifications")
          fallback: true
        }
        PrefRow {
          key: "bandwidthPolling"
          title: root.t("settings.bandwidthPolling", "Live traffic while the panel is open")
          fallback: true
        }
        PrefRow {
          key: "autoRefreshServers"
          title: root.t("settings.autoRefreshServers", "Refresh server loads in the background")
          fallback: true
        }
        PrefRow {
          key: "checkForUpdates"
          title: root.t("settings.checkForUpdates", "Check GitHub for plugin updates")
          fallback: true
        }
        PrefRow {
          key: "connectionHistory"
          title: root.t("settings.connectionHistory", "Keep connection history")
          subtitle: root.t("settings.connectionHistoryHelp", "Last 30 connections, on this computer only. Turning it off clears it")
          fallback: true
        }
        ToggleRow {
          key: "anonymous_crash_reports"
          title: root.t("settings.crashReports", "Anonymous crash reports")
          subtitle: root.t("settings.sentToProton", "Sent to Proton")
          checked: root.st ? root.st.anonymousCrashReports : false
        }
        ToggleRow {
          key: "telemetry"
          title: root.t("settings.telemetry", "Usage statistics")
          subtitle: root.t("settings.sentToProton", "Sent to Proton")
          checked: root.st ? root.st.telemetry : false
        }

        PanelSeparator { width: parent.width }

        SettingRow {
          width: parent.width
          cursorKey: "recommended"
          theme: root.theme
          title: root.t("settings.recommended", "Use Proton's recommended settings")
          subtitle: root.t("settings.recommendedHelp", "Proton's defaults for your plan. Saved DNS and app entries are kept.")
          note: root.noteFor("recommended")
          noteColor: root.noteColorFor("recommended")
          hasCursor: cursorModel.has("recommended")
          onHovered: cursorModel.setId("recommended")
          onActivated: root.activateKey("recommended")
          trailing: PanelActionButton {
            iconText: "󰑓"
            tooltipText: root.t("settings.recommendedApply", "Apply")
            foreground: root.theme.text
            hasCursor: false
            onClicked: root.activateKey("recommended")
          }
        }
      }
    }
  }

  SplitTunnelingSheet {
    id: splitSheet
    visible: root.sheet === "split"
    anchors.left: parent.left
    anchors.right: parent.right
    height: Math.min(implicitHeight, root.maxHeight)
    host: root
    svc: root.svc
    tr: root.tr
    theme: root.theme
    maxHeight: root.maxHeight
    onCloseRequested: root.closeSheet()
    onReleaseFocus: root.releaseFocus()
  }

  CustomDnsSheet {
    id: dnsSheet
    visible: root.sheet === "dns"
    anchors.left: parent.left
    anchors.right: parent.right
    height: Math.min(implicitHeight, root.maxHeight)
    host: root
    svc: root.svc
    tr: root.tr
    theme: root.theme
    maxHeight: root.maxHeight
    onCloseRequested: root.closeSheet()
    onReleaseFocus: root.releaseFocus()
  }

  // ------------------------------------------------------- inline pieces

  component ToggleRow: SettingRow {
    id: toggleRow
    property string key: ""
    property bool checked: false
    property bool needsPaid: false
    width: parent ? parent.width : 0
    cursorKey: key
    theme: root.theme
    locked: needsPaid && !root.paid
    note: root.noteFor(key)
    noteColor: root.noteColorFor(key)
    hasCursor: cursorModel.has(key)
    onHovered: cursorModel.setId(key)
    onActivated: root.activateKey(key)
    trailing: ToggleSwitch {
      checked: toggleRow.checked
      busy: root.busyKey === toggleRow.key
      cursorRing: false
      foreground: root.theme.text
      enabled: !toggleRow.locked
      onToggled: root.activateKey(toggleRow.key)
    }
  }

  component PrefRow: SettingRow {
    id: prefRow
    property string key: ""
    property bool fallback: true
    readonly property bool checked: root.widget(key, fallback) === true
    width: parent ? parent.width : 0
    cursorKey: "pref:" + key
    theme: root.theme
    hasCursor: cursorModel.has(cursorKey)
    onHovered: cursorModel.setId(cursorKey)
    onActivated: root.activateKey(cursorKey)
    trailing: ToggleSwitch {
      checked: prefRow.checked
      cursorRing: false
      foreground: root.theme.text
      onToggled: root.activateKey(prefRow.cursorKey)
    }
  }

  component GroupRow: Item {
    id: group
    property string prefix: ""
    property var options: []
    property string value: ""
    signal picked(string value)
    width: parent ? parent.width : 0
    implicitHeight: buttons.implicitHeight + Style.space(6)
    opacity: enabled ? 1.0 : 0.5

    // Invisible per-option anchors so ViewUtil.findKey can scroll to "ks:1".
    Repeater {
      model: group.options.length
      Item {
        required property int index
        property string cursorKey: group.prefix + ":" + index
        anchors.fill: parent
      }
    }

    ButtonGroup {
      id: buttons
      x: Style.space(10)
      width: parent.width - Style.space(20)
      focusable: false
      options: group.options
      value: group.value
      foreground: root.theme.text
      fontSize: Style.font.bodySmall
      cursorIndex: root.groupIndex(group.prefix)
      onChanged: function(v) { group.picked(v) }
      onHovered: function(index, isHovered) { if (isHovered) cursorModel.setId(group.prefix + ":" + index) }
    }
  }
}
