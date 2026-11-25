import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../Model.js" as Model

// Tab 2: search + feature filters + Countries → Country → City drill-down.
// The header (search, filters, breadcrumb) stays put; only the list scrolls.
Item {
  id: root

  property var svc: null
  property var tr: null
  property var theme: null
  property real maxHeight: Style.space(440)
  property bool shown: false

  readonly property alias cursor: cursorModel
  readonly property bool editing: searchField.activeFocus

  // level: countries | country | servers | sc
  property string level: "countries"
  property string countryCode: ""
  property string countryName: ""
  property string city: ""
  property string entryCountry: ""
  property string entryName: ""
  property string query: ""
  property string feature: "all"
  property string sort: "alpha"
  property var items: []
  property bool loading: false
  property string loadError: ""
  property int _seq: 0
  property bool _dirty: true
  // Ping sort: measured on server lists only; elsewhere it falls back to "fastest".
  readonly property bool serverLevel: !query && (level === "servers" || level === "sc")
  readonly property string effectiveSort: sort === "ping" && !serverLevel ? "fastest" : sort
  property bool measuring: false

  signal releaseFocus()

  implicitHeight: maxHeight

  function t(key, fallback) { return tr ? tr.t(key, fallback) : fallback }

  // ------------------------------------------------------------- data

  function reload() {
    if (!svc || !svc.loggedIn) { items = []; return }
    var seq = ++_seq
    var params = { query: query, feature: feature, sort: sort === "ping" ? "fastest" : sort, limit: 300 }
    if (!query && level !== "countries") {
      params.countryCode = countryCode
      if (level === "servers") { params.city = city; params.includeServers = true }
      if (level === "sc") { params.entryCountry = entryCountry; params.includeServers = true; params.secureCore = true }
    }
    loading = true
    measuring = false
    svc.queryServers(params, function(ok, data, error) {
      if (seq !== root._seq) return
      root.loading = false
      if (!ok) { root.loadError = error && error.message ? error.message : root.t("servers.loadFailed", "Could not load servers"); root.items = []; return }
      root.loadError = ""
      root.items = root.buildItems(data || {})
      root._dirty = false
      if (root._cursorToFirst) { root._cursorToFirst = false; root.cursorToFirstItem() }
      if (root.sort === "ping" && root.serverLevel) root.measurePing(seq)
    })
  }

  // Time a TCP connect to the 30 least-loaded usable servers, then list them by ping.
  function measurePing(seq) {
    var names = []
    for (var i = 0; i < items.length && names.length < 30; i++) {
      var it = items[i]
      if (it.kind === "server" && !it.locked && !it.maintenance) names.push(it.name)
    }
    if (names.length === 0) return
    measuring = true
    svc.measureLatency(names, function(ms) {
      if (seq !== root._seq) return
      root.measuring = false
      var keep = cursorModel.active ? cursorModel.currentId : ""
      var out = root.items.map(function(r) {
        var v = ms[r.name]
        if (r.kind !== "server" || typeof v !== "number") return r
        var c = Object.assign({}, r)
        c.ping = v
        c.subtitle = v + " ms" + (r.subtitle ? " · " + r.subtitle : "")
        return c
      })
      out.sort(function(a, b) {
        var pa = a.ping === undefined ? 1e9 : a.ping
        var pb = b.ping === undefined ? 1e9 : b.ping
        return pa - pb
      })
      root.items = out
      if (keep) cursorModel.setId(keep)
    })
  }

  property bool _cursorToFirst: false

  function cursorToFirstItem() {
    for (var i = 0; i < items.length; i++) if (items[i].key) { cursorModel.setId(items[i].key); break }
    Qt.callLater(scrollToCursor)
  }

  function header(text) { return { kind: "header", key: "", name: text } }

  function buildItems(d) {
    var out = []
    var i
    if (d.mode === "search") {
      if ((d.countries || []).length) {
        out.push(header(t("servers.matchingCountries", "Countries")))
        for (i = 0; i < d.countries.length; i++) out.push(decorate(d.countries[i]))
      }
      if ((d.cities || []).length) {
        out.push(header(t("servers.matchingCities", "Cities")))
        for (i = 0; i < d.cities.length; i++) out.push(decorate(d.cities[i]))
      }
      if ((d.servers || []).length) {
        out.push(header(t("servers.matchingServers", "Servers")))
        for (i = 0; i < d.servers.length; i++) out.push(decorate(d.servers[i]))
      }
    } else if (d.mode === "countries") {
      for (i = 0; i < (d.countries || []).length; i++) out.push(decorate(d.countries[i]))
    } else if (d.mode === "country") {
      if (d.countryName) countryName = d.countryName
      var showSc = (d.secureCore || []).length > 0 && (feature === "all" || feature === "secure_core")
      if (showSc) {
        out.push(header(t("servers.viaSecureCore", "Via Secure Core")))
        for (i = 0; i < d.secureCore.length; i++) out.push(decorate(d.secureCore[i]))
      }
      if ((d.cities || []).length) {
        out.push(header(t("servers.cities", "Cities")))
        for (i = 0; i < d.cities.length; i++) out.push(decorate(d.cities[i]))
      }
    } else {
      for (i = 0; i < (d.servers || []).length; i++) out.push(decorate(d.servers[i]))
    }
    return out
  }

  function decorate(row) {
    var r = Object.assign({}, row)
    if (r.kind === "country") {
      r.key = "c:" + r.code
      r.target = { targetType: "country", country: r.code }
      r.favLabel = r.name
      r.favDetail = t("servers.fastestIn", "Fastest server")
      r.subtitle = r.cityCount > 0 ? (tr ? tr.tn("servers.cityCount", r.cityCount, "%1 cities").replace("%1", r.cityCount) : r.cityCount + " cities")
                                   : ""
      r.badge = r.code
      r.drill = true
    } else if (r.kind === "city") {
      r.key = "ct:" + r.country + ":" + r.city
      r.target = r.city ? { targetType: "city", country: r.country, city: r.city } : { targetType: "country", country: r.country }
      r.favLabel = r.city ? r.city + ", " + r.countryName : r.countryName
      r.favDetail = t("servers.fastestIn", "Fastest server")
      r.subtitle = (tr ? tr.tn("servers.serverCount", r.serverCount, "%1 servers") : "%1 servers").replace("%1", r.serverCount)
      r.badge = level === "countries" || query ? r.country : ""
      r.drill = true
    } else if (r.kind === "secure_core") {
      r.key = "sc:" + r.entryCountry + ":" + r.country
      r.target = { targetType: "secure_core", country: r.country, entryCountry: r.entryCountry }
      r.favLabel = r.name
      r.favDetail = t("home.secureCore", "Secure Core")
      r.subtitle = (tr ? tr.tn("servers.serverCount", r.serverCount, "%1 servers") : "%1 servers").replace("%1", r.serverCount)
      r.badge = r.entryCountry
      r.features = ["SC"]
      r.drill = true
    } else {
      r.kind = "server"
      r.key = "s:" + r.name
      r.target = { targetType: "server", serverName: r.name }
      r.favLabel = r.name
      r.favDetail = r.secureCore ? (r.entryName + " → " + r.countryName) : (r.city ? r.city + ", " + r.countryName : r.countryName)
      // Inside a city the city name on every row is noise.
      r.subtitle = r.secureCore ? r.entryName + " → " + r.countryName
                                : (level === "servers" && !query ? "" : (r.city || r.countryName || ""))
      r.badge = query ? r.country : ""
      r.drill = false
    }
    if (r.load === undefined) r.load = r.bestLoad !== undefined ? r.bestLoad : -1
    r.favKey = Model.targetKey(r.target)
    return r
  }

  Timer {
    id: debounce
    interval: 160
    onTriggered: root.reload()
  }

  onShownChanged: if (shown && (_dirty || items.length === 0)) reload()
  onFeatureChanged: reload()
  onSortChanged: reload()

  Connections {
    target: root.svc
    function onServersUpdatedAtChanged() { root._dirty = true; if (root.shown) root.reload() }
    function onTierChanged() { root._dirty = true; if (root.shown) root.reload() }
    function onLoggedInChanged() { root._dirty = true; if (root.shown) root.reload() }
  }

  // --------------------------------------------------------- navigation

  function drillInto(item) {
    if (!item || !item.drill) return false
    if (item.kind === "country") {
      clearQueryQuiet()
      level = "country"; countryCode = item.code; countryName = item.name; city = ""
    } else if (item.kind === "city") {
      clearQueryQuiet()
      level = "servers"; countryCode = item.country; countryName = item.countryName; city = item.city
    } else if (item.kind === "secure_core") {
      clearQueryQuiet()
      level = "sc"; countryCode = item.country; countryName = item.countryName
      entryCountry = item.entryCountry; entryName = item.entryName
    }
    cursorModel.reset()
    list.positionViewAtBeginning()
    reload()
    return true
  }

  function goUp() {
    if (level === "servers" || level === "sc") {
      var back = level === "servers" ? "ct:" + countryCode + ":" + city : "sc:" + entryCountry + ":" + countryCode
      level = "country"
      _restoreKey = back
    } else if (level === "country") {
      _restoreKey = "c:" + countryCode
      level = "countries"
    } else return false
    reload()
    return true
  }

  property string _restoreKey: ""
  onItemsChanged: {
    if (_restoreKey !== "") {
      var k = _restoreKey
      _restoreKey = ""
      if (cursorModel.setId(k)) Qt.callLater(scrollToCursor)
    }
  }

  function clearQueryQuiet() {
    if (query === "") return
    query = ""
    searchField.text = ""
  }

  function clearSearch() {
    if (query === "" && searchField.text === "") return false
    searchField.text = ""
    query = ""
    debounce.stop()
    reload()
    return true
  }

  function focusSearch() {
    searchField.forceActiveFocus()
  }

  function resetView() {
    searchField.text = ""
    query = ""
    level = "countries"
    countryCode = ""; city = ""; entryCountry = ""
    cursorModel.reset()
    _dirty = true
  }

  // ------------------------------------------------------------- cursor

  readonly property var filterOptions: {
    var opts = [
      { key: "all", label: t("servers.all", "All") },
      { key: "secure_core", label: "SC", tip: t("home.secureCore", "Secure Core") },
      { key: "p2p", label: "P2P" },
      { key: "tor", label: "Tor" },
      { key: "streaming", label: t("servers.streaming", "Stream") }
    ]
    if (svc && svc.freeTier) opts.push({ key: "free", label: t("servers.free", "Free") })
    return opts
  }

  function sortLabel(s) {
    if (s === "fastest") return t("servers.sortFastest", "Fastest")
    if (s === "load") return t("servers.sortLoad", "Load")
    if (s === "ping") return t("servers.sortPing", "Ping")
    return t("servers.sortAlpha", "A–Z")
  }

  readonly property bool atRoot: query !== "" || level === "countries"

  readonly property var keyIndex: {
    var m = {}
    for (var i = 0; i < items.length; i++) if (items[i].key) m[items[i].key] = i
    return m
  }

  function buildRows() {
    var rows = [["search"]]
    var filters = []
    for (var i = 0; i < filterOptions.length; i++) filters.push("f:" + filterOptions[i].key)
    filters.push("sort")
    rows.push(filters)
    if (!atRoot) {
      var crumb = ["back", "connectHere"]
      if (level !== "sc") crumb.push("favHere")
      rows.push(crumb)
    }
    if (items.length === 0 && query !== "" && !loading) rows.push(["clear"])
    for (var j = 0; j < items.length; j++) if (items[j].key) rows.push([items[j].key])
    return rows
  }

  CursorModel {
    id: cursorModel
    rows: root.buildRows()
    onMoved: Qt.callLater(root.scrollToCursor)
  }

  function scrollToCursor() {
    var idx = keyIndex[cursorModel.currentId]
    if (idx !== undefined) list.positionViewAtIndex(idx, ListView.Contain)
    else if (cursorModel.row <= 2) list.positionViewAtBeginning()
  }

  function currentItem() {
    var idx = keyIndex[cursorModel.currentId]
    return idx !== undefined ? items[idx] : null
  }

  function moveCursor(dx, dy) {
    if (dy < 0 && cursorModel.active && cursorModel.currentId === "search") return false
    var item = currentItem()
    if (dx !== 0 && item) {
      if (dx > 0) {
        if (!drillInto(item)) return false
        _cursorToFirst = true  // keyboard drill: keep a visible cursor on the new level
        return true
      }
      return goUp()
    }
    if (dx < 0 && cursorModel.active && cursorModel.col === 0 && !atRoot) return goUp()
    return cursorModel.move(dx, dy)
  }

  function activate() {
    if (!cursorModel.active) return false
    activateKey(cursorModel.currentId)
    return true
  }

  function back() {
    if (clearSearch()) return true
    return goUp()
  }

  function textKey(text) {
    if (text === "f" || text === "F") { toggleFavorite(currentItem()); return true }
    return false
  }

  function toggleFavorite(item) {
    if (!item || !svc) return
    svc.toggleFavorite(item.favLabel, item.target, item.favDetail)
  }

  function hereTarget() {
    if (level === "servers") return city ? { targetType: "city", country: countryCode, city: city } : { targetType: "country", country: countryCode }
    if (level === "sc") return { targetType: "secure_core", country: countryCode, entryCountry: entryCountry }
    return { targetType: "country", country: countryCode }
  }

  function hereLabel() {
    if (level === "servers" && city) return city + ", " + countryName
    if (level === "sc") return entryName + " → " + countryName
    return countryName
  }

  function connectItem(item) {
    if (!item || !svc) return
    if (item.locked) { svc.offerUpgrade(); return }
    if (item.maintenance) { svc.showToast(t("servers.maintenance", "Under maintenance")); return }
    svc.connectTarget(item.target, item.favLabel)
  }

  function activateKey(key) {
    if (key === "search") { focusSearch(); return }
    if (key.indexOf("f:") === 0) { feature = key.substring(2); return }
    if (key === "sort") {
      var order = serverLevel ? ["alpha", "fastest", "load", "ping"] : ["alpha", "fastest", "load"]
      var at = order.indexOf(effectiveSort)
      sort = order[(at + 1) % order.length]
      return
    }
    if (key === "back") { goUp(); return }
    if (key === "clear") { clearSearch(); return }
    if (key === "connectHere") { svc.connectTarget(hereTarget(), hereLabel()); return }
    if (key === "favHere") { svc.toggleFavorite(hereLabel(), hereTarget(), t("servers.fastestIn", "Fastest server")); return }
    var item = currentItemFor(key)
    if (!item) return
    if (item.kind === "server") connectItem(item)
    else if (drillInto(item)) _cursorToFirst = true
  }

  function currentItemFor(key) {
    var idx = keyIndex[key]
    return idx !== undefined ? items[idx] : null
  }

  readonly property var favKeys: svc ? Model.favoriteKeys(svc.favorites) : ({})
  readonly property string currentServer: svc && svc.server && svc.connectionState !== "disconnected" ? String(svc.server.name || "") : ""

  // ------------------------------------------------------------- layout

  ColumnLayout {
    anchors.fill: parent
    spacing: Style.space(8)

    // Search ------------------------------------------------------------
    CursorSurface {
      Layout.fillWidth: true
      implicitHeight: searchField.implicitHeight
      hasCursor: cursorModel.has("search") && !searchField.activeFocus
      foreground: root.theme.text
      radius: Style.cornerRadius

      TextField {
        id: searchField
        anchors.fill: parent
        foreground: root.theme.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        leftPadding: Style.space(30)
        placeholderText: root.t("servers.searchPlaceholder", "Search countries, cities, servers")
        onTextChanged: {
          var q = text.trim().substring(0, 96)
          if (q === root.query) return
          root.query = q
          cursorModel.reset()
          debounce.restart()
        }
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (text !== "") root.clearSearch()
            else root.releaseFocus()
            event.accepted = true
          } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.releaseFocus()
            if (debounce.running || root.loading) {
              // Results for the typed text are not in yet: land on them once they are.
              debounce.stop()
              root._cursorToFirst = true
              root.reload()
            } else if (root.items.length > 0) {
              root.cursorToFirstItem()
            }
            event.accepted = true
          } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            root.releaseFocus()
            event.accepted = true
          }
        }
      }

      PlainText {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: "󰍉"
        color: root.theme.dim
        font.pixelSize: Style.font.iconSmall
      }
    }

    // Filters -----------------------------------------------------------
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(6)

      Repeater {
        model: root.filterOptions
        Chip {
          required property var modelData
          Layout.fillWidth: true
          Layout.minimumWidth: Style.space(36)
          cursorKey: "f:" + modelData.key
          theme: root.theme
          text: modelData.label
          tooltipText: modelData.tip || ""
          selected: root.feature === modelData.key
          locked: modelData.key !== "all" && modelData.key !== "free" && root.svc && root.svc.freeTier
          hasCursor: cursorModel.has(cursorKey)
          onHovered: cursorModel.setId(cursorKey)
          onClicked: root.activateKey(cursorKey)
        }
      }

      Chip {
        cursorKey: "sort"
        theme: root.theme
        iconText: "󰒺"
        text: root.measuring ? root.t("servers.measuring", "Pinging…") : root.sortLabel(root.effectiveSort)
        tooltipText: root.serverLevel ? root.t("servers.sortTipPing", "Change sort order. Ping times a connection to each server; while connected it is measured through the VPN")
                                      : root.t("servers.sortTip", "Change sort order")
        hasCursor: cursorModel.has("sort")
        onHovered: cursorModel.setId("sort")
        onClicked: root.activateKey("sort")
      }
    }

    // Breadcrumb --------------------------------------------------------
    RowLayout {
      visible: !root.atRoot
      Layout.fillWidth: true
      spacing: Style.space(6)

      Chip {
        Layout.fillWidth: true
        Layout.minimumWidth: Style.space(80)
        cursorKey: "back"
        theme: root.theme
        iconText: Commons.I18n.rightToLeft ? "󰁔" : "󰁍"
        text: {
          if (root.level === "country") return root.countryName
          if (root.level === "sc") return root.countryName + " / " + root.t("home.secureCore", "Secure Core")
          return root.countryName + (root.city ? " / " + root.city : "")
        }
        hasCursor: cursorModel.has("back")
        onHovered: cursorModel.setId("back")
        onClicked: root.activateKey("back")
      }
      Chip {
        cursorKey: "connectHere"
        theme: root.theme
        primary: true
        iconText: "󱐋"
        text: root.t("servers.fastest", "Fastest")
        tooltipText: root.t("servers.connectFastestHere", "Connect to the fastest server here")
        hasCursor: cursorModel.has("connectHere")
        onHovered: cursorModel.setId("connectHere")
        onClicked: root.activateKey("connectHere")
      }
      Chip {
        visible: root.level !== "sc"
        cursorKey: "favHere"
        theme: root.theme
        readonly property bool isFav: root.favKeys[Model.targetKey(root.hereTarget())] !== undefined
        iconText: isFav ? "󰓎" : "󰓒"
        text: ""
        selected: isFav
        tooltipText: root.t("servers.favorite", "Favorite")
        hasCursor: cursorModel.has("favHere")
        onHovered: cursorModel.setId("favHere")
        onClicked: root.activateKey("favHere")
      }
    }

    PanelSeparator { Layout.fillWidth: true }

    // List --------------------------------------------------------------
    Item {
      Layout.fillWidth: true
      Layout.fillHeight: true

      ListView {
        id: list
        anchors.fill: parent
        clip: true
        model: root.items
        reuseItems: true
        boundsBehavior: Flickable.StopAtBounds
        spacing: Style.space(2)
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        delegate: Item {
          id: del
          required property var modelData
          required property int index
          width: ListView.view.width
          height: modelData.kind === "header" ? hdr.implicitHeight + Style.space(6) : row.implicitHeight

          PanelSectionHeader {
            id: hdr
            visible: del.modelData.kind === "header"
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(2)
            text: del.modelData.kind === "header" ? del.modelData.name : ""
            foreground: root.theme.text
          }

          ServerRow {
            id: row
            visible: del.modelData.kind !== "header"
            width: parent.width
            theme: root.theme
            cursorKey: del.modelData.key || ""
            badgeText: del.modelData.badge || ""
            title: String(del.modelData.name || "")
            subtitle: String(del.modelData.subtitle || "")
            load: del.modelData.load !== undefined && del.modelData.load !== null ? del.modelData.load : -1
            features: del.modelData.features || []
            locked: del.modelData.locked === true
            maintenance: del.modelData.maintenance === true
            showDrill: del.modelData.drill === true
            showFavorite: true
            favorite: root.favKeys[del.modelData.favKey] !== undefined
            isCurrent: del.modelData.kind === "server" && del.modelData.name === root.currentServer
            connecting: root.svc && root.svc.busy
            connectTooltip: root.t("home.connect", "Connect")
            hasCursor: cursorModel.has(cursorKey)
            onHovered: cursorModel.setId(cursorKey)
            onActivated: root.activateKey(cursorKey)
            onConnectClicked: root.connectItem(del.modelData)
            onDrillClicked: root.drillInto(del.modelData)
            onFavoriteClicked: root.toggleFavorite(del.modelData)
          }
        }
      }

      // Loading / empty / error states, centered in the list area.
      Column {
        anchors.centerIn: parent
        width: parent.width - Style.space(40)
        spacing: Style.space(10)
        visible: root.items.length === 0

        PlainText {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          color: root.loadError !== "" ? root.theme.danger : root.theme.dim
          font.pixelSize: Style.font.bodySmall
          text: {
            if (!root.svc || !root.svc.loggedIn) return root.t("servers.signInFirst", "Sign in to browse servers")
            if (root.loading) return root.t("servers.loading", "Loading servers…")
            if (root.loadError !== "") return root.loadError
            if (root.query !== "") return root.t("servers.noMatch", "No servers match “%1”").replace("%1", root.query)
            return root.t("servers.empty", "No servers for this filter")
          }
        }

        Chip {
          visible: root.query !== "" && !root.loading
          anchors.horizontalCenter: parent.horizontalCenter
          cursorKey: "clear"
          theme: root.theme
          text: root.t("servers.clear", "Clear search")
          hasCursor: cursorModel.has("clear")
          onHovered: cursorModel.setId("clear")
          onClicked: root.activateKey("clear")
        }
      }
    }
  }
}
