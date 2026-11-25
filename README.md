# Proton for Omarchy

A Proton VPN control panel for the Omarchy bar: one-click connect, a fast server browser with Secure Core, NetShield, Kill Switch, Port Forwarding, Split Tunneling and Custom DNS, plus in-app sign-in with 2FA and security keys. It follows your Omarchy theme, font and spacing live, and every action works from the keyboard.

## Requirements

- Omarchy 4.5 or newer
- Proton VPN's Linux libraries: `proton-vpn-gtk-app` or `proton-vpn-cli` (they provide `python-proton-vpn-api-core`, the NetworkManager backends and the keyring integration)
- `wl-clipboard`, for copying the IP address and forwarded port
- Optional, for Split Tunneling: `sudo systemctl enable --now proton.VPN.service`

Omarchy's plugin installer does not install system packages, so the plugin ships a helper that does. All packages come from Arch's official `extra` repo.

## Install

```sh
omarchy plugin add https://github.com/pl0xuee/proton-for-omarchy.git --enable
~/.config/omarchy/plugins/pl0xuee.proton-for-omarchy/scripts/install-deps.sh
```

`install-deps.sh` installs `proton-vpn-cli` and `wl-clipboard` if they are missing, and asks before enabling the Split Tunneling daemon (`--yes` enables it without asking). If you skip it, the panel shows an **Install requirements** button that runs the same script in a terminal, then picks up the libraries on its own once they are installed.

Or from a checkout:

```sh
scripts/install-local.sh            # copies runtime files, rescans, enables in the right section
scripts/install-local.sh --no-enable
```

## Update

`omarchy update` updates Proton's packages but not plugins. To get a new version of this plugin, run:

```sh
omarchy plugin update pl0xuee.proton-for-omarchy && omarchy-restart-shell
```

The restart loads the new panel files. When a new release is out, the Home tab shows **Proton for Omarchy x.y.z is available**. Its **Update** button runs the command above in a terminal, which shows the changes and asks before applying them. If you installed from a checkout with `scripts/install-local.sh`, run that script again instead. You can turn the check off with `checkForUpdates`, or under Settings.

## Remove

1. Optional: sign out under **Account** first, to clear the Proton session from the system keyring.
2. Remove the plugin. This unloads it, takes it off the bar and deletes its folder:

   ```sh
   omarchy plugin remove pl0xuee.proton-for-omarchy
   ```

3. Optional: delete the favorites file with `rm -f ~/.config/omarchy/proton-for-omarchy-state.json`.
4. Optional: if you installed Proton VPN only for this plugin, run `sudo systemctl disable --now proton.VPN.service` and `sudo pacman -Rns proton-vpn-cli`.

The plugin changes no system files. Its only writes are the favorites file above and a per-session marker in `$XDG_RUNTIME_DIR`, which is cleared at logout. Proton VPN settings belong to Proton's own config, which is kept so the Proton app still works.

## Using it

| In the bar | Action |
|---|---|
| Left click | Open or close the panel |
| Right click | Connect to the fastest server, or disconnect |
| Middle click | Refresh status and server loads |

The panel has four tabs: **Home** (status, quick actions, security, favorites and recents), **Servers** (search, filters, then country → city → server), **Settings** and **Account**.

| Key | Action |
|---|---|
| `1` to `4` | Switch tab |
| `j` / `k`, arrow keys | Move the cursor |
| `h` / `l` | Go back or drill in on Servers, step through segmented controls |
| `Enter` / `Space` | Activate |
| `t` | Connect to the fastest server, or disconnect |
| `r` | Refresh |
| `/` | Search servers |
| `s` | Switch to the fastest other server, with fresh loads (Home, while connected) |
| `c` / `p` | Copy the VPN IP or forwarded port (Home) |
| `f` | Favorite the highlighted country, city or server |
| `x` / `Delete` | Remove a favorite, app, IP or DNS entry |
| `Ctrl+j` / `Ctrl+k` | Reorder custom DNS servers |
| `Esc` | Close a dialog, clear search, go up a level, then close |
| `Tab` | Move to the next bar panel |

## Scripting

```sh
omarchy-shell pl0xuee.proton-for-omarchy toggle
omarchy-shell pl0xuee.proton-for-omarchy toggleConnection
omarchy-shell pl0xuee.proton-for-omarchy connectFastest
omarchy-shell pl0xuee.proton-for-omarchy switchFastest   # leave a slow server for the fastest other one
omarchy-shell pl0xuee.proton-for-omarchy connectCountry CH
omarchy-shell pl0xuee.proton-for-omarchy disconnect
omarchy-shell pl0xuee.proton-for-omarchy status     # e.g. "Connected: CH#12 (Zurich, CH) 203.0.113.42"
omarchy-shell pl0xuee.proton-for-omarchy refresh
```

## Widget settings

Set these from the panel's Settings tab, or in the bar widget settings:

- `connectOnStartup`: `off`, `fastest` or `last`. Connects once per login session when you sign in to your desktop, retrying for about a minute while the network comes up. Shell reloads never reconnect.
- `showCountryCode`: show the country code next to the icon while connected
- `connectedIconTint`: `accent`, `foreground` or `semantic` (the theme's green)
- `showNotifications`: desktop notifications on connect, disconnect and errors
- `bandwidthPolling`: live traffic speed while the panel is open
- `autoRefreshServers`: refresh server loads in the background
- `checkForUpdates`: check GitHub for a newer release twice a day (default on)

## Privacy and security

- Your Proton session lives only in the system keyring, managed by Proton's own libraries. Passwords, 2FA codes and security key PINs travel only over a private pipe to the backend. They never go into command lines, environment variables, files or logs, and the panel clears them on submit, on error and on close.
- Apart from Proton, the plugin's only network request is the optional update check: an anonymous HTTPS request to the GitHub releases API, from which it reads only the version tag. Turn it off with `checkForUpdates`. There are no IP lookups. The VPN IP shown comes from Proton's connection details or server list, and your real IP is never displayed.
- Favorites and recents are stored in `~/.config/omarchy/proton-for-omarchy-state.json`, which is written atomically with `0600` permissions.

## Troubleshooting

Open **Account → System health** for a check of NetworkManager, the keyring, the Split Tunneling service and the backend. **Copy report** puts the results on the clipboard.

- *"Proton VPN libraries" failing*: install `proton-vpn-gtk-app` or `proton-vpn-cli`.
- *Keyring errors*: install and unlock a Secret Service keyring, such as `gnome-keyring`.
- *Split Tunneling unavailable*: `sudo systemctl enable --now proton.VPN.service`.
- *The backend keeps stopping*: use **Restart backend**, then check `journalctl --user -b | grep proton-for-omarchy`.

## Development

```sh
scripts/verify.sh                 # unit tests, safety audit, qmllint, catalog sync, plugin validator
python3 scripts/extract_strings.py  # regenerate i18n/en.json from the English fallbacks in the QML
```

License: GPL-3.0-or-later.
