#!/usr/bin/env python3
"""HyperZone cursor-arrow overlay — the Noctalia 5 replacement for the arrow Main.qml drew.

Noctalia 5 plugins can only draw bar widgets, panels and desktop widgets. None of them can be a
transparent, click-through, full-screen surface above the windows, which is what this arrow needs.
So the daemon draws it itself through this helper: `hyperzone.py daemon --overlay overlay.py`
starts it on the first `locate` and keeps it running (empty, no surface mapped) between uses.

Protocol: one JSON object per line on stdin, the same `locate` / `locate_move` / `locate_end`
events the v4 plugin received ({"event": ..., "data": {...}}; coordinates are monitor-local
logical px). EOF on stdin means the daemon is gone, and we exit.

Toolkit: GTK 4 + gtk4-layer-shell through PyGObject (python-gobject, gtk4-layer-shell and
python-cairo packages). gtk4-layer-shell has to be loaded before libwayland-client, so the
script re-executes itself once with LD_PRELOAD set.
"""
import json
import math
import os
import sys
import time

LAYER_SHELL_LIB = "libgtk4-layer-shell.so"
if LAYER_SHELL_LIB not in os.environ.get("LD_PRELOAD", ""):
    for d in ("/usr/lib", "/usr/lib64", "/usr/local/lib"):
        if os.path.exists(os.path.join(d, LAYER_SHELL_LIB)):
            env = dict(os.environ)
            env["LD_PRELOAD"] = (os.path.join(d, LAYER_SHELL_LIB) + " " + env.get("LD_PRELOAD", "")).strip()
            os.execve(sys.executable, [sys.executable] + sys.argv, env)

import gi  # noqa: E402

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Gtk4LayerShell", "1.0")
gi.require_foreign("cairo")
import cairo  # noqa: E402
from gi.repository import Gdk, GLib, Gtk  # noqa: E402
from gi.repository import Gtk4LayerShell as LayerShell  # noqa: E402

# Arrow shape and motion — the same numbers Main.qml used, so it looks the way it did in v4.
ARROW_H = 56
HEAD_LEN = 46
HEAD_HALF = 26
SHAFT_H = 16
MOVE_SMOOTH_MS = 70        # QML Behavior on x/y
ROT_SMOOTH_MS = 130        # QML Behavior on rotation
FADE_MS = 300              # fade in / out
PULSE_HALF_MS = 520        # 1.0 -> 0.62 -> 1.0 blink
PULSE_LOW = 0.62
HIDE_AFTER_FADE_MS = 340


def log(*a):
    print("%.3f" % time.time(), *a, file=sys.stderr, flush=True)


def parse_hex(color):
    c = str(color or "#ffffff").lstrip("#")
    try:
        if len(c) == 8:  # #AARRGGBB (Qt order)
            return int(c[2:4], 16) / 255, int(c[4:6], 16) / 255, int(c[6:8], 16) / 255
        return int(c[0:2], 16) / 255, int(c[2:4], 16) / 255, int(c[4:6], 16) / 255
    except ValueError:
        return 1.0, 1.0, 1.0


