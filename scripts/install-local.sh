#!/usr/bin/env bash
# Install this checkout as a local Omarchy plugin (a real copy, no symlinks),
# then rescan and enable it. Usage: scripts/install-local.sh [--no-enable] [--no-restart]
set -euo pipefail
cd "$(dirname "$0")/.."

ID=$(python3 -c 'import json; print(json.load(open("manifest.json"))["id"])')
DEST="$HOME/.config/omarchy/plugins/$ID"
ENABLE=1
RESTART=1
for arg in "$@"; do
  case $arg in
    --no-enable) ENABLE=0 ;;
    --no-restart) RESTART=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
UPDATE=0
[[ -d $DEST ]] && UPDATE=1

/usr/share/omarchy/bin/omarchy-plugin-validate .

# Runtime files only: no plan, mockup, tests or git metadata.
FILES=(manifest.json Panel.qml Service.qml Model.js ProtonVpnIcon.qml README.md)
DIRS=(components backend i18n)

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
for f in "${FILES[@]}"; do [[ -f $f ]] && cp -- "$f" "$stage/"; done
for d in "${DIRS[@]}"; do cp -R -- "$d" "$stage/"; done
find "$stage" -name '__pycache__' -type d -prune -exec rm -rf {} +
if find "$stage" -type l | grep -q .; then echo "refusing to install: symlinks found" >&2; exit 1; fi

# Stage outside the plugins folder: the shell watches it and would try to
# load any sibling directory as a plugin.
mkdir -p "$(dirname "$DEST")"
# Copy beside the old install, then swap, so the plugin folder is never missing.
rm -rf -- "$DEST.new" "$DEST.old"
cp -R -- "$stage" "$DEST.new"
chmod -R go-w "$DEST.new"
if [[ -e "$DEST" ]]; then mv -- "$DEST" "$DEST.old"; fi
mv -- "$DEST.new" "$DEST"
rm -rf -- "$DEST.old"
echo "installed $ID to $DEST"

command -v omarchy-shell >/dev/null && omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
if (( ENABLE )); then
  if omarchy-plugin-list 2>/dev/null | grep -Eq "^[[:space:]]*${ID//./\\.}[[:space:]].*enabled"; then
    echo "$ID already enabled"
  else
    omarchy-plugin-enable "$ID" --section right || echo "enable it with: omarchy plugin enable $ID --section right"
  fi
fi

# The shell keeps compiled components cached across plugin reloads, so an
# update only fully applies after a shell restart.
if (( UPDATE && RESTART )) && command -v omarchy-restart-shell >/dev/null; then
  echo "restarting the shell to load the update"
  omarchy-restart-shell >/dev/null 2>&1 || echo "restart it with: omarchy-restart-shell"
fi
