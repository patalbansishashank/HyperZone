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

## Keybinds (plugin-managed, live-registered)

The HyperZone shortcuts are owned by the daemon, editable from the settings **Keybinds** tab,
not hand-written in hyprland.lua anymore. Config lives in `config.json` under `keybinds`
(`action-id → ["SUPER + CTRL + left", …]`); `KEYBIND_CMDS`/`DEFAULT_KEYBINDS` in the daemon
map ids to hzctl invocations and seed the defaults.
- **Register/unregister LIVE via `eval`** (hl.bind is NOT a dispatcher, so `hbatch`'s
  `/dispatch` wrapper can't carry it — and `hyprctl dispatch 'hl.bind(...)'` errors on the
  outer `hl.dispatch`). Use `hypr_request('eval hl.bind("SUPER + CTRL + left",
  hl.dsp.exec_cmd("…hzctl.py move left"))')` → `ok`. Unbind: `eval hl.unbind("SUPER + CTRL + left")`.
- Re-binding the same chord **duplicates** (both fire) — to change a bind you must `hl.unbind`
  then `hl.bind`. `register_keybinds()` diffs desired vs `self.active_binds` and only touches
  the delta; `initial=True` (startup) unbinds-then-binds every combo to clear any hyprland.lua
  duplicate still loaded in the running instance.
- `binds -j` shows Lua-registered binds with a **numeric `arg`** (a Lua callback ref), not the
  command string — filter by `modmask`/`key`, not by `arg`. modmask: SHIFT=1 CTRL=4 SUPER=64
  (so SUPER+CTRL=68, SUPER+SHIFT=65, SUPER+CTRL+SHIFT=69).
- **Press-to-capture** in the settings UI: a `KeybindRecorder` inline component records the pressed
  chord (handles Super/Meta, emits `"SUPER + CTRL + left"` form). Because Hyprland fires bound chords
  globally (Super+← would trigger our focus bind, not reach the popup), recording calls the daemon's
  `set_capture_mode` RPC which **unbinds all live binds** for the duration, then re-registers on
  stop — with a `CAPTURE_MODE_TIMEOUT` backstop in `tick()` so a UI that dies mid-record can't leave
  keys dead. It also sets `PanelService.isKeybindRecording` so the panel's own key handlers stand
  down. (Noctalia's built-in `NKeybindRecorder`/`getKeybindString` is unusable here — it drops the
  Super modifier entirely.)
- **`effective_config` returns the MERGED keybinds** (`KEYBINDS`), never the raw saved set — so
  actions added in a newer build (focus-*) show up in the UI even when config.json predates them.
  (Was `setdefault`, which left an existing on-disk `keybinds` untouched → focus binds invisible.)
- `migrate_keybinds()` comments the hand-written HyperZone *keyboard* binds out of hyprland.lua
  once (marker `-- hyperzone-managed keybinds`, backup `hyprland.lua.hz-kb-backup`), leaving the
  **mouse drag-binds** (snap-drop/float-drop) and every non-HyperZone bind alone. Matches the
  hzctl verb right after `hyperzone .. "`. Runs on stdio startup; the running instance is deduped
  separately by `register_keybinds(initial=True)`.
- `push <dir>` (Super+Ctrl+Shift+arrows) = move within the screen, spill to the adjacent monitor
  at the edge (`cmd_move` now returns whether it moved; `cmd_push` falls through to `cmd_tomon`).
- `tomon` moves by **monitor name** (`hl.window.move({monitor="DP-1"})`) — moving by x/y does NOT
  reassign a floating window's output (Hyprland keeps its old monitor membership).
- **Cross-monitor direction is WINDOW-position aware** (`pick_monitor_in_dir`): the target monitor
  is chosen by the window's own rect with edge-adjacency + perpendicular overlap, so a window in a
  4K screen's TOP crosses to the output beside its top and one in the bottom to the output beside
  its bottom (the old monitor-centre pick sent both to the same place, or skipped intermediate
  monitors). Used by `tomon`, `push`, and `focus`. Falls back to the loose centre-direction pick
  if nothing is edge-adjacent.
- **The LANDING zone on a managed target is aligned too** (`cross_place` + `rank_entry_zones`): a
  window sent to a monitor we tile lands in the zone matching where it came from (top→top,
  bottom→bottom; entered-from-left→left column) instead of blind fill order. `cmd_tomon` records
  `{addr: (mon_name, ranked_zones, deadline)}` where each ranked entry is `(zone_index, aligned)`;
  `place()` consumes it on arrival (the window is still momentarily tiled when `on_moved` reads it,
  so `is_tileable` passes and it adopts). `_place_ranked` prefers zones **aligned** with the window's
  perpendicular half (`aligned` = window centre within the zone's perp span): fills the first empty
  aligned zone whole, else **subdivides** the best-ranked aligned one — so a top-origin window stays
  top even when the top is full and the bottom is EMPTY (and bottom stays bottom), never the
  nice/overflow default that fills the top first. Expires after `CROSS_PLACE_TIMEOUT`; pruned in
  `tick()` and on closewindow.
- `focus <dir>` (Super+arrows / HJKL) is layout-aware too: same-screen → native `hl.dsp.focus`
  (instant, handles floating/groups); at the screen edge → cross to `pick_monitor_in_dir` and land
  on the aligned `_entry_window` there (or `focus({monitor=…})` if that screen is empty). Focus
  dispatch keys: `hl.dsp.focus({direction=…|window="address:…"|monitor="NAME"})` (it's ONE function,
  not a namespace — `hl.dsp.focus.window` does not exist). migrate_keybinds also comments the native
  directional-focus binds out of hyprland.lua (workspace-focus binds have `workspace=` not
  `direction`, so they stay); it now re-scans each startup so upgrades pick up newly-owned actions.
- **retile is gentle; rearrange is the reset.** `retile(force=False)` (Re-tile button, Super+Shift+R,
  and config Apply) KEEPS the current arrangement — `reseed()` preserves each tracked window's zone
  and retile only re-asserts geometry (undo drift) + adopts untracked windows. It must NOT wipe the
  trees (the old bug: the non-force path did `mon.trees = [None]*…` then re-placed everyone in fill
  order, reshuffling hand-placed windows). Only `force=True` (rearrange, Super+Shift+T) wipes, clears
  `detached`, and re-grabs every window incl. floating ones.
- **Apply (`set_config`) only re-tiles when the layout actually changed** — it compares `_tiling_sig()`
  (managed set + each monitor's compiled zones/fill/nice/enabled) before vs after, and skips the
  retile entirely for keybind/deny/border edits. When it does retile, it's the gentle one. (Was an
  unconditional `retile(force=True)` on every Apply → reshuffled windows on any settings change.)

## Git / push

Remote is HTTPS with no stored creds; SSH keys aren't set up. Push works via the GitHub CLI:
`gh auth setup-git` (once) then `git push origin main`. Solo repo — commits go straight to `main`.

## Architecture rule

Keep ALL logic in `hyperzone.py`; QML stays a thin form (so it ports to future Noctalia by
re-skinning only). The daemon is the single writer of `~/.config/hyperzone/config.json` and
speaks JSON-RPC over stdio (plugin) alongside its control socket (hzctl keybinds).