class Overlay:
    def __init__(self, app):
        self.app = app
        self.windows = {}       # connector -> (window, drawing area)
        self.active_mon = None
        self.cfg = {}
        self.target = None      # (cx, cy) latest frame
        self.pos = None         # smoothed (cx, cy)
        self.angle = None       # smoothed rotation (radians)
        self.fade = 0.0
        self.fade_to = 0.0
        self.started = 0.0
        self.last_tick = None
        self.tick_id = None
        self._last_area_mon = None   # monitor whose drawing area carries the tick callback
        self.hide_src = None
        self.safety_src = None
        css = Gtk.CssProvider()
        data = "window.hz-locate { background: none; box-shadow: none; }"
        if hasattr(css, "load_from_string"):
            css.load_from_string(data)
        else:
            css.load_from_data(data.encode(), -1)
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), css,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    # ---- surfaces ----
    def monitor_for(self, connector):
        mons = Gdk.Display.get_default().get_monitors()
        for i in range(mons.get_n_items()):
            m = mons.get_item(i)
            if m.get_connector() == connector:
                return m
        return None

    def window_for(self, connector):
        if connector in self.windows:
            return self.windows[connector]
        mon = self.monitor_for(connector)
        if mon is None:
            return None
        win = Gtk.Window(application=self.app)
        win.add_css_class("hz-locate")
        win.set_decorated(False)
        LayerShell.init_for_window(win)
        LayerShell.set_namespace(win, "hyperzone-locate")
        LayerShell.set_layer(win, LayerShell.Layer.OVERLAY)
        LayerShell.set_keyboard_mode(win, LayerShell.KeyboardMode.NONE)
        LayerShell.set_exclusive_zone(win, -1)
        for edge in (LayerShell.Edge.TOP, LayerShell.Edge.BOTTOM, LayerShell.Edge.LEFT, LayerShell.Edge.RIGHT):
            LayerShell.set_anchor(win, edge, True)
        LayerShell.set_monitor(win, mon)
        area = Gtk.DrawingArea()
        area.set_draw_func(self.draw)
        area.set_can_target(False)
        win.set_child(area)
        win.set_can_target(False)
        # Click-through: an empty input region, re-applied whenever the surface is (re)created.
        win.connect("realize", self._make_click_through)
        self.windows[connector] = (win, area)
        return self.windows[connector]

    @staticmethod
    def _make_click_through(win):
        surf = win.get_surface()
        if surf is not None:
            surf.set_input_region(cairo.Region())

    def show_on(self, connector):
        if connector == self.active_mon:
            return True
        entry = self.window_for(connector)
        if entry is None:
            log("no monitor named", connector)
            return False
        for name, (w, _) in self.windows.items():
            if name != connector:
                w.set_visible(False)
        entry[0].present()
        self._make_click_through(entry[0])
        self.active_mon = connector
        return True

    def hide_all(self):
        for w, _ in self.windows.values():
            w.set_visible(False)
        self.active_mon = None
        self._stop_ticking()

    def _stop_ticking(self):
        if self.tick_id is not None:
            area = self.windows.get(self._last_area_mon, (None, None))[1]
            if area is not None:
                area.remove_tick_callback(self.tick_id)
        self.tick_id = None
        self._last_area_mon = None

    # ---- events ----
    def handle(self, ev, data):
        if ev == "locate":
            if "cx" not in data:
                return
            self.cfg = data
            self.started = time.monotonic()
            self._cancel(self.hide_src)
            self.hide_src = None
            self.pos = None
            self.angle = None
            self.frame(data)
            self.fade_to = 1.0
            self._arm_safety()
        elif ev == "locate_move":
            if self.fade_to <= 0 or "cx" not in data:
                return
            self.frame(data)
            self._arm_safety()
        elif ev == "locate_end":
            self.end()

    def frame(self, data):
        if not self.show_on(data.get("monitor")):
            return
        self.target = (float(data["cx"]), float(data["cy"]))
        if data.get("monitor") != self._last_area_mon:
            self.pos = None                      # crossed to another screen: jump, don't glide
        self._start_ticking(data.get("monitor"))

    def end(self):
        self.fade_to = 0.0
        self._cancel(self.safety_src)
        self.safety_src = None
        self._cancel(self.hide_src)
        self.hide_src = GLib.timeout_add(HIDE_AFTER_FADE_MS, self._hide_cb)

    def _hide_cb(self):
        self.hide_src = None
        if self.fade_to <= 0:
            self.hide_all()
        return False

    def _arm_safety(self):
        self._cancel(self.safety_src)
        ms = int(self.cfg.get("hold_ms", 1400)) + 9000   # hide if locate_end never comes
        self.safety_src = GLib.timeout_add(ms, self._safety_cb)

    def _safety_cb(self):
        self.safety_src = None
        self.end()
        return False

    @staticmethod
    def _cancel(src):
        if src:
            GLib.source_remove(src)

    # ---- animation ----
    def _start_ticking(self, mon):
        if self.tick_id is not None and self._last_area_mon == mon:
            return
        self._stop_ticking()
        area = self.windows[mon][1]
        self._last_area_mon = mon
        self.last_tick = None
        self.tick_id = area.add_tick_callback(self._tick)

    def _tick(self, area, clock):
        now = clock.get_frame_time() / 1e6
        dt = 0.016 if self.last_tick is None else max(0.0, min(0.1, now - self.last_tick))
        self.last_tick = now
        if self.target is not None:
            if self.pos is None:
                self.pos = self.target
            else:
                k = 1 - math.exp(-dt * 1000 / (MOVE_SMOOTH_MS / 2.5))
                self.pos = (self.pos[0] + (self.target[0] - self.pos[0]) * k,
                            self.pos[1] + (self.target[1] - self.pos[1]) * k)
            want = self._approach_angle(area)
            if self.angle is None:
                self.angle = want
            else:
                d = math.atan2(math.sin(want - self.angle), math.cos(want - self.angle))
                self.angle += d * (1 - math.exp(-dt * 1000 / (ROT_SMOOTH_MS / 2.5)))
        step = dt * 1000 / FADE_MS
        if self.fade < self.fade_to:
            self.fade = min(self.fade_to, self.fade + step)
        elif self.fade > self.fade_to:
            self.fade = max(self.fade_to, self.fade - step)
        area.queue_draw()
        return GLib.SOURCE_CONTINUE

    def _approach_angle(self, area):
        # Point down-right by default (arrow comes from the top-left); flip toward whichever
        # edge has room when the cursor is near the left or top border, so the body stays on screen.
        alen = float(self.cfg.get("arrow", 130))
        reach = alen * 0.72
        cx, cy = self.target
        sx = 1 if cx - reach >= 24 else -1
        sy = 1 if cy - reach >= 24 else -1
        return math.atan2(sy, sx)

    def draw(self, area, cr, width, height):
        cr.set_operator(cairo.OPERATOR_CLEAR)
        cr.paint()
        cr.set_operator(cairo.OPERATOR_OVER)
        if self.pos is None or self.angle is None or self.fade <= 0:
            return
        t = (time.monotonic() - self.started) * 1000
        phase = (t % (2 * PULSE_HALF_MS)) / PULSE_HALF_MS          # 0..2
        s = (1 - math.cos(math.pi * phase)) / 2                      # 0 -> 1 -> 0 (sine ease)
        pulse = 1.0 - (1.0 - PULSE_LOW) * s
        alpha = pulse * self.fade
        alen = float(self.cfg.get("arrow", 130))
        r, g, b = parse_hex(self.cfg.get("color"))
        cr.save()
        cr.translate(self.pos[0], self.pos[1])     # tip sits on the cursor
        cr.rotate(self.angle)
        cy = 0.0
        w = alen
        cr.move_to(-w, cy - SHAFT_H / 2)
        cr.line_to(-HEAD_LEN, cy - SHAFT_H / 2)
        cr.line_to(-HEAD_LEN, cy - HEAD_HALF)
        cr.line_to(0, cy)
        cr.line_to(-HEAD_LEN, cy + HEAD_HALF)
        cr.line_to(-HEAD_LEN, cy + SHAFT_H / 2)
        cr.line_to(-w, cy + SHAFT_H / 2)
        cr.close_path()
        cr.set_line_join(cairo.LINE_JOIN_ROUND)
        cr.set_source_rgba(r, g, b, alpha)
        cr.fill_preserve()
        cr.set_line_width(2)                       # dark rim: readable on any background
        cr.set_source_rgba(0, 0, 0, 0.55 * alpha)
        cr.stroke()
        cr.restore()


