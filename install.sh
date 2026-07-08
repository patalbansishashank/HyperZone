#!/usr/bin/env bash
# Install HyperZone as a Noctalia plugin.
#
#   Source of truth : this folder (edit + version-control here)
#   Plugin runtime  : ~/.config/noctalia/plugins/hyperzone/   (Noctalia loads + runs from here)
#   Keybind client  : ~/.local/bin/hzctl.py                    (fast path for Super+... keys)
#
# We COPY into the plugin dir by default (not symlink): this source folder may live
# on a removable / nofail mount, and Noctalia launches the tiling daemon from the
# plugin dir — a login must never depend on that drive being present.
#
# Usage:
#   bash install.sh           # copy-install (recommended)
#   bash install.sh --link    # symlink instead (dev iteration; accepts mount risk)
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/noctalia/plugins/hyperzone"
BIN_DIR="$HOME/.local/bin"
LINK=0
[[ "${1:-}" == "--link" ]] && LINK=1

echo "── HyperZone install ─────────────────────────────"

# 1) never ship a broken daemon/client
for f in hyperzone.py hzctl.py; do
  if ! python3 -c "import ast; ast.parse(open('$SRC/$f').read())"; then
    echo "✗ syntax error in $f — aborting, nothing installed"; exit 1
  fi
done
echo "✓ python syntax OK"

# 2) retire any pre-plugin daemon (old autostart / pre-RPC build that a takeover
#    can't shut down cleanly). The plugin will start a fresh one when enabled.
pkill -f 'hyperzone\.py daemon' 2>/dev/null || true

# 3) plugin dir
mkdir -p "$(dirname "$PLUGIN_DIR")" "$BIN_DIR"
if [[ "$LINK" == 1 ]]; then
  rm -rf "$PLUGIN_DIR"
  ln -sfn "$SRC" "$PLUGIN_DIR"
  echo "✓ linked  $PLUGIN_DIR -> $SRC   (dev mode)"
else
  mkdir -p "$PLUGIN_DIR"
  # copy the plugin payload (skip dev/build cruft); keep settings.json (user data)
  for item in manifest.json Main.qml Settings.qml hyperzone.py README.md components i18n; do
    [[ -e "$SRC/$item" ]] && cp -r "$SRC/$item" "$PLUGIN_DIR/"
  done
  echo "✓ copied plugin -> $PLUGIN_DIR"
fi

# 4) keybind fast-path client on local disk (Hyprland binds call this)
install -m 755 "$SRC/hzctl.py" "$BIN_DIR/hzctl.py"
echo "✓ installed hzctl.py -> $BIN_DIR/hzctl.py"

cat <<EOF

Done. Two one-time steps to finish:

  1) Remove the old autostart from ~/.config/hypr/hyprland.lua (the plugin owns
     the daemon now). Delete the line that runs:
         hl.exec_cmd("python3 .../hyperzone.py daemon")   (or hl.exec_once)

  2) In Noctalia → Settings → Plugins → Installed, enable "HyperZone".
     The tiling daemon starts automatically; open the plugin's settings (gear)
     to manage displays and zones. Displays can be migrated from there.

Keybinds (Hyprland) still call hzctl.py, e.g.:
     bind = SUPER, T, exec, python3 -S ~/.local/bin/hzctl.py toggle-float
EOF
