# Protonarchy — Omarchy Proton VPN Bar Plugin Plan

> **Plugin Name:** Protonarchy · **Plugin ID:** `pl0xuee.proton-for-omarchy` · **Author:** `pl0xuee`
> **Repository:** `https://github.com/pl0xuee/proton-for-omarchy`
> **Install (once published):** `omarchy plugin add https://github.com/pl0xuee/proton-for-omarchy.git --enable`
> **Target environment verified on host:** Omarchy `4.5.0-3` (Quickshell `omarchy-shell`), Python `3.14`, `python-proton-vpn-api-core 5.8.7-1`, `proton-vpn-cli 1.0.5-1`, `proton-vpn-daemon 0.13.8-1` (`me.proton.vpn.split_tunneling` D-Bus service enabled), `python-proton-keyring-linux 0.2.3-1`, `NetworkManager` enabled, `wl-copy`.

---

## 1. Goals & Design Principles

Build a **feature-complete, native Omarchy shell bar plugin** for Proton VPN anchored on the **top-right bar** (`barWidget.defaultSection: "right"`).

1. **Fast & Responsive**: Never cold-spawn `protonvpn` CLI per click or poll (~400–800 ms overhead each, plus CLI lacks server lists, split tunneling, and live events). Instead, run a **single persistent Python NDJSON bridge** (`backend/bridge.py`) directly on top of `python-proton-vpn-api-core` (`ProtonVPNAPI` + `VPNConnector` + Local Agent + NetworkManager + `proton-vpn-daemon` D-Bus).
   - **0 ms perceived interaction latency** via optimistic state (`_desired`) and instant in-RAM server search (< 2 ms).
   - **Event-driven updates** via `VPNStateSubscriber` + `NM.Client` signals — zero background polling when the panel is closed.
   - **Lazy QML content** via `KeyboardPanel.content` and virtualized `ListView` with change-signature guards (never rebuild thousands of server rows).
2. **Secure by Design**:
   - Private anonymous stdin/stdout NDJSON pipe between `omarchy-shell` and `bridge.py` (no listening TCP ports, no world-readable sockets, no secrets in argv/`ps`, no plaintext password files).
   - Authentication delegates exclusively to Proton's SRP/2FA/FIDO2 API and OS Secret Service keyring (`python-proton-keyring-linux`).
   - Strict adherence to Omarchy's **Plugin UI Safety** rules: every `Text` uses `Text.PlainText`, dynamic strings passed to shared tooltip/notification sinks are markup-sanitized, zero shell interpolation, bounded payloads, zero third-party IP-lookup HTTP calls (exit IP comes directly from Proton's authenticated Local Agent).
3. **Native Omarchy Look & Effortless Navigation**:
   - Built strictly on Omarchy's `qs.Ui` and `qs.Commons` kit (`Panel`, `BarIconButton`, `KeyboardPanel`, `PanelKeyCatcher`, `PanelHero`, `ToggleSwitch`, `ButtonGroup`, `Dropdown`, `FilterInput`, `PanelSectionHeader`, `PanelSeparator`, `PanelActionButton`, `CursorSurface`, `BorderSurface`, `ConfirmDialog`).
   - Live-reactive to every Omarchy theme (`Commons.Color`, `Style.cornerRadius`, `Style.font.*`, `Style.space()`, `Style.duration()`, `Style.easeOut`) and all 50 Omarchy languages (`Commons.Translations` + `i18n/en.json` + RTL mirroring).
   - Full mouse + keyboard navigation (`j/k`/arrows, `h/l`, `1-4` tabs, `/` instant search, `t` toggle, `c` copy IP, `p` copy port, `f` favorite, `r` refresh, `Tab` morph to adjacent bar panels, `Esc` back/close).

---

## 2. Verified Platform Architecture & Constraints

### 2.1 Omarchy 4.5 Plugin Contract (verified via `PluginRegistry.qml` & `omarchy-plugin-validate`)
- **Install directory**: `~/.config/omarchy/plugins/pl0xuee.proton-for-omarchy/` (installed via `omarchy plugin add https://github.com/pl0xuee/proton-for-omarchy.git --enable` or copied during dev; hot-reloads automatically on file save, or force via `omarchy-shell shell rescanPlugins`).
- **Plugin ID**: `pl0xuee.proton-for-omarchy`
  - Must match `^[A-Za-z0-9][A-Za-z0-9._-]*$`, no `..`, and **must NOT start with `omarchy.`** (reserved namespace rejected by `omarchy-plugin-validate`).