def main():
    app = Gtk.Application(application_id=None)
    state = {}

    def on_activate(app):
        if "ov" in state:
            return
        app.hold()                                   # no window at rest; stay alive anyway
        ov = state["ov"] = Overlay(app)
        buf = bytearray()
        os.set_blocking(0, False)

        def on_stdin(fd, cond):
            try:
                chunk = os.read(fd, 65536)
            except BlockingIOError:
                return True
            except OSError:
                chunk = b""
            if not chunk:
                app.quit()                           # daemon gone
                return False
            buf.extend(chunk)
            while b"\n" in buf:
                i = buf.index(b"\n")
                line = bytes(buf[:i]).decode("utf-8", "replace").strip()
                del buf[:i + 1]
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                    ov.handle(msg.get("event"), msg.get("data") or {})
                except Exception as e:               # a bad frame must never kill the overlay
                    log("frame error:", repr(e))
            return True

        cond = GLib.IOCondition.IN | GLib.IOCondition.HUP
        try:
            gi.require_version("GLibUnix", "2.0")
            from gi.repository import GLibUnix
            GLibUnix.fd_add_full(GLib.PRIORITY_DEFAULT, 0, cond, on_stdin)
        except (ImportError, ValueError):
            GLib.unix_fd_add_full(GLib.PRIORITY_DEFAULT, 0, cond, on_stdin)

    app.connect("activate", on_activate)
    app.run([sys.argv[0]])


if __name__ == "__main__":
    main()
