#!/usr/bin/env python3
"""hyperzone — a small, layout-engine-independent tiling manager for Hyprland.

It manages *floating* windows on selected monitors so they behave like a custom
auto-tiling layout: new windows fill priority-ordered zones (big zone first),
zones subdivide dwindle-style once full, and closing a window reflows the rest.

Why floating: "one window in the big zone, the others empty" is impossible with
native tiling (native layouts never leave empty space). Managing floating windows
with exact pixel rects is the only way to get empty-until-filled zones, and it
keeps us off Hyprland internals — we only use the most stable IPC: the documented
event socket (.socket2.sock) for events and `hyprctl dispatch` to float/move/resize
windows by address. That makes it robust across Hyprland updates and across
whatever native layout the *other* monitors use.

Run as:
    hyperzone.py daemon            # long-running; autostarted from hyprland.lua
    hyperzone.py <cmd> [arg]       # keybind helper; forwards to the daemon
        move <left|right|up|down>   # move focused window within its screen
        tomon <left|right|up|down>  # send focused window to the next monitor
        toggle-float                # detach (free float) / re-attach focused window
        snap-drop                   # (on drag release) snap window into cursor's zone
        float-drop                  # (on drag release) leave window free-floating
        retile                      # re-adopt & relayout tracked windows
        rearrange                   # hard reset: re-tile EVERY window on the screen
        dump                        # log the current layout state (debugging)

Configuration: built-in defaults below, optionally overridden by
~/.config/hyperzone/config.json (see load_user_config for the schema).
Set HYPERZONE_OFF=1 to disable the daemon entirely.
"""
import json
import os
import re
import selectors
import shutil
import socket
import subprocess
import sys
import time

# ───────────────────────── configuration ─────────────────────────
# Effective gaps, borrowed live from the Hyprland config (see refresh_gaps).
# Hyprland reports window at/size as the *content* (border drawn outside), so to
# match native tiling the content must be inset by the border too:
#   GAP_OUT (content -> screen edge)                  = gaps_out + border_size
#   GAP_IN  (per-side inset; 2*GAP_IN between windows) = gaps_in  + border_size
GAP_OUT = 11         # = gaps_out(8) + border(3); overwritten from config at start
GAP_IN = 8           # = gaps_in(5)  + border(3); 2*GAP_IN = gap between windows
# Border outline colours. Free-floating windows get amber so it's obvious which
# ones hyperzone is NOT tiling. Managed windows are repainted the CONFIG colour
# (read live in refresh_borders) — never "reset"/"unset", which don't restore it.
# BORDER_MANAGED* is None until read from config; the feature stays off if unread.
BORDER_FLOAT = "rgb(e5a50a)"          # amber (active)
BORDER_FLOAT_INACTIVE = "rgb(6b4d00)"  # dim amber (inactive)
BORDER_MANAGED = None
BORDER_MANAGED_INACTIVE = None
ADOPT_DELAY = 0.05        # s to let a new window settle before deciding to tile it.
                          # Real dialogs already report floating on their first frame
                          # (is_tileable rejects them), so this only needs to absorb a
                          # one-frame lag — kept tiny so tiling feels instant.
KILL_ENV = "HYPERZONE_OFF"   # set this env to 1 to disable management
# Window classes that should never be tiled. A denied window is floated (and
# centred) when it opens instead of being adopted. Deliberately minimal by
# default — the user curates this list in the plugin settings.
DENY_CLASSES = {"galculator", "org.gnome.Calculator"}

# Managed monitors: four zones. Zone 1 and Zone 4 hold a single window each.
# Zone 2 and Zone 3 hold one window WHOLE, or split into two halves when a second
# window lands there. We fill all four zones whole first (fill order), and only
# subdivide once every zone is occupied (split order). So a lone window in Zone 2
# or Zone 3 gets the whole zone; you only lose space when you actually need it.
# Each cell is a monitor-relative design-space rect (x, y, w, h).
#
#   +-----------+-----------------------+           whole:        split:
#   | Zone 1    |  Zone 2 (whole)       |   Zone 2  [   one   ]  [ L | R ]
#   +-----------+-----------------------+   Zone 3  [  one  ]    [ top   ]
#   | Zone 3    |                       |           [       ]    [ bot   ]
#   +-----------+   Zone 4 (big work    |
#   |           |       area)           |
#   +-----------+-----------------------+
# MANAGED (the zero-config default) is derived from DEFAULT_LAYOUT below, after
# compile_layout is defined — one source of truth for the built-in zone shapes.
MANAGED = {}

RUNTIME = os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid())
HIS = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
EVENT_SOCK = f"{RUNTIME}/hypr/{HIS}/.socket2.sock"
CTRL_SOCK = f"{RUNTIME}/hyperzone.sock"
LOG_PATH = f"{RUNTIME}/hyperzone.log"
STATE_PATH = f"{RUNTIME}/hyperzone-state.json"
VERSION = "2.0.0"
_CFG_HOME = os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config"))
CONFIG_PATH = os.path.join(_CFG_HOME, "hyperzone", "config.json")
HYPRLAND_LUA = os.path.join(_CFG_HOME, "hypr", "hyprland.lua")
MONITORS_LUA = os.path.join(_CFG_HOME, "hypr", "monitors.lua")
MIGRATE_MARKER = "-- hyperzone-managed monitors"

# The raw user config exactly as written to config.json (source form, NOT the
# compiled cells). The settings UI reads/writes THIS via RPC so the divider model
# round-trips losslessly. Empty when no config file exists.
USER_CONFIG = {}

# Divider layout that reproduces the built-in default (Zone 1..4 = TL,TR,BL,BR;
# left column 33%, top row 33%; fill Zone4->3->2->1; Zone 2 & 3 subdivide).
DEFAULT_LAYOUT = {"zones": 4, "vsplit": 1.0 / 3, "hsplit": 1.0 / 3,
                  "fill": [3, 2, 1, 0], "subdivide": [1, 2]}
LAYOUT_D = 10000        # design-space edge for compiled cells (zone_usable rescales)

SPLIT_MIN, SPLIT_MAX = 0.05, 0.95   # divider clamp (mirrored in Settings.qml setV/setH)

# ── tuning constants (seconds unless noted) ──
# Verify passes re-read settled window geometry to correct drift / learn sizes.
VERIFY_AFTER_CMD = 0.45      # settle re-check after a user command
VERIFY_AFTER_RELOAD = 1.0    # bars re-create late after a reconfigure; re-check insets
VERIFY_CHASE_DELAY = 0.15    # re-read cadence while a window is still settling
VERIFY_CHASE_MAX = 4         # bounded settle-chase iterations
FLUSH_VERIFY_DELAY = 0.12    # first verify after a geometry flush
DRIFT_PX = 4                 # size/pos mismatch at or below this is "settled"
DIR_MARGIN_PX = 10           # dead-band when deciding a directional neighbour
SETTLE_READ_DELAY = 0.5      # Hyprland reports new monitor state ~0.4s after an eval
LEARN_SUPPRESS_APPLY = 3.0   # no minsize learning around a display apply/revert
LEARN_SUPPRESS_RESEED = 2.5  # ... or around a reseed/config reload
REVERT_TIMEOUT = 15.0        # confirm-or-revert deadline for display changes
REARRANGE_DEBOUNCE = 0.3     # ignore rearrange key-repeats inside this window
DENY_PLACE_POLL = 0.05       # re-read a floating deny window's size this often…
DENY_PLACE_MAX_TRIES = 12    # …until it stops changing (settled) or this many reads (~0.6s cap)
FS_INSIST_WINDOW = 1.5       # re-fullscreen within this = app insists; stop fighting
MON_CACHE_TTL = 1.0          # monitors-list micro-cache (also event-invalidated)
CROSS_PLACE_TIMEOUT = 2.0    # honour a cross-monitor move's aligned-zone intent this long
CAPTURE_MODE_TIMEOUT = 20.0  # auto-restore binds if the UI's key-capture never resumes them


