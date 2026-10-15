#!/usr/bin/env python3
"""hzrpc — one JSON-RPC call to the HyperZone daemon over its control socket.

The Noctalia 5 plugin's request channel. Its host can read the daemon's stdout (events) but
cannot write to its stdin, so requests go over the same owner-only control socket hzctl uses,
as {"rpc": method, "params": {...}}, and the daemon writes the reply back on that connection.

Usage: hzrpc.py <method> [params-json]
Prints the daemon's reply line ({"result": ...} or {"error": {"message": ...}}).
Exit status: 0 result, 1 error reply, 2 daemon unreachable.
"""
import json
import os
import socket
import sys

SOCK = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "hyperzone.sock")


def _list(v):
    # Noctalia's Luau JSON encoder has no empty array: an empty table always encodes as {}.
    return [] if v == {} else v


def fix_lists(method, params):
    """Turn the {} an empty Luau table becomes back into [] wherever the daemon expects a list."""
    if method != "set_config" or not isinstance(params.get("config"), dict):
        return params
    cfg = params["config"]
    if "deny_classes" in cfg:
        cfg["deny_classes"] = _list(cfg["deny_classes"])
    if isinstance(cfg.get("keybinds"), dict):
        cfg["keybinds"] = {k: _list(v) for k, v in cfg["keybinds"].items()}
    for mc in (cfg.get("managed") or {}).values():
        layout = mc.get("layout") if isinstance(mc, dict) else None
        if isinstance(layout, dict):
            for k in ("fill", "subdivide"):
                if k in layout:
                    layout[k] = _list(layout[k])
    return params


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    method = sys.argv[1]
    try:
        params = json.loads(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else {}
    except ValueError as e:
        print(json.dumps({"error": {"message": "bad params: %s" % e}}))
        sys.exit(1)
    params = fix_lists(method, params)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.settimeout(30.0)            # a display apply can take a few seconds to answer
        s.connect(SOCK)
        s.sendall(json.dumps({"rpc": method, "params": params}).encode())
        s.shutdown(socket.SHUT_WR)    # end of request: the daemon reads until here
        buf = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    except OSError as e:
        print(json.dumps({"error": {"message": "daemon unreachable: %s" % e}}))
        sys.exit(2)
    finally:
        s.close()
    line = buf.decode("utf-8", "replace").strip()
    print(line)
    try:
        sys.exit(1 if "error" in json.loads(line) else 0)
    except ValueError:
        sys.exit(1)


if __name__ == "__main__":
    main()
