import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model
import "components"

// Proton for Omarchy bar widget: shield icon in the bar, four-tab keyboard panel.
Panel {
  id: root
  moduleName: "pl0xuee.proton-for-omarchy"
  ipcTarget: "pl0xuee.proton-for-omarchy"
  manageIpc: false

  // Injected by the shell when it hands the widget its own service.
  property var service: null

  // ---------------------------------------------------------- service

  // Prefer one shared service (one bridge for every bar); fall back to a
  // private instance when the host bar cannot look services up.
  readonly property var sharedService: service ? service
    : (bar && bar.shell && typeof bar.shell.serviceFor === "function" ? bar.shell.serviceFor("pl0xuee.proton-for-omarchy") : null)
  readonly property var svc: sharedService ? sharedService : (inlineLoader.item || null)

  Loader {
    id: inlineLoader
    active: !root.sharedService
    sourceComponent: Component {
      Service {
        active: true
        shell: root.bar ? root.bar.shell : null
        settings: root.settings
      }
    }
  }

  Binding { target: root.sharedService; property: "active"; value: true; when: root.sharedService !== null }
  Binding { target: root.sharedService; property: "settings"; value: root.settings; when: root.sharedService !== null }

  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }
  function t(key, fallback) { return strings.t(key, fallback) }

  ThemePalette { id: themePalette }

  // ---------------------------------------------------------- state

  property int tabIndex: 0
  // focusArea: hero | tabs | body
  property string focusArea: "body"
  property bool cursorShown: false
  property bool confirmOpen: false
  property string confirmMessage: ""
  property string confirmLabel: ""
  property var _confirmAction: null

  readonly property var tabs: [
    { key: "home", label: t("tabs.home", "Home") },
    { key: "servers", label: t("tabs.servers", "Servers") },
    { key: "settings", label: t("tabs.settings", "Settings") },
    { key: "account", label: t("tabs.account", "Account") }
  ]

  readonly property var content: panel.loadedContent
  readonly property var activeView: content ? content.views[tabIndex] : null
  readonly property bool viewEditing: activeView !== null && activeView.editing === true

  readonly property bool loggedIn: svc && svc.loggedIn
  readonly property bool hasProblem: svc && (svc.bridgeFailed || svc.realState === "error"
                                            || (svc.snapshotLoaded && !svc.loggedIn)
                                            || (svc.deps && svc.deps.protonApi === false))
  readonly property string tintRole: String(settings && settings.connectedIconTint ? settings.connectedIconTint : "accent")
  readonly property color connectedColor: tintRole === "foreground" ? barForeground
                                         : (tintRole === "semantic" ? themePalette.success : Commons.Color.accent)
  readonly property color barIconColor: svc && svc.connected ? connectedColor
                                       : (svc && svc.busy ? barForeground : Util.alpha(barForeground, 0.6))
  readonly property bool showCountry: !(settings && settings.showCountryCode === false)

  function openConfirm(message, confirmText, action) {
    confirmMessage = message
    confirmLabel = confirmText
    _confirmAction = action
    confirmOpen = true
    Qt.callLater(function() { if (root.content) root.content.confirmCatcher.forceActiveFocus() })
  }

  function closeConfirm(run) {
    var action = _confirmAction
    confirmOpen = false
    _confirmAction = null
    restoreFocus()
    if (run && typeof action === "function") action()
  }

  function restoreFocus() {
    Qt.callLater(function() { if (root.content) root.content.forceActiveFocus() })
  }

  function setTab(index) {
    if (index < 0 || index >= tabs.length) return
    if (tabIndex !== index && activeView) activeView.cursor.reset()
    tabIndex = index
  }

  function updateWidgetSetting(key, value) {
    var merged = Object.assign({}, settings || {})
    merged[key] = value
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function") bar.shell.updateEntryInline(moduleName, merged)
  }

  // ------------------------------------------------------- key routing

  function moveCursor(dx, dy) {
    if (!cursorShown) {
      cursorShown = true
      focusArea = "body"
      if (activeView && !activeView.cursor.active) activeView.moveCursor(0, 1)
      return
    }
    if (focusArea === "hero") {
      if (dy > 0) focusArea = "tabs"
      return
    }
    if (focusArea === "tabs") {
      if (dx !== 0) { setTab((tabIndex + dx + tabs.length) % tabs.length); return }
      if (dy < 0) { if (root.loggedIn) focusArea = "hero"; return }
      if (dy > 0) {
        focusArea = "body"
        if (activeView) { activeView.cursor.reset(); activeView.moveCursor(0, 1) }
      }
      return
    }
    if (!activeView) return
    var handled = activeView.moveCursor(dx, dy)
    if (!handled && dy < 0) { activeView.cursor.active = false; focusArea = "tabs" }
  }

  function activateCursor() {
    if (!cursorShown) return
    if (focusArea === "hero") { if (svc) svc.toggleConnection(); return }
    if (focusArea === "tabs") { focusArea = "body"; if (activeView) activeView.moveCursor(0, 1); return }
    if (activeView) activeView.activate()
  }

  function handleEscape() {
    if (activeView && activeView.back()) return
    if (cursorShown && focusArea !== "body") { focusArea = "body"; return }
    root.close()
  }

  function handleText(text) {
    if (activeView && focusArea === "body" && activeView.textKey(text)) return
    if (text >= "1" && text <= "4") { setTab(Number(text) - 1); focusArea = "body"; return }
    if (text === "t" || text === "T") { if (svc) svc.toggleConnection(); return }
    if (text === "r" || text === "R") { if (svc) svc.refresh(true); return }
    if (text === "/") {
      setTab(1)
      Qt.callLater(function() { if (root.content) root.content.views[1].focusSearch() })
    }
  }

  // ---------------------------------------------------------- lifecycle

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (svc) svc.setPanelOpen(opened)
    if (opened) {
      cursorShown = false
      focusArea = "body"
      if (svc && svc.snapshotLoaded && !svc.loggedIn) tabIndex = 3
      if (content) {
        for (var i = 0; i < content.views.length; i++) content.views[i].cursor.reset()
      }
      if (svc && svc.loggedIn) svc.refresh(false)
      // Deferred twice so this runs after KeyboardPanel's own focus call.
      Qt.callLater(function() { Qt.callLater(function() {
        if (!root.content) return
        if (root.tabIndex === 3 && !root.loggedIn) root.content.views[3].focusFirstField()
        else root.content.forceActiveFocus()
      }) })
    } else {
      if (confirmOpen) closeConfirm(false)
      if (content) {
        content.views[1].resetView()
        content.views[3].clearSecrets()
        content.views[2].sheet = ""
      }
    }
  }

  // After signing in, land on Home ready for one-click connect.
  Connections {
    target: root.svc
    function onLoggedInChanged() {
      if (root.svc.loggedIn && root.tabIndex === 3) root.tabIndex = 0
    }
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function toggleConnection(): string { if (!root.svc) return "unavailable"; root.svc.toggleConnection(); return "ok" }
    function connectFastest(): string { if (!root.svc) return "unavailable"; root.svc.quickConnect(); return "ok" }
    function switchFastest(): string {
      if (!root.svc) return "unavailable"
      if (root.svc.connectionState !== "connected" && root.svc.connectionState !== "error") return "not connected"
      root.svc.switchToFastest()
      return "ok"
    }
    function connectCountry(code: string): string {
      var cc = String(code || "").trim().toUpperCase()
      if (!/^[A-Z]{2}$/.test(cc)) return "invalid country code"
      if (!root.svc) return "unavailable"
      root.svc.connectTarget({ targetType: "country", country: cc }, cc)
      return "ok"
    }
    function disconnect(): string { if (!root.svc) return "unavailable"; root.svc.disconnect(); return "ok" }
    function status(): string { return root.svc ? root.svc.statusText : "Unavailable" }
    function refresh(): string { if (!root.svc) return "unavailable"; root.svc.refresh(true); return "ok" }
  }

  // ---------------------------------------------------------- bar icon

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelText: root.showCountry && root.svc && root.svc.connected && root.svc.server ? String(root.svc.server.country || "") : ""
    tooltipText: root.svc ? root.svc.statusText : ""
    iconComponent: Component {
      Item {
        ProtonVpnIcon {
          x: (parent.width - width) / 2
          y: (parent.height - height) / 2
          iconSize: button.iconSize
          color: root.barIconColor
          cutoutColor: root.bar ? root.bar.background : Commons.Color.background
          badgeColor: root.bar ? root.bar.urgent : Commons.Color.urgent
          connected: root.svc ? root.svc.connected : false
          busy: root.svc ? root.svc.busy : false
          warning: root.hasProblem
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) { if (root.svc) root.svc.toggleConnection() }
      else if (buttonCode === Qt.MiddleButton) { if (root.svc) root.svc.refresh(true) }
      else root.toggle()
    }
  }

  // ---------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(600))

    content: PanelKeyCatcher {
      id: keyCatcher
      readonly property var views: [homeView, serversView, settingsView, accountView]
      property alias confirmCatcher: confirmCatcher
      implicitHeight: chrome.implicitHeight
      anchors.fill: parent
      blocked: root.confirmOpen || root.viewEditing
      reorderable: root.tabIndex === 2 && settingsView.reorderable
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onReorderRequested: function(dy) { settingsView.reorder(dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.handleEscape()
      onDeleteRequested: if (root.activeView && root.activeView.deleteCurrent) root.activeView.deleteCurrent()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text, modifiers) {
        if (modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return
        root.handleText(text)
      }

      ColumnLayout {
        id: chrome
        anchors.fill: parent
        spacing: Style.space(10)

        // Hero + master switch ------------------------------------------------
        Item {
          id: header
          Layout.fillWidth: true
          implicitHeight: hero.implicitHeight
          readonly property bool ringVisible: root.cursorShown && root.focusArea === "hero"

          PanelHero {
            id: hero
            width: parent.width
            foreground: themePalette.text
            title: {
              if (!root.svc) return "Proton for Omarchy"
              var name = root.svc.server && root.svc.connectionState !== "disconnected" ? String(root.svc.server.name || "") : ""
              return name !== "" ? name : "Proton for Omarchy"
            }
            meta: {
              var s = root.svc
              if (!s) return ""
              if (s.bridgeFailed) return root.t("state.backendStopped", "Backend stopped")
              if (!s.snapshotLoaded) return root.t("state.starting", "Starting…")
              if (!s.loggedIn) return root.t("state.signedOut", "Signed out")
              var st = s.connectionState
              if (s.switching && st === "connected") return root.t("home.switchingFastest", "Finding a faster server…")
              if (st === "connected") {
                var loc = Model.locationLabel(s.server).toUpperCase()
                var proto = s.server ? String(s.server.protocolLabel || "") : ""
                return loc + (proto ? " · " + proto : "")
              }
              if (st === "connecting") return s.pendingLabel ? root.t("state.connectingTo", "Connecting to %1…").replace("%1", s.pendingLabel) : root.t("state.connecting", "Connecting…")
              if (st === "disconnecting") return root.t("state.disconnecting", "Disconnecting…")
              if (st === "error") return root.t("state.error", "Connection failed")
              return root.t("state.unprotected", "Not protected")
            }
            iconOpacity: root.svc && root.svc.connected ? 1.0 : 0.6
            iconComponent: Component {
              ProtonVpnIcon {
                iconSize: Style.font.display
                color: root.svc && root.svc.connected ? root.connectedColor : themePalette.text
                cutoutColor: Commons.Color.popups.background
                badgeColor: Commons.Color.urgent
                connected: root.svc ? root.svc.connected : false
                busy: root.svc ? root.svc.busy : false
                warning: root.hasProblem
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                id: powerSwitch
                visible: root.loggedIn
                checked: root.svc ? root.svc.switchOn : false
                busy: root.svc ? root.svc.busy : false
                hasCursor: header.ringVisible
                foreground: themePalette.text
                onHovered: function(on) { if (on) { root.cursorShown = true; root.focusArea = "hero" } }
                onToggled: if (root.svc) root.svc.toggleConnection()

                PanelToolTip {
                  visible: powerSwitch.containsMouse
                  text: root.svc && root.svc.switchOn ? root.t("hero.disconnect", "Disconnect (t)") : root.t("hero.connectFastest", "Connect to fastest (t)")
                }
              }
            }
          }
        }

        TabBar {
          Layout.fillWidth: true
          theme: themePalette
          tabs: root.tabs
          currentIndex: root.tabIndex
          cursorIndex: root.cursorShown && root.focusArea === "tabs" ? root.tabIndex : -1
          onSelected: function(index) { root.setTab(index); root.focusArea = "body" }
        }

        // Views ---------------------------------------------------------------
        Item {
          id: viewStack
          Layout.fillWidth: true
          readonly property real viewMax: Style.space(600) - header.implicitHeight - Style.space(140)
          implicitHeight: root.activeView ? root.activeView.implicitHeight : 0
          Layout.preferredHeight: implicitHeight

          HomeView {
            id: homeView
            anchors.fill: parent
            visible: root.tabIndex === 0
            shown: root.opened && visible
            svc: root.svc
            tr: strings
            theme: themePalette
            maxHeight: viewStack.viewMax
            onRequestTab: function(index) { root.setTab(index) }
            onRequestSetting: function(key) { root.setTab(2); settingsView.focusSetting(key) }
          }
          ServersView {
            id: serversView
            anchors.fill: parent
            visible: root.tabIndex === 1
            shown: root.opened && visible
            svc: root.svc
            tr: strings
            theme: themePalette
            maxHeight: viewStack.viewMax
            onReleaseFocus: root.restoreFocus()
          }
          SettingsView {
            id: settingsView
            anchors.fill: parent
            visible: root.tabIndex === 2
            shown: root.opened && visible
            svc: root.svc
            tr: strings
            theme: themePalette
            maxHeight: viewStack.viewMax
            widgetSettings: root.settings
            onConfirmRequested: function(message, confirmText, action) { root.openConfirm(message, confirmText, action) }
            onWidgetSettingChanged: function(key, value) { root.updateWidgetSetting(key, value) }
            onReleaseFocus: root.restoreFocus()
          }
          AccountView {
            id: accountView
            anchors.fill: parent
            visible: root.tabIndex === 3
            shown: root.opened && visible
            svc: root.svc
            tr: strings
            theme: themePalette
            maxHeight: viewStack.viewMax
            onConfirmRequested: function(message, confirmText, action) { root.openConfirm(message, confirmText, action) }
            onReleaseFocus: root.restoreFocus()
          }
        }

        // Hint strip / toast --------------------------------------------------
        PlainText {
          Layout.fillWidth: true
          horizontalAlignment: Text.AlignHCenter
          font.pixelSize: Style.font.caption
          color: root.svc && root.svc.toast !== "" ? themePalette.text
               : (root.svc && root.svc.actionError !== "" && root.tabIndex !== 0 ? themePalette.danger : themePalette.faint)
          text: {
            if (root.svc && root.svc.toast !== "") return root.svc.toast
            // Home shows errors in its own banner; other tabs surface them here.
            if (root.svc && root.svc.actionError !== "" && root.tabIndex !== 0) return root.svc.actionError
            if (root.tabIndex === 1) return root.t("hints.servers", "/ search · l open · h back · f favorite · Enter connect")
            if (root.tabIndex === 0 && root.svc && root.svc.connected) return root.t("hints.homeConnected", "t disconnect · s switch to fastest · c copy IP · p port")
            return root.t("hints.default", "j/k move · Enter select · t connect · 1–4 tabs · Esc close")
          }
        }
      }

      // Confirm dialog: takes every key while open.
      Item {
        id: confirmCatcher
        anchors.fill: parent
        visible: root.confirmOpen
        z: 20
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) { root.closeConfirm(false); event.accepted = true; return }
          confirmDialog.handleKey(event)
          event.accepted = true
        }

        ConfirmDialog {
          id: confirmDialog
          anchors.fill: parent
          // Always open on Cancel so a repeated Enter cannot confirm a destructive action.
          onOpenedChanged: if (opened) selectedIndex = 0
          opened: root.confirmOpen
          message: root.confirmMessage
          confirmText: root.confirmLabel
          cancelText: root.t("common.cancel", "Cancel")
          background: Commons.Color.popups.background
          foreground: themePalette.text
          onCanceled: root.closeConfirm(false)
          onConfirmed: root.closeConfirm(true)
        }
      }
    }
  }
}
