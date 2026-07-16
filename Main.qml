// HyperZone — plugin main instance.
// Owns the Python tiling daemon as a child Process and exposes a thin JSON-RPC
// client + mirrored daemon state for Settings.qml to bind to. ALL logic lives in
// the daemon; this file only starts it, ferries requests/events, and keeps it
// alive. That keeps the plugin trivial to port to a future Noctalia.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Services.UI

Item {
  id: root
  property var pluginApi: null

  // ---- mirrored daemon state (Settings.qml binds to these) ----
  property bool daemonReady: false
  property var config: ({})          // effective config (divider source form)
  property var monitors: []          // live monitors incl. availableModes
  property var pendingLayout: null   // {deadline, remaining} while a display change awaits confirm
  property bool migrated: false      // hyprland.lua sources monitors.lua yet?

  readonly property string daemonPath: (pluginApi ? pluginApi.pluginDir : "") + "/hyperzone.py"

  // ---- RPC request/reply ----
  property int _nextId: 1
  property var _callbacks: ({})      // id -> callback(result, errString)
  property var _deadlines: ({})      // id -> epoch-ms timeout
  property bool _wantRunning: true
  property int _restarts: 0

  // Send a request; cb(result, err) fires on reply, timeout, or daemon exit.
  function request(method, params, cb) {
    if (!backend.running || !root.daemonReady) {
      if (cb) cb(null, "daemon not running")
      return
    }
    var id = root._nextId++
    if (cb) {
      root._callbacks[id] = cb
      root._deadlines[id] = Date.now() + 10000
      if (!_timeout.running) _timeout.start()
    }
    backend.write(JSON.stringify({ id: id, method: method, params: params || {} }) + "\n")
  }

  function refresh() { request("get_state", {}, function (r) { if (r) _applySnapshot(r) }) }

  Timer {
    id: _timeout
    interval: 1000; repeat: true
    running: false
    onTriggered: {
      var now = Date.now(), any = false
      for (var id in root._deadlines) {
        if (now >= root._deadlines[id]) {
          var cb = root._callbacks[id]
          delete root._callbacks[id]; delete root._deadlines[id]
          if (cb) cb(null, "request timed out")
        } else any = true
      }
      if (!any) _timeout.stop()
    }
  }

  function _flushCallbacks(err) {
    for (var id in root._callbacks) {
      var cb = root._callbacks[id]
      if (cb) cb(null, err)
    }
    root._callbacks = ({}); root._deadlines = ({})
  }

  function _applySnapshot(s) {
    if (s.config) root.config = s.config
    if (s.monitors) root.monitors = s.monitors
    root.pendingLayout = s.pending_layout || null
    root.migrated = !!s.migrated
  }

  function handleMessage(line) {
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }
    if (msg.event !== undefined) { _handleEvent(msg.event, msg.data || {}); return }
    if (msg.id !== undefined) {
      var cb = root._callbacks[msg.id]
      if (cb) {
        delete root._callbacks[msg.id]; delete root._deadlines[msg.id]
        cb(msg.result || null, msg.error ? (msg.error.message || "error") : null)
      }
    }
  }

  function _handleEvent(ev, data) {
    switch (ev) {
    case "ready":
      root.daemonReady = true
      root._restarts = 0
      _applySnapshot(data)
      Logger.i("HyperZone", "daemon ready", data.version)
      break
    case "config_changed":
      if (data.config) root.config = data.config
      break
    case "monitors_changed":
      if (data.monitors) root.monitors = data.monitors
      break
    case "layout_pending":
      root.pendingLayout = data
      break
    case "layout_committed":
      root.pendingLayout = null
      ToastService.showNotice("HyperZone", "Display layout kept")
      break
    case "layout_reverted":
      root.pendingLayout = null
      ToastService.showNotice("HyperZone",
        "Display layout reverted" + (data.reason === "timeout" ? " (not confirmed in time)" : ""))
      break
    case "locate":
      root._startLocate(data)  // find-my-cursor / screen-share pointer: arrow appears
      break
    case "locate_move":
      root._moveLocate(data)   // live cursor frame — arrow (+ border) follow
      break
    case "locate_end":
      root._endLocate()        // cursor idle -> fade out
      break
    case "error":
      ToastService.showError("HyperZone", data.message || "error")
      break
    }
  }

  // ---- find-my-cursor / screen-share pointer ----
  // The daemon streams frames (monitor-LOCAL logical px): `locate` (start, carries config),
  // `locate_move` (a new cursor position), and `locate_end` (cursor idle -> fade). We DRAW
  // a sleek arrow that points AT the cursor and follows it live on a click-through overlay.
  // `_cfg` holds the static config from `start`; `_geo` is the latest frame; a shared
  // `_pulse * _fade` drives the arrow's blink and fade-in/out.
  property var _cfg: ({})
  property var _geo: ({})
  property var _locateScreen: null
  property bool _locateOn: false
  property real _pulse: 1.0                 // gentle sine blink while active
  property real _fade: 0.0                   // 0 hidden, 1 shown; Behavior animates it
  Behavior on _fade { NumberAnimation { duration: 300; easing.type: Easing.OutQuad } }
  readonly property real _op: _pulse * _fade

  // convenience geometry for the arrow (monitor-local logical px)
  readonly property real _cx: (_geo.cx || 0)
  readonly property real _cy: (_geo.cy || 0)
  readonly property real _alen: (_cfg.arrow || 130)
  readonly property real _sw: _locateScreen ? _locateScreen.width : 1920
  readonly property real _sh: _locateScreen ? _locateScreen.height : 1080
  // pick the approach side so the arrow BODY stays on-screen: come from the top-left
  // (point down-right) by default; flip toward whichever edge has room near a border.
  readonly property real _reach: _alen * 0.72
  readonly property int _sx: (_cx - _reach >= 24) ? 1 : -1
  readonly property int _sy: (_cy - _reach >= 24) ? 1 : -1
  readonly property real _angle: Math.atan2(_sy, _sx) * 180 / Math.PI

  function _startLocate(d) {
    if (!d || d.cx === undefined) return
    // resolve the target monitor in JS up-front — binding `visible` to `screen`
    // fights PanelWindow's own screen management and loops.
    var scr = Quickshell.screens.find(s => s.name === d.monitor) || null
    if (!scr) return
    root._cfg = d
    root._geo = d
    root._locateScreen = scr
    root._locateOn = true
    root._fade = 1.0
    _locateEnd.stop()
    _locateSafety.interval = (d.hold_ms || 1400) + 9000   // hide if `locate_end` never comes
    _locateSafety.restart()
  }
  function _moveLocate(d) {
    if (!root._locateOn || !d || d.cx === undefined) return
    if (d.monitor !== (root._geo.monitor || "")) {
      var scr = Quickshell.screens.find(s => s.name === d.monitor) || null
      if (scr) root._locateScreen = scr
    }
    root._geo = d
    _locateSafety.restart()
  }
  function _endLocate() {
    root._fade = 0.0
    _locateEnd.restart()          // hide once the fade finishes
  }

  Timer { id: _locateEnd; interval: 340; onTriggered: root._locateOn = false }
  Timer { id: _locateSafety; onTriggered: root._endLocate() }

  // gentle blink while active; multiplied by _fade for the fade-in/out
  SequentialAnimation on _pulse {
    running: root._locateOn
    loops: Animation.Infinite
    NumberAnimation { from: 1.0; to: 0.62; duration: 520; easing.type: Easing.InOutSine }
    NumberAnimation { from: 0.62; to: 1.0; duration: 520; easing.type: Easing.InOutSine }
  }

  // Always declared, shown only during a locate. `screen`/`visible` bind to plain
  // properties (not to each other) so there's no binding loop; visible:false tears
  // the surface down between uses.
  PanelWindow {
    id: locateOvl
    screen: root._locateScreen
    visible: root._locateOn
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "hyperzone-locate"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.exclusionMode: ExclusionMode.Ignore
    anchors { top: true; bottom: true; left: true; right: true }
    mask: Region {}   // fully click-through — draw only, never grab input

    // This overlay only draws the arrow (no window highlight).

    // the pointer arrow: drawn once (Canvas) pointing right with its tip at Item.Right,
    // then rotated to `_angle` and positioned so the tip sits on the cursor. Behaviors
    // on x/y/rotation smooth the daemon's discrete ~33 Hz frames into fluid motion.
    Item {
      id: arrow
      visible: root._geo.cx !== undefined
      width: root._alen
      height: 56
      transformOrigin: Item.Right                 // pivot = the tip, stays on the cursor
      x: root._cx - width
      y: root._cy - height / 2
      rotation: root._angle
      opacity: root._op
      Behavior on x { NumberAnimation { duration: 70; easing.type: Easing.OutQuad } }
      Behavior on y { NumberAnimation { duration: 70; easing.type: Easing.OutQuad } }
      Behavior on rotation { NumberAnimation { duration: 130; easing.type: Easing.OutQuad } }

      Canvas {
        anchors.fill: parent
        readonly property color tint: root._cfg.color || "#ffffff"
        onTintChanged: requestPaint()
        onWidthChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var W = width, H = height, cy = H / 2
          var headLen = 46, headHalf = 26, shaftH = 16
          ctx.lineJoin = "round"
          ctx.beginPath()
          ctx.moveTo(0, cy - shaftH / 2)                 // shaft top-left
          ctx.lineTo(W - headLen, cy - shaftH / 2)       // shaft top-right
          ctx.lineTo(W - headLen, cy - headHalf)         // head top flare
          ctx.lineTo(W, cy)                              // tip
          ctx.lineTo(W - headLen, cy + headHalf)         // head bottom flare
          ctx.lineTo(W - headLen, cy + shaftH / 2)       // shaft bottom-right
          ctx.lineTo(0, cy + shaftH / 2)                 // shaft bottom-left
          ctx.closePath()
          ctx.fillStyle = tint
          ctx.fill()
          ctx.lineWidth = 2                              // dark rim -> readable on any bg
          ctx.strokeStyle = "rgba(0,0,0,0.55)"
          ctx.stroke()
        }
      }
    }
  }

  Process {
    id: backend
    command: ["python3", root.daemonPath, "daemon", "--stdio"]
    running: pluginApi !== null && pluginApi.manifest !== null && root._wantRunning
    stdinEnabled: true

    stdout: SplitParser {
      onRead: (data) => { var l = data.trim(); if (l !== "") root.handleMessage(l) }
    }
    stderr: SplitParser {
      onRead: (data) => { var l = data.trim(); if (l !== "") Logger.w("HyperZone", l) }
    }

    onStarted: Logger.i("HyperZone", "daemon starting")
    onExited: (code, status) => {
      Logger.w("HyperZone", "daemon exited", code)
      root.daemonReady = false
      root._flushCallbacks("daemon exited")
      if (root._restarts < 5) {          // backoff-restart a crashed daemon, capped
        root._restarts++
        root._wantRunning = false
        _restart.start()
      } else {
        Logger.e("HyperZone", "daemon failed repeatedly; giving up")
        ToastService.showError("HyperZone", "Tiling daemon keeps crashing — see logs")
      }
    }
  }

  // Toggling _wantRunning false->true re-triggers the Process `running` binding.
  Timer { id: _restart; interval: 2000; onTriggered: root._wantRunning = true }

  Component.onCompleted: if (pluginApi) Logger.i("HyperZone", "plugin loaded", pluginApi.pluginId)
}
