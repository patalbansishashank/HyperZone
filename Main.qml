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
      root._showLocate(data)   // find-my-cursor: pulse a border around the active window
      break
    case "error":
      ToastService.showError("HyperZone", data.message || "error")
      break
    }
  }

  // ---- find-my-cursor: transient pulsing border overlay ----
  // The daemon balloons the pointer itself (hyprctl setcursor) and emits `locate`
  // with the focused window's rect in monitor-LOCAL logical px. We draw a bright,
  // sine-pulsing border on a click-through overlay over that monitor, then vanish.
  // (Hyprland's own border colour can't be recoloured at runtime on this build, so
  // we render our own — full control over the fade.)
  property var _locate: null
  property var _locateScreen: null
  property bool _locateOn: false

  function _showLocate(d) {
    if (!d || d.w <= 0 || d.h <= 0) return
    // resolve the target monitor in JS up-front — binding `visible` to `screen`
    // fights PanelWindow's own screen management and loops.
    var scr = Quickshell.screens.find(s => s.name === d.monitor) || null
    if (!scr) return
    root._locate = d
    root._locateScreen = scr
    root._locateOn = true
    _locateTimer.interval = Math.max(300, d.duration_ms || 1500)
    _locateTimer.restart()
  }

  Timer { id: _locateTimer; onTriggered: root._locateOn = false }

  // Always declared, shown only during a locate. `screen`/`visible` bind to plain
  // properties (not to each other) so there's no binding loop; visible:false tears
  // the surface down between uses.
  PanelWindow {
    id: locateOvl
    readonly property var d: root._locate || ({})
    screen: root._locateScreen
    visible: root._locateOn
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "hyperzone-locate"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.exclusionMode: ExclusionMode.Ignore
    anchors { top: true; bottom: true; left: true; right: true }
    mask: Region {}   // fully click-through — draw only, never grab input

    Rectangle {
      x: locateOvl.d.x || 0
      y: locateOvl.d.y || 0
      width: locateOvl.d.w || 0
      height: locateOvl.d.h || 0
      color: "transparent"
      radius: 10
      antialiasing: true
      border.width: locateOvl.d.border || 6
      border.color: locateOvl.d.color || "#ffffff"
      // fade in/out on a sine — two InOutSine half-cycles ping-ponged while visible
      SequentialAnimation on opacity {
        running: locateOvl.visible
        loops: Animation.Infinite
        NumberAnimation { from: 0.15; to: 1.0; duration: 450; easing.type: Easing.InOutSine }
        NumberAnimation { from: 1.0; to: 0.15; duration: 450; easing.type: Easing.InOutSine }
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
