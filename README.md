# HyperZone

**The thing you always wanted for Hyprland with bigger displays** — a
[Noctalia](https://noctalia.dev) plugin that gives big screens a **zone tiling
layout** (à la PowerToys FancyZones, but automatic) *and* the **real display
editor Noctalia otherwise lacks** — drag monitors around, set resolution, scale
and rotation, all from the plugin's settings.

```
+-----------+-----------------------+
| Zone 1    |  Zone 2 (wide)        |    windows fill zones biggest-first,
+-----------+-----------------------+    Zone 2 & Zone 3 split in two when a
| Zone 3    |                       |    second window lands, and anything past
+-----------+   Zone 4 (big         |    that dwindle-splits the tile under the
|           |     work area)        |    cursor — like Hyprland's default layout.
+-----------+-----------------------+
```

Everything else — other monitors, dialogs, popups, fullscreen — is left to
Hyprland's native behavior.

## Architecture

A single **Python daemon** (`hyperzone.py`, stdlib only) does *all* the logic:
it manages floating windows into zones via Hyprland's IPC, and speaks
**JSON-RPC over stdio** to a thin **Noctalia QML plugin** (`Main.qml` +
`Settings.qml`) that owns it as a child process. The QML is a dumb form — it
renders state and sends RPCs — so the plugin ports to future Noctalia versions
by re-skinning only. The daemon is the single writer of its config file.

| file           | role                                                         |
|----------------|--------------------------------------------------------------|
| `hyperzone.py` | daemon + CLI (`daemon --stdio` for the plugin, bare CLI too)  |
| `Main.qml`     | plugin instance: owns the daemon, RPC client, event mirror   |
| `Settings.qml` | settings page: Displays / Zones / General tabs (inline editors) |
| `hzctl.py`     | fast keybind client (Hyprland binds call this)               |
| `manifest.json`| Noctalia plugin manifest                                     |
| `install.sh`   | copy-install into `~/.config/noctalia/plugins/hyperzone`     |

## Install

```sh
bash install.sh            # copy-install the plugin (recommended)
bash install.sh --link     # symlink instead (dev; needs the source drive present)
```

We **copy** (not symlink) by default: the source may live on a removable mount,
and Noctalia launches the daemon from the plugin dir — a login must never depend
on that drive.

Then, one time:
1. Remove the old daemon autostart from `~/.config/hypr/hyprland.lua` (the plugin
   owns the daemon now) — delete the `hl.exec…hyperzone.py daemon` line.
2. **Noctalia → Settings → Plugins → Installed → enable "HyperZone"** (a shell
   restart may be needed for it to appear). The daemon starts automatically.

Keybinds stay in your Hyprland config and call `hzctl.py`:

```lua
local hz = "python3 -S ~/.local/bin/hzctl.py"
hl.bind(mainMod .. " + T",           hl.dsp.exec_cmd(hz .. " toggle-float"))
hl.bind(mainMod .. " + SHIFT + T",   hl.dsp.exec_cmd(hz .. " rearrange"))
hl.bind(mainMod .. " + CTRL + left", hl.dsp.exec_cmd(hz .. " move left"))   -- +right/up/down
-- Mouse: Super+drag moves a window; the LAST modifier pressed during the drag
-- decides what the drop does (border colour = current intent):
--   Super -> snap into zone | +Ctrl -> leave floating | +Shift -> back to tiling
-- Nothing is applied until you let go, so a drag can cross any number of screens
-- (managed or not) without the window being re-slotted out from under the cursor.
-- Hyprland ends a drag on EVERY key event and only a PRESS bind can restart one,
-- so each modifier press takes the drag straight back in the same input event.
-- (dispatchers are not callable from a Lua callback — hl.dispatch() fires them)
local hzDragging, hzMods = false, {}
local hzGrab = hl.dsp.window.drag()
local hzDrop = hl.dsp.exec_cmd(hz .. " drag-drop")
hl.bind("mouse:272", function()             -- fires whatever mods are still held,
    if hzDragging then hzDragging = false; hl.dispatch(hzDrop) end  -- drop never lost
end, { release = true, ignore_mods = true, non_consuming = true })
local dragCombos = { [""] = "snap", [" + CTRL"] = "float",
                     [" + SHIFT"] = "tile", [" + CTRL + SHIFT"] = "both" }
for mods, intent in pairs(dragCombos) do
    local hzStart = hl.dsp.exec_cmd(hz .. " drag-start " .. intent)
    hl.bind(mainMod .. mods .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
    hl.bind(mainMod .. mods .. " + mouse:272",
            function() hzDragging = true; hl.dispatch(hzStart) end)
    for key, which in pairs({ Control_L = "ctrl", Control_R = "ctrl",
                              Shift_L = "shift",  Shift_R = "shift" }) do
        local hzDown = hl.dsp.exec_cmd(hz .. " drag-mod " .. which .. "-down")
        local hzUp   = hl.dsp.exec_cmd(hz .. " drag-mod " .. which .. "-up")
        hl.bind(mainMod .. mods .. " + " .. key, function()
            if hzDragging and not hzMods[key] then
                hl.dispatch(hzGrab); hl.dispatch(hzDown)   -- take the drag back
            end
            hzMods[key] = true
        end, { non_consuming = true })
        hl.bind(mainMod .. mods .. " + " .. key, function()
            hzMods[key] = false
            if hzDragging then hl.dispatch(hzUp) end
        end, { release = true, non_consuming = true })
    end
end
```

## The settings UI

**Displays** — every monitor drawn true-to-scale on a canvas; **drag to
arrange** (edges snap), pick **resolution/refresh, scale, rotation**, and toggle
**"Managed"** per screen. *Apply* reconfigures your displays for real (HyperZone
writes a generated `monitors.lua` and reloads Hyprland) with a **15-second
confirm-or-revert**: if you don't click *Keep*, the daemon restores the previous
layout on its own — a bad mode can't strand you. A one-time **Migrate** button
moves your existing `hl.monitor` blocks out of `hyprland.lua` into the generated
file (timestamped backup kept).

**Zones** — per managed monitor, choose **2 or 4 zones** and drag the **divider
lines** to any split (25/75, 33/66, 50/50…). A reorder list sets the **fill
order** (top = first) and each row's checkbox marks a zone **subdividable** (it
splits in two when a second window lands there); a second list orders which
subdividable zone fills first.