- **Manifest rules**:
  - `schemaVersion` must be numeric `1`.
  - Required keys: `id`, `name`, `version`, `kinds`, `entryPoints`.
  - `kinds: ["service", "bar-widget"]`, `keepLoaded: true`, `entryPoints: { "service": "Service.qml", "barWidget": "Panel.qml" }` (mirrors Omarchy's `omarchy.media` dual-kind architecture so multi-monitor setups share **one** `Service.qml` and **one** `bridge.py` process!).
  - `barWidget.defaultSection: "right"` places it automatically in the top-right bar section.
  - **No symlinks anywhere** inside the plugin folder (except `.git` internals). `omarchy plugin validate <dir>` enforces this strictly.
- **IPC Target**: `ShellIpc` with `target: "pl0xuee.proton-for-omarchy"` (with `manageIpc: false` on the `qs.Ui.Panel` root so `Panel.qml` owns the extended IPC surface cleanly without duplicate handlers) exposes shell-level commands for Hyprland keybindings and scripting (`omarchy-shell pl0xuee.proton-for-omarchy toggle`, `open`, `close`, `show`, `hide`, `toggleConnection`, `connectFastest`, `connectCountry <CC>`, `disconnect`, `status`, `refresh`).
- **Third-Party Shell API & Custom/Cloned Bar Compatibility (verified in `Bar.qml`, `PluginBarApi.qml` & `PluginShellApi.qml`)**:
  - Third-party bar widgets receive `bar` (with `foreground`, `barForeground`, `background`, `urgent`, `fontFamily`, `position`, `vertical`, `barSize`, `foregroundAnimationEnabled`, `showTooltip`, `hideTooltip`, `requestPopout`, `releasePopout`, `switchPanelFrom`) and `bar.shell.updateEntryInline(root.moduleName, entry)` scoped strictly to their own plugin ID.
  - **Shared service lookup with safe fallback**: On stock `omarchy.bar` and cloned bars (like `pl0xuee.bar` cloned from `omarchy.bar`), `bar?.shell?.serviceFor("pl0xuee.proton-for-omarchy")` returns the single shell-mounted `Service.qml` instance shared across every monitor. On non-cloned third-party replacement bars that withhold `serviceFor`, `Panel.qml` falls back seamlessly to a lazy inline `Loader` instantiating `Service.qml` so the widget works everywhere.

### 2.2 Omarchy-Native UI & Interaction Idioms (Non-Negotiable)
Follow the exact patterns verified in `/usr/share/omarchy/shell/Ui/` and `/usr/share/omarchy/shell/plugins/panels/{tailscale,network,dropbox}/` so Protonarchy feels indistinguishable from a first-party Omarchy widget:
1. **`BarIconButton` contract** (`WidgetButton.qml` / `BarIconButton.qml`):
   - Bind `tooltipText: Model.sanitizeText(...)`, `labelText: ...`, `iconComponent: ...`, and handle `onPressed: function(buttonCode)`.
   - **Never** stack a competing `MouseArea` over `BarIconButton` — `WidgetButton` already manages click-target registration (`registerClickTarget`/`unregisterClickTarget` required for `KeyboardPanel` one-click bar handoff), press scale (`0.9`), drag-to-reorder on the bar, and hover tooltip lifecycle (`bar.showTooltip`/`hideTooltip`).
   - Guard bar icon/label color animations with `enabled: !root.bar || root.bar.foregroundAnimationEnabled`.
2. **`CursorSurface` + `PointerMoveGate` single-highlight contract**:
   - Every navigable row MUST render inside `qs.Ui.CursorSurface` driven strictly by `hasCursor` and `current` from the panel's central cursor state — **never** bind row colors/borders to `MouseArea.containsMouse` directly.
   - Route row hover (`onPositionChanged`) through `qs.Ui.PointerMoveGate` (`pointerGate.moved(row, mouse)`) and call `pointerGate.reset()` on keyboard movement or list updates so scrolling a `ListView` with `j`/`k` never lets a stationary mouse pointer steal the cursor.
3. **`PanelKeyCatcher` + `ConfirmDialog` + `Dropdown` input priority**:
   - `PanelKeyCatcher` uses `Keys.priority: Keys.BeforeItem`. Set `blocked: confirmDialog.opened || anyDropdownOpen || anyTextFieldFocused` so inline editors, dropdown popups, and confirm dialogs receive keys cleanly.
   - Forward keys to `confirmDialog.handleKey(event)` whenever `confirmDialog.opened` is true.
   - Let `PanelKeyCatcher` handle RTL `h`/`l`/`Left`/`Right` mirroring natively (do not double-flip `dx` in `onMoveRequested`).
4. **Translations & locale formatting (`Commons.Translations`)**:
   - Ship `i18n/en.json` and read every plugin-owned UI string through `Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }` inside live QML bindings (so `Setup > Language` switches re-render live without restart).
   - **Never** use `Commons.I18n.t(...)` for plugin strings (Omarchy's internal catalog can rename keys on update). Use `Commons.I18n.formatNumber(val, decimals)` for displayed numbers (load %, speeds, device counts) and `Qt.locale(Commons.I18n.formatLocale)` for dates/times; keep IPC `status()` output and diagnostic logs in English (`// i18n: ignore`).
5. **Bar lifecycle & settings persistence**:
   - Bind reactively to `settings`, `bar.position`, `bar.vertical`, and `fixedEdge` (a widget moved between bar sections or screen edges keeps running and updates in place).
   - Persist bar widget preferences (`showCountryCode`, `connectedIconTint`, `showNotifications`, `bandwidthPolling`, `autoRefreshServers`) via `bar.shell.updateEntryInline(root.moduleName, entry)` (preserving all existing keys on `settings`).
   - Support Omarchy's full CLI workflow out of the box: `omarchy plugin validate`, `omarchy plugin add`, `omarchy plugin enable/disable/update/remove`, `omarchy bar move`, `omarchy bar set`, drag-to-reorder on the bar, and `omarchy-shell shell rescanPlugins`.
- **Reference Omarchy plugins to mirror**:
  - `/usr/share/omarchy/shell/plugins/panels/tailscale/` (`Panel.qml`, `Service.qml`, `Model.js`, `TailscaleIcon.qml`, `manifest.json`)
  - `/usr/share/omarchy/shell/plugins/panels/dropbox/` (`Service.qml`, `status.py`)
  - `/usr/share/omarchy/shell/plugins/panels/network/` (`Panel.qml`, `Model.js`)

### 2.3 Proton VPN Linux Stack (verified in `/usr/lib/python3.14/site-packages/proton/vpn/`)
- **Core API facade**: `proton.vpn.core.api.ProtonVPNAPI(ClientTypeMetadata(type="gui"))`
  - Manages `SessionHolder` (keyring-backed login/logout, SRP, TOTP 2FA, FIDO2/U2F hardware keys via `generate_2fa_fido2_assertion` / `submit_2fa_fido2`), `SettingsPersistence`, `VPNDataRefresher` (auto-refreshes server list every ~3 h, loads every ~15 min, certificates before expiry), and `VPNConnector`.
- **Connection state machine**: `VPNConnector` (`proton.vpn.core.vpnconnector`)
  - `connector.register(subscriber)` delivers real-time `states.State` objects (`Disconnected`, `Connecting`, `Connected`, `Disconnecting`, `Error`).
  - `Connected` events from `LocalAgentMixin` carry:
    - `event.context.connection_details` (`device_ip`, `device_country`, `server_ipv4`, `server_ipv6`)
    - `event.context.forwarded_port` (live NAT-PMP/Local-Agent forwarded port on P2P servers!)
  - `PortForwardFileHandler` automatically writes the active forwarded port to `$XDG_RUNTIME_DIR/Proton/VPN/forwarded_port`.
  - `Error` events distinguish: `TwoFARequired` (enterprise hardware key re-auth while hard-jailed), `MaximumSessionsReached`, `ExpiredCertificate`, `NotYetValidCertificate`, `AuthDenied`, `Timeout`, `DeviceDisconnected`, `TunnelSetupFailed`, `UnexpectedError`.
  - **GLib / Asyncio interop**: `NMClient` (`proton.vpn.backend.networkmanager.core.nmclient`) runs its own dedicated daemon thread with a `GLib.MainLoop` and bridges callbacks via `concurrent.futures.Future` — so `bridge.py` runs cleanly on standard `asyncio.run(...)`!
- **Protocols** (dynamically discovered via `ProtonVPNAPI.create_registry().iter(VPNConnection)`):
  - `wireguard` ("WireGuard" — kernel WireGuard on `proton0`, lowest latency, full Local Agent live feature updates)
  - `openvpn-udp` ("OpenVPN (UDP)") / `openvpn-tcp` ("OpenVPN (TCP)")
  - `protun-smart` ("Smart"), `protun-udp` ("WireGuard UDP"), `protun-tcp` ("WireGuard TCP"), `protun-tls` ("Stealth") — surfaced only when validated available by the registry on the host.
- **Settings & Live vs. Reconnect Semantics** (`proton.vpn.core.settings.Settings`):
  - **Live-applied on active connection (Paid tier, via Local Agent + `api.save_settings`)**:
    - `features.netshield`: `0` (`NO_BLOCK`), `1` (`BLOCK_MALICIOUS_URL`), `2` (`BLOCK_ADS_AND_TRACKING`)
    - `features.vpn_accelerator`: `bool`
    - `features.moderate_nat`: `bool`
    - `features.port_forwarding`: `bool` (active on P2P servers)
    - `features.split_tunneling`: `SplitTunneling(enabled, mode=EXCLUDE|INCLUDE, config_by_mode={exclude/include: SplitTunnelingConfig(app_paths, ip_ranges)})` via `me.proton.vpn.split_tunneling` D-Bus (`proton.VPN.service`)
  - **Requires reconnect to take effect**:
    - `protocol` (`str`)
    - `ipv6` (`bool`)
    - `custom_dns` (`CustomDNS(enabled, ip_list=[CustomDNSEntry])`)
  - **Kill Switch (`KillSwitchState`) & Critical Constraints**:
    - `0` = `OFF`, `1` = `ON` (Standard — blocks internet on unexpected drop while connected; restores on intentional disconnect), `2` = `PERMANENT` (Always-On — blocks internet even when disconnected/after reboot until disabled).
    - **Constraint 1 (Mutual Exclusion)**: `VPNConnector._apply_split_tunneling_settings` rejects Split Tunneling whenever `killswitch != OFF`. UI must clearly surface this and offer an explicit confirmation dialog to disable one when enabling the other.
    - **Constraint 2 (Protocol Switch / Kill Switch Backend)**: `VPNConnector._set_ks_impl` uses different NetworkManager kill switch backends for WireGuard vs OpenVPN and requires disconnecting before switching protocol or changing kill switch mode when active (if `connector.is_connection_active` and changing kill switch, prompt to disconnect-and-apply or offer a 1-click "Disconnect & Apply" button).
    - **Constraint 3 (Free Tier)**: `user_tier == 0` allows Quick Connect (auto-selected free server), Kill Switch, IPv6, Protocol, Anonymous Crash Reports; blocks specific country/city/server/random selection, Secure Core, P2P, Tor, NetShield, Port Forwarding, Split Tunneling, Moderate NAT, VPN Accelerator, Custom DNS. UI must display tier badges and disable locked controls cleanly rather than throwing raw API errors.
- **Server List & Grouping** (`proton.vpn.session.servers.logicals.ServerList`):
  - `LogicalServer` exposes: `id`, `name` (`US-NY#12`), `entry_country`, `exit_country`, `entry_country_name`, `exit_country_name`, `city`, `location` (state/city), `load` (0–100), `score` (lower = faster), `enabled`/`under_maintenance`, `tier` (`0`=Free, `2`=Plus, `3`=PM), `smart_routing` (`host_country is not None`), `features` (`ServerFeatureEnum`: `SECURE_CORE`, `TOR`, `P2P`, `STREAMING`, `IPV6`).
  - `ServerList.group_by_country(group_by_city=True)` produces `Country` objects with `locations` (cities) and `secure_core_group` (multi-hop entry→exit routes).

---

## 3. Repository & Plugin File Layout

Keep the repository root directly validatable by `omarchy plugin validate .` and directly installable via `omarchy plugin add <repo> --enable` (no nested subdirectory needed, no symlinks).

```text
.
├── manifest.json                   # Omarchy schemaVersion 1 manifest (id: "pl0xuee.proton-for-omarchy", defaultSection: "right")
├── README.md                       # Install, keybindings, IPC commands, troubleshooting
├── PLAN.md                         # This implementation blueprint
├── Panel.qml                       # BarWidget root (extends qs.Ui.Panel): BarIconButton, ShellIpc, KeyboardPanel
├── Service.qml                     # Owns persistent bridge.py Process, optimistic state, timers, profiles, clipboard
├── Model.js                        # Pure JS helpers: sanitization, formatting, load colors, filtering, sorting, validation
├── ProtonVpnIcon.qml               # Native QML vector Proton VPN shield mark (all states, crisp at 12px–48px)
├── components/
│   ├── PlainText.qml               # Enforces textFormat: Text.PlainText everywhere (Plugin UI Safety)
│   ├── ThemePalette.qml            # Watches ~/.local/state/omarchy/current/theme/colors.toml for optional color2/color3 semantic tokens + light/dark luminance helper
│   ├── TabBar.qml                  # 4-tab keyboard+mouse switcher (Home, Servers, Settings, Account)
│   ├── HomeView.qml                # Hero, active connection telemetry card, quick-toggle pills, favorites & recents
│   ├── ServersView.qml             # Search FilterInput, feature chips, virtualized Country/City/Server drill-down
│   ├── SettingsView.qml            # Protocol, Kill Switch, NetShield, Port Forwarding, Split Tunneling, DNS, Privacy
│   ├── SplitTunnelingSheet.qml     # Sub-view/drawer inside Settings for App picker (.desktop) & IP/CIDR rules
│   ├── CustomDnsSheet.qml          # Sub-view/drawer inside Settings for Custom DNS IPv4/IPv6 list management
│   ├── AccountView.qml             # Account info / inline secure Sign In (SRP + TOTP + FIDO2) / diagnostics
│   ├── ServerRow.qml               # Reusable virtualized row for Country, City, Secure Core hop, and Server
│   ├── LoadIndicator.qml           # Compact load bar/dot (theme color2 <50%, color3 50-84%, urgent >=85%)
│   └── FeatureBadge.qml            # Compact pill for SC, P2P, TOR, STR, IPv6, FREE, SR (Smart Routing)
├── backend/
│   ├── bridge.py                   # Entry point: asyncio NDJSON stdio loop, single-process controller
│   ├── proton_client.py            # Wraps ProtonVPNAPI, VPNConnector, VPNDataRefresher, Local Agent, Auth/2FA/FIDO2
│   ├── server_index.py             # Fast in-memory server tree, filtering, search, country/city projection
│   ├── telemetry.py                # Reads /sys/class/net/<iface>/statistics/{rx,tx}_bytes + NM active iface detection
│   ├── split_tunnel.py             # Desktop app discovery (/usr/share/applications -> resolved binary path) + CIDR validation
│   ├── profiles.py                 # Atomic 0600 JSON persistence for Favorites, Recents, Custom Profiles (~/.config/omarchy/protonarchy-state.json)
│   └── protocol.py                 # NDJSON schema validation, payload bounds, error serialization, log scrubbing
├── i18n/
│   └── en.json                     # Complete English translation catalog (CLDR plurals, %1 args)
├── scripts/
│   ├── install-local.sh            # Copies runtime files to ~/.config/omarchy/plugins/pl0xuee.proton-for-omarchy (no symlinks), validates, enables
│   └── verify.sh                   # Runs omarchy plugin validate, Python unit tests, QML syntax/safety lint
└── tests/
    ├── test_protocol.py            # NDJSON bounds, malformed input, secret-scrubbing tests
    ├── test_server_index.py        # Filtering, Secure Core hops, tier rules, search ranking, performance (<5ms on 5k servers)
    ├── test_split_tunnel.py        # App binary resolution, CIDR validation, KS mutual exclusion
    ├── test_profiles.py            # Atomic 0600 file writes, corruption recovery, max limits
    ├── test_model.mjs              # Node/qmljs unit tests for Model.js (markup sanitization, formatting, state reducers)
    └── test_qml_safety.sh          # Static audit: verifies zero AutoText/RichText sinks, zero shell interpolation, zero bare Animation durations
```

---

## 4. Manifest & Bar Placement Specification

`manifest.json`:
```json
{
  "schemaVersion": 1,
  "id": "pl0xuee.proton-for-omarchy",
  "name": "Protonarchy",
  "version": "1.0.0",
  "author": "pl0xuee",
  "license": "GPL-3.0-or-later",
  "homepage": "https://github.com/pl0xuee/proton-for-omarchy",
  "description": "Fast, secure, feature-complete Proton VPN control panel for the Omarchy bar.",
  "kinds": [
    "service",
    "bar-widget"
  ],
  "keepLoaded": true,
  "entryPoints": {
    "service": "Service.qml",
    "barWidget": "Panel.qml"
  },
  "barWidget": {
    "displayName": "Protonarchy",
    "description": "Proton VPN: quick connect, server browser, Secure Core, NetShield, Kill Switch, Port Forwarding, and Split Tunneling.",
    "category": "Network",
    "allowMultiple": false,
    "defaultSection": "right",
    "defaults": {
      "showCountryCode": true,
      "connectedIconTint": "accent",
      "showNotifications": true,
      "bandwidthPolling": true,
      "autoRefreshServers": true,
      "autoConnectProfile": ""
    },
    "schema": [
      {
        "key": "showCountryCode",
        "type": "boolean",
        "label": "Show country code beside bar icon when connected",
        "defaultValue": true
      },
      {
        "key": "connectedIconTint",
        "type": "enum",
        "label": "Connected icon color role (follows active theme)",
        "options": ["accent", "foreground", "semantic"],
        "defaultValue": "accent"
      },
      {
        "key": "showNotifications",
        "type": "boolean",
        "label": "Show desktop notifications on connect, disconnect, and errors",
        "defaultValue": true
      },
      {
        "key": "bandwidthPolling",
        "type": "boolean",
        "label": "Show live traffic speed while panel is open",
        "defaultValue": true
      },
      {
        "key": "autoRefreshServers",
        "type": "boolean",
        "label": "Automatically refresh server loads in the background",
        "defaultValue": true
      }
    ]
  }
}
```

### Bar Icon & Interactions (`BarIconButton` + `ProtonVpnIcon.qml`)
- **Placement**: Top-right bar (`right` section, next to `omarchy.network` / `omarchy.bluetooth`). Works identically on `top`, `bottom`, `left`, and `right` bar orientations (hides `labelText` country code when `bar.vertical === true`).
- **Native Vector Icon (`ProtonVpnIcon.qml`)**: Drawn directly in QML using `QtQuick.Shapes` (`Shape` + `ShapePath`) or crisp geometric primitives at `button.iconSize` (default 12–16 px) so it scales cleanly with zero SVG blur:
  - **Connected**: Full `barForeground` color; optional `labelText: vpn.exitCountryCode` (e.g. `CH`) when `showCountryCode && !bar.vertical`.
  - **Connected (Secure Core)**: Subtle secondary accent shield dot / inner ring.
  - **Connecting / Disconnecting**: Smooth opacity pulse (`0.45 ↔ 1.0`, `Style.duration(750)`, disabled cleanly when animations are off).
  - **Disconnected**: Dimmed (`Util.alpha(barForeground, 0.48)`, works cleanly on both dark and light bars) with diagonal slash (matching `omarchy.tailscale`).
  - **Kill Switch Blocking / Error / Auth Needed / 2FA Hard-Jailed**: Corner badge (`BorderSurface`, `Commons.Color.urgent`) with `!` (or lock glyph when Permanent Kill Switch is active while disconnected).
- **Mouse Actions on Bar Icon**:
  - **Left click**: Toggle `KeyboardPanel`.
  - **Right click**: Instant Quick Connect (if disconnected, connects to last/default profile or fastest) / Disconnect (if connected or connecting).
  - **Middle click**: Force refresh connection state & server loads.
  - **Hover Tooltip** (bound directly to `BarIconButton.tooltipText` with `Model.sanitizeText(...)` — `WidgetButton` calls `bar.showTooltip`/`bar.hideTooltip` automatically):
    - Connected: `Protonarchy — Connected\nCH#12 · Zurich, Switzerland (18%)\nIP: 185.159.157.x · WireGuard` (plus `Port: 54321` if active).
    - Disconnected (Permanent KS): `Protonarchy — Disconnected (Permanent Kill Switch active)`.
    - Disconnected: `Protonarchy — Disconnected`.

---

## 5. Backend Bridge Architecture (`backend/bridge.py`)

### 5.1 Process Model & Lifecycle
- `Service.qml` spawns one `Quickshell.Io.Process`:
  - `command: ["python3", "-u", "-s", bridgeScriptPath]` (`-u` unbuffered stdio, `-s` ignores user-site shadowing while keeping Arch's `/usr/lib/python3.14/site-packages`). Resolve `bridgeScriptPath` cleanly from `Qt.resolvedUrl("backend/bridge.py")` stripping the `file://` prefix (matching `Translations.qml`).
  - `stdout: SplitParser { onRead: ... }` parses one JSON event object per line.
  - `stderr: SplitParser { onRead: ... }` logs sanitized diagnostics to `console.warn` (never shown raw to AutoText).
  - `Service.qml` sends NDJSON commands to `bridgeProcess.write(JSON.stringify(req) + "\n")`.
- **Clean Shutdown & Crash Recovery**:
  - `bridge.py` exits immediately when `stdin` reaches EOF (so if `omarchy-shell` reloads plugins or exits, no orphan Python process is ever left behind!).
  - If `bridge.py` crashes unexpectedly, `Service.qml` restarts it with exponential backoff (1 s, 2 s, 4 s, max 30 s, capped after 5 consecutive immediate crashes with a manual "Restart backend" button).
  - On startup, `bridge.py` initializes `ProtonVPNAPI`, attaches `VPNConnector` (detecting any already-active VPN connection persisted from before shell start!), registers `VPNStateSubscriber`, checks `proton.VPN.service` D-Bus availability, loads saved profiles, and emits an initial `snapshot` event.

### 5.2 NDJSON Wire Protocol (`backend/protocol.py`)

Every message is a single UTF-8 JSON object terminated by `\n`. Max incoming line size: 64 KB; max outgoing line size: 2 MB (capped server page payloads).

#### Requests (`Service.qml` → `bridge.py`)
Each request carries `{ "id": "<uuid-or-seq>", "cmd": "<name>", "params": { ... } }`:

| Command | Params | Behavior |
|---|---|---|
| `get_snapshot` | `{}` | Full initial state: dependencies, auth, connection, settings, capabilities, profiles, recents, country summary list |
| `connect` | `{ targetType: "fastest"\|"random"\|"country"\|"city"\|"server"\|"secure_core"\|"profile", country?, entryCountry?, city?, serverName?, features?: ["p2p"\|"tor"\|"streaming"\|"secure_core"], profileId? }` | Resolves optimal `LogicalServer`, refreshes cert if needed, connects via `VPNConnector` |
| `disconnect` | `{}` | Cleanly disconnects current VPN connection |
| `reconnect` | `{}` | Disconnects and reconnects to the same target (used after changing Protocol / IPv6 / Custom DNS) |
| `cancel_connect` | `{}` | Cancels in-progress connection cleanly |
| `query_servers` | `{ query?, feature?: "all"\|"secure_core"\|"p2p"\|"tor"\|"streaming"\|"free", sort?: "alpha"\|"fastest"\|"load", countryCode?, city?, includeServers?: bool, limit?: int }` | Sub-2 ms in-RAM query returning matching countries, cities/SC-hops, or logical servers (capped to 300 rows per page) |
| `refresh_servers` | `{ force?: bool }` | Updates server loads or full server list via `VPNDataRefresher` |
| `set_setting` | `{ key: "netshield"\|"killswitch"\|"protocol"\|"vpn_accelerator"\|"moderate_nat"\|"port_forwarding"\|"ipv6"\|"custom_dns"\|"split_tunneling"\|"anonymous_crash_reports"\|"telemetry", value: ..., forceDisconnect?: bool }` | Validates tier & mutual-exclusion rules, persists via `api.save_settings()`, pushes live via Local Agent when supported, returns `{ appliedLive: bool, requiresReconnect: bool }` |
| `set_panel_open` | `{ open: bool }` | Enables/disables 1 Hz `/sys/class/net/<iface>` throughput stream (0% overhead when closed!) |
| `list_apps` | `{ query? }` | Scans `.desktop` files to suggest binaries for Split Tunneling app picker |
| `save_profile` | `{ profile: { id?, name, targetType, ... } }` | Creates/updates a favorite/custom connection profile in `0600` state file |
| `delete_profile` | `{ id }` | Removes a profile |
| `toggle_favorite` | `{ key, label, target }` | Pins/unpins a country, city, or server in Favorites |
| `auth_login` | `{ username, password }` | SRP login via `api.login()`; **password never logged/echoed**; returns `{ status: "ok"\|"2fa_required", supportsFido2: bool }` |
| `auth_2fa_totp` | `{ code }` | Submits TOTP / recovery code via `api.submit_2fa_code()` |
| `auth_2fa_fido2_start` | `{}` | Starts FIDO2 hardware key assertion; emits `fido2_prompt` events (`touch`, `pin_required`, `select_key`) |
| `auth_2fa_fido2_pin` | `{ pin }` | Supplies hardware key PIN if requested (never logged) |
| `auth_2fa_fido2_cancel` | `{}` | Sets `cancel_assertion` `threading.Event` cleanly |
| `auth_logout` | `{}` | Disconnects if active, calls `api.logout()`, resets state |
| `auth_refresh_account` | `{}` | Calls `api.refresh_vpn_info()` (useful after upgrading plan online) |
| `diagnostics` | `{}` | Checks `NetworkManager`, `proton.VPN.service`, keyring availability, active protocols, runtime dir, certificate expiry |
| `copy_clipboard` | `{ text }` | Copies bounded plain text (<= 256 chars, e.g. VPN IP or forwarded port) to Wayland clipboard via `wl-copy --` stdin (zero shell, never in argv) |

#### Events (`bridge.py` → `Service.qml`)
- `{ "type": "reply", "id": "...", "ok": true|false, "data": ..., "error": { "code": "...", "message": "..." } }`
- `{ "type": "snapshot", "data": { ... } }` — full state sync on startup or auth change
- `{ "type": "state", "data": { connectionState, server, connectionDetails, forwardedPort, connectedSinceMs, iface, errorCode, errorMessage, requiresReconnectFlags } }` — instant push from `VPNStateSubscriber`
- `{ "type": "settings", "data": { ... } }` — emitted whenever settings change
- `{ "type": "traffic", "data": { rxBytesPerSec, txBytesPerSec, totalRxBytes, totalTxBytes, uptimeSec } }` — emitted at 1 Hz only while `panelOpen && connected && bandwidthPolling`
- `{ "type": "servers_updated", "data": { countryCount, serverCount, updatedAtMs, countries: [...] } }` — emitted after server list / load refresh
- `{ "type": "fido2_prompt", "data": { kind: "insert"\|"touch"\|"pin"\|"select_key" } }`

### 5.3 Handling External State Changes & Concurrency
- **External CLI / `nmcli` sync**: `VPNConnector` attaches to `NM.Client` signals for the active connection. Additionally, `bridge.py` subscribes to `NM.Client`'s `active-connection-added` / `active-connection-removed` signals on the GLib thread to detect if a Proton VPN connection was started externally via `protonvpn connect` while the plugin was disconnected, and re-runs `connector.initialize_state()` safely!
- **Serialization lock**: All mutating commands (`connect`, `disconnect`, `set_setting`, `auth_*`) acquire a single `asyncio.Lock` so rapid double-clicks can never race NetworkManager or corrupt `settings.json`.
- **No external telemetry leak**: `bridge.py` does NOT enable Sentry or send crash reports unless the user's own Proton `settings.anonymous_crash_reports` is explicitly enabled.

---

## 6. UI/UX, Visual Craft & Navigation Design (`KeyboardPanel`)

### 6.0 Aesthetic, Layout & Navigation Quality Bar (High Priority)
The finished plugin MUST look **refined, cohesive, and genuinely professional** — matching the polish of Omarchy's best first-party panels (`omarchy.network`, `omarchy.audio`, `omarchy.tailscale`) and using [mockup.html](mockup.html) as the visual north star for hierarchy, spacing rhythm, and calm visual density. Never ship cramped controls, misaligned rows, raw unstyled lists, or cluttered screens.

- **Clean Layout & Visual Hierarchy**:
  - **Consistent spacing rhythm**: Use `Style.spacing.popupPadding` outer insets, `Style.spacing.panelGap` between major sections, uniform card internal padding (`Style.space(10)`–`Style.space(12)`), and consistent row heights (`Style.spacing.popupRowHeight` / `Style.spacing.controlHeight`) so every tab feels balanced and intentional.
  - **Crisp alignment**: All left icons/codes align on one vertical rail, all trailing controls (toggles, load indicators, copy buttons, chevrons) align cleanly on the right edge, and all text labels use `elide: Text.ElideRight` with proper width bounds so long city, server, or binary names never clip harshly or wrap awkwardly.
  - **Calm, scannable grouping**: Group primary live info (active connection telemetry, account card) inside subtle `BorderSurface` cards; separate sections with `PanelSeparator` + `PanelSectionHeader`; keep badges compact and understated so the active state and primary actions stand out immediately.
  - **Zero layout jank**: Reserve stable heights for loading/connecting states and dynamic banners; let `KeyboardPanel.drawnHeight` smoothly animate height changes rather than snapping.
- **Effortless, Intuitive Navigation**:
  - **1-click common tasks**: From **Home**, users can connect/disconnect, switch to a Favorite/Recent, copy VPN IP or forwarded port (with brief inline `"Copied"` confirmation), or cycle NetShield in a single click or keystroke — zero digging through menus.
  - **Progressive disclosure (zero clutter)**: Keep the top-level **Settings** tab scannable by placing multi-item editors (**Split Tunneling** apps/CIDRs, **Custom DNS** IP list) in dedicated inline sub-sheets with a clear `← Settings` breadcrumb header.
  - **Clear orientation everywhere**: Always show where you are via the active tab highlight, drill-down breadcrumbs (`← All Countries`, `← Switzerland / Zurich`), and a subtle bottom hint strip for key shortcuts.
  - **Polished edge states**: Every list and flow must have a clean, helpful empty state (e.g. `"No servers match …"` with a 1-click `[Clear]` button, `"No favorites pinned yet"` hint), clear inline connecting/busy feedback (no unresponsive clicks), and concise human-readable error banners with a direct recovery action.

### 6.1 Panel Geometry, Dynamic Custom Theme Adaptation & Visual Language
The plugin MUST automatically inherit and live-adapt to **any Omarchy theme** — stock themes, forked/overlaid themes in `~/.config/omarchy/themes/<custom>/`, user `~/.config/omarchy/shell.toml` overrides, custom fonts (`omarchy font set`), Hyprland rounding/gaps, translucent/glassy/opaque bars, and **both dark and light custom themes** — with zero restart required.

- **Zero hardcoded colors, radii, fonts, or pixel sizes in QML**:
  - **Surfaces & Palette**: Bind exclusively to `Commons.Color` and `bar`:
    - Popup card background & border: inherited from `KeyboardPanel` (`Commons.Color.popups.background`, `Border.surfaceSpec("popups", "border", ...)` — honors custom popup alpha, flat/gradient borders, and border widths from `shell.toml`).
    - Bar icon & label: `bar.barForeground` / `bar.foreground` / `Commons.Color.accent` / `Commons.Color.urgent` (automatically adapts to opaque, glassy, and clear bar modes).
    - Primary text: `Commons.Color.popups.text` (falls back to `Commons.Color.foreground`).
    - Secondary / muted text: Use `Commons.Color.muted` or `Util.alpha(Commons.Color.popups.text, 0.65)` — **NEVER** rely blindly on `Qt.darker(foreground, ...)` because on **light custom themes** darkening dark text makes secondary text *higher* contrast instead of muted!
    - Interactive control states (rows, buttons, tabs, inputs, badges): Use `Style.controlFill(...)`, `Style.controlBorder(...)`, `Style.controlBorderWidth(...)`, `Style.hoverFillFor(...)`, `Style.selectedFillFor(...)`, and `Border.controlSpec(...)` so custom `[controls]` overrides in the user's `shell.toml` apply automatically everywhere.
  - **Theme-Matched Semantic Colors (Optional `colors.toml` Watch)**:
    - Watch `~/.local/state/omarchy/current/theme/colors.toml` via `FileView { watchChanges: true; printErrors: false }` in a tiny `ThemePalette` helper to read optional ANSI `color2` (success / low load) and `color3` (warning / medium load) from the user's active custom theme, falling back safely to `Commons.Color.accent` and `Util.alpha(Commons.Color.urgent, 0.85)` when absent.
    - High load / destructive / Kill Switch alert always uses `Commons.Color.urgent`.
    - Compute background relative luminance (`Model.isLightColor(Commons.Color.popups.background)`) so subtle divider alphas and badge backgrounds stay crisp on light themes (e.g. Catppuccin Latte, Solarized Light, custom light themes).
  - **Custom Geometry, Typography & Spacing**:
    - Panel width & height: `panel.fittedContentWidth(Style.space(400))` and `panel.fittedContentHeight(panel.loadedContentHeight, Style.space(600))`.
    - Corners: bind every surface/pill/card radius to `Style.cornerRadius` (and `ToggleSwitch` auto-detects `Style.cornerRadius > 0` so sharp `0px` custom themes get sharp switches and cards, while rounded themes get rounded pills).
    - Spacing & sizing: use `Style.space(px)` and `Style.spacing.*` (`popupPadding`, `controlHeight`, `popupRowHeight`, `controlGap`, `rowGap`) so custom `[spacing] scale` in `shell.toml` scales the entire plugin cleanly.
    - Typography: bind `font.family` to `Style.font.family` (follows `omarchy font set` live) and pixel sizes strictly to `Style.font.{caption, bodySmall, body, subtitle, title, heading, display, icon, iconSmall, iconLarge}` so custom `[font] base-size` and overrides never clip or overflow.
    - Bar dimensions: use `BarIconButton` (`Style.bar.{iconSize, iconCanvas, iconSlot}`) so custom `[bar]` dimensions in `shell.toml` and vertical/horizontal bar orientations fit seamlessly.
  - **User-Selectable Connected Icon Role**: `connectedIconTint` widget setting (`accent` | `foreground` | `semantic` theme green `color2`) lets users match their personal top-bar aesthetic while still staying 100% bound to their active theme.
- **Motion**:
  - Open/close/morph/height growth come free from `KeyboardPanel`.
  - Any custom transitions (tab indicator slide, sub-sheet transition, connecting pulse) MUST use `Style.duration(ms)` (`150–180ms` in, `100–120ms` out) and `Style.easeOut` / `Easing.OutCubic` — never bare millisecond integers.

### 6.2 Four-Tab Navigation Layout

```text
┌──────────────────────────────────────────────────────────┐
│ [Shield Icon]  Protonarchy · CH#12       [  ○═══  ]      │  ← PanelHero + Master ToggleSwitch
│                ZURICH, SWITZERLAND · WG                  │    (Optimistic instant flip!)
├──────────────────────────────────────────────────────────┤
│  [1 Home]    [2 Servers]    [3 Settings]    [4 Account]  │  ← Compact TabBar (h/l or 1-4)
├──────────────────────────────────────────────────────────┤
│  (Active Tab Body — smooth scroll via Flickable/ListView)│
│                                                          │
└──────────────────────────────────────────────────────────┘
```

#### Tab 1: **Home** (`HomeView.qml`)
Designed for 90% of daily use in 1 click or 1 keystroke:
1. **Connection Telemetry Card** (visible when `connected`, collapses cleanly when `disconnected`):
   - **Location & Hop**: e.g. `Switzerland · Zurich` (or `Iceland → United States` badge when Secure Core is active) + Server ID `CH#12` + `LoadIndicator` (`18%`).
   - **VPN IP Row**: `203.0.113.42` (+ IPv6 indicator if enabled) with inline copy `PanelActionButton` (`c` shortcut).
   - **Protocol & Port Row**: `WireGuard` badge + (when Port Forwarding is active on a P2P server) **Forwarded Port pill** `Port 54321` with 1-click copy (`p` shortcut)!
   - **Live Traffic & Uptime Strip** (when `bandwidthPolling` enabled): `↓ 4.2 MB/s   ↑ 310 KB/s   ·   01:24:18`.
   - **Reconnect Banner** (shown only if user changed Protocol / IPv6 / Custom DNS while connected): `"Changes require reconnect"` + inline `[Reconnect]` button.
2. **Error / Alert Banner** (conditional):
   - Permanent Kill Switch active while disconnected: `"Permanent Kill Switch is blocking internet"` + `[Connect]` / `[Turn Off KS]`.
   - `TwoFARequired`: `"Traffic blocked — hardware key authentication required"` + guidance.
   - `MaximumSessionsReached` / `AuthDenied` / missing daemon: concise actionable message + retry button.
3. **Quick Action Row** (when disconnected, or quick switch when connected):
   - Primary `[Quick Connect]` (or `[Disconnect]` + `[Change Server]`)
   - `[Fastest P2P]`, `[Secure Core]`, `[Random]` compact chips (locked with subtle badge on Free tier).
4. **Live Security Strip** (2-tap inline status & toggles right from Home):
   - **NetShield**: clickable cycle pill (`Off` / `Malware` / `Ads+Trackers`) — applies live!
   - **Kill Switch**: clickable status pill (`Off` / `Standard` / `Permanent`) — jumps to Kill Switch control or toggles Standard cleanly.
   - **Split Tunnel**: indicator badge when active (`Split: Exclude (3)`).
5. **Favorites & Recents** (compact clickable rows):
   - User-pinned Favorites / Custom Profiles (e.g. `★ Fastest US`, `★ CH → NL Secure Core`, `★ P2P Zurich`) with inline connect + unpin actions.
   - Up to 5 Recent connections (one-click reconnect).

#### Tab 2: **Servers** (`ServersView.qml`)
Fast, zero-lag browsing across 100+ countries and 5,000+ servers:
1. **Sticky Search Bar** (`FilterInput`, focused by `/` or typing directly on Servers tab):
   - Instant client+bridge filter across country names, ISO codes (`US`, `CH`), cities (`Zurich`, `New York`), and exact server IDs (`US-NY#42`).
   - Clears automatically when panel closes (matching `omarchy.tailscale` UX so users never wonder why countries are missing).
2. **Feature Filter Chips** (`ButtonGroup` / wrap pills):
   - `All` · `Secure Core` · `P2P` · `Tor` · `Streaming` (+ `Sort: A-Z | Fastest | Load`).
3. **3-Level Drill-Down with Breadcrumb Header** (cleaner & faster than deeply nested accordions inside a 400 px popup):
   - **Level 0 — Countries** (virtualized `ListView`):
     - Each row: Country Code badge (`CH`), Country Name (`Switzerland`), Feature badges (`SC`, `P2P`, `TOR`, `STR`), Best Load dot, `[Connect Fastest]` quick action, and `▸` drill-in arrow (`l` / `→` / click row).
     - Free tier users see Free countries at the top and paid countries visibly marked as Plus.
   - **Level 1 — Country Detail** (`← Switzerland` breadcrumb + `[Connect Fastest in CH]` + `[★ Favorite]`):
     - If Secure Core filter or Secure Core available: **"Via Secure Core"** section listing entry hops (`IS → CH`, `SE → CH`, `CH → ...`) with load & instant connect.
     - **Cities / States** list (`Zurich (42 servers · 14% load)`, `Geneva (12 servers · 22% load)`): click Connect for fastest in city, or `▸` to inspect individual servers.
   - **Level 2 — City Servers** (`← Switzerland / Zurich`):
     - Virtualized list of individual `LogicalServer` entries: `CH#12`, `LoadIndicator (14%)`, `FeatureBadge`s (`P2P`, `STR`, `IPv6`, `SR`), `[Connect]`, `[★]`.
     - Under-maintenance servers dimmed & non-connectable with tooltip `"Under maintenance"`.
   - **Direct Search Mode**: When search query is non-empty, show flat ranked sections: **Matching Countries**, **Matching Cities**, and **Matching Servers** (instant jump to `US-NY#42` in 3 keystrokes!).

#### Tab 3: **Settings** (`SettingsView.qml`)
Clean grouped sections matching `omarchy.network` & `omarchy.audio` aesthetics:
1. **Security**:
   - **Kill Switch**: 3-way `ButtonGroup` (`Off` / `Standard` / `Permanent`).
     - Selecting `Permanent` opens `ConfirmDialog` explaining all non-VPN traffic will be blocked even when disconnected/rebooted.
     - If Split Tunneling is currently ON, prompts `ConfirmDialog`: `"Kill Switch cannot run with Split Tunneling. Disable Split Tunneling and enable Kill Switch?"`.
     - If currently connected and backend requires disconnect before changing Kill Switch, prompts `ConfirmDialog`: `"Disconnect temporarily to update Kill Switch?"`.
   - **NetShield**: 3-way `ButtonGroup` (`Off` / `Malware` / `Ads & Trackers`) — shows subtle `"Live"` confirmation; shows warning note if Custom DNS is active (Custom DNS overrides NetShield DNS).
2. **Connection**:
   - **Protocol**: `Dropdown` populated dynamically from validated backend protocols (`WireGuard`, `Smart`, `WireGuard UDP/TCP`, `Stealth`, `OpenVPN UDP`, `OpenVPN TCP`). Marks `"Reconnect to apply"` if changed while connected.
   - **VPN Accelerator**: `ToggleSwitch` (live).
   - **Moderate NAT**: `ToggleSwitch` (live, helper subtitle `"For gaming & P2P"`).
   - **Port Forwarding**: `ToggleSwitch` (live, helper subtitle `"P2P servers only"` + displays active port if connected).
   - **IPv6**: `ToggleSwitch` (marks `"Reconnect to apply"` if connected).
3. **Routing & DNS**:
   - **Split Tunneling**: Summary row (`Off` / `Exclude · 3 apps, 1 IP` / `Include · 2 apps`) with `▸` chevron opening `SplitTunnelingSheet.qml`:
     - Master `ToggleSwitch` (checks `proton.VPN.service` availability; shows conflict prompt if Kill Switch is ON).
     - Mode `ButtonGroup` (`Exclude from VPN` / `Include only in VPN`).
     - **Apps** section: list of configured binary paths with remove button + searchable installed-app picker (resolved from `.desktop` files) + manual absolute binary path input (validated as existing executable).
     - **IP Addresses / Subnets** section: list of CIDR/IP entries with remove button + validated IPv4/IPv6/CIDR input.
   - **Custom DNS**: Summary row (`Off` / `1.1.1.1, 9.9.9.9`) with `▸` chevron opening `CustomDnsSheet.qml`:
     - Master `ToggleSwitch` + ordered IP list (add/remove/reorder) with strict `ipaddress` validation.
4. **Plugin Preferences & Privacy**:
   - Links cleanly to Omarchy bar widget settings (`showCountryCode`, `showNotifications`, `bandwidthPolling`) via `bar.shell.updateEntryInline` or direct toggles, plus Proton's `Anonymous crash reports` and `Telemetry` toggles.

#### Tab 4: **Account** (`AccountView.qml`) & First-Class In-App Sign-In
1. **When Signed Out (First-Class In-App Login — Confirmed Requirement)**:
   - When the user is not signed in, opening the panel lands directly on the clean **In-App Sign-In** screen (no terminal required, no external browser required for standard login):
     - **Step 1 — Credentials**:
       - Proton username / email (`TextField`, autofocused on open, `Enter` advances to password).
       - Password (`TextField`, `echoMode: TextInput.Password`, inline show/hide eye `PanelActionButton`, `Enter` submits).
       - Primary `[Sign In]` button with inline spinner while authenticating (`ProtonVPNAPI.login` → SRP handshake + `fetch_session_data`).
       - Actionable inline error banner (plain text, sanitized) for wrong credentials (`AuthenticationFailedError`), offline/unreachable API (`ProtonAPINotReachable`), locked/missing OS keyring (`KeyringError` with unlock hint), or rate-limit/human-verification notices.
     - **Step 2 — Two-Factor Authentication** (automatically shown when `login_result.twofa_required === true`):
       - **FIDO2 / U2F Hardware Security Key** (when `api.supports_fido2` is true): interactive in-panel card driving `UserInteraction` callbacks (`"Insert your security key"`, `"Enter security key PIN"` masked input, `"Multiple keys detected — tap one"`, `"Touch your security key"`) with live `[Cancel]` button (`cancel_assertion.set()`).
       - **Authenticator App (TOTP) / Recovery Code**: inline switcher or default input (6-digit TOTP or recovery code, `Enter` submits via `api.submit_2fa_code()`), allowing retries on invalid code without losing the 2FA session.
     - **Post-Login Transition**: On success, `bridge.py` finishes `fetch_session_data()`, persists the session exclusively in the OS Secret Service keyring (`python-proton-keyring-linux`), indexes the server list in RAM, emits a full `snapshot`, and the panel smoothly transitions to the **Home** tab ready for 1-click connect.
   - **Strict Security Invariants for In-App Login**:
     - Credentials, 2FA codes, and FIDO2 PINs are transmitted **only** over the private anonymous stdin pipe to `bridge.py` — never via CLI args, env vars, temp files, or shell commands.
     - `bridge.py` redacts `password`, `code`, and `pin` from all logs and error reports, and drops references immediately after calling `api.login` / `submit_2fa_code` / `request_pin`.
     - QML clears `passwordField.text`, `totpField.text`, and `pinField.text` immediately on submit, on error, and on panel close (`onOpenedChanged`).
2. **When Signed In**:
   - Account username, Plan badge (`VPN Plus`, `Proton Unlimited`, `VPN Free`), Max concurrent connections (`e.g. 10 devices`), `[Refresh Plan]` button.
   - **System Health / Diagnostics** collapsible card:
     - `NetworkManager`: Active / Error
     - `proton.VPN.service` (Split Tunneling): Active / Inactive (with exact command hint `sudo systemctl enable --now proton.VPN.service`)
     - `Keyring`: Secret Service OK
     - `Backend Bridge`: Connected (PID / uptime) + `[Restart Bridge]`
   - `[Sign Out]` button (destructive `urgent` hover; opens `ConfirmDialog` if VPN is active).

### 6.3 Complete Keyboard Shortcut Map

| Scope | Key | Action |
|---|---|---|
| Global (Panel Open) | `Esc` | Close active dialog/sheet → clear search → navigate up drill-down level → close panel |
| Global (Panel Open) | `1` / `2` / `3` / `4` | Jump to Home / Servers / Settings / Account (when not typing in a text input) |
| Global (Panel Open) | `Tab` / `Shift+Tab` | Morph to next / previous Omarchy bar panel (`root.switchPanel(dir)`) |
| Global (Panel Open) | `j` / `k` or `↑` / `↓` | Move keyboard cursor down / up |
| Global (Panel Open) | `h` / `l` or `←` / `→` | Drill out / drill in on Servers tab, or step segmented controls (RTL-aware via `Util.readingKey(event)`) |
| Global (Panel Open) | `Enter` / `Space` | Activate focused row / toggle / button |
| Global (Panel Open) | `t` | Quick Connect / Disconnect toggle |
| Global (Panel Open) | `r` | Refresh status & server loads |
| Global (Panel Open) | `/` | Jump to Servers tab and focus search `FilterInput` |
| Home / Connected | `c` | Copy active VPN IPv4 address to clipboard (`wl-copy`) |
| Home / Connected | `p` | Copy active forwarded port to clipboard (when available) |
| Servers | `f` | Toggle Favorite on highlighted country / city / server |

### 6.4 Shell IPC Surface (`ShellIpc` target: `pl0xuee.proton-for-omarchy`)
Enables effortless Hyprland keybindings in `~/.config/hypr/bindings.lua` and terminal scripting:
- `omarchy-shell pl0xuee.proton-for-omarchy toggle` — open/close panel
- `omarchy-shell pl0xuee.proton-for-omarchy open` / `close`
- `omarchy-shell pl0xuee.proton-for-omarchy toggleConnection` — quick connect or disconnect
- `omarchy-shell pl0xuee.proton-for-omarchy connectFastest`
- `omarchy-shell pl0xuee.proton-for-omarchy connectCountry US`
- `omarchy-shell pl0xuee.proton-for-omarchy disconnect`
- `omarchy-shell pl0xuee.proton-for-omarchy status` — returns English one-line status string (e.g. `Connected: CH#12 (Zurich, CH) 203.0.113.42`)
- `omarchy-shell pl0xuee.proton-for-omarchy refresh`

---

## 7. Security Hardening Checklist (Non-Negotiable Invariants)

The implementing agent MUST enforce and test every item below:

1. **QML Injection Prevention (Omarchy Plugin UI Safety)**:
   - Create `components/PlainText.qml` (`Text { textFormat: Text.PlainText }`) and use it for **every** text element in the plugin. Never use bare `Text` with dynamic data.
   - Implement `Model.sanitizeText(str, maxLen)` that strips control characters and neutralizes HTML/XML tags (`<` → `‹`, `>` → `›`, `&` → `&amp;` or strips `<[^>]*>`) before passing ANY dynamic string (server name, city, error message, account name, tooltip) into `bar.showTooltip(...)` or `notify-send`.
2. **Zero Command Injection**:
   - Never invoke `bash -c` or `sh -c` with interpolated variables.
   - Clipboard copy: pass text via `bridge.py` (`subprocess.run(["wl-copy", "--"], input=text.encode(), check=False)`) OR `Quickshell.Io.Process` stdin — **zero shell quoting hazards**, and never puts copied IPs/ports in argv!
   - Notifications: `Quickshell.execDetached(["notify-send", "-a", "Protonarchy", "-i", "network-vpn", "--", title, body])` (note `--` terminator prevents option injection!).
3. **Zero Credential Exposure**:
   - Passwords, 2FA codes, and FIDO2 PINs travel ONLY over the private `Quickshell.Io.Process` stdin pipe (anonymous kernel pipe, same UID, unreadable by other users), never in argv, never in `console.log`, never in `bridge.py` logs, never persisted outside Proton's OS Keyring.
   - `bridge.py` installs a log filter that redacts any keys named `password`, `code`, `pin`, `token`, `private_key`, `secret`.
   - QML clears auth inputs immediately on submit, error, and panel close.
4. **Strict Input & Output Validation**:
   - `bridge.py` validates every request against strict allowlists: country codes (`^[A-Z]{2}$`), server names (`^[A-Za-z0-9#._-]{1,64}$`), DNS IPs (`ipaddress.ip_address`), Split Tunneling IP ranges (`ipaddress.ip_network(..., strict=False)`), Split Tunneling app paths (must be absolute existing non-directory executable paths, `os.path.realpath` resolved, rejecting null bytes / newlines).
   - Bound NDJSON payload sizes, list lengths (max 50 custom profiles, max 50 favorites, max 10 custom DNS entries, max 200 split-tunnel rules, max 300 server rows per query response), and string lengths.
5. **Atomic Private Storage**:
   - `~/.config/omarchy/protonarchy-state.json` (favorites, recents, custom profiles) written atomically (`mkstemp` in same dir → `chmod 0o600` → `fsync` → `os.replace`) so power loss or crashes never corrupt state and other users cannot read VPN location history.
6. **Zero Third-Party Network Calls**:
   - Never query external services (`ifconfig.me`, `ipinfo.io`, etc.) to find the user's IP or location — that leaks traffic and breaks VPN privacy! All IP/country/server/load data comes exclusively from `python-proton-vpn-api-core` and Proton's authenticated Local Agent inside the tunnel.
7. **Packaging & Symlink Hygiene**:
   - Zero symlinks in the plugin directory; must exit `0` from `omarchy plugin validate .`.

---

## 8. Phased Implementation Plan (For the Executing Agent)

> **Builder Agent Handoff Notes:**
> - This repository root is the plugin root (do not nest inside a subfolder; `git remote origin` is already configured to `https://github.com/pl0xuee/proton-for-omarchy.git`).
> - [mockup.html](mockup.html) is a visual design reference only — keep `mockup.html`, `PLAN.md`, `tests/`, and `.git/` out of the installed copy when `scripts/install-local.sh` copies runtime files into `~/.config/omarchy/plugins/pl0xuee.proton-for-omarchy/`.
> - On `Panel.qml` (extending `qs.Ui.Panel`), set `manageIpc: false` and declare the full `ShellIpc { target: "pl0xuee.proton-for-omarchy" }` block directly to avoid duplicate IPC handlers.
> - Use `api.refresher.set_server_list_updated_callback(...)`, `set_server_loads_updated_callback(...)`, and `set_error_callback(...)` in `backend/proton_client.py`, enabling the refresher after login and disabling cleanly on logout/shutdown.
> - Do not overwrite or delete other widgets in `~/.config/omarchy/shell.json`; use `omarchy plugin enable pl0xuee.proton-for-omarchy` (which honors `defaultSection: "right"`).

Execute in order, verifying each phase before advancing.

### Phase 1 — Scaffold, Manifest & Protocol Core
1. Create directory structure, `manifest.json`, `i18n/en.json`, `components/PlainText.qml`, and `scripts/install-local.sh`.
2. Run `omarchy plugin validate .` immediately to lock in manifest compliance.
3. Build `backend/protocol.py` (NDJSON framing, size bounds, schema validation, secret-redacting logger) and `backend/profiles.py` (atomic `0600` JSON store for favorites/recents/profiles).
4. Write unit tests `tests/test_protocol.py` and `tests/test_profiles.py`; run `pytest` / `python3 -m unittest`.

### Phase 2 — Persistent Proton VPN Python Bridge
1. Build `backend/server_index.py`:
   - In-memory index over `ServerList` supporting instant (< 2 ms) search, feature bitmask filtering (`SECURE_CORE`, `P2P`, `TOR`, `STREAMING`, `IPV6`), tier awareness, country/city/Secure-Core grouping, and load/score sorting.
2. Build `backend/telemetry.py`:
   - Detects active VPN network interface (`proton0` or NM active connection `ip-iface`), samples `/sys/class/net/<iface>/statistics/{rx,tx}_bytes` for delta B/s + session totals + uptime.
3. Build `backend/split_tunnel.py`:
   - Validates IPv4/IPv6 CIDR rules and executable binary paths; parses `.desktop` entries in `/usr/share/applications` and `~/.local/share/applications` into `{ name, icon, binaryPath }` (resolving `Exec=` first token safely via `shlex.split` + `shutil.which` + `realpath`).
4. Build `backend/proton_client.py` and `backend/bridge.py`:
   - Full `ProtonVPNAPI` + `VPNConnector` + `VPNDataRefresher` integration.
   - `VPNStateSubscriber` pushing real-time `state` events (including `ConnectionDetails`, `forwarded_port`, and typed error codes).
   - NM `active-connection-added`/`removed` listener for external CLI sync.
   - Complete settings mutator enforcing Kill Switch ↔ Split Tunneling mutual exclusion, protocol-switch disconnect guard, and Free-tier checks.
   - Full Auth flow: SRP login, TOTP 2FA, FIDO2 `UserInteraction` callback bridge (`touch`, `pin`, `select_key`, `cancel`), logout, plan refresh.
   - Graceful degradation when `python-proton-vpn-api-core` or `proton.VPN.service` is missing.
   - Stdin EOF clean exit + `asyncio.Lock` around mutations.
5. Write `tests/test_server_index.py` and `tests/test_split_tunnel.py` (using mock `LogicalServer` datasets of 5,000 servers to assert `< 10 ms` query time).

### Phase 3 — QML Service, Model & Native Bar Icon
1. Build `Model.js` (pure JS helpers: `sanitizeText`, `formatSpeed`, `formatBytes`, `formatDuration`, `loadLevel`, `countryCodeDisplay`, `stateLabel`, `featureBadges`).
2. Build `ProtonVpnIcon.qml` (crisp native vector shield mark + connected/connecting/disconnected/KS-blocked/warning states).
3. Build `Service.qml`:
   - Spawns & manages `backend/bridge.py` (`Quickshell.Io.Process` + `SplitParser` + backoff restart + request/reply map with timeouts).
   - Optimistic `_desired` connection state, change-signature guards on server lists, clipboard helper (routed via bridge stdin to `wl-copy`), sanitized desktop notifications (`notify-send --`), and `panelOpen` forwarding to gate 1 Hz traffic telemetry.
4. Build `Panel.qml` shell with `BarIconButton` (using native `tooltipText`, `labelText`, `iconComponent`, `onPressed`), `ShellIpc` (`pl0xuee.proton-for-omarchy`, `manageIpc: false`), shared `Service.qml` lookup (`bar?.shell?.serviceFor("pl0xuee.proton-for-omarchy")` with inline `Loader` fallback), `Commons.Translations`, and `KeyboardPanel` with lazy `content`.
5. Write `tests/test_model.mjs` covering sanitization (including `<img src=...>`, `<b>`, control chars, long strings) and formatters.

### Phase 4 — Complete Panel UI & Keyboard Ergonomics
1. Build `components/TabBar.qml`, `LoadIndicator.qml`, `FeatureBadge.qml`, `ServerRow.qml`.
2. Build `components/HomeView.qml` (Hero, live telemetry card, copy IP & forwarded port, quick connect/feature chips, inline NetShield/KS pills, Favorites & Recents, reconnect & alert banners).
3. Build `components/ServersView.qml` (instant `FilterInput`, feature chips, sort toggle, 3-level Country → City/Secure Core → Server drill-down + flat search results, virtualized `ListView`).
4. Build `components/SettingsView.qml`, `SplitTunnelingSheet.qml`, and `CustomDnsSheet.qml` (all Proton settings, `ConfirmDialog` for Permanent KS and KS↔Split Tunneling swap, reconnect badges, live confirmation indicators).
5. Build `components/AccountView.qml` (first-class in-app SRP sign-in with show/hide password + TOTP/recovery code + FIDO2 hardware key touch/PIN prompts + signed-in plan card + system diagnostics + Sign Out confirmation; auto-land here when signed out).
6. Wire complete keyboard navigation in `Panel.qml` (`PanelKeyCatcher` with `blocked` bound to dialog/dropdown/input focus, `ConfirmDialog.handleKey`, `CursorSurface` + `PointerMoveGate` single-highlight cursor tracking across all 4 tabs, `scrollItemIntoView`, `Tab` panel morphing via `root.switchPanel`, and `Esc` layered unwind).

### Phase 5 — Verification, Security Audit & Local Installation
1. Write `tests/test_qml_safety.sh` and `scripts/verify.sh` to automatically assert:
   - `omarchy plugin validate .` exits `0`.
   - Zero bare `Text {` elements without `textFormat: Text.PlainText` (or use `PlainText`).
   - Zero `bash -c` / `sh -c` calls.
   - Zero bare numeric `Animation { duration: <N> }` (all use `Style.duration(...)`).
   - Zero hardcoded hex color literals (`#[0-9a-fA-F]{3,8}`) in QML files (all colors derive from `Commons.Color`, `Style`, `bar`, or live-watched `colors.toml` tokens).
   - Zero symlinks in repo.
   - All Python unit tests and `Model.js` tests pass.
   - `qmllint` (if installed on host) reports zero syntax/import errors.
2. Test local install via `scripts/install-local.sh` (copies runtime files to `~/.config/omarchy/plugins/pl0xuee.proton-for-omarchy`, runs `omarchy-shell shell rescanPlugins`, `omarchy plugin enable pl0xuee.proton-for-omarchy`, confirms bar placement in `right` section of `~/.config/omarchy/shell.json` without clobbering existing widgets).
3. Verify remote install compatibility with `omarchy plugin add https://github.com/pl0xuee/proton-for-omarchy.git --enable` (repo root must contain `manifest.json`, zero symlinks, and a clean `README.md`).
4. Live verification checklist on desktop:
   - Bar icon renders cleanly at horizontal top bar and vertical bar; tooltip updates and strips markup.
   - Left/right/middle click work; panel morphs smoothly with adjacent `omarchy.network` and `omarchy.audio` panels.
   - Live theme switch (`omarchy theme set ...`) across stock dark themes, **light themes**, **custom user themes** (`~/.config/omarchy/themes/<custom>/`), `0px` sharp-corner themes, custom fonts (`omarchy font set`), and custom `shell.toml` overrides updates every surface, border, radius, font, and semantic color immediately without restart.
   - Animations toggle (`omarchy toggle animations`) sets all transition durations to 0.
   - Connect/Disconnect, Country/City/Server/Secure Core/P2P connect, live NetShield toggle, Port Forwarding readout, Split Tunneling rule apply, Kill Switch confirmation & state, Custom DNS validation, and Sign Out/Sign In (including 2FA) all work end-to-end.
   - Visual polish & usability review: verify alignment, consistent spacing/padding, clean text elision (no clipping/overflow on long city/server/app names), smooth hover/keyboard focus transitions, crisp empty/loading/error states, and overall visual parity with [mockup.html](mockup.html) across both dark and light themes.
   - Multi-monitor & custom-bar check: with 2+ monitors (or cloned `pl0xuee.bar`), `ps aux | grep bridge.py` confirms **one** shared `bridge.py` process (no duplicates), zero secrets in cmdline, and clean exit on `omarchy restart shell` or `omarchy-shell shell rescanPlugins`.

---

## 9. Key Edge Cases & Pitfalls to Avoid

1. **`XDG_RUNTIME_DIR` & `XDG_CONFIG_HOME` at import time**: `proton.vpn.core.settings.settings` evaluates `VPNExecutionEnvironment().path_config` at module import time and raises `KeyError` if `XDG_RUNTIME_DIR` is unset. `bridge.py` must verify environment variables before importing `proton.vpn.*` and emit a structured `env_error` event rather than crashing with a raw traceback.
2. **Free-tier ProTun override**: `ProtonVPNAPI.load_settings()` may map `wireguard` → `protun-smart` once per process for free users when `PROTUN_ONLY_FEATURE_FLAG` is set. Always reflect the effective protocol returned by `load_settings()`.
3. **Kill Switch + Protocol switching**: Never swap between WireGuard and OpenVPN while Kill Switch is active without disconnecting first (`VPNConnector._set_ks_impl` documents that WG and OpenVPN NM kill switches are incompatible).
4. **Custom DNS + NetShield interaction**: Proton's NetShield operates at Proton's DNS resolver (`10.2.0.1`). When Custom DNS is enabled, surface a clear informational note in Settings that NetShield DNS blocking is bypassed by custom DNS servers.
5. **Port Forwarding on Linux**: On WireGuard/ProTun, Local Agent automatically requests and reports `forwarded_port` in `Connected` events and writes it to `$XDG_RUNTIME_DIR/Proton/VPN/forwarded_port`. Only P2P-capable servers (`ServerFeatureEnum.P2P`) assign a port; if Port Forwarding is enabled on a non-P2P server, display `"Connect to a P2P server for port forwarding"` with a 1-click `[Switch to P2P]` action.
6. **External `protonvpn` CLI / GUI coexistence**: Keep `bridge.py` synced via NM active-connection signals and reload `settings.json` mtime before mutating settings so changes made via `protonvpn config set ...` are never clobbered.
7. **Plugin hot-reload cleanup**: When saving QML files during development, `omarchy-shell` destroys and recreates the `Panel` instance; `Service.qml`'s `Component.onDestruction` must set `bridgeProcess.running = false`, and `bridge.py` must exit immediately on stdin EOF / `SIGTERM`.
8. **No `omarchy.*` ID & No Symlinks**: Never name the plugin `omarchy.protonvpn` and never symlink the workspace into `~/.config/omarchy/plugins/`; `omarchy-plugin-validate` explicitly rejects both.
