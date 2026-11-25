import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Four compact tabs with number hints and a sliding underline.
Item {
  id: root

  property var theme: null
  property var tabs: []            // [{ key, label }]
  property int currentIndex: 0
  property int cursorIndex: -1     // keyboard cursor when the tab row is focused

  signal selected(int index)
  signal hovered(int index)

  implicitHeight: Style.spacing.controlHeight + Style.space(4)

  Row {
    id: tabRow
    anchors.fill: parent

    Repeater {
      model: root.tabs
      CursorSurface {
        id: tab
        required property var modelData
        required property int index
        width: tabRow.width / Math.max(1, root.tabs.length)
        height: tabRow.height - Style.space(4)
        hasCursor: root.cursorIndex === index
        current: false
        foreground: root.theme ? root.theme.text : Commons.Color.foreground

        Row {
          anchors.centerIn: parent
          spacing: Style.space(6)

          PlainText {
            anchors.verticalCenter: parent.verticalCenter
            text: String(tab.index + 1)
            color: root.theme ? root.theme.faint : tab.foreground
            font.pixelSize: Style.font.caption
          }

          PlainText {
            anchors.verticalCenter: parent.verticalCenter
            text: String(tab.modelData.label || "")
            color: root.currentIndex === tab.index ? tab.foreground : (root.theme ? root.theme.dim : tab.foreground)
            font.pixelSize: Style.font.bodySmall
            font.bold: root.currentIndex === tab.index
          }
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onEntered: root.hovered(tab.index)
          onClicked: root.selected(tab.index)
        }
      }
    }
  }

  Rectangle {
    anchors.bottom: parent.bottom
    width: parent.width
    height: 1
    color: root.theme ? root.theme.hairline : Util.alpha(Commons.Color.foreground, 0.12)
  }

  Rectangle {
    id: indicator
    readonly property real tabWidth: root.width / Math.max(1, root.tabs.length)
    anchors.bottom: parent.bottom
    height: Math.max(2, Style.space(2))
    radius: height / 2
    width: tabWidth * 0.5
    x: tabWidth * root.currentIndex + (tabWidth - width) / 2
    color: Commons.Color.accent

    Behavior on x {
      enabled: !Style.reduceMotion
      NumberAnimation { duration: Style.duration(170); easing.type: Easing.OutCubic }
    }
  }
}
