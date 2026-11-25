import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Label + helper text on the left, a trailing control on the right edge.
CursorSurface {
  id: root

  property var theme: null
  property string cursorKey: ""
  property string title: ""
  property string subtitle: ""
  property string note: ""           // e.g. "Reconnect to apply" / "Live"
  property color noteColor: Commons.Color.accent
  property bool locked: false
  property bool chevron: false
  property alias trailing: trailingSlot.data

  signal activated()
  signal hovered()

  readonly property color fg: theme ? theme.text : Commons.Color.foreground

  foreground: fg
  implicitHeight: Math.max(Style.spacing.popupRowHeight, layout.implicitHeight + Style.spacing.rowPaddingX)

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onContainsMouseChanged: if (containsMouse) root.hovered()
    onClicked: root.activated()
  }

  RowLayout {
    id: layout
    anchors.fill: parent
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(8)
    spacing: Style.space(10)
    opacity: root.enabled ? 1.0 : 0.5

    ColumnLayout {
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      spacing: Style.space(1)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        PlainText {
          Layout.fillWidth: true
          text: root.title
          color: root.fg
          font.pixelSize: Style.font.body
        }

        FeatureBadge {
          visible: root.locked
          theme: root.theme
          text: "PLUS"
          strong: true
          tint: Commons.Color.accent
        }

        PlainText {
          visible: root.note !== ""
          text: root.note
          color: root.noteColor
          font.pixelSize: Style.font.caption
        }
      }

      PlainText {
        Layout.fillWidth: true
        visible: text !== ""
        text: root.subtitle
        color: root.theme ? root.theme.dim : root.fg
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        maximumLineCount: 2
      }
    }

    Item {
      id: trailingSlot
      Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
      implicitWidth: childrenRect.width
      implicitHeight: childrenRect.height
    }

    PlainText {
      visible: root.chevron
      text: "󰅂"
      color: root.theme ? root.theme.faint : root.fg
      font.pixelSize: Style.font.iconSmall
      rotation: Commons.I18n.rightToLeft ? 180 : 0
      Layout.alignment: Qt.AlignVCenter
    }
  }
}
