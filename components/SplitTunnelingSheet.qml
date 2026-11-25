import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../Model.js" as Model
import "ViewUtil.js" as ViewUtil

// Settings → Split Tunneling: master switch, mode, apps and IP rules.
Item {
  id: root

  property var host: null      // SettingsView (applySetting, notes)
  property var svc: null
  property var tr: null
  property var theme: null
  property real maxHeight: Style.space(440)

  signal closeRequested()
  signal releaseFocus()

  readonly property alias cursor: cursorModel
  readonly property bool editing: appField.activeFocus || ipField.activeFocus
  readonly property var split: svc && svc.vpnSettings ? svc.vpnSettings.splitTunneling : null
  readonly property bool enabled_: split ? split.enabled === true : false
  readonly property string mode: split && split.mode === "include" ? "include" : "exclude"
  readonly property var apps: split ? (split.apps || []) : []
  readonly property var ips: split ? (split.ips || []) : []
  readonly property bool daemonOk: svc && svc.deps ? svc.deps.splitTunnelDaemon === true : false
  property var appResults: []
  property string ipError: ""
  property int _seq: 0

  implicitHeight: column.implicitHeight

  function t(key, fallback) { return tr ? tr.t(key, fallback) : fallback }

  function apply(patch) {
    host.applySetting("split_tunneling", Object.assign({ mode: mode }, patch))
  }

  function addApp(path) {
    var p = String(path || "").trim()
    if (p === "") return
    for (var i = 0; i < apps.length; i++) if (apps[i] === p) { svc.showToast(t("split.alreadyAdded", "Already in the list")); return }
    apply({ apps: apps.concat([p]) })
    appField.text = ""
    appResults = []
  }

  function removeApp(index) {
    var next = apps.slice()
    next.splice(index, 1)
    apply({ apps: next })
  }

  function addIp() {
    var v = ipField.text.trim()
    if (v === "") return
    if (!Model.isIpAddress(v) && !Model.isIpNetwork(v)) {
      ipError = t("split.badIp", "Enter an IPv4/IPv6 address or a CIDR range like 10.0.0.0/8")
      return
    }
    for (var i = 0; i < ips.length; i++) if (ips[i] === v) { ipError = t("split.alreadyAdded", "Already in the list"); return }
    ipError = ""
    apply({ ips: ips.concat([v]) })
    ipField.text = ""
  }

  function removeIp(index) {
    var next = ips.slice()
    next.splice(index, 1)
    apply({ ips: next })
  }

  function searchApps() {
    var q = appField.text.trim()
    if (q === "" || q.charAt(0) === "/") { appResults = []; return }
    var seq = ++_seq
    svc.listApps(q, function(ok, data) {
      if (seq !== root._seq) return
      root.appResults = ok && data ? (data.apps || []).slice(0, 8) : []
    })
  }

  Timer { id: appDebounce; interval: 200; onTriggered: root.searchApps() }

  // ------------------------------------------------------------- cursor

  function buildRows() {
    var rows = [["back"], ["enabled"], ["mode:0", "mode:1"]]
    for (var i = 0; i < apps.length; i++) rows.push(["app:" + i])
    rows.push(["appField"])
    for (var j = 0; j < appResults.length; j++) rows.push(["pick:" + j])
    for (var k = 0; k < ips.length; k++) rows.push(["ip:" + k])
    rows.push(["ipField"])
    return rows
  }

  CursorModel {
    id: cursorModel
    rows: root.buildRows()
    onMoved: Qt.callLater(root.scrollToCursor)
  }

  function scrollToCursor() {
    ViewUtil.ensureVisible(flick, ViewUtil.findKey(column, cursorModel.currentId), Style.space(6))
  }

  function resetCursor() { cursorModel.reset() }
  function moveCursor(dx, dy) { return cursorModel.move(dx, dy) }

  function activate() {
    if (!cursorModel.active) return false
    activateKey(cursorModel.currentId)
    return true
  }

  function back() { return false }
  function textKey(text) { return false }

  function deleteCurrent() {
    var key = cursorModel.currentId
    if (key.indexOf("app:") === 0) { removeApp(Number(key.substring(4))); return true }
    if (key.indexOf("ip:") === 0) { removeIp(Number(key.substring(3))); return true }
    return false
  }

  function activateKey(key) {
    if (key === "back") closeRequested()
    else if (key === "enabled") apply({ enabled: !enabled_ })
    else if (key === "mode:0") { if (mode !== "exclude") apply({ mode: "exclude" }) }
    else if (key === "mode:1") { if (mode !== "include") apply({ mode: "include" }) }
    else if (key === "appField") appField.forceActiveFocus()
    else if (key === "ipField") ipField.forceActiveFocus()
    else if (key.indexOf("pick:") === 0) {
      var app = appResults[Number(key.substring(5))]
      if (app) addApp(app.binaryPath)
    }
  }

  function fieldKeys(field, event, onEnter) {
    if (event.key === Qt.Key_Escape) {
      if (field.text !== "") field.text = ""
      else root.releaseFocus()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      onEnter()
      event.accepted = true
    } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Up || event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      root.releaseFocus()
      cursorModel.setId(field === appField ? "appField" : "ipField")
      cursorModel.move(0, event.key === Qt.Key_Up || event.key === Qt.Key_Backtab ? -1 : 1)
      event.accepted = true
    }
  }

  // ------------------------------------------------------------- layout

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
      spacing: Style.space(4)

      Chip {
        cursorKey: "back"
        theme: root.theme
        iconText: Commons.I18n.rightToLeft ? "󰁔" : "󰁍"
        text: root.t("tabs.settings", "Settings")
        hasCursor: cursorModel.has("back")
        onHovered: cursorModel.setId("back")
        onClicked: root.closeRequested()
      }

      PlainText {
        width: parent.width
        topPadding: Style.space(4)
        text: root.t("settings.splitTunneling", "Split Tunneling")
        color: root.theme.text
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      // Daemon missing: the feature cannot work at all.
      BorderSurface {
        visible: !root.daemonOk
        width: parent.width
        color: Util.alpha(root.theme.warning, 0.12)
        radius: Style.cornerRadius
        borderSpec: Border.flat(Util.alpha(root.theme.warning, 0.45), 1)
        implicitHeight: daemonCol.implicitHeight + Style.space(20)

        Column {
          id: daemonCol
          x: Style.space(10)
          y: Style.space(10)
          width: parent.width - Style.space(20)
          spacing: Style.space(4)
          PlainText {
            width: parent.width
            text: root.t("split.daemonMissing", "Split Tunneling needs the Proton VPN system service")
            color: root.theme.text
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
          PlainText {
            width: parent.width
            text: "sudo systemctl enable --now proton.VPN.service"
            color: root.theme.dim
            font.pixelSize: Style.font.caption
            wrapMode: Text.WrapAnywhere
          }
        }
      }

      SettingRow {
        width: parent.width
        cursorKey: "enabled"
        theme: root.theme
        title: root.t("split.enable", "Use Split Tunneling")
        subtitle: root.t("split.ksNote", "Not available while Kill Switch is on")
        note: root.host ? root.host.noteFor("split_tunneling") : ""
        noteColor: root.host ? root.host.noteColorFor("split_tunneling") : root.theme.text
        hasCursor: cursorModel.has("enabled")
        onHovered: cursorModel.setId("enabled")
        onActivated: root.activateKey("enabled")
        trailing: ToggleSwitch {
          checked: root.enabled_
          busy: root.host && root.host.busyKey === "split_tunneling"
          cursorRing: false
          foreground: root.theme.text
          onToggled: root.activateKey("enabled")
        }
      }

      Item {
        width: parent.width
        implicitHeight: modeGroup.implicitHeight + Style.space(8)

        Item { property string cursorKey: "mode:0"; anchors.fill: parent }
        Item { property string cursorKey: "mode:1"; anchors.fill: parent }

        ButtonGroup {
          id: modeGroup
          x: Style.space(10)
          y: Style.space(4)
          width: parent.width - Style.space(20)
          focusable: false
          foreground: root.theme.text
          fontSize: Style.font.bodySmall
          value: root.mode
          options: [
            { value: "exclude", label: root.t("split.exclude", "Exclude from VPN") },
            { value: "include", label: root.t("split.include", "Only through VPN") }
          ]
          cursorIndex: cursorModel.active && cursorModel.currentId.indexOf("mode:") === 0 ? cursorModel.col : -1
          onChanged: function(v) { root.activateKey(v === "include" ? "mode:1" : "mode:0") }
          onHovered: function(index, isHovered) { if (isHovered) cursorModel.setId("mode:" + index) }
        }
      }

      PlainText {
        width: parent.width
        leftPadding: Style.space(10)
        rightPadding: Style.space(10)
        text: root.mode === "include"
              ? root.t("split.includeHelp", "Only the apps and addresses below use the VPN.")
              : root.t("split.excludeHelp", "The apps and addresses below bypass the VPN.")
        color: root.theme.dim
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      PanelSeparator { width: parent.width }

      // --------------------------------------------------- Apps
      PanelSectionHeader { text: root.t("split.apps", "Apps"); foreground: root.theme.text }

      Repeater {
        model: root.apps
        ServerRow {
          required property var modelData
          required property int index
          width: parent.width
          cursorKey: "app:" + index
          theme: root.theme
          badgeText: "󰣆"
          badgeIsGlyph: true
          title: Model.basename(String(modelData))
          subtitle: String(modelData)
          showConnect: false
          showRemove: true
          hasCursor: cursorModel.has(cursorKey)
          onHovered: cursorModel.setId(cursorKey)
          onRemoveClicked: root.removeApp(index)
        }
      }

      CursorSurface {
        property string cursorKey: "appField"
        width: parent.width
        implicitHeight: appField.implicitHeight
        hasCursor: cursorModel.has("appField") && !appField.activeFocus
        foreground: root.theme.text
        radius: Style.cornerRadius

        TextField {
          id: appField
          anchors.fill: parent
          foreground: root.theme.text
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          placeholderText: root.t("split.appPlaceholder", "Search apps or type /path/to/binary")
          onTextChanged: appDebounce.restart()
          Keys.onPressed: function(event) {
            root.fieldKeys(appField, event, function() {
              var v = appField.text.trim()
              if (v.charAt(0) === "/") root.addApp(v)
              else if (root.appResults.length > 0) root.addApp(root.appResults[0].binaryPath)
            })
          }
        }
      }

      Repeater {
        model: root.appResults
        ServerRow {
          required property var modelData
          required property int index
          width: parent.width
          cursorKey: "pick:" + index
          theme: root.theme
          badgeText: "󰐕"
          badgeIsGlyph: true
          title: String(modelData.name || "")
          subtitle: String(modelData.binaryPath || "")
          connectTooltip: root.t("split.add", "Add")
          hasCursor: cursorModel.has(cursorKey)
          onHovered: cursorModel.setId(cursorKey)
          onActivated: root.addApp(modelData.binaryPath)
          onConnectClicked: root.addApp(modelData.binaryPath)
        }
      }

      PanelSeparator { width: parent.width }

      // --------------------------------------------------- IPs
      PanelSectionHeader { text: root.t("split.ips", "IP addresses & ranges"); foreground: root.theme.text }

      Repeater {
        model: root.ips
        ServerRow {
          required property var modelData
          required property int index
          width: parent.width
          cursorKey: "ip:" + index
          theme: root.theme
          badgeText: "󰩟"
          badgeIsGlyph: true
          title: String(modelData)
          showConnect: false
          showRemove: true
          hasCursor: cursorModel.has(cursorKey)
          onHovered: cursorModel.setId(cursorKey)
          onRemoveClicked: root.removeIp(index)
        }
      }

      CursorSurface {
        property string cursorKey: "ipField"
        width: parent.width
        implicitHeight: ipField.implicitHeight
        hasCursor: cursorModel.has("ipField") && !ipField.activeFocus
        foreground: root.theme.text
        radius: Style.cornerRadius

        TextField {
          id: ipField
          anchors.fill: parent
          foreground: root.theme.text
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          placeholderText: root.t("split.ipPlaceholder", "Add an IP or CIDR, then press Enter")
          inputMethodHints: Qt.ImhNoPredictiveText
          onTextChanged: root.ipError = ""
          Keys.onPressed: function(event) { root.fieldKeys(ipField, event, root.addIp) }
        }
      }

      PlainText {
        visible: root.ipError !== ""
        width: parent.width
        text: root.ipError
        color: root.theme.danger
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }
}
