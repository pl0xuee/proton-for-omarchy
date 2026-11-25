import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Native shield mark for tiny bar slots (no SVG/effects). States:
//   connected  -> solid shield with a cut-out check
//   connecting -> outline shield pulsing
//   off        -> outline shield, dimmed by the caller
//   warning    -> urgent "!" badge (error / kill switch blocking)
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Commons.Color.foreground
  property color cutoutColor: Commons.Color.background
  property color badgeColor: Commons.Color.urgent
  property bool connected: false
  property bool busy: false
  property bool warning: false

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real s: iconSize
  readonly property real stroke: Math.max(1.25, s * 0.11)

  Shape {
    id: shield
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    opacity: 1.0

    ShapePath {
      strokeColor: root.color
      strokeWidth: root.stroke
      fillColor: root.connected ? root.color : "transparent"
      joinStyle: ShapePath.RoundJoin
      capStyle: ShapePath.RoundCap
      startX: root.s * 0.5; startY: root.s * 0.06
      PathLine { x: root.s * 0.88; y: root.s * 0.2 }
      PathCubic {
        x: root.s * 0.5; y: root.s * 0.95
        control1X: root.s * 0.88; control1Y: root.s * 0.58
        control2X: root.s * 0.72; control2Y: root.s * 0.82
      }
      PathCubic {
        x: root.s * 0.12; y: root.s * 0.2
        control1X: root.s * 0.28; control1Y: root.s * 0.82
        control2X: root.s * 0.12; control2Y: root.s * 0.58
      }
      PathLine { x: root.s * 0.5; y: root.s * 0.06 }
    }

    ShapePath {
      strokeColor: root.connected ? root.cutoutColor : "transparent"
      strokeWidth: root.stroke
      fillColor: "transparent"
      joinStyle: ShapePath.RoundJoin
      capStyle: ShapePath.RoundCap
      startX: root.s * 0.33; startY: root.s * 0.48
      PathLine { x: root.s * 0.46; y: root.s * 0.61 }
      PathLine { x: root.s * 0.68; y: root.s * 0.37 }
    }

    SequentialAnimation on opacity {
      running: root.busy && !Style.reduceMotion
      loops: Animation.Infinite
      onRunningChanged: if (!running) shield.opacity = 1.0
      NumberAnimation { to: 0.35; duration: Style.duration(520); easing.type: Easing.InOutQuad }
      NumberAnimation { to: 1.0; duration: Style.duration(520); easing.type: Easing.InOutQuad }
    }
  }

  BorderSurface {
    visible: root.warning
    width: Math.max(7, parent.width * 0.44)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.rightMargin: -width * 0.2
    borderSpec: Border.flat(Commons.Color.popups.background, 1)

    Text {
      anchors.centerIn: parent
      text: "!"
      textFormat: Text.PlainText
      color: Commons.Color.background
      font.family: Style.font.family
      font.pixelSize: Math.max(6, parent.height * 0.72)
      font.bold: true
    }
  }
}
