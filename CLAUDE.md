# HyperZone — working notes for Claude

Zone-tiling daemon for Hyprland, packaged as a **Noctalia 4 plugin** that also acts
as a drag-and-drop display editor. Single-file Python daemon (stdlib only) + thin QML.

## Layout & source of truth

- **Repo (edit here):** `/media/DEV/Scripts/Linux/Hyperzone/`
  - `hyperzone.py` — the daemon: ALL logic (tiling, config, JSON-RPC, display apply).
  - `Main.qml` — plugin instance: owns the daemon as a child `Process`, JSON-RPC client.
  - `Settings.qml` — settings pane (thin form over the daemon; inline sub-components).
  - `manifest.json`, `install.sh`, `hzctl.py`, `README.md`.
- **Installed plugin (what actually runs):** `~/.config/noctalia/plugins/hyperzone/`
  - The plugin loads QML and spawns the daemon **from here**, not from the repo.
  - `/media/DEV` is an ntfs3 `nofail` (removable) drive → **copy-install, never symlink**
    (login must not depend on the drive; the daemon must not run off it).

## Deploy (after editing the repo)

Copy the changed files into the installed plugin dir, then restart Noctalia (below):

```bash
SRC=/media/DEV/Scripts/Linux/Hyperzone; DST=~/.config/noctalia/plugins/hyperzone
python3 -c "import ast; ast.parse(open('$SRC/hyperzone.py').read())"   # syntax gate
cp "$SRC/Settings.qml" "$SRC/hyperzone.py" "$SRC/Main.qml" "$SRC/manifest.json" "$DST/"
# verify parity
for f in Settings.qml hyperzone.py Main.qml manifest.json; do diff -q "$SRC/$f" "$DST/$f"; done
```

`install.sh` does the same copy-install (+ `hzctl.py` → `~/.local/bin`). Use it for a
full install; a targeted `cp` of changed files is fine during iteration.

## Restarting Noctalia to test — READ THIS, it has teeth

The plugin's QML is **compiled/loaded once when `qs` starts**; editing files on disk does
NOT hot-reload it. You must restart the `qs` (Quickshell) process. Gotchas that have
burned us:

1. **The process arg is `qs -c noctalia-shell`, NOT `/usr/bin/qs ...`.** `pgrep`/`kill`
   patterns matching `/usr/bin/qs` silently match nothing → "restart" is a no-op and you
   keep testing the old build. Match `qs -c noctalia-shell` or kill by PID.
2. **`pkill -f "qs -c noctalia-shell"` also matches THIS shell's own command line**
   (the string is in your bash `eval`), so it kills your own tool call (exit 144) before
   the relaunch runs. Kill by explicit PID instead.
3. **Nothing auto-restarts it** — the login `qs` runs in a plain `session-NN.scope`, not a
   systemd service. If you kill it you MUST relaunch it yourself or the user loses their bar.
4. **Launch detached or it dies with your tool call.** `setsid -f` / `hyprctl dispatch exec`
   are unreliable here (Hyprland uses a Lua config → `dispatch exec "..."` errors). Use a
   transient **systemd user unit** — it reparents cleanly and survives.
5. Clear the QML disk cache when in doubt: `rm -rf ~/.cache/noctalia-qs/qmlcache`.

Reliable restart sequence:

```bash
rm -rf ~/.cache/noctalia-qs/qmlcache
PID=$(pgrep -f "qs -c noctalia-shell" | head -1); kill "$PID"; sleep 2   # kills bar + daemon
systemd-run --user \
  --setenv=WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
  --setenv=HYPRLAND_INSTANCE_SIGNATURE="$HYPRLAND_INSTANCE_SIGNATURE" \
  --setenv=XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" --setenv=DISPLAY="$DISPLAY" \
  --unit=noctalia-manual-restart --collect  qs -c noctalia-shell
sleep 5
ps -eo pid,lstart,args | grep "qs -c noctalia-shell" | grep -v grep   # start time must be ~now
pgrep -af "hyperzone.py daemon"                                        # daemon respawned
journalctl --user -u noctalia-manual-restart --since "40 sec ago" | grep -iE "error|Settings.qml"
```

Verify the qs **start time is fresh** — if it predates your edit, the restart didn't take.
The bar disappears for ~2–5 s during the restart; that's expected. The user normally starts
Noctalia via their Hyprland autostart, so the transient unit is only for our test cycle.

## Display apply mechanism (why it's `eval`, not `keyword`)

Hyprland here uses the **Lua / non-legacy config parser** (`~/.config/hypr/hyprland.lua`,
`hl.monitor{...}`). Consequences:
- `hyprctl keyword monitor ...` → rejected: *"keyword can't work with non-legacy parsers.
  Use eval."*
- `hyprctl dispatch exec "qs ..."` → Lua syntax error (`hl.dispatch(...)` wrapping).
- **Apply displays LIVE** via `eval`: `hypr_request('eval hl.monitor({output="DP-3",
  mode="3840x2160@120.00", position="1920x0", scale="1", transform=N})')` → returns `ok`,
  applies instantly, no reload, no migration needed. This is `_apply_live_specs()` in the daemon.
- Migration (`migrate_hyprland_config`) is **optional** — it only moves monitor blocks into a
  generated `~/.config/hypr/monitors.lua` so edits survive a config reload. Live apply works
  without it (runtime-only until reload).
- Confirm-or-revert is daemon-enforced (15 s timer in `tick()`): revert re-applies the
  snapshotted `layout_prev_specs`. Safe even if the UI dies.

## Git / push

Remote is HTTPS with no stored creds; SSH keys aren't set up. Push works via the GitHub CLI:
`gh auth setup-git` (once) then `git push origin main`. Solo repo — commits go straight to `main`.

## Architecture rule

Keep ALL logic in `hyperzone.py`; QML stays a thin form (so it ports to future Noctalia by
re-skinning only). The daemon is the single writer of `~/.config/hyperzone/config.json` and
speaks JSON-RPC over stdio (plugin) alongside its control socket (hzctl keybinds).
