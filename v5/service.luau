--!nonstrict
-- HyperZone daemon owner — the v5 counterpart of the Process block in Main.qml.
--
-- Runs `hyperzone.py daemon --events --overlay overlay.py` through noctalia.runStream, reads its
-- event lines, and publishes the daemon's state to the other entries through noctalia.state:
--   "daemon"   { status = "starting" | "ready" | "down", version = "…" }
--   "snapshot" the full state snapshot (config, monitors, pending_layout, extensions, migrated,
--              default_keybinds), kept current from the event stream
--   "pending"  the pending display layout ({deadline, remaining}) or false
-- Toasts that Main.qml showed (layout kept/reverted, daemon errors) become notifications.
--
-- The host terminates the stream (SIGTERM to the process group) when the plugin is disabled,
-- reloaded or Noctalia exits; the daemon stops cleanly on SIGTERM, and also stops on its own if
-- Noctalia dies without that (it watches for being reparented). A new daemon takes the control
-- socket over from any older instance, so enabling the plugin always wins.

local hz = require("./lib/hz.luau")

local MAX_RESTARTS = 5
local CHECK_MS = 3000

local restarts = 0
local startedAt = 0
local running = false
local snapshot = nil

local function shq(s)
  return "'" .. (string.gsub(s, "'", "'\\''")) .. "'"
end

local function setStatus(status, version)
  noctalia.state.set("daemon", { status = status, version = version or "" })
end

local function publish()
  if snapshot == nil then
    return
  end
  noctalia.state.set("snapshot", snapshot)
  noctalia.state.set("pending", snapshot.pending_layout or false)
end

local function refetch()
  hz.rpc("get_state", {}, function(r, err)
    if r ~= nil then
      snapshot = r
      publish()
    else
      noctalia.log("HyperZone: get_state failed: " .. tostring(err))
    end
  end)
end

local function onEvent(ev, data)
  if ev == "ready" then
    restarts = 0
    if data.refetch then
      refetch()
    else
      snapshot = data
      publish()
    end
    setStatus("ready", data.version)
    noctalia.log("HyperZone: daemon ready " .. tostring(data.version or ""))
  elseif ev == "config_changed" or ev == "monitors_changed" then
    if data.refetch or snapshot == nil then
      refetch()
    else
      if data.config ~= nil then
        snapshot.config = data.config
      end
      if data.monitors ~= nil then
        snapshot.monitors = data.monitors
      end
      publish()
    end
  elseif ev == "layout_pending" then
    if snapshot ~= nil then
      snapshot.pending_layout = data
    end
    noctalia.state.set("pending", data)
  elseif ev == "layout_committed" then
    if snapshot ~= nil then
      snapshot.pending_layout = nil
    end
    noctalia.state.set("pending", false)
    noctalia.notify("HyperZone", "Display layout kept")
  elseif ev == "layout_reverted" then
    if snapshot ~= nil then
      snapshot.pending_layout = nil
    end
    noctalia.state.set("pending", false)
    noctalia.notify("HyperZone", "Display layout reverted" .. (data.reason == "timeout" and " (not confirmed in time)" or ""))
  elseif ev == "error" then
    noctalia.notifyError("HyperZone", data.message or "error")
  end
end

local function onLine(line)
  if line == "" then
    return
  end
  local msg = noctalia.json.decode(line)
  if type(msg) ~= "table" or msg.event == nil then
    return
  end
  onEvent(msg.event, msg.data or {})
end

local function start()
  local daemon = hz.daemonPath()
  local overlay = hz.dir() .. "/overlay.py"
  local cmd = "exec python3 " .. shq(daemon) .. " daemon --events"
  if noctalia.getConfig("cursor_overlay") ~= false then
    cmd = cmd .. " --overlay " .. shq(overlay)
  end
  running = noctalia.runStream(cmd, onLine)
  startedAt = noctalia.nowMs()
  setStatus(running and "starting" or "down")
  noctalia.log("HyperZone: " .. (running and "starting daemon: " or "failed to start daemon: ") .. cmd)
end

-- runStream has no exit callback, so probe the control socket instead and restart the daemon
-- with the same capped backoff Main.qml used. Two misses in a row count as dead, so one slow
-- answer (a display apply in flight) never triggers a takeover of a healthy daemon.
local misses = 0
local probing = false

local function check()
  if not running or probing or noctalia.nowMs() - startedAt < CHECK_MS then
    return
  end
  probing = true
  hz.rpc("ping", {}, function(r, _err)
    probing = false
    if r ~= nil and r.mode == "events" then
      misses = 0
      return
    end
    misses += 1
    if misses < 2 then
      return
    end
    misses = 0
    running = false
    setStatus("down")
    if restarts < MAX_RESTARTS then
      restarts += 1
      noctalia.log("HyperZone: daemon gone; restart " .. restarts .. "/" .. MAX_RESTARTS)
      start()
    else
      noctalia.notifyError("HyperZone", "Tiling daemon keeps crashing — see $XDG_RUNTIME_DIR/hyperzone.log")
    end
  end, 8000)
end

noctalia.setUpdateInterval(CHECK_MS)

function update()
  check()
end

-- Settings are read once at start; keep the daemon (and the windows it holds) running through
-- a settings edit instead of letting the host restart this service.
function onConfigChanged() end

-- noctalia msg plugin shashank/hyperzone:daemon <event>
--   retile  -> re-snap every window into its zone (keeps the arrangement)
--   restart -> stop the daemon; the watchdog above starts a fresh one
--   refresh -> re-read the full state
function onIpc(event, _payload)
  if event == "retile" then
    hz.rpc("retile", {})
  elseif event == "refresh" then
    refetch()
  elseif event == "restart" then
    restarts = 0
    hz.rpc("ping", {}, function(r)
      if r ~= nil and r.pid ~= nil then
        noctalia.runAsync({ "kill", "-TERM", tostring(math.floor(r.pid)) })
      end
    end)
  end
end

setStatus("starting")
start()