def _clampf(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def compile_layout(layout):
    """Compile a divider-model layout into {cells, fill, nice}. Canonical cell
    order — zones=2: [Left, Right]; zones=4: [TL, TR, BL, BR] (= Zone 1,2,3,4).
    Cells live in a fixed square design space; zone_usable() rescales them to the
    monitor, so the same layout fits any resolution/aspect. `fill`/`subdivide`
    index the canonical cells; `subdivide` becomes `nice` (zones that split to two)."""
    D = LAYOUT_D
    zones = int(layout.get("zones", 4))
    vx = round(_clampf(float(layout.get("vsplit", 1.0 / 3)), SPLIT_MIN, SPLIT_MAX) * D)
    if zones == 2:
        cells = [(0, 0, vx, D), (vx, 0, D - vx, D)]
    else:
        hy = round(_clampf(float(layout.get("hsplit", 1.0 / 3)), SPLIT_MIN, SPLIT_MAX) * D)
        cells = [(0, 0, vx, hy), (vx, 0, D - vx, hy),
                 (0, hy, vx, D - hy), (vx, hy, D - vx, D - hy)]
    fill = [int(i) for i in layout.get("fill", range(zones))]
    nice = [int(i) for i in layout.get("subdivide", [])]
    return {"cells": cells, "fill": fill, "nice": nice}


# Built-in default when no config.json exists: manage HDMI-A-1 with the standard
# four-zone layout. Same compile path as user configs, so there is exactly one
# definition of the default zone shapes (DEFAULT_LAYOUT above).
MANAGED = {"HDMI-A-1": compile_layout(DEFAULT_LAYOUT)}

# ── keybinds (plugin-managed, registered live via `eval hl.bind`) ──
# Each action maps to the hzctl invocation it runs. The daemon binds/unbinds the
# user's chosen key combos at runtime (register_keybinds), so they are editable
# from the plugin settings with no hyprland.lua round-trip. A combo is a Hyprland
# bind string, e.g. "SUPER + CTRL + left". The settings UI edits KEYBINDS via the
# normal set_config path; defaults below reproduce the hand-written binds that
# hyprland.lua used to carry (which migrate_keybinds() then comments out).
HZCTL_CMD = "python3 -S " + os.path.join(
    os.environ.get("HOME") or os.path.expanduser("~"), ".local", "bin", "hzctl.py")
KEYBIND_CMDS = {
    "focus-left": "focus left", "focus-right": "focus right",
    "focus-up": "focus up", "focus-down": "focus down",
    "move-left": "move left", "move-right": "move right",
    "move-up": "move up", "move-down": "move down",
    "tomon-left": "tomon left", "tomon-right": "tomon right",
    "tomon-up": "tomon up", "tomon-down": "tomon down",
    "push-left": "push left", "push-right": "push right",
    "push-up": "push up", "push-down": "push down",
    "swap-left": "swap left", "swap-right": "swap right",
    "swap-up": "swap up", "swap-down": "swap down",
    "toggle-float": "toggle-float", "rearrange": "rearrange", "retile": "retile",
}
DEFAULT_KEYBINDS = {
    "focus-left": ["SUPER + left", "SUPER + H"],
    "focus-right": ["SUPER + right", "SUPER + L"],
    "focus-up": ["SUPER + up", "SUPER + K"],
    "focus-down": ["SUPER + down", "SUPER + J"],
    "move-left": ["SUPER + CTRL + left", "SUPER + CTRL + H"],
    "move-right": ["SUPER + CTRL + right", "SUPER + CTRL + L"],
    "move-up": ["SUPER + CTRL + up", "SUPER + CTRL + K"],
    "move-down": ["SUPER + CTRL + down", "SUPER + CTRL + J"],
    "tomon-left": ["SUPER + SHIFT + left"],
    "tomon-right": ["SUPER + SHIFT + right"],
    "tomon-up": ["SUPER + SHIFT + up"],
    "tomon-down": ["SUPER + SHIFT + down"],
    "push-left": ["SUPER + CTRL + SHIFT + left"],
    "push-right": ["SUPER + CTRL + SHIFT + right"],
    "push-up": ["SUPER + CTRL + SHIFT + up"],
    "push-down": ["SUPER + CTRL + SHIFT + down"],
    "swap-left": ["SUPER + ALT + left"],
    "swap-right": ["SUPER + ALT + right"],
    "swap-up": ["SUPER + ALT + up"],
    "swap-down": ["SUPER + ALT + down"],
    "toggle-float": ["SUPER + T"],
    "rearrange": ["SUPER + SHIFT + T"],
    "retile": ["SUPER + SHIFT + R"],
}
KEYBINDS = {k: list(v) for k, v in DEFAULT_KEYBINDS.items()}
KEYBIND_MARKER = "-- hyperzone-managed keybinds"
# verbs whose hand-written hyprland.lua binds we take over (mouse drag-binds
# snap-drop/float-drop are deliberately NOT in this set — they stay in hyprland.lua)
_KB_VERBS = ("focus", "move", "tomon", "push", "swap", "toggle-float", "rearrange", "retile")


def merge_keybinds(user):
    """Full keybind map = defaults overlaid with the user's per-action lists, so an
    action the user never touched keeps its default and one they cleared stays empty."""
    merged = {k: list(v) for k, v in DEFAULT_KEYBINDS.items()}
    if isinstance(user, dict):
        for act, combos in user.items():
            if act in KEYBIND_CMDS and isinstance(combos, list):
                merged[act] = [str(c) for c in combos]
    return merged


def _validate_layout(name, layout):
    if not isinstance(layout, dict):
        raise ValueError("managed.%s.layout must be an object" % name)
    zones = layout.get("zones")
    if zones not in (2, 4):
        raise ValueError("managed.%s.layout.zones must be 2 or 4" % name)
    for k in ("vsplit", "hsplit"):
        if k in layout:
            float(layout[k])          # numeric (clamped at compile time)
    fill = [int(i) for i in layout.get("fill", range(zones))]
    if sorted(fill) != list(range(zones)):
        raise ValueError("managed.%s.layout.fill must be a permutation of 0..%d"
                         % (name, zones - 1))
    sub = [int(i) for i in layout.get("subdivide", [])]
    if len(set(sub)) != len(sub) or any(not 0 <= i < zones for i in sub):
        raise ValueError("managed.%s.layout.subdivide invalid" % name)


def _validate_cells(name, mc):
    cells = mc["cells"]
    if not cells or any(len(c) != 4 for c in cells):
        raise ValueError("managed.%s.cells must be [x,y,w,h] lists" % name)
    n = len(cells)
    for i in [int(x) for x in mc.get("fill", [])] + [int(x) for x in mc.get("nice", [])]:
        if not 0 <= i < n:
            raise ValueError("managed.%s: zone index %d out of range" % (name, i))


def validate_config(cfg):
    """Raise ValueError if cfg is not a well-formed hyperzone config (v2 divider
    form OR legacy cells form). Shared by load_user_config and the set_config RPC,
    so the UI and the file go through exactly the same gate."""
    if not isinstance(cfg, dict):
        raise ValueError("config must be an object")
    managed = cfg.get("managed", {})
    if not isinstance(managed, dict):
        raise ValueError("managed must be an object")
    for name, mc in managed.items():
        if not isinstance(mc, dict):
            raise ValueError("managed.%s must be an object" % name)
        if "enabled" in mc and not isinstance(mc["enabled"], bool):
            raise ValueError("managed.%s.enabled must be a bool" % name)
        if "layout" in mc:
            _validate_layout(name, mc["layout"])
        elif "cells" in mc:
            _validate_cells(name, mc)
        # neither -> monitor uses the default layout (allowed, e.g. enabled:false)
    if "deny_classes" in cfg and not all(isinstance(x, str) for x in cfg["deny_classes"]):
        raise ValueError("deny_classes must be a list of strings")
    if "adopt_delay" in cfg and not 0 <= float(cfg["adopt_delay"]) <= 2:
        raise ValueError("adopt_delay must be between 0 and 2")
    for k in ("border_float", "border_float_inactive"):
        if k in cfg and not isinstance(cfg[k], str):
            raise ValueError("%s must be a string" % k)
    if "keybinds" in cfg:
        kb = cfg["keybinds"]
        if not isinstance(kb, dict):
            raise ValueError("keybinds must be an object")
        for act, combos in kb.items():
            if act not in KEYBIND_CMDS:
                raise ValueError("unknown keybind action: %s" % act)
            if not isinstance(combos, list) or not all(isinstance(c, str) for c in combos):
                raise ValueError("keybinds.%s must be a list of strings" % act)


def apply_config(cfg):
    """Validate cfg, then apply it to the module globals. Raises ValueError if
    invalid (globals untouched on failure — validate runs first). Does NOT write
    the file; the caller persists. Compiles each monitor's divider layout into
    cells and carries an `enabled` flag reseed() honours."""
    validate_config(cfg)
    global MANAGED, DENY_CLASSES, BORDER_FLOAT, BORDER_FLOAT_INACTIVE, ADOPT_DELAY
    global KEYBINDS
    if "managed" in cfg:
        managed = {}
        for name, mc in cfg["managed"].items():
            if "layout" in mc:
                compiled = compile_layout(mc["layout"])
            elif "cells" in mc:
                compiled = {"cells": [tuple(int(v) for v in c) for c in mc["cells"]],
                            "fill": [int(i) for i in mc.get("fill", range(len(mc["cells"])))],
                            "nice": [int(i) for i in mc.get("nice", [])]}
            else:
                compiled = compile_layout(DEFAULT_LAYOUT)
            compiled["enabled"] = bool(mc.get("enabled", True))
            managed[name] = compiled
        MANAGED = managed
    if "deny_classes" in cfg:
        DENY_CLASSES = {str(c) for c in cfg["deny_classes"]}
    if "border_float" in cfg:
        BORDER_FLOAT = str(cfg["border_float"])
    if "border_float_inactive" in cfg:
        BORDER_FLOAT_INACTIVE = str(cfg["border_float_inactive"])
    if "adopt_delay" in cfg:
        ADOPT_DELAY = float(cfg["adopt_delay"])
    if "keybinds" in cfg:
        KEYBINDS = merge_keybinds(cfg["keybinds"])


def load_user_config():
    """Load ~/.config/hyperzone/config.json over the built-in defaults, so a
    packaged install works on any machine without editing this file. A missing or
    broken file is logged and ignored (defaults win). See validate_config for the
    schema (v2 divider form + legacy cells both accepted)."""
    global USER_CONFIG
    try:
        with open(CONFIG_PATH) as f:
            cfg = json.load(f)
    except FileNotFoundError:
        USER_CONFIG = {}
        return
    except (OSError, ValueError) as e:
        log("config error (using defaults):", CONFIG_PATH, e)
        return
    try:
        apply_config(cfg)
        USER_CONFIG = cfg
        log("config loaded:", CONFIG_PATH, "managed:", list(MANAGED))
    except (KeyError, TypeError, ValueError) as e:
        log("config invalid (using defaults):", e)


def hyprland_is_migrated():
    """True once hyprland.lua sources the generated monitors.lua (marker present)."""
    try:
        with open(HYPRLAND_LUA) as f:
            return MIGRATE_MARKER in f.read()
    except OSError:
        return False


def generate_monitors_lua(specs):
    """Render monitor specs into hl.monitor({...}) blocks. Each spec:
    {name, mode, x, y, scale, transform} or {name, disabled:true}. `mode` may be an
    availableModes string ('1920x1080@60.00Hz') — the 'Hz' suffix is stripped to the
    'WxH@R' form the Hyprland config parser expects."""
    out = ["-- generated by hyperzone — do not edit by hand",
           "-- (edit displays via Noctalia → HyperZone plugin settings)", ""]
    for m in specs:
        out.append("hl.monitor({")
        out.append('    output = "%s",' % m["name"])
        if m.get("disabled"):
            out.append('    mode = "disable",')
            out += ["})", ""]
            continue
        out.append('    mode = "%s",' % str(m.get("mode", "preferred")).replace("Hz", ""))
        out.append('    position = "%dx%d",' % (int(m.get("x", 0)), int(m.get("y", 0))))
        out.append('    scale = "%s",' % m.get("scale", 1))
        if int(m.get("transform", 0)):
            out.append('    transform = %d,' % int(m["transform"]))
        out += ["})", ""]
    return "\n".join(out) + "\n"


def lua_monitor(spec):
    """Render one monitor spec as an `hl.monitor({...})` Lua call, suitable for
    Hyprland's runtime `eval` endpoint. This is how displays are reconfigured LIVE
    (the Lua/non-legacy config parser rejects `keyword monitor`; `eval` runs the
    same hl.monitor the config would). Instant, no reload, no migration needed."""
    if spec.get("disabled"):
        return 'hl.monitor({output="%s", mode="disable"})' % spec["name"]
    # transform is ALWAYS emitted: at eval time an omitted key means "keep the
    # monitor's current value", so leaving out transform=0 made it impossible to
    # rotate a screen back to normal (verified live: 1 stayed 1 without the key).
    parts = ['output="%s"' % spec["name"],
             'mode="%s"' % str(spec.get("mode", "preferred")).replace("Hz", ""),
             'position="%dx%d"' % (int(spec.get("x", 0)), int(spec.get("y", 0))),
             'scale="%s"' % spec.get("scale", 1),
             "transform=%d" % int(spec.get("transform", 0))]
    return "hl.monitor({%s})" % ", ".join(parts)


def migrate_lua_text(text):
    """Comment out every hl.monitor({...}) block in hyprland.lua and insert a
    `dofile(monitors.lua)` line where the first one was. Pure string transform so
    it is unit-testable. Returns (new_text, n_blocks). Paren-depth scan — safe for
    these configs (monitor values contain no parentheses)."""
    dofile = ('dofile(os.getenv("HOME") .. "/.config/hypr/monitors.lua") %s'
              % MIGRATE_MARKER)
    out, depth, in_block, inserted, n = [], 0, False, False, 0
    for line in text.split("\n"):
        if not in_block and "hl.monitor(" in line:
            if not inserted:
                out += [dofile, ""]
                inserted = True
            in_block = True
            n += 1
        if in_block:
            depth += line.count("(") - line.count(")")
            out.append(("-- " + line) if line.strip() else line)
            if depth <= 0:
                in_block, depth = False, 0
        else:
            out.append(line)
    return "\n".join(out), n


LOG_MAX = 1_000_000     # bytes; the log lives on tmpfs (RAM), so cap it
LOG_CHECK_EVERY = 100   # rotation-size stat once per N lines, not per line
DEBUG = os.environ.get("HYPERZONE_DEBUG", "") == "1"   # per-action trace logging
_log_since_check = 0


def log(*a):
    global _log_since_check
    try:
        _log_since_check += 1
        if _log_since_check >= LOG_CHECK_EVERY:
            _log_since_check = 0
            try:
                if os.path.getsize(LOG_PATH) > LOG_MAX:
                    os.replace(LOG_PATH, LOG_PATH + ".1")   # keep one generation
            except OSError:
                pass
        with open(LOG_PATH, "a") as f:
            f.write("%.3f " % time.time() + " ".join(str(x) for x in a) + "\n")
    except OSError:
        pass


def dlog(*a):
    """Per-action trace (every place/remove/apply/keybind). Off by default —
    it's pure noise in normal operation; set HYPERZONE_DEBUG=1 to enable."""
    if DEBUG:
        log(*a)


# ───────────────────────── hyprland IPC ─────────────────────────
# Talk to Hyprland's request socket directly instead of spawning the hyprctl
# binary (~0.06 ms vs ~3 ms per call — measured 50x). hyprctl itself is just a
# thin client for this same socket, so the protocol is equally stable. Falls
# back to subprocess if the socket ever misbehaves.
REQ_SOCK = f"{RUNTIME}/hypr/{HIS}/.socket.sock"


def hypr_request(payload):
    """Send one request to Hyprland's .socket.sock, return the reply text."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.settimeout(2)
        s.connect(REQ_SOCK)
        s.sendall(payload.encode())
        buf = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
        return buf.decode("utf-8", "replace")
    finally:
        s.close()


def hjson(*cmd):
    try:
        out = hypr_request("j/" + " ".join(cmd))
        return json.loads(out) if out.strip() else None
    except Exception as e:
        log("hjson socket error, subprocess fallback:", cmd, e)
        try:
            out = subprocess.run(["hyprctl", *cmd, "-j"],
                                 capture_output=True, text=True, timeout=2).stdout
            return json.loads(out) if out.strip() else None
        except Exception as e2:
            log("hjson error", cmd, e2)
            return None


def hbatch(exprs):
    """Run several `dispatch <lua>` in one request (atomic batch). Hyprland
    answers one line per dispatch ('ok' or an error message) — log anything
    that isn't ok, so a rejected dispatch never fails silently."""
    if not exprs:
        return
    try:
        out = hypr_request("[[BATCH]]" + ";".join("/dispatch " + e for e in exprs))
        bad = [ln for ln in out.splitlines() if ln.strip() not in ("", "ok")]
        if bad:
            log("hbatch rejected:", bad[:3], "in", exprs[:3])
    except Exception as e:
        log("hbatch socket error, subprocess fallback:", e)
        try:
            subprocess.run(["hyprctl", "--batch",
                            " ; ".join("dispatch " + e for e in exprs)],
                           capture_output=True, text=True, timeout=2)
        except Exception as e2:
            log("hbatch error", e2)


def naddr(a):
    """Normalize an address to 0x-prefixed form (socket2 omits the 0x)."""
    if not a:
        return a
    return a if a.startswith("0x") else "0x" + a


def float_geom_exprs(addr, w, h, x, y):
    """The float→resize→move dispatch triple that pins a window to an exact rect.
    Order matters: float first (resize/move act on the floating window), resize
    before move (resize is centre-anchored; the final move sets the top-left)."""
    sel = "address:" + addr
    return ['hl.dsp.window.float({action="enable", window="%s"})' % sel,
            'hl.dsp.window.resize({x=%d,y=%d, window="%s"})' % (w, h, sel),
            'hl.dsp.window.move({x=%d,y=%d, window="%s"})' % (x, y, sel)]


def logical_rect(m):
    """(x, y, w, h) of a live monitor record in LOGICAL pixels: physical size
    divided by scale, sides swapped when rotated 90°/270°. The one place this
    transform is defined (Monitor.update and cmd_tomon both build on it)."""
    w = m.get("width", 0) / float(m.get("scale") or 1)
    h = m.get("height", 0) / float(m.get("scale") or 1)
    if int(m.get("transform", 0)) % 2:
        w, h = h, w
    return m.get("x", 0), m.get("y", 0), w, h


def _atomic_write(path, content):
    """Write text via a temp file + rename, so a crash can't leave a half file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(content)
    os.replace(tmp, path)


def refresh_gaps():
    """Borrow gaps + border from the live Hyprland config so our spacing matches
    native tiling exactly. Called at startup and on config reload."""
    global GAP_OUT, GAP_IN

    def opt(name, default):
        o = hjson("getoption", "general:" + name) or {}
        if "css" in o:                       # gaps_in/out report as e.g. "5 5 5 5"
            try:
                return int(str(o["css"]).split()[0])
            except (ValueError, IndexError):
                return default
        return o.get("int", default)

    border = opt("border_size", 3)
    GAP_OUT = opt("gaps_out", 8) + border    # content -> screen edge
    GAP_IN = opt("gaps_in", 5) + border      # per-side inset (2*GAP_IN between tiles)
    log("gaps: GAP_OUT=%d GAP_IN=%d (border=%d)" % (GAP_OUT, GAP_IN, border))


def refresh_borders():
    """Read the config's border colours so we can repaint managed windows back to
    the real config colour (explicitly — 'unset' doesn't restore a gradient).
    Colours report as e.g. {"gradient": "ff26a269 45deg"}: take the first hex
    token, use its RRGGBB. If parsing fails the feature disables (colours stay None)."""
    global BORDER_MANAGED, BORDER_MANAGED_INACTIVE

    def color(name):
        o = hjson("getoption", "general:col." + name) or {}
        raw = o.get("gradient") or o.get("custom") or ""
        tok = str(raw).split()[0] if raw else ""
        hexpart = tok[-6:] if len(tok) >= 6 else ""
        return "rgb(%s)" % hexpart if len(hexpart) == 6 else None

    BORDER_MANAGED = color("active_border")
    BORDER_MANAGED_INACTIVE = color("inactive_border")
    log("borders: managed=%s inactive=%s float=%s" %
        (BORDER_MANAGED, BORDER_MANAGED_INACTIVE, BORDER_FLOAT))


# ───────────────────────── geometry / BSP ─────────────────────────
# Each zone holds a binary tree: a leaf {"win": addr} or a split
# {"split": "v"|"h", "ratio", "a", "b"}. "v" divides width (left|right),
# "h" divides height (top|bottom). Zones fill whole first; extra windows
# dwindle-split the focused leaf (Hyprland-style), so no space is wasted.

def leaf(win=None):
    return {"win": win}


def is_leaf(n):
    return "win" in n


def zone_usable(cell, sw, sh, usable):
    """Map a design-space zone cell into the monitor's *usable* rect (full monitor
    minus reserved bar space), then apply gaps. GAP_OUT against a screen/bar edge,
    GAP_IN against an internal boundary. `usable` is (x, y, w, h), monitor-relative.
    """
    ux, uy, uw, uh = usable
    x, y, w, h = cell
    sx, sy = uw / sw, uh / sh                 # scale design space into usable area
    mx, my, mw, mh = ux + x * sx, uy + y * sy, w * sx, h * sy
    l = GAP_OUT if x == 0 else GAP_IN
    t = GAP_OUT if y == 0 else GAP_IN
    r = GAP_OUT if x + w == sw else GAP_IN
    b = GAP_OUT if y + h == sh else GAP_IN
    return (round(mx + l), round(my + t), round(mw - l - r), round(mh - t - b))


def split_rects(node, rect):
    x, y, w, h = rect
    rr = node.get("ratio", 0.5)
    g = 2 * GAP_IN               # full gap between two tiles (same as between zones)
    if node["split"] == "v":
        wa = int(round((w - g) * rr))
        return (x, y, wa, h), (x + wa + g, y, w - wa - g, h)
    ha = int(round((h - g) * rr))
    return (x, y, w, ha), (x, y + ha + g, w, h - ha - g)


def walk(node, rect):
    """Yield (leaf_node, rect) for every leaf under node."""
    if is_leaf(node):
        yield node, rect
        return
    ra, rb = split_rects(node, rect)
    yield from walk(node["a"], ra)
    yield from walk(node["b"], rb)


def count_leaves(node):
    if node is None:
        return 0
    if is_leaf(node):
        return 0 if node["win"] is None else 1
    return count_leaves(node["a"]) + count_leaves(node["b"])


def split_leaf(target, new_win, rect, new_first=False):
    """Turn a leaf into a split of (existing, new), dividing the longer side.
    new_first puts the NEW window in the first half (left/top) instead of the
    second — used to open it on the side the mouse is on, like Hyprland."""
    x, y, w, h = rect
    direction = "v" if w >= h else "h"
    existing = leaf(target["win"])
    fresh = leaf(new_win)
    a, b = (fresh, existing) if new_first else (existing, fresh)
    target.clear()
    target.update({"split": direction, "ratio": 0.5, "a": a, "b": b})


def prune(node, valid):
    """Drop leaves whose addr is not in `valid`; collapse splits accordingly."""
    if node is None:
        return None
    if is_leaf(node):
        return node if node["win"] in valid else None
    a, b = prune(node["a"], valid), prune(node["b"], valid)
    if a is None and b is None:
        return None
    if a is None:
        return b
    if b is None:
        return a
    node["a"], node["b"] = a, b
    return node


def remove_win(node, addr):
    """Remove addr; return replacement node (sibling collapses up)."""
    if node is None:
        return None
    if is_leaf(node):
        return None if node["win"] == addr else node
    a = remove_win(node["a"], addr)
    b = remove_win(node["b"], addr)
    if a is None and b is None:
        return None
    if a is None:
        return b
    if b is None:
        return a
    node["a"], node["b"] = a, b
    return node


# ───────────────────────── monitor state ─────────────────────────
class Monitor:
    """A managed monitor is a fixed set of zones, each holding a BSP tree of
    windows. Zones fill whole first (fill order); Zone 2 and Zone 3 then split
    once (nice order); any further window dwindle-splits the focused leaf."""

    def __init__(self, name, cfg, info):
        self.name = name
        self.cells = cfg["cells"]
        self.fill = cfg["fill"]
        self.nice = cfg["nice"]
        self.sw = max(x + w for (x, y, w, h) in self.cells)
        self.sh = max(y + h for (x, y, w, h) in self.cells)
        self.trees = [None] * len(self.cells)     # zone index -> BSP node | None
        self.update(info)

    def update(self, info):
        """Refresh offset, LOGICAL size and reserved bar space from a live
        monitors record. Hyprland reports width/height in physical pixels;
        layout coordinates are logical (physical / scale, sides swapped when
        rotated) — using the design-space size here instead would silently
        misplace every zone on a scaled or rotated monitor."""
        self.ox, self.oy, lw, lh = logical_rect(info)
        self.lw, self.lh = round(lw), round(lh)
        # Hyprland reserved = [left, top, right, bottom] (exclusive-zone insets).
        self.reserved = info.get("reserved", [0, 0, 0, 0])

    def usable(self):
        rl, rt, rr, rb = self.reserved
        return (rl, rt, self.lw - rl - rr, self.lh - rt - rb)

    def zone_rect(self, zi):
        return zone_usable(self.cells[zi], self.sw, self.sh, self.usable())

    def leaves(self):
        """All (zone_index, leaf_node, monitor_relative_rect) placed."""
        out = []
        for zi, tree in enumerate(self.trees):
            if tree is not None:
                for lf, rect in walk(tree, self.zone_rect(zi)):
                    if lf["win"] is not None:
                        out.append((zi, lf, rect))
        return out

    def leaf_of(self, addr):
        """Return (zone_index, leaf_node, rect) for addr, or None."""
        for zi, tree in enumerate(self.trees):
            if tree is not None:
                for lf, rect in walk(tree, self.zone_rect(zi)):
                    if lf["win"] == addr:
                        return (zi, lf, rect)
        return None

    def has(self, addr):
        return self.leaf_of(addr) is not None

    def dump(self):
        return {zi + 1: [lf["win"] for lf, _ in walk(t, self.zone_rect(zi))]
                for zi, t in enumerate(self.trees) if t is not None}


# ───────────────────────── the manager ─────────────────────────
class HyperZone:
    def __init__(self):
        self.mons = {}              # name -> Monitor
        self.detached = set()       # addrs the user popped to free-float (ignored)
        self.suspended = {}         # addr -> (mon, zone) saved while fullscreen
        self.dirty = set()          # monitor names needing a geometry flush
        self.reconcile_needed = False   # a fullscreen event arrived; reconcile once
        self.unfs_at = {}           # addr -> when we last un-fullscreened it
        self.focused = None         # last-focused managed window (overflow splits it)
        self.painted = set()        # addrs we painted amber (so we only ever repaint
                                    # windows WE touched — pristine ones stay config)
        self.was_managed = set()    # addrs we managed that have since left for an
                                    # UNMANAGED screen. While managed we floated them
                                    # at a ZONE size, which Hyprland now remembers as
                                    # their float geometry — so the FIRST Super+T on
                                    # such a window would wrongly restore a zone size.
                                    # We intercept that one toggle (float at the
                                    # window's real docked size instead) and clear it.
        self.minsize = {}           # class -> [w, h]: LEARNED app minimum size. Apps
                                    # with a min bigger than a zone can't take the
                                    # zone size; if we command it anyway the app's
                                    # async clamp re-commits a different size and the
                                    # window visibly bumps/drifts. Once learned (from
                                    # the settled size in run_verify) we command
                                    # max(zone, min) up front — the app accepts it
                                    # verbatim and the geometry is exact first-pass.
        self.verify_at = None       # deadline of the next verify pass (or None)
        self._verify_chase = 0      # verify chase counter (bounds the settle loop)
        self._last_size = {}        # addr -> size at the previous verify read; a size
                                    # must repeat (stable) before we learn from it
        self._apply_count = 0       # geometry passes done (log/diagnostics only)
        self._mon_cache = (0.0, None)   # (fetched_at, monitors list) micro-cache
        self.reseed()

    def want_size(self, cls, rw, rh):
        """The size to actually command for a tile of (rw, rh): the zone size,
        raised to the app's learned minimum so the app won't re-commit a different
        size afterwards (which is what caused the bump/drift)."""
        ms = self.minsize.get(cls or "")
        if ms:
            return max(rw, ms[0]), max(rh, ms[1])
        return rw, rh

    def reprobe_min(self, addr):
        """Forget an app's learned min-size when the user DELIBERATELY repositions
        the window, so the next placement re-measures against its new zone.

        The min is learned from a window's settled size (run_verify), which can latch
        onto a ONE-TIME size the app isn't actually pinned to -- e.g. VLC resizes
        itself to the video's native width the instant it loads, right as we're
        measuring it. That gets recorded as a hard minimum, and because want_size then
        always commands max(zone, min), the app is never again asked to go smaller, so
        the self-correction in run_verify can't fire: the stale min sticks forever and
        every placement into a narrower zone overflows it.

        A deliberate move (drag-drop, Super+arrow) means the app is done loading and
        the user wants it in THIS zone -- the moment to re-test. Drop the record; if a
        genuine minimum exists, verify simply re-learns it from the new settled size."""
        c = self.client(addr)
        cls = (c or {}).get("class")
        if cls and cls in self.minsize:
            self.minsize.pop(cls, None)
            self.save()
            dlog("reprobe min: cleared", cls)

    def paint(self, addr, floating):
        """Outline addr: amber if free-floating, config colour if managed. Only ever
        repaints a window we previously painted (self.painted), so windows we never
        touched keep their exact config borders. The whole feature is off unless the
        config colour was read (BORDER_MANAGED) — never paint what we can't restore."""
        if floating and BORDER_MANAGED:
            hbatch(['hl.dsp.window.set_prop({window="address:%s", prop="active_border_color", value="%s"})' % (addr, BORDER_FLOAT),
                    'hl.dsp.window.set_prop({window="address:%s", prop="inactive_border_color", value="%s"})' % (addr, BORDER_FLOAT_INACTIVE)])
            self.painted.add(addr)
        elif addr in self.painted and BORDER_MANAGED:
            hbatch(['hl.dsp.window.set_prop({window="address:%s", prop="active_border_color", value="%s"})' % (addr, BORDER_MANAGED),
                    'hl.dsp.window.set_prop({window="address:%s", prop="inactive_border_color", value="%s"})' % (addr, BORDER_MANAGED_INACTIVE or BORDER_MANAGED)])
            self.painted.discard(addr)

    # -- monitor discovery --
    def monitors_cached(self):
        """The live monitors list, memoised for MON_CACHE_TTL. Every window event
        needs this list (managed_monitor_for, apply); it only actually changes on
        hotplug / config reload / our own display applies — all of which call
        invalidate_monitors() — so the TTL is just a safety net."""
        now = time.time()
        t, data = self._mon_cache
        if data is None or now - t > MON_CACHE_TTL:
            data = hjson("monitors") or []
            self._mon_cache = (now, data)
        return data

    def invalidate_monitors(self):
        self._mon_cache = (0.0, None)

    def reseed(self):
        self.invalidate_monitors()
        info = {m["name"]: m for m in self.monitors_cached()}
        # keep existing slot occupants where the monitor still exists
        old = self.mons
        self.mons = {}
        for name, cfg in MANAGED.items():
            if name in info and cfg.get("enabled", True):   # skip toggled-off monitors
                mon = Monitor(name, cfg, info[name])
                if name in old and len(old[name].trees) == len(mon.trees):
                    mon.trees = old[name].trees     # preserve layout on reseed
                self.mons[name] = mon
        dlog("reseed managed:", list(self.mons))

    def mon_of_addr(self, addr):
        for mon in self.mons.values():
            if mon.has(addr):
                return mon
        return None

    # -- window metadata --
    def client(self, addr):
        for c in (hjson("clients") or []):
            if c.get("address") == addr:
                return c
        return None

    def managed_monitor_for(self, client):
        """Return the Monitor a client should be managed on, or None."""
        if not client:
            return None
        mid = client.get("monitor")
        name = next((m["name"] for m in self.monitors_cached() if m["id"] == mid), None)
        return self.mons.get(name)

    def is_popup(self, client):
        """A genuine dialog/popup/utility window we should never tile."""
        if not client:
            return True
        if client.get("class", "") in DENY_CLASSES:
            return True
        # XWayland transient dialogs usually have an empty class and title
        if client.get("class", "") == "" and client.get("title", "") == "":
            return True
        return bool(client.get("pinned"))

    def is_tileable(self, client):
        """For window OPEN / startup adoption: a normal window that the app did
        not request to float (apps float their own dialogs/pop-ups)."""
        if self.is_popup(client) or client.get("fullscreen"):
            return False
        if client.get("floating") and client["address"] not in self.detached:
            return False
        return True

    def is_forceable(self, client):
        """For MANUAL recovery (Super+T on an untracked window, Super+Shift+T
        rearrange): grab anything the user could reasonably want tiled. Unlike
        is_tileable this does NOT reject floating OR fullscreen windows — that's
        the whole point, it recovers windows that slipped through auto-adoption
        (a window stuck fullscreen falls back to a broken floating size otherwise).
        apply() un-fullscreens them as it tiles. It only refuses what we truly
        must not tile."""
        if not client or not client.get("mapped", True):
            return False
        if client.get("pinned"):
            return False
        return client.get("class", "") not in DENY_CLASSES

    # -- placement --
    @staticmethod
    def rank_entry_zones(mon, rect, direction):
        """(zone_index, aligned) for each zone of `mon`, ranked for a window arriving
        from `rect` moving `direction`: closest on the PERPENDICULAR axis first (so a
        window from a screen's top lands in the target's top, bottom→bottom), then
        nearest the edge it enters through (moving right → left column first, left →
        right column, etc). `aligned` is True when the window's perpendicular centre
        falls within the zone's perpendicular span; placement prefers aligned zones so
        a window never jumps to the opposite half just because an empty zone is there.
        Rects are global-logical; zone rects are monitor-local, so shift by mon.ox/oy."""
        wx, wy, ww, wh = rect
        wcx, wcy = wx + ww / 2.0, wy + wh / 2.0
        ranked = []
        for zi in range(len(mon.cells)):
            rx, ry, rw, rh = mon.zone_rect(zi)
            gx, gy = mon.ox + rx, mon.oy + ry
            gcx, gcy = gx + rw / 2.0, gy + rh / 2.0
            if direction in ("left", "right"):
                perp = abs(gcy - wcy)
                edge = -gx if direction == "left" else gx
                aligned = gy <= wcy <= gy + rh
            else:
                perp = abs(gcx - wcx)
                edge = -gy if direction == "up" else gy
                aligned = gx <= wcx <= gx + rw
            ranked.append((perp, edge, zi, aligned))
        ranked.sort(key=lambda t: t[:2])
        return [(zi, aligned) for _, _, zi, aligned in ranked]

    def _place_ranked(self, addr, mon, ranked):
        """Land addr from a cross-monitor move (see rank_entry_zones): prefer zones
        ALIGNED with the window's perpendicular half — fill the first empty one whole,
        or, if all aligned zones are occupied, subdivide the best-ranked aligned one.
        So a top-origin window stays top even when the top is full and the bottom is
        empty (and a bottom-origin one stays bottom), instead of jumping halves or
        using the normal nice/overflow default (which fills the top first). Only if no
        zone is aligned (window centre off every zone) does it fall back to plain
        ranked order. Always places when `ranked` is non-empty."""
        # zi is None only if a caller passed a bogus intent; drop those so a stray
        # None can never index mon.trees[None] and abort the placement mid-move.
        order = ([zi for zi, al in ranked if al and zi is not None]
                 or [zi for zi, _ in ranked if zi is not None])
        for zi in order:
            if mon.trees[zi] is None:
                self.was_managed.discard(addr)
                mon.trees[zi] = leaf(addr)
                dlog("cross-place", addr, "-> empty zone", zi + 1, mon.name)
                self.apply(mon)
                return True
        if order:
            zi = order[0]
            lf, rect = next(walk(mon.trees[zi], mon.zone_rect(zi)))
            split_leaf(lf, addr, rect, new_first=self._new_first(mon, rect))
            self.was_managed.discard(addr)
            dlog("cross-place", addr, "-> split zone", zi + 1, mon.name)
            self.apply(mon)
            return True
        return False

    def place(self, addr, mon):
        """Insert addr: (0) if it just crossed from another monitor in a direction,
        land it in the zone spatially aligned with where it came from; (1) else fill
        an empty zone whole, in fill order; (2) else bring Zone 2 then Zone 3 to two
        windows (the nice 6-window layout); (3) else overflow — dwindle-split the
        focused window, like Hyprland does."""
        if mon.has(addr):
            return
        self.was_managed.discard(addr)   # managed again -> no stale-float override due
        # 0) honour a cross-monitor move's aligned-zone intent (see cmd_tomon)
        order = self.cross_place.get(addr)
        if order and order[0] == mon.name and time.time() < order[2]:
            self.cross_place.pop(addr, None)
            if self._place_ranked(addr, mon, order[1]):
                return
        # 1) whole-fill the first empty zone
        for zi in mon.fill:
            if mon.trees[zi] is None:
                mon.trees[zi] = leaf(addr)
                dlog("place", addr, "-> zone", zi + 1, "whole", mon.name)
                self.apply(mon)
                return
        # 2) nice split: Zone 2 then Zone 3 to a second window
        for zi in mon.nice:
            if count_leaves(mon.trees[zi]) < 2:
                lf, rect = next(walk(mon.trees[zi], mon.zone_rect(zi)))
                split_leaf(lf, addr, rect, new_first=self._new_first(mon, rect))
                dlog("place", addr, "-> zone", zi + 1, "split", mon.name)
                self.apply(mon)
                return
        # 3) overflow: subdivide the focused window (Hyprland-style dwindle)
        self.overflow(addr, mon)

    def _new_first(self, mon, rect):
        """True if the new window should take the FIRST half (left/top): i.e. the
        mouse is in that half of `rect`. Opens the new tile on the mouse's side,
        like Hyprland's dwindle. Defaults to False (second half) if no cursor."""
        rx, ry, rw, rh = rect
        pos = hjson("cursorpos") or {}
        cx, cy = pos.get("x"), pos.get("y")
        if cx is None:
            return False
        if rw >= rh:                              # vertical split -> left | right
            return cx < mon.ox + rx + rw / 2
        return cy < mon.oy + ry + rh / 2          # horizontal split -> top | bottom

    def overflow(self, addr, mon):
        """Past the nice layout, split the FOCUSED window's tile in half (dwindle),
        exactly like opening another window in Hyprland's default layout. Falls
        back to the largest tile if the focused window can't be found."""
        tgt = self.focused_leaf(mon) or self.largest_leaf(mon)
        if tgt is None:
            return
        zi, lf, rect = tgt
        split_leaf(lf, addr, rect, new_first=self._new_first(mon, rect))
        dlog("place", addr, "-> overflow split zone", zi + 1, mon.name)
        self.apply(mon)

    def focused_leaf(self, mon):
        """The tile an overflow window subdivides — the tile under the cursor. A
        new window opens next to the mouse, like Hyprland; and since keyboard focus
        warps the cursor onto the active window, this also tracks keyboard focus.
        Falls back to the last active window (cursor off-screen), then None."""
        pos = hjson("cursorpos") or {}
        cx, cy = pos.get("x"), pos.get("y")
        if cx is not None:
            for zi, lf, (rx, ry, rw, rh) in mon.leaves():
                gx, gy = mon.ox + rx, mon.oy + ry
                if gx <= cx < gx + rw and gy <= cy < gy + rh:
                    return (zi, lf, (rx, ry, rw, rh))
        if self.focused:
            return mon.leaf_of(self.focused)
        return None

    def largest_leaf(self, mon):
        best, best_area = None, -1
        for zi, lf, rect in mon.leaves():
            area = rect[2] * rect[3]
            if area > best_area:
                best, best_area = (zi, lf, rect), area
        return best

    def run_verify(self):
        """Re-anchor pass: pin every tiled window's top-left back to its zone corner.

        Why this is needed: our `resize` is CENTRE-anchored, and an app resizing
        itself (to honour a min size larger than the zone, or growing content to
        fill a bigger zone) settles with its top-left pushed off the corner — the
        window drifts up/left and looks like it isn't filling the zone (or, cycling
        zones, walks off-screen). The app's final committed size only lands a moment
        after we place it, so we can't get the position right synchronously. Instead
        we read the ACTUAL settled geometry here and move the top-left to the corner
        (an absolute move; floating windows overflow the screen freely, so this never
        gets shoved back — it converges).

        The app's commit time varies, so this CHASES: if we still see drift we run
        again shortly, until the layout is stable (bounded, so a genuinely stuck
        window can't loop forever). Scheduled via verify_at, never a blocking sleep."""
        clients = {c["address"]: c for c in (hjson("clients") or [])}
        reanchor = []
        learned = unsettled = False
        seen = {}
        for mon in self.mons.values():
            for zi, lf, (rx, ry, rw, rh) in mon.leaves():
                addr = lf["win"]
                c = clients.get(addr)
                if not c:
                    continue
                cls = c.get("class") or ""
                gx, gy = mon.ox + rx, mon.oy + ry
                tw, th = self.want_size(cls, rw, rh)     # what we commanded
                cw, ch = c.get("size", [tw, th])         # what the app settled at
                cx, cy = c.get("at", [gx, gy])
                seen[addr] = (cw, ch)
                mismatch = abs(cw - tw) > DRIFT_PX or abs(ch - th) > DRIFT_PX
                # LEARN the app's true minimum from the settled size, per class:
                #  - settled BIGGER than commanded -> its min is higher than we knew
                #  - settled SMALLER than a clamp we applied -> our record was too
                #    high (stale/wrong); lower it so we stop over-sizing this app
                # Only from a STABLE size: two consecutive reads (after the last
                # geometry change — flush() clears _last_size) must agree, so a slow
                # app still showing its pre-apply size can't teach us garbage.
                stable = self._last_size.get(addr) == (cw, ch)
                if mismatch and not stable:
                    unsettled = True                     # still settling: read again
                if mismatch and stable and time.time() >= self.learn_suppress_until:
                    ms = self.minsize.setdefault(cls, [0, 0])
                    for i, (got, want, zone) in enumerate(((cw, tw, rw), (ch, th, rh))):
                        if got - want > DRIFT_PX and got > ms[i]:
                            ms[i] = int(got); learned = True
                        elif want > zone and want - got > DRIFT_PX:   # our clamp overshot
                            ms[i] = int(got) if got > zone + DRIFT_PX else 0
                            learned = True
                    if ms == [0, 0]:
                        self.minsize.pop(cls, None)
                # Re-anchor: pin the top-left back to the zone corner if the app's
                # commit pushed it off (centre-anchored re-position). Once its size
                # is learned we command the right size up front and this stops firing.
                if abs(cx - gx) > DRIFT_PX or abs(cy - gy) > DRIFT_PX:
                    reanchor.append('hl.dsp.window.move({x=%d,y=%d, window="address:%s"})'
                                    % (gx, gy, addr))
        self._last_size = seen
        if learned:
            log("minsize learned:", dict(self.minsize))
            self.save()
        if reanchor:
            dlog("verify re-anchor", len(reanchor), "chase", self._verify_chase)
            hbatch(reanchor)
        if (reanchor or unsettled) and self._verify_chase < VERIFY_CHASE_MAX:
            # not settled yet -> read again shortly (bounded). Once sizes are
            # learned, applies are exact first-pass and this never runs.
            self._verify_chase += 1
            self.verify_at = time.time() + VERIFY_CHASE_DELAY
        elif not reanchor and not unsettled:
            self._verify_chase = 0

    def gc(self):
        """Free slots whose window no longer exists (a missed closewindow or a
        restart race can leave a dead address occupying a slot). Cheap safety net
        run before each keybind command so ghosts never block a real window."""
        valid = {c["address"] for c in (hjson("clients") or [])}
        if not valid:
            return
        for mon in self.mons.values():
            for zi in range(len(mon.trees)):
                if mon.trees[zi] is not None:
                    mon.trees[zi] = prune(mon.trees[zi], valid)
        self.detached &= valid
        self.painted &= valid
        self.was_managed &= valid

    def remove(self, addr, mon=None):
        """Free addr's spot. Its sibling collapses up to reclaim the space; other
        zones stay put."""
        mon = mon or self.mon_of_addr(addr)
        if not mon or not mon.has(addr):
            return False
        for zi in range(len(mon.trees)):
            if mon.trees[zi] is not None:
                mon.trees[zi] = remove_win(mon.trees[zi], addr)
        dlog("remove", addr, mon.name)
        self.apply(mon)
        return True

    # -- apply geometry --
    def apply(self, mon):
        """Coalesced: just mark the monitor dirty. The run loop flushes once per
        tick (see flush()), so a burst of placements/events collapses into a
        SINGLE geometry pass instead of re-floating/resizing/moving every window
        many times over — which is what froze the managed screen."""
        self.dirty.add(mon.name)

    def flush(self):
        """Apply geometry once for each monitor marked dirty this tick, then focus
        and warp the mouse to a just-placed window (geometry first so it's already
        at its final rect when we move the cursor to its centre)."""
        applied = False
        for name in list(self.dirty):
            self.dirty.discard(name)
            mon = self.mons.get(name)
            if mon:
                self._apply_now(mon)
                applied = True
        if applied:
            # fresh geometry: schedule a verify pass (learn sizes / correct drift).
            # Reset the chase budget and the stability history — sizes read before
            # this change must not count as "stable" for learning.
            self._verify_chase = 0
            self._last_size = {}
            due = time.time() + FLUSH_VERIFY_DELAY
            if self.verify_at is None or due < self.verify_at:
                self.verify_at = due

    def _apply_now(self, mon):
        self._apply_count += 1
        dlog("APPLY#", self._apply_count, mon.name)
        # refresh offset + reserved bar space so layout tracks the live bar
        info = next((m for m in self.monitors_cached() if m["name"] == mon.name), None)
        if info:
            mon.update(info)
        # live client map so we can un-fullscreen anything we're about to tile
        # (a stuck-fullscreen window otherwise falls back to a broken float size).
        clients = {c["address"]: c for c in (hjson("clients") or [])}
        exprs, repaint = [], []
        for zi, lf, (rx, ry, rw, rh) in mon.leaves():
            addr = lf["win"]
            gx, gy = mon.ox + rx, mon.oy + ry
            c = clients.get(addr)
            if c and c.get("fullscreen"):
                # same batch = atomic: leave fullscreen, THEN size/place it.
                exprs.append('hl.dsp.window.fullscreen({action="unset", window="address:%s"})' % addr)
                self.suspended.pop(addr, None)
                self.unfs_at[addr] = time.time()   # for fullscreen-insist guard
            # command the size the app will actually settle at (zone raised to its
            # learned min) so its async clamp can't re-commit and bump the window
            tw, th = self.want_size((c or {}).get("class"), rw, rh)
            exprs += float_geom_exprs(addr, tw, th, gx, gy)
            if addr in self.painted:   # tiled again -> back to the config colour
                repaint.append(addr)
        hbatch(exprs)
        for addr in repaint:
            self.paint(addr, False)
        self.save()

    # -- persistence (survives a daemon restart within the same session) --
    def save(self):
        try:
            data = {"trees": {n: m.trees for n, m in self.mons.items()},
                    "detached": sorted(self.detached),
                    "painted": sorted(self.painted),
                    "was_managed": sorted(self.was_managed),
                    "minsize": self.minsize}
            tmp = STATE_PATH + ".tmp"      # write-then-rename: a crash mid-write
            with open(tmp, "w") as f:      # can never leave a corrupt state file
                json.dump(data, f)
            os.replace(tmp, STATE_PATH)
        except OSError as e:
            log("save error", e)

    def load(self):
        try:
            with open(STATE_PATH) as f:
                data = json.load(f)
        except (OSError, ValueError):
            return
        clients = hjson("clients") or []
        mons = hjson("monitors") or []
        id2name = {m["id"]: m["name"] for m in mons}
        # addresses currently living on each managed monitor — a saved tree entry
        # is only trustworthy if that window is still on *this* monitor (guards
        # against a reused address now belonging to a window elsewhere).
        here = {name: set() for name in self.mons}
        for c in clients:
            n = id2name.get(c.get("monitor"))
            if n in here:
                here[n].add(c["address"])
        all_valid = {c["address"] for c in clients}
        self.detached = set(data.get("detached", [])) & all_valid
        self.painted = set(data.get("painted", [])) & all_valid
        self.was_managed = set(data.get("was_managed", [])) & all_valid
        try:   # learned app min sizes are per-CLASS, valid across window lifetimes
            self.minsize = {str(k): [int(v[0]), int(v[1])]
                            for k, v in dict(data.get("minsize", {})).items()}
        except (TypeError, ValueError, IndexError):
            self.minsize = {}
        for name, trees in data.get("trees", {}).items():
            mon = self.mons.get(name)
            if mon and len(trees) == len(mon.trees):
                # restore a window only if it's still on THIS monitor (guards a
                # reused address now belonging to a window elsewhere).
                mon.trees = [prune(t, here[name]) for t in trees]
        log("loaded state; detached", self.detached)

    # -- full re-adopt (startup / recovery) --
    def retile(self, restore=False, force=False):
        """Re-tile the managed monitors.

        force=True — the "rearrange everything" reset (Super+Shift+T): wipe every
        zone, forget deliberate float-outs, and re-grab EVERY normal window (even
        floating ones) in fill order. Use it to reclaim a window that slipped through
        untracked, or to deliberately reshuffle.

        force=False — a gentle re-snap (Re-tile / Super+Shift+R, and config Apply):
        KEEP the current arrangement (reseed already preserves each tracked window's
        zone), only re-assert geometry to undo drift and adopt any untracked tileable
        window into an empty zone. It does NOT reshuffle windows placed by hand.

        restore=True — reload the saved layout after a same-session daemon restart.
        """
        self.reseed()               # rebuilds self.mons, preserving trees where zones still fit
        if restore:
            self.load()              # restore prior layout (same-session restart)
        elif force:
            self.detached.clear()
            for mon in self.mons.values():
                mon.trees = [None] * len(mon.cells)   # only the hard reset wipes
        clients = hjson("clients") or []
        mons = hjson("monitors") or []
        id2name = {m["id"]: m["name"] for m in mons}
        for c in clients:
            addr = c.get("address")
            if not addr or addr in self.detached:
                continue
            mon = self.mons.get(id2name.get(c.get("monitor")))
            if not mon or mon.has(addr):
                continue
            ok = self.is_forceable(c) if force else self.is_tileable(c)
            if ok:
                self.place(addr, mon)
        for mon in self.mons.values():
            self.apply(mon)
        dlog("retile done force=%s" % force)


# ───────────────────────── directional navigation ─────────────────────────
def _in_direction(direction, mc, oc, msize, osize):
    """True if tile at center `oc` is a neighbour of the tile at `mc` in the given
    direction — beyond it along that axis, and overlapping on the other axis."""
    mcx, mcy = mc
    ocx, ocy = oc
    mw, mh = msize
    ow, oh = osize
    overlap_x = abs(ocx - mcx) < (mw + ow) / 2
    overlap_y = abs(ocy - mcy) < (mh + oh) / 2
    if direction == "left":
        return ocx < mcx - DIR_MARGIN_PX and overlap_y
    if direction == "right":
        return ocx > mcx + DIR_MARGIN_PX and overlap_y
    if direction == "up":
        return ocy < mcy - DIR_MARGIN_PX and overlap_x
    if direction == "down":
        return ocy > mcy + DIR_MARGIN_PX and overlap_x
    return False


# ───────────────────────── daemon ─────────────────────────
class Daemon(HyperZone):
    def __init__(self):
        super().__init__()
        self.sel = selectors.DefaultSelector()
        self.pending = {}      # addr -> deadline: adopt only after it settles
        self.deny_place = {}   # addr -> [next_check, cx, cy, prev_size, tries]: centre on the
                               # cursor once the floated deny window's size stops changing
        self.cross_place = {}  # addr -> (mon_name, ranked_zone_ids, deadline): land a window
                               # crossing to a managed monitor in the zone aligned with where
                               # it came from, instead of blind fill order (see cmd_tomon/place)
        self.swap_pending = set()  # addrs mid cross-monitor SWAP: force on_moved to adopt them
                               # onto their destination even though we pre-emptied their source
                               # tree slot (so is_tileable/was_ours are both false). See cmd_swap.
        self.last_rearrange = 0.0   # for debouncing rapid rearrange key-repeats
        self.stop = False           # set by the `shutdown` cmd -> loop exits cleanly
        self.stdio = False          # RPC-over-stdio mode (owned by a Noctalia plugin)
        self.rpc_out = None         # private handle to the REAL stdout (see run())
        self.layout_revert_at = None    # deadline to auto-revert a pending display layout
        self.layout_prev_specs = None   # live specs snapshotted before an apply (for exact revert)
        self.monitors_refresh_at = None # deadline for a deferred (settled) monitors_changed push
        self.capture_resume_at = None   # while set, our keybinds are suspended so the UI can
                                        # record a chord Hyprland would otherwise grab; a deadline
                                        # backstop re-registers them if the UI never resumes
        self.learn_suppress_until = 0.0 # no minsize learning until then (display transitions
                                        # freeze windows at stale sizes long enough to look
                                        # "stable" and teach garbage, e.g. a zone-wide min)

    # -- JSON-RPC over stdio (plugin control channel) --
    def _rpc_write(self, obj):
        if not self.rpc_out:
            return
        try:
            self.rpc_out.write(json.dumps(obj) + "\n")
            self.rpc_out.flush()
        except (OSError, ValueError) as e:
            log("rpc write error", e)

    def emit(self, event, data=None):
        """Push an unsolicited event to the plugin (no-op outside stdio mode)."""
        self._rpc_write({"event": event, "data": {} if data is None else data})

    def reply(self, rid, result=None, error=None):
        if error is not None:
            self._rpc_write({"id": rid, "error": {"message": str(error)}})
        else:
            self._rpc_write({"id": rid, "result": {} if result is None else result})

    def on_rpc(self, line):
        """Handle one JSON-RPC request line. Every handler is wrapped so a bad
        request replies with an error and never takes the daemon down."""
        try:
            msg = json.loads(line)
        except ValueError:
            return
        rid, method, params = msg.get("id"), msg.get("method"), msg.get("params") or {}
        handler = self.RPC.get(method)
        if handler is None:
            self.reply(rid, error="unknown method: %s" % method)
            return
        try:
            self.reply(rid, result=handler(self, params))
        except Exception as e:
            log("rpc error", method, repr(e))
            self.reply(rid, error=e)

    # -- monitor / config snapshots for the UI --
    def live_monitors(self):
        return hjson("monitors", "all") or hjson("monitors") or []

    def effective_config(self):
        """The config the UI edits: the user's config.json (source form, so the
        divider model round-trips) augmented with an entry for every LIVE monitor
        (enabled=false for ones not currently managed) so the UI can toggle any of
        them on. Global keys fall back to the live defaults."""
        cfg = {k: v for k, v in USER_CONFIG.items() if k != "managed"}
        user_managed = USER_CONFIG.get("managed", {})
        managed = {}
        for m in self.live_monitors():
            name = m.get("name")
            if not name:
                continue
            if name in user_managed:
                entry = dict(user_managed[name])
                entry.setdefault("enabled", True)
            else:   # not user-configured: managed only if the built-in default is
                builtin = (not user_managed and name in MANAGED
                           and MANAGED[name].get("enabled", True))
                entry = {"enabled": bool(builtin)}
            if "cells" not in entry:
                entry.setdefault("layout", dict(DEFAULT_LAYOUT))
            managed[name] = entry
        cfg["managed"] = managed
        cfg.setdefault("deny_classes", sorted(DENY_CLASSES))
        cfg.setdefault("adopt_delay", ADOPT_DELAY)
        cfg.setdefault("border_float", BORDER_FLOAT)
        cfg.setdefault("border_float_inactive", BORDER_FLOAT_INACTIVE)
        # ALWAYS the merged set (defaults + user overrides), never the raw saved
        # keybinds — so actions added in a newer build (e.g. focus-*) show up in the
        # UI even when the on-disk config predates them.
        cfg["keybinds"] = {k: list(v) for k, v in KEYBINDS.items()}
        return cfg

    def state_snapshot(self):
        return {"version": VERSION,
                "config": self.effective_config(),
                "monitors": self.live_monitors(),
                "pending_layout": self.pending_layout_info(),
                "migrated": hyprland_is_migrated()}

    def pending_layout_info(self):
        if self.layout_revert_at is None:
            return None
        return {"deadline": self.layout_revert_at,
                "remaining": max(0.0, self.layout_revert_at - time.time())}

    @staticmethod
    def _write_config(cfg):
        os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
        tmp = CONFIG_PATH + ".tmp"
        with open(tmp, "w") as f:
            json.dump(cfg, f, indent=2)
        os.replace(tmp, CONFIG_PATH)   # atomic: a crash can't leave a half file

    # -- RPC handlers (return a JSON-able result or raise) --
    def rpc_get_state(self, params):
        return self.state_snapshot()

    def rpc_get_monitors(self, params):
        return {"monitors": self.live_monitors()}

    @staticmethod
    def _tiling_sig():
        """Signature of the parts of the config that affect how windows tile — the
        managed set and each monitor's compiled zones/fill/nice + enabled flag. Apply
        only re-tiles when THIS changes, so editing keybinds, deny-classes or border
        colours never disturbs the current window arrangement."""
        return {name: (bool(m.get("enabled", True)), tuple(m.get("cells", ())),
                       tuple(m.get("fill", ())), tuple(m.get("nice", ())))
                for name, m in MANAGED.items()}

    def rpc_set_config(self, params):
        global USER_CONFIG
        cfg = params.get("config")
        if not isinstance(cfg, dict):
            raise ValueError("missing/invalid config")
        old_sig = self._tiling_sig()
        apply_config(cfg)              # validates first -> globals untouched on error
        self._write_config(cfg)
        USER_CONFIG = cfg
        refresh_gaps()
        self.register_keybinds()       # apply any changed key combos live
        # Only re-tile when the zone layout / managed set actually changed — and then
        # gently (preserve hand-placed windows, just fit the new zones). A keybind or
        # colour edit leaves every window exactly where it is.
        if self._tiling_sig() != old_sig:
            self.retile()
        self.emit("config_changed", {"config": self.effective_config()})
        return {"config": self.effective_config()}

    # -- keybinds (registered live via Hyprland's Lua `eval`) --
    def _keybind_expr(self, combo, action):
        return 'hl.bind("%s", hl.dsp.exec_cmd("%s %s"))' % (
            combo, HZCTL_CMD, KEYBIND_CMDS[action])

    @staticmethod
    def _heval(expr):
        """Run one Lua expression through Hyprland's `eval` (hl.bind/hl.unbind are
        not dispatchers, so hbatch's /dispatch wrapper can't carry them)."""
        reply = hypr_request("eval " + expr)
        if reply is not None and reply.strip() and reply.strip() != "ok":
            log("keybind eval:", expr[:70], "->", reply.strip())

    @staticmethod
    def desired_binds():
        """KEYBINDS flattened to {combo: action}; blanks dropped."""
        out = {}
        for action, combos in KEYBINDS.items():
            for combo in combos:
                c = combo.strip()
                if c:
                    out[c] = action
        return out

    def register_keybinds(self, initial=False):
        """Reconcile Hyprland's live binds with KEYBINDS. On `initial` (startup) we
        unbind every wanted combo first, clearing any duplicate hyprland.lua still
        registered before we took ownership, then (re)bind ours. Afterwards only the
        delta is touched, so editing one shortcut doesn't re-register them all."""
        desired = self.desired_binds()
        prev = getattr(self, "active_binds", {})
        for combo, action in prev.items():         # gone, or remapped to a new action
            if desired.get(combo) != action:
                self._heval('hl.unbind("%s")' % combo)
        for combo, action in desired.items():
            if initial or prev.get(combo) != action:
                if initial:
                    self._heval('hl.unbind("%s")' % combo)   # drop hyprland.lua dup
                self._heval(self._keybind_expr(combo, action))
        self.active_binds = desired

    def migrate_keybinds(self):
        """Stop hyprland.lua from ALSO binding the keys we now own (else a press fires
        twice). Comments out its hand-written HyperZone binds AND the native
        directional-focus binds we've taken over — leaving the mouse drag-binds,
        workspace-focus binds, and every unrelated bind untouched — keeping the
        original as a one-time backup. Re-scans each startup (only writes when
        something changed, and already-commented lines don't re-match), so newly
        taken-over actions get picked up on upgrade. The already-loaded running
        instance is deduped separately by register_keybinds(initial=True)."""
        try:
            with open(HYPRLAND_LUA) as f:
                text = f.read()
        except OSError:
            return
        out, changed = [], False
        for ln in text.splitlines(keepends=True):
            if self._is_hz_keyboard_bind(ln):
                out.append("-- " + ln)
                changed = True
            else:
                out.append(ln)
        body = "".join(out)
        if KEYBIND_MARKER not in body:
            body = "%s  (auto-added when HyperZone took over these keybinds)\n" % KEYBIND_MARKER + body
            changed = True
        if not changed:
            return
        try:
            if not os.path.exists(HYPRLAND_LUA + ".hz-kb-backup"):
                shutil.copy2(HYPRLAND_LUA, HYPRLAND_LUA + ".hz-kb-backup")   # true original, once
            tmp = HYPRLAND_LUA + ".tmp"
            with open(tmp, "w") as f:
                f.write(body)
            os.replace(tmp, HYPRLAND_LUA)
            log("keybinds: migrated hyprland.lua (commented %s HyperZone binds)"
                % sum(1 for l in out if l.startswith("-- hl.bind")))
        except OSError as e:
            log("keybinds: hyprland.lua migration failed:", e)

    @staticmethod
    def _is_hz_keyboard_bind(line):
        """A hyprland.lua keyboard bind HyperZone now owns: either a hand-written
        `hl.bind(... hyperzone .. " <verb> ...")` (matched by the hzctl subcommand, so
        the mouse drag-binds are left alone) or a native DIRECTIONAL focus bind
        `hl.bind(... hl.dsp.focus({direction=...}))` (workspace-focus binds have
        `workspace=`, not `direction`, so they stay)."""
        s = line.strip()
        if not s.startswith("hl.bind(") or "mouse" in s:
            return False
        if "hyperzone" in s:
            m = re.search(r'hyperzone\s*\.\.\s*"\s*([a-z-]+)', s)
            return bool(m) and m.group(1) in _KB_VERBS
        return "hl.dsp.focus(" in s and "direction" in s

    def rpc_retile(self, params):
        self.retile()   # gentle re-snap (preserve arrangement); rearrange is the hard reset
        return {"ok": True}

    def rpc_set_capture_mode(self, params):
        """Suspend/restore our live keybinds so the settings UI can RECORD a chord.
        Hyprland fires bound chords globally, so pressing e.g. Super+←  would trigger
        our focus bind instead of reaching the recorder. On (True) we unbind them all;
        Off (False) re-registers from the current config. A deadline backstop in
        tick() restores them even if the UI dies mid-record, so keys can't stay dead."""
        if params.get("on"):
            for combo in list(getattr(self, "active_binds", {})):
                self._heval('hl.unbind("%s")' % combo)
            self.active_binds = {}
            self.capture_resume_at = time.time() + CAPTURE_MODE_TIMEOUT
        else:
            self.capture_resume_at = None
            self.register_keybinds(initial=True)
        return {"ok": True}

    # -- display layout (real reconfigure, with confirm-or-revert safety) --
    def _reload_hyprland(self):
        """Reload the Hyprland config so a rewritten monitors.lua takes effect."""
        if hypr_request("reload") is None:
            subprocess.run(["hyprctl", "reload"], capture_output=True, timeout=5)

    def _live_specs(self):
        """Current live monitors as generator specs (basis for revert / first monitors.lua)."""
        specs = []
        for m in self.live_monitors():
            if m.get("disabled"):
                specs.append({"name": m["name"], "disabled": True})
            else:
                specs.append({"name": m["name"],
                              "mode": "%dx%d@%.2f" % (m["width"], m["height"],
                                                      float(m.get("refreshRate", 60))),
                              "x": m.get("x", 0), "y": m.get("y", 0),
                              "scale": m.get("scale", 1), "transform": m.get("transform", 0)})
        return specs

    def _apply_live_specs(self, specs):
        """Reconfigure monitors at runtime via Hyprland's Lua `eval` — instant, no
        reload, and it works whether or not hyprland.lua has been migrated."""
        for spec in specs:
            reply = hypr_request("eval " + lua_monitor(spec))
            if reply is not None and reply.strip() and reply.strip() != "ok":
                log("monitor eval:", spec.get("name"), "->", reply.strip())
        self.invalidate_monitors()   # geometry just changed under the cache

    def rpc_apply_monitor_layout(self, params):
        """Reconfigure displays LIVE (Lua `eval`), then arm a daemon-enforced revert:
        unless confirm_monitor_layout arrives within timeout_s, we re-apply the
        previous live specs automatically. Survives the UI dying or every screen
        going dark — recovery needs zero user input. Migration is NOT required to
        apply; it only decides whether the change is persisted to monitors.lua
        (so it survives a config reload) or is runtime-only until the next reload."""
        if self.layout_revert_at is not None:
            raise ValueError("a display change is already pending confirmation")
        mons = params.get("monitors")
        if not isinstance(mons, list) or not mons:
            raise ValueError("monitors must be a non-empty list")
        live = {m["name"]: m for m in self.live_monitors()}
        specs = []
        for m in mons:
            name = m.get("name")
            if name not in live:
                raise ValueError("unknown monitor: %r" % name)
            if m.get("disabled"):
                specs.append({"name": name, "disabled": True})
                continue
            mode = str(m.get("mode", "preferred"))
            modes = [str(x) for x in live[name].get("availableModes", [])]
            if mode not in modes and mode not in ("preferred", "highres", "highrr"):
                raise ValueError("monitor %s: mode %r not available" % (name, mode))
            if float(m.get("scale", 1)) <= 0:
                raise ValueError("monitor %s: scale must be > 0" % name)
            if int(m.get("transform", 0)) not in range(8):
                raise ValueError("monitor %s: transform must be 0-7" % name)
            specs.append({"name": name, "mode": mode,
                          "x": int(m.get("x", 0)), "y": int(m.get("y", 0)),
                          "scale": m.get("scale", 1), "transform": int(m.get("transform", 0))})
        # snapshot the exact current live state so revert is exact
        self.layout_prev_specs = self._live_specs()
        migrated = hyprland_is_migrated()
        if migrated and os.path.exists(MONITORS_LUA):
            shutil.copyfile(MONITORS_LUA, MONITORS_LUA + ".pending-backup")
        self._apply_live_specs(specs)                       # <- takes effect now
        self.learn_suppress_until = time.time() + LEARN_SUPPRESS_APPLY       # windows are in flux
        if migrated:
            _atomic_write(MONITORS_LUA, generate_monitors_lua(specs))
        timeout_s = float(params.get("timeout_s", REVERT_TIMEOUT))
        self.layout_revert_at = time.time() + timeout_s
        # Hyprland reports the new mode/scale/transform a beat AFTER the eval
        # (measured ~0.4s); a synchronous live_monitors() read is stale and would
        # bounce the UI's preview back to the old value. Defer the state push to a
        # settled read in tick().
        self.monitors_refresh_at = time.time() + SETTLE_READ_DELAY
        self.emit("layout_pending", self.pending_layout_info())
        return {"deadline": self.layout_revert_at, "persisted": migrated}

    def rpc_confirm_monitor_layout(self, params):
        if self.layout_revert_at is None:
            raise ValueError("no pending display change")
        self.layout_revert_at = None
        self.layout_prev_specs = None
        if hyprland_is_migrated() and os.path.exists(MONITORS_LUA):
            shutil.copyfile(MONITORS_LUA, MONITORS_LUA + ".good")  # rescue snapshot
            try:
                os.remove(MONITORS_LUA + ".pending-backup")
            except OSError:
                pass
        self.emit("layout_committed", {})
        return {"ok": True}

    def rpc_revert_monitor_layout(self, params):
        if self.layout_revert_at is None:
            raise ValueError("no pending display change")
        self.revert_layout("user")
        return {"ok": True}

    def revert_layout(self, reason):
        """Re-apply the pre-apply live specs (and restore monitors.lua if migrated).
        Daemon-driven (also fired by the timeout in tick), so a bad layout always
        recovers on its own even if the UI is gone."""
        self.layout_revert_at = None
        prev = self.layout_prev_specs
        self.layout_prev_specs = None
        if prev:
            try:
                self._apply_live_specs(prev)                # restore the actual display state
                self.learn_suppress_until = time.time() + LEARN_SUPPRESS_APPLY
            except Exception as e:
                log("revert live-apply error", e)
        bak = MONITORS_LUA + ".pending-backup"
        try:
            if os.path.exists(bak):
                os.replace(bak, MONITORS_LUA)               # keep the persisted file in sync
        except OSError as e:
            log("revert_layout file error", e)
        log("display layout reverted:", reason)
        self.monitors_refresh_at = time.time() + SETTLE_READ_DELAY   # settled read (see apply)
        self.emit("layout_reverted", {"reason": reason})

    def rpc_migrate_hyprland_config(self, params):
        """One-time: move the hl.monitor blocks out of hyprland.lua into a generated
        monitors.lua that hyprland.lua then sources. Idempotent, timestamped backup."""
        try:
            with open(HYPRLAND_LUA) as f:
                text = f.read()
        except OSError as e:
            raise ValueError("cannot read hyprland.lua: %s" % e)
        if MIGRATE_MARKER in text:
            return {"changed": False}
        new_text, n = migrate_lua_text(text)
        if n == 0:
            raise ValueError("no hl.monitor blocks found in hyprland.lua")
        _atomic_write(MONITORS_LUA, generate_monitors_lua(self._live_specs()))
        backup = "%s.hz-backup-%d" % (HYPRLAND_LUA, int(time.time()))
        shutil.copyfile(HYPRLAND_LUA, backup)
        _atomic_write(HYPRLAND_LUA, new_text)
        self._reload_hyprland()
        self.emit("monitors_changed", {"monitors": self.live_monitors()})
        log("migrated hyprland.lua; backup:", backup, "blocks:", n)
        return {"changed": True, "backup": backup}

    # method name -> handler
    RPC = {
        "get_state": rpc_get_state,
        "get_monitors": rpc_get_monitors,
        "set_config": rpc_set_config,
        "retile": rpc_retile,
        "set_capture_mode": rpc_set_capture_mode,
        "apply_monitor_layout": rpc_apply_monitor_layout,
        "confirm_monitor_layout": rpc_confirm_monitor_layout,
        "revert_monitor_layout": rpc_revert_monitor_layout,
        "migrate_hyprland_config": rpc_migrate_hyprland_config,
    }

    # -- event dispatch from .socket2.sock --
    def on_event(self, line):
        try:
            name, _, payload = line.partition(">>")
            if name == "openwindow":
                addr = naddr(payload.split(",", 1)[0])
                # Defer the adoption decision: a dialog/popup usually opens as a
                # "normal" window for a frame or two before the app marks it
                # floating. Adopting on the raw event races that and yanks the
                # popup into a zone. Wait ADOPT_DELAY, then re-read its settled
                # state (is_tileable rejects the now-floating popup).
                self.pending[addr] = time.time() + ADOPT_DELAY
            elif name == "closewindow":
                addr = naddr(payload.strip())
                self.pending.pop(addr, None)
                self.deny_place.pop(addr, None)
                self.cross_place.pop(addr, None)
                self.swap_pending.discard(addr)
                self.remove(addr)
                self.detached.discard(addr)
                self.painted.discard(addr)
                self.suspended.pop(addr, None)
                self.was_managed.discard(addr)
            elif name == "movewindowv2":
                addr = naddr(payload.split(",", 1)[0])
                self.on_moved(addr)
            elif name == "activewindowv2":
                # remember the last focused MANAGED window; a new window (not yet
                # managed) won't overwrite it, so overflow splits the right tile.
                a = naddr(payload.strip())
                if a and any(m.has(a) for m in self.mons.values()):
                    self.focused = a
            elif name == "fullscreen":
                # coalesce: a burst of fullscreen flips -> one reconcile per tick
                self.reconcile_needed = True
            elif name.startswith("monitoradded") or name.startswith("monitorremoved"):
                self.reseed()        # monitor hot-plug: drop/keep managed monitors
                self.emit("monitors_changed", {"monitors": self.live_monitors()})
            elif name.startswith("configreloaded"):
                refresh_gaps()       # gaps/border may have changed -> re-lay-out
                refresh_borders()    # config colours may have changed
                self.reseed()        # a monitor's position/scale may have changed
                for a in list(self.painted):   # repaint our floating windows amber
                    self.paint(a, True)
                for mon in self.mons.values():
                    self.apply(mon)
                # A reload rebuilds Hyprland's bind table from hyprland.lua (where our
                # binds are commented out), silently wiping every runtime `hl.bind` we
                # added via eval. Re-register so the shortcuts survive any `hyprctl
                # reload` -- but not mid-record, or we'd clobber the capture.
                if self.capture_resume_at is None:
                    self.register_keybinds(initial=True)
                # Noctalia re-creates its bar a beat after a reconfigure, changing
                # the reserved insets; a second pass then re-anchors to the new area.
                self.verify_at = time.time() + VERIFY_AFTER_RELOAD
                self.learn_suppress_until = max(self.learn_suppress_until,
                                                time.time() + LEARN_SUPPRESS_RESEED)
                self.emit("monitors_changed", {"monitors": self.live_monitors()})
        except Exception as e:
            log("on_event error", repr(line), e)

    def tick(self):
        """Run any work that came due since the last select() wake-up. Order
        matters: reconcile + adopt may mark monitors dirty, then flush() applies
        geometry ONCE per dirty monitor. Nothing here may block for long."""
        now = time.time()
        if self.reconcile_needed:
            self.reconcile_needed = False
            self.reconcile_fullscreen()
        for addr in [a for a, t in self.pending.items() if t <= now]:
            self.pending.pop(addr, None)
            self.try_adopt(addr)
        for addr in [a for a, e in self.deny_place.items() if e[0] <= now]:
            self.place_deny_step(addr)
        for addr in [a for a, o in self.cross_place.items() if o[2] <= now]:
            self.cross_place.pop(addr, None)   # move never adopted -> drop stale intent
            self.swap_pending.discard(addr)    # (also clears a swap that never landed)
        if self.capture_resume_at is not None and now >= self.capture_resume_at:
            self.capture_resume_at = None      # UI never resumed -> restore keybinds
            self.register_keybinds(initial=True)
        if self.verify_at is not None and now >= self.verify_at:
            self.verify_at = None
            self.run_verify()
        if self.layout_revert_at is not None and now >= self.layout_revert_at:
            self.revert_layout("timeout")   # nobody confirmed -> auto-restore
        if self.monitors_refresh_at is not None and now >= self.monitors_refresh_at:
            self.monitors_refresh_at = None
            # A live `eval hl.monitor` apply fires NO configreloaded event, so the
            # tiler must re-learn monitor geometry here or zones go stale (windows
            # tile against pre-rotation/pre-move rectangles).
            self.reseed()
            for mon in self.mons.values():
                self.apply(mon)
            self.verify_at = now + VERIFY_AFTER_RELOAD   # bars re-anchor late; re-check insets
            self.learn_suppress_until = max(self.learn_suppress_until, now + LEARN_SUPPRESS_RESEED)
            self.emit("monitors_changed", {"monitors": self.live_monitors()})
        self.flush()                 # single coalesced geometry pass

    def next_timeout(self):
        """Seconds until the earliest scheduled timer (None = block forever).
        Returns 0 when there is dirty geometry or a pending reconcile, so the
        loop ticks immediately instead of blocking on select()."""
        if self.dirty or self.reconcile_needed:
            return 0.0
        deadlines = list(self.pending.values())
        deadlines += [e[0] for e in self.deny_place.values()]
        if self.verify_at is not None:
            deadlines.append(self.verify_at)
        if self.layout_revert_at is not None:
            deadlines.append(self.layout_revert_at)
        if self.monitors_refresh_at is not None:
            deadlines.append(self.monitors_refresh_at)
        if self.capture_resume_at is not None:
            deadlines.append(self.capture_resume_at)
        if not deadlines:
            return None
        return max(0.0, min(deadlines) - time.time())

    def try_adopt(self, addr):
        # Address reuse: apps recycle freed window addresses. If this addr is a
        # leftover from a window whose closewindow we missed, purge the ghost so
        # the fresh window isn't mistaken for "already placed" (which would slap
        # it into the old window's zone at some stale size). Same for a stale
        # detach flag on a reused address.
        stale = self.mon_of_addr(addr)
        if stale:
            self.remove(addr, stale)
        self.detached.discard(addr)
        c = self.client(addr)
        mon = self.managed_monitor_for(c)
        if mon and c and c.get("class", "") in DENY_CLASSES:
            # never-tile, but ONLY on a screen we manage: float it near the cursor
            # with the amber floating border so it doesn't get tiled. On unmanaged
            # screens we touch nothing — the app keeps its own default behaviour.
            self.float_deny(addr, c)
            return
        if mon and not mon.has(addr) and c and not c.get("fullscreen"):
            if self.is_tileable(c):
                self.place(addr, mon)
            elif addr not in self.detached:
                # a floating dialog/popup on a managed screen -> keep it inside its
                # zone (huge file/download dialogs otherwise overflow a 4K screen).
                self.float_popup(addr, c)

    def float_deny(self, addr, c):
        """Float a deny-classed window and paint it the amber floating border, then
        centre it on the cursor. Positioning is DEFERRED: on a managed screen the
        window first maps at a tiled (near-full-monitor) size, so centring on that
        now would fling it into a corner. Float it, let it settle to its natural
        size, then place_deny_step() re-reads that size and centres it on the cursor."""
        pos = hjson("cursorpos") or {}
        cx, cy = pos.get("x"), pos.get("y")
        hbatch(['hl.dsp.window.float({action="enable", window="address:%s"})' % addr])
        self.paint(addr, True)   # amber active/inactive floating border
        self.save()              # persist the paint flag
        if cx is not None:
            self.deny_place[addr] = [time.time() + DENY_PLACE_POLL, cx, cy, None, 0]
        dlog("deny-float", addr, c.get("class"), "cursor", (cx, cy))

    def _zone_at_point(self, mon, px, py):
        """Index of the zone on `mon` containing the global point (px, py), or None."""
        if px is None or py is None:
            return None
        for zi in range(len(mon.cells)):
            rx, ry, rw, rh = mon.zone_rect(zi)
            gx, gy = mon.ox + rx, mon.oy + ry
            if gx <= px < gx + rw and gy <= py < gy + rh:
                return zi
        return None

    def _app_window(self, c, mon):
        """(w, h) of the app's LARGEST window on `mon` (same pid), or None. Used only
        to decide whether a popup is oversized: a menu/dropdown is smaller than its own
        app window, so it fails this test and is left alone; a runaway file dialog is
        bigger, so it gets fitted."""
        pid, mid = c.get("pid"), c.get("monitor")
        best = None
        if pid is not None:
            for o in hjson("clients") or []:
                if o.get("address") == c.get("address") or o.get("pid") != pid:
                    continue
                if o.get("monitor") != mid or o.get("hidden"):
                    continue
                sz = o.get("size") or [0, 0]
                area = sz[0] * sz[1]
                if area > 0 and (best is None or area > best[0]):
                    best = (area, sz[0], sz[1])
        return (best[1], best[2]) if best else None

    def _popup_zone_rect(self, c, mon):
        """Global rect of the zone a popup on `mon` sits in (cursor first, else its own
        centre). This is its container — big enough even when the app's window is a
        narrow subdivided half, so we don't fight the popup's minimum size."""
        pos = hjson("cursorpos") or {}
        zi = self._zone_at_point(mon, pos.get("x"), pos.get("y"))
        if zi is None:
            sz, at = c.get("size") or [0, 0], c.get("at") or [0, 0]
            zi = self._zone_at_point(mon, at[0] + sz[0] / 2, at[1] + sz[1] / 2)
        rx, ry, rw, rh = mon.zone_rect(zi if zi is not None else 0)
        return mon.ox + rx, mon.oy + ry, rw, rh

    def float_popup(self, addr, c):
        """A floating dialog that opened on a managed screen BIGGER than the app window
        it belongs to — a file/download dialog ballooning off a 4K screen. Cap it to the
        ZONE it's over (its container, wide enough even when the app is in a narrow
        subdivided half, so we don't fight the dialog's minimum size), centre it there,
        clamp on-screen, and paint the floating border. A popup that already fits its app
        window (menus, dropdowns, tooltips, normal dialogs) is LEFT EXACTLY where the app
        put it — we must never reposition an app menu (that broke Steam/VLC menu bars)."""
        mon = self.managed_monitor_for(c)
        if not mon or not mon.cells:
            return
        size = c.get("size") or [0, 0]
        if size[0] <= 0 or size[1] <= 0:
            return
        aw = self._app_window(c, mon)
        if aw and size[0] <= aw[0] and size[1] <= aw[1]:
            return   # fits its own app window -> menu/dropdown/normal dialog, leave it
        zx, zy, zw, zh = self._popup_zone_rect(c, mon)
        if zw <= 0 or zh <= 0:
            return
        w = min(int(size[0]), int(zw))
        h = min(int(size[1]), int(zh))
        gx = int(zx + (zw - w) / 2)
        gy = int(zy + (zh - h) / 2)
        ux, uy, uw, uh = mon.usable()        # keep the whole rect on-screen
        mux, muy = mon.ox + ux, mon.oy + uy
        gx = max(mux, min(gx, mux + uw - w))
        gy = max(muy, min(gy, muy + uh - h))
        hbatch(float_geom_exprs(addr, w, h, gx, gy))
        self.paint(addr, True)               # floating (amber) border on the fitted dialog
        dlog("popup fit", addr, c.get("class"), "-> zone", (w, h, gx, gy))

    def place_deny_step(self, addr):
        """One poll toward centring a floated deny window on its cursor, instead of
        guessing a fixed delay. The window first maps at a tiled (near-full-monitor)
        size, so we place only once it is (a) no longer filling the monitor AND
        (b) stable between two reads — or a bounded number of reads as a backstop.
        Just 'stable' isn't enough: the tiled size is itself stable for a frame or
        two before the window shrinks to its natural size. Reschedules until then."""
        e = self.deny_place.get(addr)
        if not e:
            return
        _, cx, cy, prev, tries = e
        c = self.client(addr)
        if not c or not c.get("floating"):
            self.deny_place.pop(addr, None)      # gone or re-tiled: give up
            return
        size = tuple(c.get("size") or [0, 0])
        mon = next((m for m in self.monitors_cached() if m.get("id") == c.get("monitor")), None)
        tiled_ish = False
        if mon:
            _, _, mw, mh = logical_rect(mon)
            tiled_ish = size[0] >= 0.9 * mw and size[1] >= 0.9 * mh
        settled = size[0] > 0 and not tiled_ish and size == prev
        if settled or tries >= DENY_PLACE_MAX_TRIES:
            sw, sh = size if size[0] > 0 else (800, 600)
            gx, gy = self._clamp_to_monitor(c, int(cx - sw / 2), int(cy - sh / 2), sw, sh)
            hbatch(['hl.dsp.window.move({x=%d,y=%d, window="address:%s"})' % (gx, gy, addr)])
            self.deny_place.pop(addr, None)
            dlog("deny-place", addr, "->", (gx, gy), "size", (sw, sh), "tries", tries)
        else:
            e[0], e[3], e[4] = time.time() + DENY_PLACE_POLL, size, tries + 1

    def _clamp_to_monitor(self, c, x, y, w, h):
        """Keep a (w,h) window fully on the monitor the client is on."""
        mon = next((m for m in self.monitors_cached()
                    if m.get("id") == c.get("monitor")), None)
        if not mon:
            return x, y
        mx, my, mw, mh = logical_rect(mon)
        x = max(int(mx), min(x, int(mx + mw - w)))
        y = max(int(my), min(y, int(my + mh - h)))
        return x, y

    def unmanage_float_reset(self, addr, c):
        """A window is leaving a managed monitor for an UNMANAGED one: stop forcing
        it to float so it docks (tiles) natively there, like every other window on
        that screen. We deliberately do NOT impose a size — the app/native layout
        decides it. The one wrinkle: while managed we floated it at a ZONE size, and
        Hyprland now remembers that as its float geometry, so its FIRST Super+T here
        would wrongly pop it back to a zone size. We don't fight that eagerly (that
        needs a visible float->tile bounce); instead we flag it so cmd_toggle_float
        fixes it lazily, on that first Super+T, by floating it at its real docked
        size (see there). Nothing arbitrary, nothing imposed."""
        hbatch(['hl.dsp.window.float({action="disable", window="address:%s"})' % addr])
        self.was_managed.add(addr)   # first Super+T here -> float at docked size
        self.paint(addr, False)      # tiled native window -> config colour, not amber

    def on_moved(self, addr):
        if addr in self.detached:
            return
        c = self.client(addr)
        cur = self.managed_monitor_for(c)
        prev = self.mon_of_addr(addr)
        was_ours = prev is not None            # was a window we already managed
        if prev and prev is not cur:
            self.remove(addr, prev)          # left a managed monitor
            if cur is None and c and not c.get("fullscreen"):
                # moved onto an UNMANAGED screen: stop forcing float so it tiles
                # natively there, and reset the stale zone-size float geometry.
                self.unmanage_float_reset(addr, c)
        # Arrived on a managed monitor. Adopt a normal tiled window (is_tileable),
        # or one that was already ours being shuffled between managed monitors
        # (those stay floating because we float them). Do NOT adopt an app-floated
        # window (a dialog/popup that merely emitted a move event) — that grabbed
        # popups and half-tiled them at the wrong size/place.
        # A cross-monitor swap participant: we emptied its old zone up front (so the
        # window arriving from the other screen finds a clean slot), which makes both
        # is_tileable (it's floating) and was_ours (no longer in any tree) false — so
        # force the adoption here, then clear the flag.
        force = addr in self.swap_pending
        if cur and not cur.has(addr) and c and not c.get("fullscreen") \
                and (self.is_tileable(c) or was_ours or force):
            self.place(addr, cur)
        self.swap_pending.discard(addr)

    def reconcile_fullscreen(self):
        clients = hjson("clients") or []
        fs = {c["address"] for c in clients if c.get("fullscreen")}
        # managed window went fullscreen -> pull it out of its zone, remember it
        for mon in self.mons.values():
            for zi, lf, _ in list(mon.leaves()):
                if lf["win"] in fs:
                    a = lf["win"]
                    self.remove(a, mon)
                    if time.time() - self.unfs_at.get(a, 0) < FS_INSIST_WINDOW:
                        # it re-fullscreened right after WE cleared it: a wedged
                        # app that insists on fullscreen. Stop fighting it — leave
                        # it alone (don't restore) so it can't ping-pong forever.
                        self.detached.add(a)
                        self.unfs_at.pop(a, None)
                        log("fullscreen-insist; leaving alone", a)
                    else:
                        self.suspended[a] = mon.name
        # a suspended window left fullscreen -> put it back
        for a, mname in list(self.suspended.items()):
            if a not in fs:
                self.suspended.pop(a, None)
                c = self.client(a)
                mon = self.managed_monitor_for(c)
                # restore regardless of float state (it was managed before FS)
                if mon and c and not self.is_popup(c) and a not in self.detached:
                    self.place(a, mon)

    # -- control commands from keybinds --
    DIRECTIONS = ("left", "right", "up", "down")

    def on_cmd(self, msg):
        cmd = msg.get("cmd")
        arg = msg.get("arg")
        active = naddr(str(msg.get("active") or ""))
        if not active:                       # thin clients omit it; resolve here
            aw = hjson("activewindow")
            active = naddr(aw.get("address", "")) if aw else ""
        # args get interpolated into dispatch strings — accept only the fixed
        # vocabulary, so a malformed message can't inject or crash anything.
        if cmd in ("move", "tomon", "push", "swap", "focus") and arg not in self.DIRECTIONS:
            log("cmd rejected: bad arg", cmd, repr(arg))
            return
        if active and not (active.startswith("0x")
                           and all(ch in "0123456789abcdef" for ch in active[2:].lower())):
            log("cmd rejected: bad address", repr(active))
            return
        dlog("cmd", cmd, arg, active)
        if cmd == "shutdown":                # a takeover daemon asked us to stand down
            self.stop = True
            return
        self.gc()                            # clear any dead-window ghosts first
        if cmd == "retile":
            self.retile()
        elif cmd == "rearrange":
            # debounce: rearrange is idempotent, so ignore key-repeat bursts that
            # would otherwise each re-tile the whole screen (the freeze trigger).
            now = time.time()
            if now - self.last_rearrange < REARRANGE_DEBOUNCE:
                dlog("rearrange debounced")
            else:
                self.last_rearrange = now
                self.retile(force=True)  # hard reset: re-tile everything
                self.verify_at = now + VERIFY_AFTER_CMD
        elif cmd == "dump":
            for mon in self.mons.values():
                log("STATE", mon.name, mon.dump(), "detached", self.detached)
        elif cmd == "move" and active:
            self.cmd_move(active, arg)
        elif cmd == "tomon" and active:
            self.cmd_tomon(active, arg)
        elif cmd == "push" and active:
            self.cmd_push(active, arg)
        elif cmd == "swap" and active:
            self.cmd_swap(active, arg)
        elif cmd == "focus":
            if active:
                self.cmd_focus(active, arg)
            else:
                self.cmd_focus_from_cursor(arg)   # focus stranded on an empty screen -> recover
        elif cmd == "toggle-float" and active:
            self.cmd_toggle_float(active)
            self.verify_at = time.time() + VERIFY_AFTER_CMD
        elif cmd == "snap-drop" and active:
            self.cmd_snap_drop(active)     # dropped on managed -> snap to cursor zone
            self.verify_at = time.time() + VERIFY_AFTER_CMD
        elif cmd == "float-drop" and active:
            self.cmd_float_drop(active)     # dropped with float modifier -> leave loose

    def _same_mon_neighbour(self, addr, direction):
        """True if a tiled window exists in `direction` on the SAME monitor/workspace
        as addr — so a swap won't cross to another screen."""
        clients = hjson("clients") or []
        me = next((c for c in clients if c.get("address") == addr), None)
        if not me:
            return False
        mid = me.get("monitor")
        mws = (me.get("workspace") or {}).get("id")
        mx, my = me.get("at", [0, 0])
        mw, mh = me.get("size", [0, 0])
        mc = (mx + mw / 2, my + mh / 2)
        for c in clients:
            if c.get("address") == addr or c.get("monitor") != mid:
                continue
            if (c.get("workspace") or {}).get("id") != mws or c.get("floating"):
                continue
            x, y = c.get("at", [0, 0])
            w, h = c.get("size", [0, 0])
            if _in_direction(direction, mc, (x + w / 2, y + h / 2), (mw, mh), (w, h)):
                return True
        return False

    def cmd_move(self, addr, direction):
        """Move the focused window one slot in `direction` WITHIN its screen.
        Returns True if it moved/swapped, False if there was nothing that way (the
        window is at the screen edge) — cmd_push uses that to decide when to spill
        over to the next monitor."""
        mon = self.mon_of_addr(addr)
        if not mon:
            # Unmanaged window: swap with the neighbour in `direction` ONLY if it's
            # on the same monitor. At the screen edge there's no same-monitor
            # neighbour, so we stay put (Super+Shift crosses monitors). This makes
            # Super+Ctrl behave like it does on the managed screen: never leaves.
            if self._same_mon_neighbour(addr, direction):
                hbatch(['hl.dsp.window.swap({direction="%s"})' % direction])
                return True
            return False
        # Find the nearest target in `direction`. Targets are BOTH occupied tiles
        # (swap with them) and EMPTY zones (move into them, so you can rearrange
        # even when fewer than 4 windows are open).
        me = mon.leaf_of(addr)
        if not me:
            return False
        my_zi, my_leaf, (mx, my, mw, mh) = me
        mc = (mx + mw / 2, my + mh / 2)
        best = None                          # (dist, kind, payload)
        for zi, lf, (x, y, w, h) in mon.leaves():
            if lf["win"] == addr:
                continue
            oc = (x + w / 2, y + h / 2)
            if _in_direction(direction, mc, oc, (mw, mh), (w, h)):
                d = (oc[0] - mc[0]) ** 2 + (oc[1] - mc[1]) ** 2
                if best is None or d < best[0]:
                    best = (d, "swap", lf)
        for zi in range(len(mon.trees)):        # empty zones as move targets
            if mon.trees[zi] is None:
                rx, ry, rw, rh = mon.zone_rect(zi)
                zc = (rx + rw / 2, ry + rh / 2)
                if _in_direction(direction, mc, zc, (mw, mh), (rw, rh)):
                    d = (zc[0] - mc[0]) ** 2 + (zc[1] - mc[1]) ** 2
                    if best is None or d < best[0]:
                        best = (d, "into", zi)
        if best is None:
            return False  # nothing in that direction: at the edge, stay put
        if best[1] == "swap":
            my_leaf["win"], best[2]["win"] = best[2]["win"], my_leaf["win"]
            self.reprobe_min(my_leaf["win"])    # the swapped-in window changed zone too
        else:                                   # move into the empty zone (whole)
            mon.trees[my_zi] = remove_win(mon.trees[my_zi], addr)
            mon.trees[best[2]] = leaf(addr)
        self.reprobe_min(addr)                  # re-measure in its new zone
        self.apply(mon)
        return True

    def cmd_push(self, addr, direction):
        """Unified 'move it that way, across everything': shove the window one slot
        in `direction` within the screen, and if it's already at that edge, send it
        to the adjacent monitor instead. One keybind that flows a window across the
        whole desk (in-screen rearrange + cross-screen handoff)."""
        if not self.cmd_move(addr, direction):
            self.cmd_tomon(addr, direction)

    def cmd_swap(self, addr, direction):
        """Swap the focused window with whatever window lies in `direction` — the
        very target directional focus would jump to (_focus_target), so it reads as
        "trade places with the window the arrow points at". Works within a screen and
        across screens: same monitor -> exchange the two zone slots in the tree;
        different monitors -> each window takes the other's zone on the other monitor.
        Nothing else in the layout is disturbed, and if there's no window that way the
        focused one simply stays put."""
        c = self.client(addr)
        if not c:
            return
        tgt = self._focus_target(c, direction)
        if not tgt:
            return                                   # nothing that way -> stay put
        other = tgt.get("address")
        if not other or other == addr:
            return
        mon_a = self.mon_of_addr(addr)
        mon_b = self.mon_of_addr(other)
        if c.get("monitor") == tgt.get("monitor"):
            # same physical screen: a straight slot swap when we tile both windows
            if mon_a is not None and mon_a is mon_b:
                la, lb = mon_a.leaf_of(addr), mon_a.leaf_of(other)
                if la and lb:
                    la[1]["win"], lb[1]["win"] = other, addr
                    self.reprobe_min(addr)
                    self.reprobe_min(other)
                    self.apply(mon_a)
            else:
                # one of them isn't in our grid (a native/floating window): let
                # Hyprland swap the two tiled windows the ordinary way
                hbatch(['hl.dsp.window.swap({direction="%s"})' % direction])
            return
        self._swap_across(addr, mon_a, c, other, mon_b, tgt, direction)

    def _swap_across(self, addr, mon_a, ca, other, mon_b, tgt, direction):
        """Swap two windows living on DIFFERENT monitors: `addr` takes `other`'s place
        and vice versa. Each window we tile is pulled out of its source zone FIRST so
        the incoming window drops into a clean, empty slot (no transient subdivide-
        then-collapse flicker), handed to the destination output BY NAME — the only
        move that truly reassigns monitor + workspace membership (see cmd_tomon) — and
        steered into the vacated zone by a one-shot cross_place intent (swap_pending
        forces the adoption, since an emptied-out floating window passes neither
        is_tileable nor was_ours). A window whose destination isn't a managed monitor
        just docks there natively. Focus follows the window the user was driving."""
        id2name = {m.get("id"): m.get("name") for m in self.monitors_cached()}
        a_dest = id2name.get(tgt.get("monitor"))     # addr -> other's monitor (by name)
        b_dest = id2name.get(ca.get("monitor"))      # other -> addr's monitor
        if not a_dest or not b_dest:
            return
        a_dest_mon = self.mons.get(a_dest)           # None when that screen isn't managed
        b_dest_mon = self.mons.get(b_dest)
        # A window's current zone — or None when we DON'T tile it (a floating/detached
        # window can sit on a managed monitor yet be in no tree). Never let that None
        # reach cross_place: it would index mon.trees[None] and crash the placement.
        a_zi = mon_a.leaf_of(addr)[0] if mon_a else None    # addr's current zone
        b_zi = mon_b.leaf_of(other)[0] if mon_b else None   # other's current zone
        a_at = ca.get("at") or [0, 0]
        a_sz = ca.get("size") or [0, 0]
        a_rect = (a_at[0], a_at[1], a_sz[0], a_sz[1])
        b_at = tgt.get("at") or [0, 0]
        b_sz = tgt.get("size") or [0, 0]
        b_rect = (b_at[0], b_at[1], b_sz[0], b_sz[1])
        deadline = time.time() + CROSS_PLACE_TIMEOUT
        # empty each tiled source slot up front. If that window is headed for an
        # UNMANAGED screen, on_moved won't reset its stale zone-size float (its tree
        # slot is already gone), so do that here instead.
        if mon_a:
            self.remove(addr, mon_a)
            if a_dest_mon is None:
                self.unmanage_float_reset(addr, ca)
        if mon_b:
            self.remove(other, mon_b)
            if b_dest_mon is None:
                cb = self.client(other)
                if cb:
                    self.unmanage_float_reset(other, cb)
        # land each window on its managed destination: in the OTHER's just-vacated zone
        # when we know it, else in the zone aligned with where it entered from (the same
        # ranking cmd_tomon uses) — either way a list of REAL zone indices, never None.
        if a_dest_mon is not None:
            ranked = [(b_zi, True)] if b_zi is not None \
                else self.rank_entry_zones(a_dest_mon, a_rect, direction)
            self.cross_place[addr] = (a_dest, ranked, deadline)
            self.swap_pending.add(addr)
        if b_dest_mon is not None:
            ranked = [(a_zi, True)] if a_zi is not None \
                else self.rank_entry_zones(b_dest_mon, b_rect, direction)
            self.cross_place[other] = (b_dest, ranked, deadline)
            self.swap_pending.add(other)
        self.reprobe_min(addr)
        self.reprobe_min(other)
        bx, by, bw, bh = b_rect
        hbatch([
            'hl.dsp.window.move({monitor="%s", window="address:%s"})' % (a_dest, addr),
            'hl.dsp.window.move({monitor="%s", window="address:%s"})' % (b_dest, other),
            'hl.dsp.cursor.move({x=%d,y=%d})' % (bx + bw // 2, by + bh // 2),
            'hl.dsp.focus({window="address:%s"})' % addr,   # focus follows the driven window
        ])

    def cmd_toggle_float(self, addr):
        mon = self.mon_of_addr(addr)
        dlog("toggle-float", addr, "mon=", mon.name if mon else None,
            "detached?", addr in self.detached)
        if mon:                       # managed -> detach to free float
            self.remove(addr, mon)
            self.detached.add(addr)
            self.paint(addr, True)    # amber: now free-floating
            self.save()
            return
        if addr in self.detached:     # re-attach a deliberately floated window
            self.detached.discard(addr)
            c = self.client(addr)
            m = self.managed_monitor_for(c)
            if m:
                self.place(addr, m)
            self.paint(addr, False)   # back to config colour (if we'd painted it)
            return
        # Untracked window: if it's a normal window sitting on a managed monitor
        # (it slipped through adoption and is at some odd size), pull it into the
        # grid instead of a useless native float toggle.
        c = self.client(addr)
        m = self.managed_monitor_for(c)
        if m and self.is_forceable(c):
            self.place(addr, m)
        else:                         # genuine unmanaged native window -> toggle
            was_floating = bool(c.get("floating")) if c else False
            sz = c.get("size") if c else None
            at = c.get("at") if c else None
            if (addr in self.was_managed and not was_floating
                    and sz and sz[0] > 1 and sz[1] > 1 and at):
                # We polluted this window's remembered float geometry with a zone
                # rect while it was managed. A plain toggle would restore that stale
                # size AND position. Instead float it at its CURRENT docked size and
                # position (resize+move override the stale restore; truly in-place —
                # no size jump, no shift), which also rewrites Hyprland's float
                # memory to a sane value. One-shot.
                self.was_managed.discard(addr)
                hbatch(float_geom_exprs(addr, int(sz[0]), int(sz[1]),
                                        int(at[0]), int(at[1])))
                self.paint(addr, True)   # amber: now free-floating
                self.save()              # persist the consumed flag
            else:
                hbatch(['hl.dsp.window.float({action="toggle", window="address:%s"})' % addr])
                self.paint(addr, not was_floating)   # amber if it just became floating

    def drop_target(self, mon, skip_addr=None):
        """What's under the cursor on mon: ('tile', addr, rect) over an occupied
        tile, ('zone', zi) over an empty zone, or None."""
        pos = hjson("cursorpos") or {}
        cx, cy = pos.get("x"), pos.get("y")
        if cx is None:
            return None
        for zi, lf, (rx, ry, rw, rh) in mon.leaves():
            if lf["win"] == skip_addr:
                continue
            gx, gy = mon.ox + rx, mon.oy + ry
            if gx <= cx < gx + rw and gy <= cy < gy + rh:
                return ("tile", lf["win"], (rx, ry, rw, rh))
        for zi in range(len(mon.trees)):
            if mon.trees[zi] is None:
                rx, ry, rw, rh = mon.zone_rect(zi)
                gx, gy = mon.ox + rx, mon.oy + ry
                if gx <= cx < gx + rw and gy <= cy < gy + rh:
                    return ("zone", zi)
        return None

    def pick_monitor_in_dir(self, rect, direction, exclude_id):
        """The monitor beside <rect> in <direction>, chosen by EDGE ADJACENCY from
        the window's own position — not the source monitor's centre. A monitor
        qualifies only if it sits on that side AND shares extent on the perpendicular
        axis, so a window in the TOP of a tall 4K screen crosses to the output beside
        its top, and one in the bottom crosses to the output beside its bottom (the
        old centre-to-centre pick sent both to the same place). Ranked by gap
        distance, then most perpendicular overlap, then nearest perpendicular centre.
        Falls back to the loose centre-direction pick when nothing is edge-adjacent
        (e.g. a purely diagonal neighbour), so a move never silently dies."""
        wx, wy, ww, wh = rect
        wr, wb, wcx, wcy = wx + ww, wy + wh, wx + ww / 2.0, wy + wh / 2.0
        M = DIR_MARGIN_PX
        edge, loose = [], []
        for m in self.monitors_cached():
            if m.get("id") == exclude_id or m.get("disabled"):
                continue
            mx, my, mw, mh = logical_rect(m)
            mr, mb, mcx, mcy = mx + mw, my + mh, mx + mw / 2.0, my + mh / 2.0
            dx, dy = mcx - wcx, mcy - wcy
            if {"left": dx < 0 and abs(dx) >= abs(dy),
                "right": dx > 0 and abs(dx) >= abs(dy),
                "up": dy < 0 and abs(dy) > abs(dx),
                "down": dy > 0 and abs(dy) > abs(dx)}[direction]:
                loose.append((dx * dx + dy * dy, m))
            if direction in ("left", "right"):
                overlap = min(wb, mb) - max(wy, my)      # shared vertical extent
                if overlap <= 0:
                    continue
                gap = (mx - wr) if direction == "right" else (wx - mr)
                onside = (mx >= wr - M) if direction == "right" else (mr <= wx + M)
                if onside:
                    edge.append((max(0.0, gap), -overlap, abs(mcy - wcy), m))
            else:
                overlap = min(wr, mr) - max(wx, mx)      # shared horizontal extent
                if overlap <= 0:
                    continue
                gap = (my - wb) if direction == "down" else (wy - mb)
                onside = (my >= wb - M) if direction == "down" else (mb <= wy + M)
                if onside:
                    edge.append((max(0.0, gap), -overlap, abs(mcx - wcx), m))
        if edge:
            edge.sort(key=lambda e: e[:3])
            return edge[0][3]
        if loose:
            loose.sort(key=lambda e: e[0])
            return loose[0][1]
        return None

    def cmd_tomon(self, addr, direction):
        """Send a window to the monitor beside IT in <direction> (see
        pick_monitor_in_dir — the target depends on where the window sits, not just
        which screen it's on), then hand off to Hyprland by monitor NAME:
        hl.window.move({monitor="<name>"}) actually reassigns the window to that
        output (Hyprland re-places it on the target's active workspace) and fires
        movewindowv2, so the daemon re-adopts it (managed) or lets it dock natively
        (unmanaged). Moving by absolute x/y does NOT do this — Hyprland keeps a
        floating window's monitor membership on its old output even when the
        coordinates sit fully on another one (verified live). Direction LETTERS
        ("left"/"right") also raise "Invalid monitor"; only the output name works."""
        c = self.client(addr)
        if not c:
            return
        at = c.get("at") or [0, 0]
        size = c.get("size") or [0, 0]
        rect = (at[0], at[1], size[0], size[1])
        target = self.pick_monitor_in_dir(rect, direction, c.get("monitor"))
        if target is None:
            log("tomon: no monitor to the", direction)
            return
        name = target.get("name", "")
        if not name:
            return
        # If the destination is one we tile, remember which zone lines up with where
        # the window sat, so on arrival place() lands it there (top->top, bottom->
        # bottom) rather than in blind fill order. Unmanaged targets: Hyprland places.
        tmon = self.mons.get(name)
        if tmon is not None:
            self.cross_place[addr] = (name, self.rank_entry_zones(tmon, rect, direction),
                                      time.time() + CROSS_PLACE_TIMEOUT)
        self.reprobe_min(addr)                  # re-measure against the target zone
        hbatch(['hl.dsp.window.move({monitor="%s", window="address:%s"})'
                % (name, addr)])

    def cmd_focus(self, addr, direction):
        """Directional focus, computed FRESH from live window geometry on every press
        — one algorithm across all screens, no native delegation, nothing tracked. The
        target is the best window in `direction` among every visible window on any
        monitor (_focus_target): true row/column neighbours (perpendicular overlap)
        always beat unaligned ones, so bottom-left -> right lands on bottom-right even
        when the top-right zone is subdivided (native focus jumped into that
        subdivision), left never wraps to the other side of the screen, empty monitors
        are skipped (no window there = no candidate), and at the edge of the desk focus
        simply stays put."""
        c = self.client(addr)
        if not c:
            self.cmd_focus_from_cursor(direction)
            return
        tgt = self._focus_target(c, direction)
        if tgt:
            self._focus_window(tgt, cross=tgt.get("monitor") != c.get("monitor"))
        # else: no window that way anywhere -> stay put

    @staticmethod
    def _focus_window(tgt, cross):
        """Focus a window; when CROSSING monitors, warp the cursor to it first (one
        batch). Hyprland's cross-monitor focusWindow activates the target monitor
        before focusing, and that activation momentarily restores the monitor's
        LAST-ACTIVE window — a visible one-frame flash of the wrong window (verified
        via socket2: focusedmon -> activewindowv2 <old> -> activewindowv2 <target>).
        With the cursor already on the target, the activation resolves to the target
        itself and the flash is gone. Focus warps the cursor here anyway, so this only
        changes ordering, not behaviour."""
        exprs = []
        if cross:
            at, sz = tgt.get("at") or [0, 0], tgt.get("size") or [0, 0]
            exprs.append('hl.dsp.cursor.move({x=%d,y=%d})'
                         % (at[0] + sz[0] // 2, at[1] + sz[1] // 2))
        exprs.append('hl.dsp.focus({window="address:%s"})' % tgt.get("address"))
        hbatch(exprs)

    def cmd_focus_from_cursor(self, direction):
        """Recovery when there is NO active window (focus was left on an empty screen):
        focus the nearest window in `direction` from the cursor, or just the nearest
        window overall, so the keyboard can always get back to a window."""
        pos = hjson("cursorpos") or {}
        cx, cy = pos.get("x"), pos.get("y")
        if cx is None:
            tgt = self._nearest_window(0, 0, None)
        else:
            tgt = self._nearest_window(cx, cy, direction)
        if tgt:
            self._focus_window(tgt, cross=True)   # coming from an empty screen

    def _focusable_windows(self):
        """Mapped windows currently visible (on each monitor's active workspace)."""
        mons = self.monitors_cached()
        active_ws = {m.get("id"): (m.get("activeWorkspace") or {}).get("id") for m in mons}
        out = []
        for o in hjson("clients") or []:
            sz = o.get("size") or [0, 0]
            if o.get("hidden") or sz[0] <= 0 or sz[1] <= 0:
                continue
            if (o.get("workspace") or {}).get("id") != active_ws.get(o.get("monitor")):
                continue
            out.append(o)
        return out

    def _focus_target(self, c, direction):
        """The window focus should land on: best candidate in `direction` of c among
        ALL visible windows on every monitor, ranked by
          1. alignment  — true row/column neighbours (perpendicular overlap with c)
                          always beat unaligned ones, no matter the distance;
          2. primary-axis centre distance (nearest first);
          3. perpendicular centre offset (most in-line first).
        One geometric rule for in-screen and cross-screen: a same-screen aligned
        neighbour is nearer so it wins; with no aligned window on this screen the
        nearest aligned one on the next screen wins over an unaligned same-screen
        window (bottom row stays in the bottom row); unaligned windows are a last
        resort so focus still moves when something exists that way. None = nothing
        that way at all."""
        at = c.get("at") or [0, 0]
        sz = c.get("size") or [0, 0]
        cl, ct, cr, cb = at[0], at[1], at[0] + sz[0], at[1] + sz[1]
        ccx, ccy = (cl + cr) / 2.0, (ct + cb) / 2.0
        M = DIR_MARGIN_PX
        best = None
        for o in self._focusable_windows():
            if o.get("address") == c.get("address"):
                continue
            oa, os_ = o.get("at") or [0, 0], o.get("size") or [0, 0]
            ol, ot, orr, ob = oa[0], oa[1], oa[0] + os_[0], oa[1] + os_[1]
            ocx, ocy = (ol + orr) / 2.0, (ot + ob) / 2.0
            # A candidate is "that way" only when its centre is beyond MY EDGE in that
            # direction (not merely beyond my centre): a top-right subdivision whose
            # centre is horizontally inside a wide bottom window is above it, not
            # right of it — using centres made focus-right jump into it.
            if direction == "right":
                if ocx <= cr - M:
                    continue
                prim, overlap, perp = ocx - ccx, min(cb, ob) - max(ct, ot), abs(ocy - ccy)
            elif direction == "left":
                if ocx >= cl + M:
                    continue
                prim, overlap, perp = ccx - ocx, min(cb, ob) - max(ct, ot), abs(ocy - ccy)
            elif direction == "down":
                if ocy <= cb - M:
                    continue
                prim, overlap, perp = ocy - ccy, min(cr, orr) - max(cl, ol), abs(ocx - ccx)
            else:   # up
                if ocy >= ct + M:
                    continue
                prim, overlap, perp = ccy - ocy, min(cr, orr) - max(cl, ol), abs(ocx - ccx)
            key = (0 if overlap > 0 else 1, prim, perp)
            if best is None or key < best[0]:
                best = (key, o)
        return best[1] if best else None

    def _nearest_window(self, px, py, direction):
        """The focusable window (client dict) nearest point (px, py). With `direction`,
        prefer windows that way but fall back to the overall nearest, so focus can
        never get stuck with no window to go to."""
        best_dir = best_any = None
        for o in self._focusable_windows():
            oa, os_ = o.get("at") or [0, 0], o.get("size") or [0, 0]
            ocx, ocy = oa[0] + os_[0] / 2.0, oa[1] + os_[1] / 2.0
            d2 = (ocx - px) ** 2 + (ocy - py) ** 2
            if best_any is None or d2 < best_any[0]:
                best_any = (d2, o)
            if direction:
                that_way = {"right": ocx > px, "left": ocx < px,
                            "up": ocy < py, "down": ocy > py}.get(direction, True)
                if that_way and (best_dir is None or d2 < best_dir[0]):
                    best_dir = (d2, o)
        if direction and best_dir:
            return best_dir[1]
        return best_any[1] if best_any else None

    def cmd_snap_drop(self, addr):
        """A window was dropped on the managed screen: snap it into the zone/space
        under the cursor — adopt it if it came from elsewhere, or move it if it was
        already managed. Occupied tile -> subdivide (on the cursor's side); empty
        zone -> take it whole; anywhere else -> fall back to fill order."""
        c = self.client(addr)
        mon = self.managed_monitor_for(c)
        if not mon:
            return  # dropped on an unmanaged screen -> leave it to Hyprland
        self.detached.discard(addr)
        self.was_managed.discard(addr)   # managed again -> no stale-float override due
        self.reprobe_min(addr)           # deliberate drop -> re-measure min in new zone
        tgt = self.drop_target(mon, skip_addr=addr)   # read cursor BEFORE removing
        if tgt is None and mon.has(addr):
            # dropped on its own space (or a click) -> snap it back into its zone
            # rather than leaving it floating where the drag left it.
            self.apply(mon)
            return
        if mon.has(addr):
            self.remove(addr, mon)                    # lift it out of its old spot
        if tgt and tgt[0] == "tile":
            tl = mon.leaf_of(tgt[1])                  # re-find after the remove
            if tl:
                split_leaf(tl[1], addr, tl[2], new_first=self._new_first(mon, tl[2]))
            else:
                self.place(addr, mon)
        elif tgt and tgt[0] == "zone":
            mon.trees[tgt[1]] = leaf(addr)
        else:
            self.place(addr, mon)
        self.apply(mon)

    def cmd_float_drop(self, addr):
        """A window was dropped with the float modifier: leave it free-floating
        where it landed. Detach it from the grid."""
        mon = self.mon_of_addr(addr)
        if mon:
            self.remove(addr, mon)
        self.detached.add(addr)
        self.paint(addr, True)        # amber: free-floating
        self.save()

    def _acquire_control_socket(self):
        """Singleton guard. If another daemon already answers the control socket:
        in stdio (plugin-owned) mode we ask it to shut down and wait for it to
        release the socket — a takeover, so enabling the plugin always wins over a
        stale instance. Otherwise (bare CLI) we stand down. Returns True to proceed."""
        if not os.path.exists(CTRL_SOCK):
            return True
        try:
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            probe.settimeout(0.5)
            probe.connect(CTRL_SOCK)
            if self.stdio:
                probe.sendall(json.dumps({"cmd": "shutdown"}).encode())
            probe.close()
        except OSError:
            return True                       # stale socket, nobody listening
        if not self.stdio:
            log("another daemon is already running; exiting")
            return False
        for _ in range(20):                   # wait up to ~2s for it to let go
            time.sleep(0.1)
            try:
                p = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                p.settimeout(0.3)
                p.connect(CTRL_SOCK)
                p.close()
            except OSError:
                log("took over from previous daemon")
                return True
        log("previous daemon did not release the control socket; taking over anyway")
        return True

    # -- main loop --
    def _harden_stdio(self):
        """Repurpose stdout as the RPC channel: dup the real fd 1 to a private
        handle, then point fd 1 at /dev/null so NOTHING — stray prints, C
        libraries, child processes inheriting fd 1 — can ever corrupt the
        stream. Must run FIRST, before any other code. stderr is left alone
        (tracebacks/logs flow to the plugin's logger)."""
        self.rpc_out = os.fdopen(os.dup(1), "w", buffering=1)
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, 1)
        os.close(devnull)

    def _connect_event_socket(self):
        """Connect to socket2 — retry briefly: when autostarted from the Hyprland
        config the compositor may not be listening yet on the first attempt."""
        ev = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        for attempt in range(20):
            try:
                ev.connect(EVENT_SOCK)
                break
            except OSError as e:
                if attempt == 19:
                    log("cannot reach Hyprland event socket:", EVENT_SOCK, e)
                    sys.exit("hyperzone: cannot reach Hyprland at %s (%s)"
                             % (EVENT_SOCK, e))
                time.sleep(0.25)
        ev.setblocking(False)
        self.sel.register(ev, selectors.EVENT_READ, ("event", b""))

    def _bind_control_socket(self):
        """Owner-only socket accepting window-management commands (hzctl)."""
        try:
            os.unlink(CTRL_SOCK)
        except FileNotFoundError:
            pass
        ctl = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        ctl.bind(CTRL_SOCK)
        os.chmod(CTRL_SOCK, 0o600)
        ctl.listen(8)
        ctl.setblocking(False)
        self.sel.register(ctl, selectors.EVENT_READ, ("ctl", None))

    def run(self, stdio=False):
        self.stdio = stdio
        if stdio:
            self._harden_stdio()
        if not self._acquire_control_socket():
            return
        self._connect_event_socket()
        self._bind_control_socket()
        refresh_gaps()              # borrow gaps/border from the live Hyprland config
        refresh_borders()           # config border colours (for repainting managed)
        self.retile(restore=True)   # restore prior layout if the daemon restarted
        for a in list(self.painted):  # re-assert amber on windows we had painted
            self.paint(a, True)
        if stdio:
            # stdin is the RPC request channel; EOF means our parent (the Noctalia
            # plugin) died -> we shut down with it. Announce ourselves with a full
            # state snapshot the plugin renders immediately.
            os.set_blocking(0, False)
            self.sel.register(0, selectors.EVENT_READ, ("rpc", b""))
            self.emit("ready", self.state_snapshot())
            # take ownership of the HyperZone keybinds: comment the hand-written
            # ones out of hyprland.lua (once) and register the configured set live.
            self.migrate_keybinds()
            self.register_keybinds(initial=True)
        log("daemon up; managing", list(self.mons), "stdio" if stdio else "")
        while not self.stop:
            for key, _ in self.sel.select(self.next_timeout()):
                kind = key.data[0]
                if kind == "ctl":
                    conn, _ = key.fileobj.accept()
                    data = ""
                    try:
                        data = conn.recv(8192).decode("utf-8", "replace").strip()
                        if data:
                            self.on_cmd(json.loads(data))
                    except Exception as e:
                        log("ctl error:", repr(e), "handling", data[:200])
                    finally:
                        conn.close()
                elif kind == "event":
                    buf = key.data[1]
                    try:
                        chunk = key.fileobj.recv(65536)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        log("event socket closed; exiting")
                        return
                    buf += chunk
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        self.on_event(line.decode("utf-8", "replace"))
                    self.sel.modify(key.fileobj, selectors.EVENT_READ, ("event", buf))
                elif kind == "rpc":
                    buf = key.data[1]
                    try:
                        chunk = os.read(0, 65536)
                    except BlockingIOError:
                        continue
                    if not chunk:                 # stdin EOF -> parent gone
                        log("stdin closed; exiting")
                        self.stop = True
                        break
                    buf += chunk
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        text = line.decode("utf-8", "replace").strip()
                        if text:
                            self.on_rpc(text)
                    self.sel.modify(0, selectors.EVENT_READ, ("rpc", buf))
            # after handling any events (or a timeout), run due timers
            self.tick()
        self.save()
        log("daemon stopped")


# ───────────────────────── CLI ─────────────────────────
def send(cmd, arg=None):
    active = ""
    aw = hjson("activewindow")
    if aw:
        active = aw.get("address", "")
    msg = json.dumps({"cmd": cmd, "arg": arg, "active": active}).encode()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.settimeout(1.5)
        s.connect(CTRL_SOCK)
        s.sendall(msg)
        return True
    except OSError:
        return False
    finally:
        s.close()


def cli_fallback(cmd, arg):
    """If the daemon is down, degrade to a sensible native action (never hang).
    tomon has no fallback: resolving which output lies in <direction> needs the
    daemon's live monitor geometry (see Daemon.cmd_tomon)."""
    if cmd == "move":
        hbatch(['hl.dsp.window.move({direction="%s"})' % arg])
    elif cmd == "toggle-float":
        hbatch(['hl.dsp.window.float({action="toggle"})'])


COMMANDS = ("daemon", "focus", "move", "tomon", "push", "swap", "toggle-float",
            "snap-drop", "float-drop", "retile", "rearrange", "dump")


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    arg = sys.argv[2] if len(sys.argv) > 2 else None
    if not HIS:
        sys.exit("hyperzone: HYPRLAND_INSTANCE_SIGNATURE is not set — "
                 "run inside a Hyprland session")
    if cmd == "daemon":
        if os.environ.get(KILL_ENV) in ("1", "true", "yes"):
            log("disabled via", KILL_ENV)
            return
        load_user_config()   # optional ~/.config/hyperzone/config.json overlay
        Daemon().run(stdio="--stdio" in sys.argv[2:])
    else:
        if not send(cmd, arg):
            cli_fallback(cmd, arg)


if __name__ == "__main__":
    main()
