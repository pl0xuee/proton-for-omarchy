import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Modal prompt: "name this profile" (with a text field) or a plain offer
// such as "See plans" (showField false). Enter saves, Esc cancels, Tab moves
// between the field and the buttons. Styled like the shell's ConfirmDialog,
// but the main action is accent-colored rather than destructive red.
Item {
  id: root

  property bool opened: false
  property string title: ""
  property string initialText: ""
  property string saveText: "Save"
  property string cancelText: "Cancel"
  property string placeholder: "Name"
  property bool showField: true
  property color background: Commons.Color.background
  property color foreground: Commons.Color.foreground
  // 0 field, 1 cancel, 2 save
  property int focusIndex: 0
  readonly property string value: field.text.trim()

  signal canceled()
  signal saved(string name)

  visible: opened

  onOpenedChanged: {
    if (!opened) return
    field.text = initialText
    if (!showField) {
      focusIndex = 2
      Qt.callLater(function() { keySink.forceActiveFocus() })
      return
    }
    focusIndex = 0
    Qt.callLater(function() { field.forceActiveFocus(); field.selectAll() })
  }

  function save() {
    if (!root.showField) { root.saved(""); return }
    if (root.value === "") { field.forceActiveFocus(); return }
    root.saved(root.value.substring(0, 80))
  }

  function cycle(step) {
    if (!showField) { focusIndex = focusIndex === 1 ? 2 : 1; return }
    focusIndex = (focusIndex + step + 3) % 3
    if (focusIndex === 0) field.forceActiveFocus()
    else keySink.forceActiveFocus()
  }

  // Keys while a button (not the field) is selected.
  Item {
    id: keySink
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape) root.canceled()
      else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Right) root.cycle(1)
      else if (event.key === Qt.Key_Backtab || event.key === Qt.Key_Left) root.cycle(-1)
      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
        if (root.focusIndex === 1) root.canceled()
        else root.save()
      }
      event.accepted = true
    }
  }

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(Commons.Color.background, 0.7)

    MouseArea { anchors.fill: parent; onClicked: root.canceled() }

    BorderSurface {
      id: card
      width: Math.min(parent.width - Style.space(32), Style.space(370))
      height: card.contentTopInset + card.contentBottomInset + titleText.implicitHeight
              + (root.showField ? field.implicitHeight + Style.space(14) : 0) + Style.space(34) + Style.space(18)
      anchors.centerIn: parent
      color: root.background
      borderSpec: Border.flat(Commons.Color.accent, Style.normalBorderWidth)
      padding: Style.space(18)
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        PlainText {
          id: titleText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          text: root.title
          color: root.foreground
          font.pixelSize: Style.font.title
          wrapMode: Text.WordWrap
        }

        TextField {
          id: field
          visible: root.showField
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: titleText.bottom
          anchors.topMargin: Style.space(14)
          foreground: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          maximumLength: 80
          placeholderText: root.placeholder
          inputMethodHints: Qt.ImhNoPredictiveText
          onActiveFocusChanged: if (activeFocus) root.focusIndex = 0
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) { root.canceled(); event.accepted = true }
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.save(); event.accepted = true }
            else if (event.key === Qt.Key_Tab) { root.cycle(1); event.accepted = true }
            else if (event.key === Qt.Key_Backtab) { root.cycle(-1); event.accepted = true }
          }
        }

        Row {
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          spacing: Style.space(10)

          Repeater {
            model: [root.cancelText, root.saveText]

            BorderSurface {
              required property int index
              required property string modelData
              readonly property bool selected: root.focusIndex === index + 1
              readonly property bool isSave: index === 1
              readonly property bool usable: !isSave || !root.showField || root.value !== ""

              width: Math.max(Style.space(88), label.implicitWidth + Style.space(24))
              height: Style.space(34)
              opacity: usable ? 1 : 0.5
              color: selected ? Util.alpha(root.foreground, 0.08) : "transparent"
              borderSpec: Border.flat(selected || (isSave && usable) ? Commons.Color.accent : Util.alpha(root.foreground, 0.38),
                                      Style.normalBorderWidth)
              radius: 0

              PlainText {
                id: label
                anchors.centerIn: parent
                text: modelData
                color: selected || (isSave && usable) ? Commons.Color.accent : root.foreground
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: if (!root.showField) root.focusIndex = index + 1
                onClicked: { if (isSave) root.save(); else root.canceled() }
              }
            }
          }
        }
      }
    }
  }
}
