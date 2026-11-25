import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Compact, understated tag pill: SC, P2P, TOR, STR, IPv6, PLUS, CH ...
BorderSurface {
  id: root

  property var theme: null
  property string text: ""
  property bool strong: false
  property color tint: theme ? theme.text : Commons.Color.foreground

  implicitWidth: label.implicitWidth + Style.space(10)
  implicitHeight: label.implicitHeight + Style.space(3)
  radius: Math.min(Style.cornerRadius, height / 2)
  color: strong ? Util.alpha(tint, 0.18) : (theme ? theme.badgeFill : Util.alpha(tint, 0.08))
  borderSpec: Border.none()

  PlainText {
    id: label
    anchors.centerIn: parent
    text: root.text
    color: root.strong ? root.tint : (root.theme ? root.theme.dim : root.tint)
    font.pixelSize: Style.font.caption
    font.bold: root.strong
    font.letterSpacing: 0.4
  }
}
