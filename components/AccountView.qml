import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../Model.js" as Model
import "ViewUtil.js" as ViewUtil

// Tab 4: in-app sign-in (credentials → TOTP / FIDO2), account card,
// diagnostics and sign out. Secrets live only in the fields and are cleared
// on submit, on error and when the panel closes.
Item {
  id: root

  property var svc: null
  property var tr: null
  property var theme: null
  property real maxHeight: Style.space(440)
  property bool shown: false

  signal confirmRequested(string message, string confirmText, var onConfirm)
  signal releaseFocus()

  readonly property alias cursor: cursorModel
  readonly property bool editing: userField.activeFocus || passField.activeFocus || totpField.activeFocus || pinField.activeFocus
  readonly property bool loggedIn: svc && svc.loggedIn
  readonly property string step: !svc || loggedIn ? "account" : (svc.authStep === "2fa" ? "2fa" : "credentials")
  readonly property bool fido2Supported: svc && svc.auth && svc.auth.supportsFido2 === true
  property bool showPassword: false
  property bool diagOpen: false
  property bool historyOpen: false
  property var diagChecks: []
  property bool diagLoading: false

  implicitHeight: Math.min(column.implicitHeight, maxHeight)

  function t(key, fallback) { return tr ? tr.t(key, fallback) : fallback }

  function clearSecrets() {
    passField.text = ""
    totpField.text = ""
    pinField.text = ""
    showPassword = false
  }

  // Panel closed: start collapsed next time (diagnostics would be stale anyway).
  function resetView() {
    diagOpen = false
    historyOpen = false
    diagChecks = []
  }

  function focusFirstField() {
    if (step === "credentials") (userField.text === "" ? userField : passField).forceActiveFocus()
    else if (step === "2fa" && svc.fido2Prompt === "pin") pinField.forceActiveFocus()
    else if (step === "2fa") totpField.forceActiveFocus()
  }

  onStepChanged: {
    cursorModel.reset()
    if (step === "2fa" && shown) Qt.callLater(focusFirstField)
    if (step === "account") { clearSecrets(); userField.text = "" }
  }

  Connections {
    target: root.svc
    function onAuthErrorChanged() { if (root.svc.authError !== "") { passField.text = ""; totpField.text = ""; pinField.text = "" } }
    function onFido2PromptChanged() { if (root.svc.fido2Prompt === "pin" && root.shown) Qt.callLater(function() { pinField.forceActiveFocus() }) }
  }

  // ----------------------------------------------------------- actions

  function submitCredentials() {
    if (svc.authBusy) return
    var user = userField.text.trim()
    var pass = passField.text
    if (user === "") { userField.forceActiveFocus(); return }
    if (pass === "") { passField.forceActiveFocus(); return }
    passField.text = ""
    showPassword = false
    svc.login(user, pass)
    pass = ""
  }

  function submitTotp() {
    if (svc.authBusy) return
    var code = totpField.text.replace(/\s+/g, "")
    if (code === "") { totpField.forceActiveFocus(); return }
    totpField.text = ""
    svc.submitTotp(code)
  }

  function submitPin() {
    if (svc.authBusy) return
    var pin = pinField.text
    if (pin === "") return
    pinField.text = ""
    svc.submitFido2Pin(pin)
  }

  function signOut() {
    if (svc.connectionState !== "disconnected") {
      confirmRequested(t("account.signOutConnected", "Sign out? The VPN will disconnect."),
                       t("account.signOut", "Sign out"),
                       function() { root.svc.logout() })
      return
    }
    confirmRequested(t("account.signOutConfirm", "Sign out of Proton VPN on this device?"),
                     t("account.signOut", "Sign out"),
                     function() { root.svc.logout() })
  }

  function loadDiagnostics() {
    diagLoading = true
    svc.diagnostics(function(ok, data) {
      root.diagLoading = false
      root.diagChecks = ok && data ? (data.checks || []) : []
    })
  }

  function checkLabel(key) {
    switch (key) {
    case "runtimeDir": return t("diag.runtimeDir", "Runtime directory")
    case "protonApi": return t("diag.protonApi", "Proton VPN libraries")
    case "networkManager": return "NetworkManager"
    case "splitTunnelDaemon": return t("diag.splitDaemon", "Split Tunneling service")
    case "keyring": return t("diag.keyring", "Keyring")
    case "protocols": return t("diag.protocols", "Protocols")
    case "bridge": return t("diag.bridge", "Backend bridge")
    }
    return key
  }

  // ------------------------------------------------------------- cursor

  function buildRows() {
    if (!svc) return []
    if (step === "credentials") return [["user"], ["pass", "showPass"], ["signIn"], ["signup"]]
    if (step === "2fa") {
      var rows = []
      if (svc.fido2Prompt === "pin") rows.push(["pin"])
      if (fido2Supported) rows.push(["fido2"])
      rows.push(["totp"], ["verify", "backToLogin"])
      return rows
    }
    var acct = svc.freeTier ? [["upgrade"], ["refreshPlan"], ["diag"]] : [["refreshPlan"], ["diag"]]
    if (diagOpen) acct.push(["copyDiag", "restartBridge"])
    acct.push(["history"])
    if (historyOpen && svc.history.length > 0) acct.push(["clearHistory"])
    acct.push(["signOut"])
    return acct
  }

  CursorModel {
    id: cursorModel
    rows: root.buildRows()
    onMoved: Qt.callLater(root.scrollToCursor)
  }

  function scrollToCursor() {
    ViewUtil.ensureVisible(flick, ViewUtil.findKey(column, cursorModel.currentId), Style.space(6))
  }

  function resetCursor() { cursorModel.reset() }
  function moveCursor(dx, dy) { return cursorModel.move(dx, dy) }
  function activate() {
    if (!cursorModel.active) return false
    activateKey(cursorModel.currentId)
    return true
  }
  function back() {
    if (step === "2fa") { svc.backToCredentials(); return true }
    if (diagOpen) { diagOpen = false; return true }
    if (historyOpen) { historyOpen = false; return true }
    return false
  }
  function textKey(text) { return false }

  function activateKey(key) {
    if (key === "user") userField.forceActiveFocus()
    else if (key === "pass") passField.forceActiveFocus()
    else if (key === "showPass") showPassword = !showPassword
    else if (key === "signIn") submitCredentials()
    else if (key === "pin") pinField.forceActiveFocus()
    else if (key === "fido2") { if (svc.fido2Running) svc.cancelFido2(); else svc.startFido2() }
    else if (key === "totp") totpField.forceActiveFocus()
    else if (key === "verify") submitTotp()
    else if (key === "backToLogin") svc.backToCredentials()
    else if (key === "refreshPlan") svc.refreshAccount()
    else if (key === "upgrade") svc.openPricing()
    else if (key === "signup") svc.openSignup()
    else if (key === "diag") { diagOpen = !diagOpen; if (diagOpen) loadDiagnostics() }
    else if (key === "copyDiag") {
      var lines = []
      for (var i = 0; i < diagChecks.length; i++) {
        var c = diagChecks[i]
        lines.push(checkLabel(c.key) + ": " + (c.ok ? "OK" : "FAIL") + (c.detail ? " (" + c.detail + ")" : ""))
      }
      svc.copyText(lines.join("\n"), t("account.diagnosticsReport", "Diagnostics"))
    }
    else if (key === "restartBridge") svc.restartBridge()
    else if (key === "history") historyOpen = !historyOpen
    else if (key === "clearHistory") {
      confirmRequested(t("history.clearConfirm", "Clear your connection history?"), t("history.clear", "Clear history"),
                       function() { root.svc.clearHistory() })
    }
    else if (key === "signOut") signOut()
  }

  // Shared key handling for the inline fields.
  function fieldKeys(field, cursorId, event, onEnter) {
    if (event.key === Qt.Key_Escape) {
      root.releaseFocus()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      onEnter()
      event.accepted = true
    } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
      root.releaseFocus()
      cursorModel.setId(cursorId)
      cursorModel.move(0, event.key === Qt.Key_Up ? -1 : 1)
      event.accepted = true
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      // Tab walks the form like a browser: user ↔ password.
      if (field === userField && event.key === Qt.Key_Tab) passField.forceActiveFocus()
      else if (field === passField && event.key === Qt.Key_Backtab) userField.forceActiveFocus()
      else root.releaseFocus()
      event.accepted = true
    }
  }

  // ------------------------------------------------------------- layout

  Flickable {
    id: flick
    anchors.fill: parent
    contentWidth: width
    contentHeight: column.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    Column {
      id: column
      width: flick.width
      spacing: Style.space(8)

      // ================================================= sign in
      Column {
        visible: root.step === "credentials"
        width: parent.width
        spacing: Style.space(8)

        PlainText {
          width: parent.width
          text: root.t("account.signInTitle", "Sign in to Proton VPN")
          color: root.theme.text
          font.pixelSize: Style.font.title
          font.bold: true
        }
        PlainText {
          width: parent.width
          text: root.t("account.signInBody", "Use your Proton account. Your session is kept in the system keyring.")
          color: root.theme.dim
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        FieldBox {
          cursorKey: "user"
          field: userField
          TextField {
            id: userField
            anchors.fill: parent
            foreground: root.theme.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            enabled: !root.svc || !root.svc.authBusy
            placeholderText: root.t("account.username", "Username or email")
            inputMethodHints: Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText | Qt.ImhSensitiveData
            Keys.onPressed: function(event) {
              root.fieldKeys(userField, "user", event, function() {
                if (userField.text.trim() !== "") passField.forceActiveFocus()
              })
            }
          }
        }

        RowLayout {
          width: parent.width
          spacing: Style.space(6)

          FieldBox {
            Layout.fillWidth: true
            cursorKey: "pass"
            field: passField
            TextField {
              id: passField
              anchors.fill: parent
              foreground: root.theme.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              enabled: !root.svc || !root.svc.authBusy
              password: !root.showPassword
              placeholderText: root.t("account.password", "Password")
              inputMethodHints: Qt.ImhHiddenText | Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
              Keys.onPressed: function(event) { root.fieldKeys(passField, "pass", event, root.submitCredentials) }
            }
          }

          PanelActionButton {
            property string cursorKey: "showPass"
            iconText: root.showPassword ? "󰈉" : "󰈈"
            tooltipText: root.showPassword ? root.t("account.hidePassword", "Hide password") : root.t("account.showPassword", "Show password")
            foreground: root.theme.text
            hasCursor: cursorModel.has("showPass")
            onHovered: function(h) { if (h) cursorModel.setId("showPass") }
            onClicked: root.activateKey("showPass")
          }
        }

        ErrorLine { text: root.svc ? root.svc.authError : "" }

        Chip {
          width: parent.width
          cursorKey: "signIn"
          theme: root.theme
          primary: true
          enabled: root.svc && !root.svc.authBusy
          iconText: root.svc && root.svc.authBusy ? "󰔟" : "󰍂"
          text: root.svc && root.svc.authBusy ? root.t("account.signingIn", "Signing in…") : root.t("account.signIn", "Sign in")
          hasCursor: cursorModel.has("signIn")
          onHovered: cursorModel.setId("signIn")
          onClicked: root.activateKey("signIn")
        }

        Chip {
          width: parent.width
          cursorKey: "signup"
          theme: root.theme
          iconText: "󰏌"
          text: root.t("account.createAccount", "New to Proton? Create a free account")
          tooltipText: "account.protonvpn.com"
          hasCursor: cursorModel.has("signup")
          onHovered: cursorModel.setId("signup")
          onClicked: root.activateKey("signup")
        }
      }

      // ================================================= two-factor
      Column {
        visible: root.step === "2fa"
        width: parent.width
        spacing: Style.space(8)

        PlainText {
          width: parent.width
          text: root.t("account.twofaTitle", "Two-factor authentication")
          color: root.theme.text
          font.pixelSize: Style.font.title
          font.bold: true
        }

        // FIDO2 card.
        BorderSurface {
          visible: root.fido2Supported
          width: parent.width
          color: root.theme.cardFill
          radius: Style.cornerRadius
          borderSpec: Border.flat(root.theme.hairline, 1)
          implicitHeight: fidoCol.implicitHeight + Style.space(24)

          Column {
            id: fidoCol
            x: Style.space(12)
            y: Style.space(12)
            width: parent.width - Style.space(24)
            spacing: Style.space(8)

            RowLayout {
              width: parent.width
              spacing: Style.space(10)
              PlainText {
                text: "󰌋"
                color: root.svc && root.svc.fido2Running ? Commons.Color.accent : root.theme.dim
                font.pixelSize: Style.font.iconLarge
              }
              PlainText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: root.theme.text
                font.pixelSize: Style.font.bodySmall
                text: {
                  var p = root.svc ? root.svc.fido2Prompt : ""
                  if (p === "insert") return root.t("fido2.insert", "Insert your security key")
                  if (p === "touch") return root.t("fido2.touch", "Touch your security key")
                  if (p === "pin") return root.t("fido2.pin", "Enter your security key PIN")
                  if (p === "select_key") return root.t("fido2.select", "Several keys found. Touch the one to use")
                  return root.t("fido2.idle", "Use a hardware security key")
                }
              }
            }

            FieldBox {
              visible: root.svc && root.svc.fido2Prompt === "pin"
              cursorKey: "pin"
              field: pinField
              TextField {
                id: pinField
                anchors.fill: parent
                foreground: root.theme.text
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                password: true
                placeholderText: root.t("fido2.pinPlaceholder", "Security key PIN")
                inputMethodHints: Qt.ImhHiddenText | Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
                Keys.onPressed: function(event) { root.fieldKeys(pinField, "pin", event, root.submitPin) }
              }
            }

            Chip {
              cursorKey: "fido2"
              theme: root.theme
              primary: !(root.svc && root.svc.fido2Running)
              iconText: root.svc && root.svc.fido2Running ? "󰜺" : "󰌋"
              text: root.svc && root.svc.fido2Running ? root.t("common.cancel", "Cancel") : root.t("fido2.use", "Use security key")
              hasCursor: cursorModel.has("fido2")
              onHovered: cursorModel.setId("fido2")
              onClicked: root.activateKey("fido2")
            }
          }
        }

        PlainText {
          width: parent.width
          text: root.fido2Supported ? root.t("account.orTotp", "Or enter a code from your authenticator app, or a recovery code")
                                    : root.t("account.totpBody", "Enter the code from your authenticator app, or a recovery code")
          color: root.theme.dim
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        FieldBox {
          cursorKey: "totp"
          field: totpField
          TextField {
            id: totpField
            anchors.fill: parent
            foreground: root.theme.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            enabled: root.svc && !root.svc.authBusy
            maximumLength: 64
            placeholderText: root.t("account.totpPlaceholder", "123456")
            inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
            Keys.onPressed: function(event) { root.fieldKeys(totpField, "totp", event, root.submitTotp) }
          }
        }

        ErrorLine { text: root.svc ? root.svc.authError : "" }

        RowLayout {
          width: parent.width
          spacing: Style.space(8)
          Chip {
            Layout.fillWidth: true
            cursorKey: "verify"
            theme: root.theme
            primary: true
            enabled: root.svc && !root.svc.authBusy
            iconText: root.svc && root.svc.authBusy ? "󰔟" : "󰄬"
            text: root.svc && root.svc.authBusy ? root.t("account.verifying", "Verifying…") : root.t("account.verify", "Verify")
            hasCursor: cursorModel.has("verify")
            onHovered: cursorModel.setId("verify")
            onClicked: root.activateKey("verify")
          }
          Chip {
            cursorKey: "backToLogin"
            theme: root.theme
            text: root.t("common.back", "Back")
            hasCursor: cursorModel.has("backToLogin")
            onHovered: cursorModel.setId("backToLogin")
            onClicked: root.activateKey("backToLogin")
          }
        }
      }

      // ================================================= signed in
      Column {
        visible: root.step === "account"
        width: parent.width
        spacing: Style.space(8)

        BorderSurface {
          width: parent.width
          color: root.theme.cardFill
          radius: Style.cornerRadius
          borderSpec: Border.flat(root.theme.hairline, 1)
          implicitHeight: acctCol.implicitHeight + Style.space(24)

          Column {
            id: acctCol
            x: Style.space(12)
            y: Style.space(12)
            width: parent.width - Style.space(24)
            spacing: Style.space(6)

            RowLayout {
              width: parent.width
              spacing: Style.space(8)
              PlainText {
                Layout.fillWidth: true
                text: root.svc && root.svc.auth ? String(root.svc.auth.accountName || "") : ""
                color: root.theme.text
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
              FeatureBadge {
                theme: root.theme
                strong: true
                tint: root.svc && root.svc.freeTier ? root.theme.text : Commons.Color.accent
                text: root.svc && root.svc.auth ? String(root.svc.auth.planTitle || (root.svc.freeTier ? "VPN Free" : "VPN Plus")) : ""
              }
            }
            PlainText {
              visible: root.svc && root.svc.auth && root.svc.auth.maxConnections > 0
              width: parent.width
              text: root.svc && root.svc.auth ? (root.tr ? root.tr.tn("account.devices", root.svc.auth.maxConnections, "Up to %1 devices") : "Up to %1 devices").replace("%1", root.svc.auth.maxConnections) : ""
              color: root.theme.dim
              font.pixelSize: Style.font.bodySmall
            }
            PlainText {
              visible: root.svc && root.svc.auth && root.svc.auth.delinquent === true
              width: parent.width
              text: root.t("account.delinquent", "There is a billing problem with this account")
              color: root.theme.danger
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }
        }

        SettingRow {
          visible: root.svc && root.svc.freeTier
          width: parent.width
          cursorKey: "upgrade"
          theme: root.theme
          title: root.t("account.upgrade", "Upgrade to VPN Plus")
          subtitle: root.t("account.upgradeHelp", "Every country, Secure Core, P2P, streaming and NetShield")
          hasCursor: cursorModel.has("upgrade")
          onHovered: cursorModel.setId("upgrade")
          onActivated: root.activateKey("upgrade")
          trailing: PlainText { text: "󰏌"; color: Commons.Color.accent; font.pixelSize: Style.font.iconSmall }
        }

        SettingRow {
          width: parent.width
          cursorKey: "refreshPlan"
          theme: root.theme
          title: root.t("account.refreshPlan", "Refresh plan")
          subtitle: root.t("account.refreshPlanHelp", "After upgrading or changing your subscription")
          hasCursor: cursorModel.has("refreshPlan")
          onHovered: cursorModel.setId("refreshPlan")
          onActivated: root.activateKey("refreshPlan")
          trailing: PlainText { text: "󰑐"; color: root.theme.dim; font.pixelSize: Style.font.iconSmall }
        }

        SettingRow {
          width: parent.width
          cursorKey: "diag"
          theme: root.theme
          title: root.t("account.diagnostics", "System health")
          subtitle: root.t("account.diagnosticsHelp", "NetworkManager, keyring, Split Tunneling service, backend")
          hasCursor: cursorModel.has("diag")
          onHovered: cursorModel.setId("diag")
          onActivated: root.activateKey("diag")
          trailing: PlainText {
            text: "󰅀"
            rotation: root.diagOpen ? 180 : 0
            color: root.theme.dim
            font.pixelSize: Style.font.iconSmall
            Behavior on rotation { enabled: !Style.reduceMotion; NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
          }
        }

        Column {
          visible: root.diagOpen
          width: parent.width
          spacing: Style.space(4)
          leftPadding: Style.space(10)

          PlainText {
            visible: root.diagLoading
            text: root.t("account.checking", "Checking…")
            color: root.theme.dim
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.diagChecks
            Column {
              required property var modelData
              width: parent.width - Style.space(10)
              spacing: Style.space(1)
              RowLayout {
                width: parent.width
                spacing: Style.space(8)
                Rectangle {
                  Layout.preferredWidth: Style.space(7)
                  Layout.preferredHeight: Style.space(7)
                  radius: width / 2
                  color: modelData.ok ? root.theme.success : root.theme.danger
                }
                PlainText {
                  Layout.preferredWidth: Style.space(150)
                  text: root.checkLabel(modelData.key)
                  color: root.theme.text
                  font.pixelSize: Style.font.bodySmall
                }
                PlainText {
                  Layout.fillWidth: true
                  text: String(modelData.detail || "")
                  color: root.theme.dim
                  font.pixelSize: Style.font.caption
                }
              }
              PlainText {
                visible: !modelData.ok && String(modelData.hint || "") !== ""
                width: parent.width
                leftPadding: Style.space(15)
                text: String(modelData.hint || "")
                color: root.theme.warning
                font.pixelSize: Style.font.caption
                wrapMode: Text.WrapAnywhere
              }
            }
          }

          Row {
            spacing: Style.space(8)
            topPadding: Style.space(4)
            Chip {
              cursorKey: "copyDiag"
              theme: root.theme
              iconText: "󰆏"
              text: root.t("account.copyReport", "Copy report")
              enabled: root.diagChecks.length > 0
              hasCursor: cursorModel.has("copyDiag")
              onHovered: cursorModel.setId("copyDiag")
              onClicked: root.activateKey("copyDiag")
            }
            Chip {
              cursorKey: "restartBridge"
              theme: root.theme
              iconText: "󰜉"
              text: root.t("home.restartBackend", "Restart backend")
              hasCursor: cursorModel.has("restartBridge")
              onHovered: cursorModel.setId("restartBridge")
              onClicked: root.activateKey("restartBridge")
            }
          }
        }

        SettingRow {
          width: parent.width
          cursorKey: "history"
          theme: root.theme
          title: root.t("history.title", "Connection history")
          subtitle: root.svc && root.svc.historyWanted
                    ? root.t("history.help", "Your last 30 connections, kept only on this computer")
                    : root.t("history.off", "Off. Turn on Keep connection history in Settings")
          hasCursor: cursorModel.has("history")
          onHovered: cursorModel.setId("history")
          onActivated: root.activateKey("history")
          trailing: PlainText {
            text: "󰅀"
            rotation: root.historyOpen ? 180 : 0
            color: root.theme.dim
            font.pixelSize: Style.font.iconSmall
            Behavior on rotation { enabled: !Style.reduceMotion; NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
          }
        }

        Column {
          visible: root.historyOpen
          width: parent.width
          spacing: Style.space(6)
          leftPadding: Style.space(10)

          PlainText {
            visible: root.svc && root.svc.history.length === 0
            width: parent.width - Style.space(10)
            text: root.t("history.empty", "No connections recorded yet.")
            color: root.theme.dim
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.svc ? root.svc.history : []
            Column {
              required property var modelData
              width: parent.width - Style.space(24)
              spacing: Style.space(1)
              RowLayout {
                width: parent.width
                spacing: Style.space(8)
                PlainText {
                  Layout.fillWidth: true
                  text: String(modelData.label || modelData.server)
                  color: root.theme.text
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
                PlainText {
                  text: String(modelData.server || "")
                  visible: String(modelData.label || "") !== String(modelData.server || "")
                  color: root.theme.dim
                  font.pixelSize: Style.font.caption
                }
              }
              PlainText {
                width: parent.width
                text: new Date(modelData.start * 1000).toLocaleString(Qt.locale(), Locale.ShortFormat)
                      + " · " + Model.shortDuration(modelData.end - modelData.start)
                      + (modelData.rx || modelData.tx ? " · ↓ " + Model.formatBytes(modelData.rx) + "  ↑ " + Model.formatBytes(modelData.tx) : "")
                color: root.theme.dim
                font.pixelSize: Style.font.caption
                font.features: { "tnum": 1 }
                elide: Text.ElideRight
              }
            }
          }

          Chip {
            visible: root.svc && root.svc.history.length > 0
            cursorKey: "clearHistory"
            theme: root.theme
            iconText: "󰆴"
            text: root.t("history.clear", "Clear history")
            hasCursor: cursorModel.has("clearHistory")
            onHovered: cursorModel.setId("clearHistory")
            onClicked: root.activateKey("clearHistory")
          }
        }

        PanelSeparator { width: parent.width }

        Chip {
          width: parent.width
          cursorKey: "signOut"
          theme: root.theme
          tint: Commons.Color.urgent
          iconText: "󰍃"
          text: root.t("account.signOut", "Sign out")
          hasCursor: cursorModel.has("signOut")
          onHovered: cursorModel.setId("signOut")
          onClicked: root.activateKey("signOut")
        }
      }
    }
  }

  // ------------------------------------------------------- inline pieces

  component FieldBox: CursorSurface {
    id: box
    property string cursorKey: ""
    property Item field: null
    width: parent ? parent.width : 0
    implicitHeight: field ? field.implicitHeight : Style.spacing.controlHeight
    hasCursor: cursorModel.has(cursorKey) && !(field && field.activeFocus)
    foreground: root.theme.text
    radius: Style.cornerRadius
  }

  component ErrorLine: PlainText {
    visible: text !== ""
    width: parent ? parent.width : 0
    color: root.theme.danger
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }
}
