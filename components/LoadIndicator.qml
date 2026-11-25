import QtQuick
import qs.Commons
import qs.Commons as Commons
import "../Model.js" as Model

// Small load dot + percentage, colored by the theme's semantic palette.
Row {
  id: root

  property var theme: null
  property int load: 0
  property bool showText: true
  property bool dimmed: false

  spacing: Style.space(5)
  opacity: dimmed ? 0.5 : 1.0

  Rectangle {
    width: Style.space(7)
    height: width
    radius: width / 2
    anchors.verticalCenter: parent.verticalCenter
    color: root.theme ? root.theme.loadColor(root.load) : Commons.Color.accent
  }

  PlainText {
    visible: root.showText
    anchors.verticalCenter: parent.verticalCenter
    text: Model.clampLoad(root.load) + "%"
    color: root.theme ? root.theme.dim : Commons.Color.foreground
    font.pixelSize: Style.font.caption
    font.features: { "tnum": 1 }
    horizontalAlignment: Text.AlignRight
    width: Math.max(implicitWidth, Style.space(28))
  }
}