**General** — new-window adopt delay, never-tile window classes, floating border
colors.

## Configuration

The UI writes `~/.config/hyperzone/config.json` (the daemon is the only writer).
You can also hand-edit it. Per-monitor divider form:

```json
{
  "managed": {
    "HDMI-A-1": {
      "enabled": true,
      "layout": { "zones": 4, "vsplit": 0.3333, "hsplit": 0.3333,
                  "fill": [3, 2, 1, 0], "subdivide": [1, 2] }
    }
  },
  "deny_classes": ["pavucontrol"],
  "border_float": "rgb(e5a50a)",
  "adopt_delay": 0.05
}
```

Canonical zone indices — 2 zones: `0`=Left, `1`=Right; 4 zones: `0..3` =
top-left, top-right, bottom-left, bottom-right (= Zone 1–4). `fill` is the
whole-zone fill order, `subdivide` the zones that split (in subdivision-fill
order). The legacy explicit-`cells` form is still accepted. Set `HYPERZONE_OFF=1`
to disable the daemon.

## Troubleshooting

- `tail -f $XDG_RUNTIME_DIR/hyperzone.log` — every decision is logged.
- Disabling the plugin stops the daemon; re-enabling takes over any stale one.
- Display rescue from a TTY: `cp ~/.config/hypr/monitors.lua.good ~/.config/hypr/monitors.lua && hyprctl reload`.
- If the daemon is down, keybinds degrade to native Hyprland actions.
