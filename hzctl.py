#!/usr/bin/env python3
"""hzctl — tiny local client for the hyperzone tiling daemon.

Kept on the LOCAL disk (not /media/DEV, where the main hyperzone.py lives) so
Hyprland keybinds never stall on that removable fuseblk mount when it spins down.
It just forwards the command to the daemon's control socket; the daemon resolves
the focused window itself. If the daemon is down, it degrades to a native action
so the key still does something sensible.

Startup cost is the whole latency of a keypress, so imports are kept minimal
(no json — the message is hand-built; subprocess only on the fallback path).
Run with `python3 -S` to skip site-packages for a few more ms.

Usage: hzctl.py <focus|move|tomon|push|swap|toggle-float|snap-drop|float-drop|drag-start|drag-toggle|drag-carry|drag-drop|rearrange|retile|dump> [arg]
       hzctl.py ext <extension.action>
"""
import os
import socket
import sys

SOCK = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "hyperzone.sock")
# fixed vocabulary only: the message below is hand-built (no json import for
# startup speed), which is safe exactly because these are the only values.
COMMANDS = ("focus", "move", "tomon", "push", "swap", "toggle-float", "snap-drop",
            "float-drop", "drag-start", "drag-toggle", "drag-carry", "drag-drop",
            "retile", "rearrange", "dump", "locate", "ext")
ARGS = (None, "left", "right", "up", "down",
        "flip")                          # drag-start: Ctrl was held at the grab
# `ext` is the one command whose argument can't be a fixed vocabulary — it names an
# action some installed extension registered, which this client knows nothing about.
# It stays safe by being a strict CHARSET instead: the id goes straight into the
# hand-built JSON below, so anything that could break out of a string is not a
# legal character. The daemon re-checks it against its own registry regardless.
EXT_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789-_."


def dispatch(expr):
    import subprocess
    subprocess.run(["hyprctl", "dispatch", expr])


def main():
    if len(sys.argv) < 2:
        return
    cmd = sys.argv[1]
    arg = sys.argv[2] if len(sys.argv) > 2 else None
    if cmd not in COMMANDS:
        return
    if cmd == "ext":
        if not arg or len(arg) > 66 or not all(ch in EXT_CHARS for ch in arg):
            return
    elif arg not in ARGS:
        return
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect(SOCK)
        # keybind args are a fixed vocabulary (move/left/...), safe to hand-build
        a = '"%s"' % arg if arg is not None else "null"
        s.sendall(('{"cmd": "%s", "arg": %s}' % (cmd, a)).encode())
        s.close()
        return
    except OSError:
        pass  # daemon down -> best-effort native fallback
    # (tomon has no fallback: picking the output in <direction> needs the daemon's
    #  live monitor geometry — see Daemon.cmd_tomon)
    if cmd == "move":
        dispatch('hl.dsp.window.move({direction="%s"})' % arg)
    elif cmd == "toggle-float":
        dispatch('hl.dsp.window.float({action="toggle"})')


if __name__ == "__main__":
    main()
