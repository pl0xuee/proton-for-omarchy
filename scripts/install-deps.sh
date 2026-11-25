#!/usr/bin/env bash
# Install everything Proton for Omarchy needs, from Arch's official repos.
#   proton-vpn-cli  pulls in Proton's VPN libraries, the NetworkManager backend,
#                   the keyring integration, the local agent and the system daemon
#   wl-clipboard    copy the VPN IP and forwarded port
# Usage: scripts/install-deps.sh [--yes]   (--yes also enables the Split Tunneling daemon)
set -euo pipefail

PKGS=(proton-vpn-cli wl-clipboard)
YES=0
for arg in "$@"; do
  case $arg in
    --yes | -y) YES=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

missing=()
for pkg in "${PKGS[@]}"; do
  pacman -Q -- "$pkg" &>/dev/null || missing+=("$pkg")
done

if (( ${#missing[@]} )); then
  echo "Installing: ${missing[*]}"
  if command -v omarchy-pkg-add >/dev/null; then
    omarchy-pkg-add "${missing[@]}"
  else
    sudo pacman -S --needed -- "${missing[@]}"
  fi
else
  echo "Proton VPN packages are already installed."
fi

if ! systemctl is-active --quiet NetworkManager; then
  echo "Warning: NetworkManager is not running. Proton VPN needs it: sudo systemctl enable --now NetworkManager" >&2
fi

# Split Tunneling goes through Proton's root daemon, which ships with proton-vpn-cli
# but is not enabled by default. Only enable it when asked.
if systemctl cat proton.VPN.service &>/dev/null && ! systemctl is-enabled --quiet proton.VPN.service; then
  enable=$YES
  if (( ! enable )) && [[ -t 0 ]]; then
    if command -v gum >/dev/null; then
      gum confirm "Enable Proton's system daemon? (only needed for Split Tunneling)" && enable=1 || true
    else
      read -r -p "Enable Proton's system daemon? Only needed for Split Tunneling [y/N] " reply
      [[ $reply == [yY]* ]] && enable=1
    fi
  fi
  (( enable )) && sudo systemctl enable --now proton.VPN.service
fi

echo "Done. Proton for Omarchy will pick up the change on its own, or press Restart backend in the panel."
