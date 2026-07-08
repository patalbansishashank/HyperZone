#!/usr/bin/env bash
# NOTE: For the Noctalia plugin install, use ./install.sh instead — it copies the
# plugin (incl. the daemon) into ~/.config/noctalia/plugins/hyperzone and lets
# Noctalia own the daemon. This deploy.sh remains only for standalone/dev use of
# the bare daemon (daemon started by hand or a Hyprland exec).
#
# Deploy hyperzone from this Scripts source folder to the local runtime.
#
#   Source of truth : /media/DEV/Scripts/Linux/Hyperzone/   (edit here, version here)
#   Runtime         : ~/.local/bin/               (what actually runs — always
#                                                   on local disk, so a login
#                                                   never depends on this drive)
#
# Usage:  bash deploy.sh            # deploy + restart the daemon
#         bash deploy.sh --no-run   # deploy files only, don't touch the daemon
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.local/bin"
FILES=(hyperzone.py hzctl.py)

mkdir -p "$DEST"

# 1) syntax-check before deploying anything (never ship a broken daemon)
for f in "${FILES[@]}"; do
  if ! python3 -c "import ast; ast.parse(open('$SRC/$f').read())"; then
    echo "✗ syntax error in $f — aborting, nothing deployed"; exit 1
  fi
done

# 2) copy to the local runtime
for f in "${FILES[@]}"; do
  install -m 755 "$SRC/$f" "$DEST/$f"
  echo "✓ deployed $f -> $DEST/$f"
done

# 3) restart the daemon from the local copy (unless --no-run)
if [[ "${1:-}" != "--no-run" ]]; then
  for p in $(ps -eo pid=,comm=,args= | awk '$2=="python3" && /hyperzone\.py daemon/ {print $1}'); do
    kill "$p" 2>/dev/null || true
  done
  sleep 0.5
  setsid python3 "$DEST/hyperzone.py" daemon </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
  sleep 1.2
  # strict match (same as the kill loop): pgrep -f would also match this very
  # script's command line and report a bogus pid
  DPID="$(ps -eo pid=,comm=,args= | awk '$2=="python3" && /hyperzone\.py daemon/ {print $1; exit}')"
  if [[ -n "$DPID" ]]; then
    echo "✓ daemon restarted (pid $DPID), managing from $DEST"
  else
    echo "✗ WARNING: daemon did not come up — check $XDG_RUNTIME_DIR/hyperzone.log"
  fi
fi
