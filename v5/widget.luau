--!nonstrict
-- HyperZone bar widget: the way into the settings panel (v4 reached its settings through
-- Noctalia's plugin settings page, which v5 only offers for typed settings). Left click opens
-- the panel, right click re-tiles. The glyph dims while the daemon is not running.

local hz = require("./lib/hz.luau")

local daemon = noctalia.state.get("daemon") or { status = "starting" }
local snapshot = noctalia.state.get("snapshot")

local function managedNames()
  local out = {}
  local managed = snapshot and snapshot.config and snapshot.config.managed or {}
  for name, mc in pairs(managed) do
    if type(mc) == "table" and mc.enabled then
      local zones = mc.layout and mc.layout.zones or 4
      table.insert(out, { name = name, zones = zones })
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

local function render()
  barWidget.setGlyph(noctalia.getConfig("glyph") or "layout-grid")
  local up = daemon.status == "ready"
  barWidget.setGlyphColor(up and "on_surface" or "on_surface_variant")
  local rows = { { "HyperZone", up and "tiling" or (daemon.status == "starting" and "starting…" or "daemon not running") } }
  for _, m in ipairs(managedNames()) do
    table.insert(rows, { m.name, m.zones .. " zones" })
  end
  if snapshot and snapshot.pending_layout then
    table.insert(rows, { "Display change", "waiting for Keep / Revert" })
  end
  table.insert(rows, { "Click", "settings · right click: re-tile" })
  barWidget.setTooltip(rows)
end

noctalia.state.watch("daemon", function(v)
  daemon = v or { status = "down" }
  render()
end)
noctalia.state.watch("snapshot", function(v)
  snapshot = v
  render()
end)

-- Everything arrives through the state watches above; the tick is only a backstop.
noctalia.setUpdateInterval(5000)

function update()
  render()
end

function onClick()
  noctalia.togglePanel(hz.PANEL)
end

function onRightClick()
  hz.rpc("retile", {}, function(_, err)
    if err then
      noctalia.notifyError("HyperZone", "Re-tile failed: " .. err)
    end
  end)
end

render()
