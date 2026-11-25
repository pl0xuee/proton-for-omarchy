import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// One navigable row for countries, cities, Secure Core hops, servers,
// favorites and recents. Visuals come only from hasCursor/current (never
// containsMouse), per the CursorSurface contract.
CursorSurface {
  id: root

  property var theme: null
  property string cursorKey: ""
  property string badgeText: ""      // country code / glyph on the left rail
  property bool badgeIsGlyph: false
  property string title: ""
  property string subtitle: ""
  property int load: -1
  property var features: []
  property bool locked: false
  property bool maintenance: false
  property bool showConnect: true
  property bool showDrill: false
  property bool showFavorite: false
  property bool favorite: false
  property bool showRemove: false
  property bool showRename: false
  property string renameTooltip: ""
  property bool connecting: false
  property bool isCurrent: false
  property string connectTooltip: ""
  property string lockedText: "PLUS"

  signal activated()
  signal connectClicked()
  signal drillClicked()
  signal favoriteClicked()
  signal removeClicked()
  signal renameClicked()
  signal hovered()

  readonly property bool usable: !locked && !maintenance
  readonly property color fg: theme ? theme.text : Commons.Color.foreground

  foreground: fg
  current: isCurrent
  implicitHeight: Math.max(Style.spacing.popupRowHeight, content.implicitHeight + Style.spacing.rowPaddingX)

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.usable || root.showDrill ? Qt.PointingHandCursor : Qt.ArrowCursor
    onContainsMouseChanged: if (containsMouse) root.hovered()
    onClicked: root.activated()
  }

  RowLayout {
    id: content
    anchors.fill: parent
    anchors.leftMargin: Style.space(8)
    anchors.rightMargin: Style.space(4)
    spacing: Style.space(8)
    opacity: root.maintenance ? 0.5 : 1.0

    // Left rail: fixed width so every title starts on the same line.
    Item {
      Layout.preferredWidth: Style.space(30)
      Layout.preferredHeight: Style.space(20)
      Layout.alignment: Qt.AlignVCenter
      visible: root.badgeText !== ""

      FeatureBadge {
        visible: !root.badgeIsGlyph
        anchors.centerIn: parent
        theme: root.theme
        text: root.badgeText
        strong: root.isCurrent
        tint: root.isCurrent ? Commons.Color.accent : root.fg
      }

      PlainText {
        visible: root.badgeIsGlyph
        anchors.centerIn: parent
        text: root.badgeText
        color: root.isCurrent ? Commons.Color.accent : (root.theme ? root.theme.dim : root.fg)
        font.pixelSize: Style.font.icon
      }
    }

    ColumnLayout {
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      spacing: Style.space(1)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        PlainText {
          Layout.fillWidth: true
          Layout.minimumWidth: Style.space(40)
          text: root.title
          color: root.fg
          font.pixelSize: Style.font.body
          font.bold: root.isCurrent
        }

        FeatureBadge {
          visible: root.locked
          theme: root.theme
          text: root.lockedText
          strong: true
          tint: Commons.Color.accent
          Layout.alignment: Qt.AlignVCenter
        }
      }

      // Second line: details, then feature badges, so names never get cut short.
      RowLayout {
        Layout.fillWidth: true
        visible: root.subtitle !== "" || root.features.length > 0
        spacing: Style.space(4)

        PlainText {
          visible: text !== ""
          // Bound to the row, not this layout, so the layout never re-triggers itself.
          Layout.maximumWidth: Math.max(Style.space(60), root.width * 0.4)
          elide: Text.ElideRight
          text: root.subtitle
          color: root.theme ? root.theme.dim : root.fg
          font.pixelSize: Style.font.caption
          rightPadding: root.features.length > 0 ? Style.space(4) : 0
        }

        Repeater {
          model: root.features
          FeatureBadge {
            required property var modelData
            theme: root.theme
            text: String(modelData)
            Layout.alignment: Qt.AlignVCenter
          }
        }

        Item { Layout.fillWidth: true }
      }
    }

    LoadIndicator {
      visible: root.load >= 0 && !root.maintenance
      theme: root.theme
      load: Math.max(0, root.load)
      Layout.alignment: Qt.AlignVCenter
    }

    PanelActionButton {
      visible: root.showFavorite
      iconText: root.favorite ? "󰓎" : "󰓒"
      tooltipText: ""
      foreground: root.favorite ? Commons.Color.accent : root.fg
      Layout.alignment: Qt.AlignVCenter
      onClicked: root.favoriteClicked()
    }

    PanelActionButton {
      visible: root.showRename
      iconText: "󰏫"
      tooltipText: root.renameTooltip
      foreground: root.fg
      Layout.alignment: Qt.AlignVCenter
      onClicked: root.renameClicked()
    }

    PanelActionButton {
      visible: root.showRemove
      iconText: "󰅖"
      foreground: root.fg
      hoverColor: Commons.Color.urgent
      Layout.alignment: Qt.AlignVCenter
      onClicked: root.removeClicked()
    }

    PanelActionButton {
      visible: root.showConnect
      enabled: root.usable && !root.connecting
      iconText: root.isCurrent ? "󰌾" : "󰐊"
      tooltipText: root.connectTooltip
      foreground: root.isCurrent ? Commons.Color.accent : root.fg
      Layout.alignment: Qt.AlignVCenter
      onClicked: root.connectClicked()
    }

    PlainText {
      visible: root.showDrill
      text: "󰅂"
      color: root.theme ? root.theme.faint : root.fg
      font.pixelSize: Style.font.iconSmall
      Layout.preferredWidth: Style.space(16)
      horizontalAlignment: Text.AlignHCenter
      Layout.alignment: Qt.AlignVCenter
      LayoutMirroring.enabled: false
      rotation: Commons.I18n.rightToLeft ? 180 : 0

      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(6)
        cursorShape: Qt.PointingHandCursor
        onClicked: root.drillClicked()
      }
    }
  }
}
