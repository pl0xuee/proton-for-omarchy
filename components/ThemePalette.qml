import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "../Model.js" as Model

// Semantic colors derived from the active Omarchy theme. Reads the optional
// green/yellow (or ANSI color2/color3) entries from the live theme's
// colors.toml and falls back to accent/urgent so every theme still works.
QtObject {
  id: root

  property color foreground: Commons.Color.popups.text
  property color background: Commons.Color.popups.background

  readonly property bool light: Model.isLightColor(background)
  readonly property color text: foreground
  readonly property color dim: Util.alpha(foreground, light ? 0.72 : 0.62)
  readonly property color faint: Util.alpha(foreground, light ? 0.5 : 0.4)
  readonly property color hairline: Util.alpha(foreground, light ? 0.18 : 0.12)
  readonly property color cardFill: Util.alpha(foreground, light ? 0.05 : 0.04)
  readonly property color badgeFill: Util.alpha(foreground, light ? 0.1 : 0.08)
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent

  readonly property string _toml: themeFile.text()
  readonly property string _green: Model.parseThemeColor(_toml, "green") || Model.parseThemeColor(_toml, "color2")
  readonly property string _yellow: Model.parseThemeColor(_toml, "yellow") || Model.parseThemeColor(_toml, "color3")

  readonly property color success: _green !== "" ? _green : accent
  readonly property color warning: _yellow !== "" ? _yellow : Util.alpha(urgent, 0.85)
  readonly property color danger: urgent

  function loadColor(load) {
    var level = Model.loadLevel(load)
    return level === 2 ? danger : (level === 1 ? warning : success)
  }

  property FileView themeFile: FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    blockLoading: true
    onFileChanged: reload()
  }
}
