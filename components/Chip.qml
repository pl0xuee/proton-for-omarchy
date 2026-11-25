import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Compact pill action (quick connect variants, security strip, filters).
CursorSurface {
  id: root

  property var theme: null
  property string cursorKey: ""
  property string text: ""
  property string iconText: ""
  property bool selected: false
  property bool locked: false
  property bool primary: false
  property color tint: Commons.Color.accent
  property string tooltipText: ""

  signal clicked()
  signal hovered()

  readonly property color fg: theme ? theme.text : Commons.Color.foreground

  foreground: fg
  bordered: true
  current: selected
  opacity: enabled ? (locked ? 0.6 : 1.0) : 0.4
  implicitHeight: Style.spacing.controlHeight
  implicitWidth: row.implicitWidth + Style.space(20)
  radius: Style.cornerRadius
  // Keep CursorSurface's cursor/selected fills; only the resting fill differs.
  color: hasCursor ? fill : (current ? currentFill : (primary ? Util.alpha(tint, 0.16) : "transparent"))

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)

    PlainText {
      visible: root.iconText !== ""
      anchors.verticalCenter: parent.verticalCenter
      text: root.iconText
      color: root.primary || root.selected ? root.tint : root.fg
      font.pixelSize: Style.font.iconSmall
    }

    PlainText {
      anchors.verticalCenter: parent.verticalCenter
      text: root.text
      color: root.primary ? root.tint : root.fg
      font.pixelSize: Style.font.bodySmall
      font.bold: root.primary || root.selected
    }

    PlainText {
      visible: root.locked
      anchors.verticalCenter: parent.verticalCenter
      text: "󰌾"
      color: root.theme ? root.theme.faint : root.fg
      font.pixelSize: Style.font.caption
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    enabled: root.enabled
    cursorShape: Qt.PointingHandCursor
    onContainsMouseChanged: if (containsMouse) root.hovered()
    onClicked: root.clicked()
  }

  PanelToolTip {
    visible: root.tooltipText !== "" && mouse.containsMouse
    text: root.tooltipText
  }
}
