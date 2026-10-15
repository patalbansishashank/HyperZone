# HyperZone for Noctalia 5

The Noctalia 5 port of the HyperZone plugin. The daemon is the same `hyperzone.py` the Noctalia 4 plugin uses (one directory up); this directory only holds the v5 skin over it. The v4 files (`Main.qml`, `Settings.qml`, `manifest.json`) are untouched and still work on Noctalia 4.

## Install (development)

```sh
ln -sfn /media/DEV/Scripts/Linux/Hyperzone/v5 ~/.local/share/noctalia/plugins/hyperzone
noctalia msg plugins enable shashank/hyperzone
```

Enabling the plugin starts the daemon; a daemon that is already running (a stray standalone one, or the v4 plugin's) hands the control socket over and exits. Keybinds are unchanged: the daemon registers them live and they call `~/.local/bin/hzctl.py` exactly as before.

## Entries

| entry | id | what it does |
|-------|----|--------------|
| service | `shashank/hyperzone:daemon` | Owns the daemon: runs `hyperzone.py daemon --events --overlay overlay.py` through `noctalia.runStream`, mirrors its state into `noctalia.state`, turns its events into notifications, restarts it (capped at 5) if it dies. |
| bar widget | `shashank/hyperzone:zones` | Glyph with a tooltip of the tiled screens. Click opens the settings panel, right click re-tiles. |
| panel | `shashank/hyperzone:settings` | The settings UI: Displays, Zones, Keybinds, General, with the Keep / Revert banner for display changes. |

## How it talks to the daemon

The v4 plugin spoke JSON-RPC over the daemon's stdin and stdout. A v5 plugin can read a child's stdout (`runStream`) but cannot write to its stdin, so the daemon has an `--events` mode:

- **Events** go out on stdout, one JSON line each, as in `--stdio` mode. Lines bigger than 48 KiB are sent as `{"refetch": true}` hints, because the host drops a partial line past 64 KiB.
- **Requests** go over the control socket hzctl already uses: `{"rpc": "<method>", "params": {...}}`, answered on the same connection. `hzrpc.py` is the client; it also restores the empty lists Noctalia's Luau JSON encoder turns into `{}`.
- **Lifetime**: the host stops the stream with SIGTERM, which the daemon now handles as a clean stop (state saved). If Noctalia dies without that, the daemon notices it was reparented and stops on its own within two seconds.

## The cursor-pointer arrow

v4 drew the "find my cursor" arrow on a transparent, click-through, full-screen layer above the windows. No v5 plugin surface can do that: panels have a themed background and take input over their whole area, desktop widgets live below the windows, and neither can be positioned at runtime. So the daemon draws it itself through `overlay.py`, a small GTK 4 + gtk4-layer-shell helper (python-gobject, gtk4-layer-shell and python-cairo, all already installed here). It starts on the first use and stays idle afterwards. Turn it off with the plugin's "Draw the cursor pointer arrow" setting.

## Differences from the v4 settings page

- Displays are picked from a row of buttons and positioned with X / Y fields; there is no drag-to-arrange canvas.
- Zone dividers are sliders under a to-scale preview, and fill order uses up / down buttons instead of drag handles.
- Keybinds are typed (`SUPER + CTRL + left`) rather than recorded by pressing them: a panel only receives chords it declared up front, and never Super chords.

## Testing hooks

```sh
noctalia msg plugin shashank/hyperzone:daemon all restart     # restart the daemon
noctalia msg plugin shashank/hyperzone:daemon all retile
noctalia msg panel-toggle shashank/hyperzone:settings
noctalia msg plugin shashank/hyperzone:settings all tab 3     # while the panel is open
python3 hzrpc.py ping                                         # who owns the control socket
```
