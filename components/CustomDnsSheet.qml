import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../Model.js" as Model
import "ViewUtil.js" as ViewUtil

// Settings → Custom DNS: master switch and an ordered list of resolvers.
Item {
  id: root

  property var host: null
  property var svc: null
  property var tr: null
  property var theme: null
  property real maxHeight: Style.space(440)

  signal closeRequested()
  signal releaseFocus()

  readonly property alias cursor: cursorModel
  readonly property bool editing: dnsField.activeFocus
  readonly property bool reorderable: cursorModel.active && cursorModel.currentId.indexOf("dns:") === 0
  readonly property var dns: svc && svc.vpnSettings ? svc.vpnSettings.customDns : null
  readonly property bool enabled_: dns ? dns.enabled === true : false
  readonly property var entries: dns ? (dns.ips || []) : []
  property string fieldError: ""

  implicitHeight: column.implicitHeight

  function t(key, fallback) { return tr ? tr.t(key, fallback) : fallback }

  function apply(enabled, list) {
    host.applySetting("custom_dns", { enabled: enabled, ips: list })
  }

  function addEntry() {
    var v = dnsField.text.trim()
    if (v === "") return
    if (!Model.isIpAddress(v)) { fieldError = t("dns.badIp", "Enter a valid IPv4 or IPv6 address"); return }
    for (var i = 0; i < entries.length; i++) if (entries[i].ip === v) { fieldError = t("split.alreadyAdded", "Already in the list"); return }
    if (entries.length >= 10) { fieldError = t("dns.tooMany", "Up to 10 DNS servers"); return }
    fieldError = ""
    apply(enabled_, entries.concat([{ ip: v, enabled: true }]))
    dnsField.text = ""
  }

  function removeEntry(index) {
    var next = entries.slice()
    next.splice(index, 1)
    apply(next.length > 0 ? enabled_ : false, next)
  }

  function reorder(dy) {
    var key = cursorModel.currentId
    if (key.indexOf("dns:") !== 0) return false
    if (host && host.busyKey === "custom_dns") return true  // wait for the last change to land
    var i = Number(key.substring(4))
    var j = i + dy
    if (j < 0 || j >= entries.length) return true
    var next = entries.slice()
    var tmp = next[i]; next[i] = next[j]; next[j] = tmp
    apply(enabled_, next)
    cursorModel.setId("dns:" + j)
    return true
  }

  // ------------------------------------------------------------- cursor

  function buildRows() {
    var rows = [["back"], ["enabled"]]
    for (var i = 0; i < entries.length; i++) rows.push(["dns:" + i])
    rows.push(["dnsField"])
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
    if (key.indexOf("dns:") === 0) { removeEntry(Number(key.substring(4))); return true }
    return false
  }

  function activateKey(key) {
    if (key === "back") closeRequested()
    else if (key === "enabled") {
      if (!enabled_ && entries.length === 0) { fieldError = t("dns.addFirst", "Add at least one DNS server first"); dnsField.forceActiveFocus(); return }
      apply(!enabled_, entries)
    } else if (key === "dnsField") dnsField.forceActiveFocus()
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
        text: root.t("settings.customDns", "Custom DNS")
        color: root.theme.text
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      SettingRow {
        width: parent.width
        cursorKey: "enabled"
        theme: root.theme
        title: root.t("dns.enable", "Use custom DNS servers")
        subtitle: root.t("dns.help", "Overrides NetShield filtering. Reconnect to apply.")
        note: root.host ? root.host.noteFor("custom_dns") : ""
        noteColor: root.host ? root.host.noteColorFor("custom_dns") : root.theme.text
        hasCursor: cursorModel.has("enabled")
        onHovered: cursorModel.setId("enabled")
        onActivated: root.activateKey("enabled")
        trailing: ToggleSwitch {
          checked: root.enabled_
          busy: root.host && root.host.busyKey === "custom_dns"
          cursorRing: false
          foreground: root.theme.text
          onToggled: root.activateKey("enabled")
        }
      }

      PanelSeparator { width: parent.width }

      PanelSectionHeader { text: root.t("dns.servers", "DNS servers (in order)"); foreground: root.theme.text }

      PlainText {
        visible: root.entries.length === 0
        width: parent.width
        leftPadding: Style.space(10)
        text: root.t("dns.empty", "No DNS servers yet")
        color: root.theme.dim
        font.pixelSize: Style.font.bodySmall
      }

      Repeater {
        model: root.entries
        ServerRow {
          required property var modelData
          required property int index
          width: parent.width
          cursorKey: "dns:" + index
          theme: root.theme
          badgeText: String(index + 1)
          title: String(modelData.ip || "")
          subtitle: index === 0 ? root.t("dns.primary", "Primary") : ""
          showConnect: false
          showRemove: true
          hasCursor: cursorModel.has(cursorKey)
          onHovered: cursorModel.setId(cursorKey)
          onRemoveClicked: root.removeEntry(index)
        }
      }

      PlainText {
        visible: root.entries.length > 1
        width: parent.width
        leftPadding: Style.space(10)
        text: root.t("dns.reorderHint", "Ctrl+j / Ctrl+k reorders, x removes")
        color: root.theme.faint
        font.pixelSize: Style.font.caption
      }

      CursorSurface {
        property string cursorKey: "dnsField"
        width: parent.width
        implicitHeight: dnsField.implicitHeight
        hasCursor: cursorModel.has("dnsField") && !dnsField.activeFocus
        foreground: root.theme.text
        radius: Style.cornerRadius

        TextField {
          id: dnsField
          anchors.fill: parent
          foreground: root.theme.text
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          placeholderText: root.t("dns.placeholder", "Add a DNS server, e.g. 9.9.9.9")
          inputMethodHints: Qt.ImhNoPredictiveText
          onTextChanged: root.fieldError = ""
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              if (dnsField.text !== "") dnsField.text = ""
              else root.releaseFocus()
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.addEntry()
              event.accepted = true
            } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab || event.key === Qt.Key_Tab) {
              root.releaseFocus()
              cursorModel.setId("dnsField")
              cursorModel.move(0, -1)
              event.accepted = true
            }
          }
        }
      }

      PlainText {
        visible: root.fieldError !== ""
        width: parent.width
        text: root.fieldError
        color: root.theme.danger
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }
}
