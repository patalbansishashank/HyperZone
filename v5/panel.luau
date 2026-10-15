--!nonstrict
-- HyperZone settings panel — the v5 port of Settings.qml. Same model as v4: a thin form that
-- edits a local copy of the daemon's effective config and sends it back with set_config, plus a
-- display editor that sends apply_monitor_layout (confirm-or-revert enforced by the daemon).
--
-- What changed against the QML (the declarative ui.* vocabulary has no free-form canvas and no
-- arbitrary key capture):
--   * Displays: monitors are picked from a row of buttons and positioned with X / Y fields
--     instead of being dragged on a canvas.
--   * Zones: the dividers are sliders under a to-scale preview instead of draggable lines; fill
--     order uses up / down buttons instead of a drag list.
--   * Keybinds: chords are typed ("SUPER + CTRL + left") instead of recorded — a panel can only
--     capture chords it declared up front, and never Super chords.

local hz = require("./lib/hz.luau")

local W = 700 -- content width inside the panel

-- ---------------------------------------------------------------- static UI data
local KEYBIND_GROUPS = {
  { title = "Focus", desc = "Move focus by direction — layout-aware, crosses to the monitor beside the window",
    items = { { "focus-left", "Focus left" }, { "focus-right", "Focus right" }, { "focus-up", "Focus up" }, { "focus-down", "Focus down" } } },
  { title = "Move within a screen", desc = "Shuffle the focused window between zones",
    items = { { "move-left", "Move left" }, { "move-right", "Move right" }, { "move-up", "Move up" }, { "move-down", "Move down" } } },
  { title = "Send to monitor", desc = "Throw the window to the screen in that direction",
    items = { { "tomon-left", "To monitor ← left" }, { "tomon-right", "To monitor → right" }, { "tomon-up", "To monitor ↑ up" }, { "tomon-down", "To monitor ↓ down" } } },
  { title = "Send to workspace", desc = "Throw the focused window to another workspace. Switching which workspace you are looking at stays with Hyprland (Super+1…0)",
    items = { { "tows-1", "To workspace 1" }, { "tows-2", "To workspace 2" }, { "tows-3", "To workspace 3" }, { "tows-4", "To workspace 4" },
              { "tows-5", "To workspace 5" }, { "tows-6", "To workspace 6" }, { "tows-7", "To workspace 7" }, { "tows-8", "To workspace 8" },
              { "tows-9", "To workspace 9" }, { "tows-10", "To workspace 10" }, { "tows-special", "To special (magic)" } } },
  { title = "Move across everything", desc = "Rearrange in-screen, then spill to the next monitor at the edge",
    items = { { "push-left", "Push left" }, { "push-right", "Push right" }, { "push-up", "Push up" }, { "push-down", "Push down" } } },
  { title = "Swap window", desc = "Trade places with the window in that direction — works across screens too",
    items = { { "swap-left", "Swap ← left" }, { "swap-right", "Swap → right" }, { "swap-up", "Swap ↑ up" }, { "swap-down", "Swap ↓ down" } } },
  { title = "Window state", desc = "Fullscreen the focused window · Group stacks the windows in a zone as tabs",
    items = { { "fullscreen", "Toggle fullscreen" }, { "toggle-group", "Toggle group / tabs" } } },
  { title = "Close window", desc = "Close asks the window to close · Force kill SIGKILLs the whole process (no save prompt, every window it owns)",
    items = { { "close-window", "Close window" }, { "kill-window", "Force kill app (no save!)" } } },
  { title = "Cursor pointer", desc = "Pops an arrow that points at the cursor and follows it live, then fades once you stop moving",
    items = { { "locate-cursor", "Show cursor pointer arrow" } } },
  { title = "Actions", desc = "Re-tile re-snaps windows into their zones · Rearrange is a hard reset that also reclaims floated windows",
    items = { { "toggle-float", "Toggle float" }, { "rearrange", "Rearrange all" }, { "retile", "Re-tile / re-snap" } } },
  { title = "Mouse gesture", desc = "Hold the modifier and drag with the left button to move a window; the toggle key flips mid-drag between snapping into the zone and leaving it floating (amber border)",
    items = { { "drag-window", "Drag a window", "drag" }, { "drag-toggle", "Toggle the drop", "modifier" } } },
}

local ZONE_NAMES = { "Blue", "Green", "Orange", "Red" }
local ZONE_HEX = { "#4c8dff", "#3fc16a", "#f59234", "#ef5350" }
local ZONE_FILL = { "#4c8dff38", "#3fc16a38", "#f5923438", "#ef535038" }
local SCALES = { "1", "1.25", "1.33", "1.5", "1.6", "1.67", "1.75", "2" }
local ROTATIONS = { "Normal", "90°", "180°", "270°" }
local ZONE_COUNTS = { 1, 2, 4 }
local ZONE_COUNT_LABELS = { "1 · off", "2 zones", "4 zones" }
local MODIFIERS = { "(none)", "CTRL", "ALT", "SHIFT", "SUPER" }
local TABS = { "Displays", "Zones", "Keybinds", "General" }

-- ---------------------------------------------------------------- state
local daemon = noctalia.state.get("daemon") or { status = "starting" }
local snap = noctalia.state.get("snapshot")
local pending = noctalia.state.get("pending") or false
local edit = {}
local cfgBaseline = ""
local dispEdit = {}
local dispBaseline = ""
local dispSel = 1
local zoneMon = nil
local tab = 1
local loadRev = 0 -- bumped on every reload, so uncontrolled inputs re-seed
local addRev = 0  -- bumped to clear "add" inputs after a submit
local kbDraft = {} -- action id -> text typed into its add field
local denyDraft = ""

local render -- forward

-- ---------------------------------------------------------------- helpers
local function enc(v)
  return noctalia.json.encode(v) or ""
end

local function indexOf(list, value)
  for i, v in ipairs(list) do
    if v == value then
      return i
    end
  end
  return nil
end

local function copyList(list)
  local out = {}
  for i, v in ipairs(list or {}) do
    out[i] = v
  end
  return out
end

local function toast(msg)
  noctalia.notify("HyperZone", msg)
end

local function toastErr(msg)
  noctalia.notifyError("HyperZone", msg)
end

local function fmtNum(n)
  local s = string.format("%.2f", tonumber(n) or 0)
  s = string.gsub(s, "0+$", "")
  s = string.gsub(s, "%.$", "")
  return s
end

-- ---------------------------------------------------------------- config model (ported from Settings.qml)
local function defaultLayout()
  return { zones = 4, vsplit = 1 / 3, hsplit = 1 / 3, fill = { 3, 2, 1, 0 }, subdivide = { 1, 2 } }
end

local function defaultFill(z)
  local a = {}
  for i = 0, z - 1 do
    table.insert(a, z - 1 - i)
  end
  return a
end

local function monEntry(name)
  edit.managed = edit.managed or {}
  if edit.managed[name] == nil then
    edit.managed[name] = { enabled = false, layout = defaultLayout() }
  end
  if edit.managed[name].layout == nil then
    edit.managed[name].layout = defaultLayout()
  end
  return edit.managed[name]
end

local function layoutOf(name)
  return monEntry(name).layout
end

local function fillOf(name)
  local l = layoutOf(name)
  if l.fill ~= nil and #l.fill > 0 then
    return l.fill
  end
  return defaultFill(l.zones or 4)
end

local function isManaged(name)
  local mc = edit.managed and edit.managed[name]
  return mc ~= nil and mc.enabled == true
end

local function zoneCountOf(name)
  return isManaged(name) and (layoutOf(name).zones or 4) or 1
end

local function allMonitorNames()
  local out = {}
  for name, _ in pairs(edit.managed or {}) do
    table.insert(out, name)
  end
  table.sort(out)
  return out
end

local function combosOf(id)
  return copyList((edit.keybinds or {})[id])
end

local function setCombos(id, arr)
  edit.keybinds = edit.keybinds or {}
  edit.keybinds[id] = arr
end

local MODMAP = { super = "SUPER", win = "SUPER", meta = "SUPER", mod = "SUPER", cmd = "SUPER",
                 ctrl = "CTRL", control = "CTRL", alt = "ALT", mod1 = "ALT", shift = "SHIFT" }
local MODORDER = { SUPER = 1, CTRL = 2, ALT = 3, SHIFT = 4 }
local NAMED = { left = true, right = true, up = true, down = true, space = true, tab = true, ["return"] = true, escape = true }

-- "super+ctrl+left" -> "SUPER + CTRL + left"; "" when there is no real key.
local function normalizeCombo(s, modsOnly)
  local mods, key = {}, ""
  for part in string.gmatch(tostring(s or ""), "[^+]+") do
    local p = noctalia.string.trim(part)
    if p ~= "" then
      local m = MODMAP[string.lower(p)]
      if m ~= nil then
        if indexOf(mods, m) == nil then
          table.insert(mods, m)
        end
      else
        key = p
      end
    end
  end
  table.sort(mods, function(a, b) return MODORDER[a] < MODORDER[b] end)
  if modsOnly then
    return table.concat(mods, " + ")
  end
  if key == "" then
    return ""
  end
  local kl = string.lower(key)
  if NAMED[kl] then
    key = kl
  elseif #key == 1 then
    key = string.upper(key)
  end
  table.insert(mods, key)
  return table.concat(mods, " + ")
end

local function keybindLabel(id)
  for _, g in ipairs(KEYBIND_GROUPS) do
    for _, it in ipairs(g.items) do
      if it[1] == id then
        return it[2]
      end
    end
  end
  for _, e in ipairs(snap and snap.extensions or {}) do
    for _, a in ipairs(e.actions or {}) do
      if a.id == id then
        return a.label or a.id
      end
    end
  end
  return id
end

local function comboOwner(combo)
  for act, combos in pairs(edit.keybinds or {}) do
    if indexOf(combos, combo) ~= nil then
      return act
    end
  end
  return nil
end

local function addCombo(id, raw)
  local combo = normalizeCombo(raw, false)
  if combo == "" then
    toast("Type a combo like SUPER + CTRL + left")
    return false
  end
  local owner = comboOwner(combo)
  if owner == id then
    return true
  end
  if owner ~= nil then
    toast(combo .. " is already bound to “" .. keybindLabel(owner) .. "”")
    return false
  end
  local arr = combosOf(id)
  if #arr >= 3 then
    toast("An action holds at most 3 shortcuts — remove one first")
    return false
  end
  table.insert(arr, combo)
  setCombos(id, arr)
  return true
end

local function removeCombo(id, combo)
  local out = {}
  for _, c in ipairs(combosOf(id)) do
    if c ~= combo then
      table.insert(out, c)
    end
  end
  setCombos(id, out)
end

-- ---------------------------------------------------------------- displays model
local function currentModeOf(m)
  local pfx = tostring(m.width) .. "x" .. tostring(m.height) .. "@"
  local modes = {}
  for _, s in ipairs(m.availableModes or {}) do
    if string.sub(s, 1, #pfx) == pfx then
      table.insert(modes, s)
    end
  end
  local rr = math.floor((m.refreshRate or 0) + 0.5)
  for _, s in ipairs(modes) do
    local hzv = tonumber((string.match(s, "@([%d%.]+)")))
    if hzv ~= nil and math.floor(hzv + 0.5) == rr then
      return s
    end
  end
  if #modes > 0 then
    return modes[1]
  end
  return pfx .. string.format("%.2f", m.refreshRate or 60) .. "Hz"
end

local function dispSpecs()
  local out = {}
  for _, d in ipairs(dispEdit) do
    table.insert(out, { name = d.name, mode = d.mode, x = math.floor(d.x + 0.5), y = math.floor(d.y + 0.5),
                        scale = d.scale, transform = d.transform, disabled = d.disabled })
  end
  return out
end

local function displaysDirty()
  return enc(dispSpecs()) ~= dispBaseline
end

local function configDirty()
  return enc(edit) ~= cfgBaseline
end

local function reloadConfig()
  edit = hz.clone(snap and snap.config or {}) or {}
  edit.managed = edit.managed or {}
  cfgBaseline = enc(edit)
  local names = allMonitorNames()
  if zoneMon == nil or edit.managed[zoneMon] == nil then
    zoneMon = names[1]
    for _, name in ipairs(names) do
      if isManaged(name) then
        zoneMon = name -- open on a screen that is actually tiled
        break
      end
    end
  end
end

local function reloadDisplays()
  dispEdit = {}
  for _, m in ipairs(snap and snap.monitors or {}) do
    table.insert(dispEdit, {
      name = m.name, description = m.description or "", mode = currentModeOf(m), x = m.x or 0, y = m.y or 0,
      scale = m.scale or 1, transform = m.transform or 0, disabled = m.disabled == true,
      noEdid = m.noEdid == true, modes = copyList(m.availableModes),
    })
  end
  if dispSel > #dispEdit then
    dispSel = 1
  end
  dispBaseline = enc(dispSpecs())
end

local function reloadAll()
  reloadConfig()
  reloadDisplays()
  loadRev += 1
end

local function selDisp()
  return dispEdit[dispSel]
end

local function scaleIndex(s)
  local v = tonumber(s) or 1
  local best, bd = nil, 0.02
  for i, k in ipairs(SCALES) do
    local d = math.abs(tonumber(k) - v)
    if d < bd then
      best, bd = i, d
    end
  end
  return best
end

-- ---------------------------------------------------------------- daemon calls
local function applyConfig(after)
  hz.rpc("set_config", { config = edit }, function(r, err)
    if err then
      toastErr("Save failed: " .. err)
    elseif r and r.config then
      snap = snap or {}
      snap.config = r.config
      reloadConfig()
      loadRev += 1
      if after then
        after()
      end
    end
    render()
  end)
end

local function applyDisplays()
  hz.rpc("apply_monitor_layout", { monitors = dispSpecs() }, function(_, err)
    if err then
      toastErr("Display apply failed: " .. err)
    end
    render()
  end, 30000)
end

local function saveSettings()
  local dispDirty = displaysDirty()
  local function displaysStep()
    if not dispDirty then
      return
    end
    if pending then
      toast("Display change waiting for Keep / Revert — new display edits not applied")
      return
    end
    applyDisplays()
  end
  if configDirty() then
    applyConfig(displaysStep)
  else
    displaysStep()
  end
end

local function setZoneCount(name, n)
  if n == 1 then
    monEntry(name).enabled = false
  else
    local mc = monEntry(name)
    mc.enabled = true
    local l = mc.layout
    l.zones = n
    l.fill = defaultFill(n)
    local sub = {}
    for _, i in ipairs(l.subdivide or {}) do
      if i < n then
        table.insert(sub, i)
      end
    end
    l.subdivide = sub
  end
  applyConfig(nil) -- like v4: the zone count applies at once
end

-- ---------------------------------------------------------------- small UI builders
local function heading(text)
  return ui.label({ text = text, fontWeight = "semibold", color = "on_surface" })
end

local function hint(text)
  return ui.label({ text = text, fontSize = 11, color = "on_surface_variant", maxWidth = W, maxLines = 6 })
end

local function labelled(title, control)
  return ui.column({ gap = 4 }, { ui.label({ text = title, fontSize = 12, color = "on_surface_variant" }), control })
end

-- ---------------------------------------------------------------- Displays tab
local function displaysTab()
  local kids = { heading("Displays"), hint("Pick a display, then set resolution, scale, rotation and position. Positions are logical px; the layout applies live with a 15-second Keep / Revert.") }
  local pick = {}
  for i, d in ipairs(dispEdit) do
    table.insert(pick, ui.button({
      key = "disp-" .. d.name, text = d.name, controlSize = "sm",
      variant = (i == dispSel) and "primary" or "outline",
      tooltip = (d.description ~= "" and d.description or d.name) .. " · " .. string.gsub(d.mode, "Hz", "") .. " at " .. fmtNum(d.x) .. "," .. fmtNum(d.y),
      onClick = function() dispSel = i; render() end,
    }))
  end
  table.insert(kids, ui.row({ gap = 6 }, pick))

  local d = selDisp()
  if d ~= nil then
    local modeLabels = {}
    for _, s in ipairs(d.modes) do
      table.insert(modeLabels, (string.gsub(s, "Hz", "")))
    end
    if #modeLabels == 0 then
      table.insert(modeLabels, (string.gsub(d.mode, "Hz", "")))
    end
    local scaleLabels = {}
    for _, s in ipairs(SCALES) do
      table.insert(scaleLabels, s .. "×")
    end
    local si = scaleIndex(d.scale)
    if si == nil then
      table.insert(scaleLabels, fmtNum(d.scale) .. "× (custom)")
      si = #scaleLabels
    end
    local zc = zoneCountOf(d.name)
    table.insert(kids, ui.column({ gap = 10, padding = 12, radius = 10, fill = "surface_variant/0.5" }, {
      ui.label({ text = d.name .. (d.description ~= "" and ("  ·  " .. d.description) or ""), fontWeight = "semibold" }),
      ui.row({ gap = 10 }, {
        labelled("Resolution", ui.select({ key = "mode-" .. d.name, options = modeLabels, width = 230,
          selectedIndex = math.max(0, (indexOf(d.modes, d.mode) or 1) - 1),
          onChange = function(idx) local m = d.modes[(tonumber(idx) or 0) + 1]; if m then d.mode = m end; render() end })),
        labelled("Scale", ui.select({ key = "scale-" .. d.name, options = scaleLabels, width = 140, selectedIndex = si - 1,
          onChange = function(idx) local k = SCALES[(tonumber(idx) or 0) + 1]; if k then d.scale = tonumber(k) end; render() end })),
        labelled("Rotation", ui.select({ key = "rot-" .. d.name, options = ROTATIONS, width = 120, selectedIndex = d.transform % 4,
          onChange = function(idx) d.transform = tonumber(idx) or 0; render() end })),
        labelled("Zones", ui.select({ key = "zc-" .. d.name, options = ZONE_COUNT_LABELS, width = 120,
          selectedIndex = (indexOf(ZONE_COUNTS, zc) or 1) - 1,
          onChange = function(idx) setZoneCount(d.name, ZONE_COUNTS[(tonumber(idx) or 0) + 1] or 1); render() end })),
      }),
      ui.row({ gap = 10, align = "end" }, {
        labelled("X", ui.input({ key = "x-" .. d.name .. "-" .. loadRev, value = tostring(math.floor(d.x + 0.5)), width = 120, controlSize = "sm",
          onChange = function(v) local n = tonumber(v); if n then d.x = n end end })),
        labelled("Y", ui.input({ key = "y-" .. d.name .. "-" .. loadRev, value = tostring(math.floor(d.y + 0.5)), width = 120, controlSize = "sm",
          onChange = function(v) local n = tonumber(v); if n then d.y = n end end })),
        ui.label({ text = "top-left corner, logical px", fontSize = 11, color = "on_surface_variant" }),
      }),
    }))
    if d.noEdid then
      table.insert(kids, hint("This display publishes no EDID, so it cannot tell us what it supports — the resolutions above are standard VESA timings. If none gives a correct picture, enter a custom timing (Enter to keep it)."))
      table.insert(kids, ui.input({ key = "ml-" .. d.name .. "-" .. loadRev,
        value = (edit.modelines and edit.modelines[d.name]) or "",
        placeholder = "modeline 148.50 1920 2008 2052 2200 1080 1084 1089 1125 +hsync +vsync",
        onChange = function(v)
          edit.modelines = edit.modelines or {}
          local t = noctalia.string.trim(v)
          edit.modelines[d.name] = (t ~= "") and t or nil
        end }))
    end
  end
  table.insert(kids, hint("Press Apply at the bottom to apply display changes." ..
    ((snap and not snap.migrated) and " Changes reset on a Hyprland reload until you use “Persist displays” in General (one-time)." or "")))
  return ui.column({ gap = 10 }, kids)
end

-- ---------------------------------------------------------------- Zones tab
local function zonePreview(l)
  local PW, PH = 480, 270
  local v = math.clamp(l.vsplit or 1 / 3, 0.05, 0.95)
  local h = math.clamp(l.hsplit or 1 / 3, 0.05, 0.95)
  local fill = (l.fill and #l.fill > 0) and l.fill or defaultFill(l.zones or 4)
  local function cell(zi, w, hh)
    local order = indexOf(fill, zi)
    local splits = indexOf(l.subdivide or {}, zi) ~= nil
    return ui.column({ key = "cell" .. zi, width = w, height = hh, fill = ZONE_FILL[zi + 1], border = ZONE_HEX[zi + 1],
                       borderWidth = 2, radius = 4, align = "center", justify = "center" }, {
      ui.label({ text = order and tostring(order) or "–", fontSize = 20, fontWeight = "bold", color = ZONE_HEX[zi + 1] }),
      ui.label({ text = ZONE_NAMES[zi + 1] .. (splits and " · splits" or ""), fontSize = 11, color = ZONE_HEX[zi + 1] }),
    })
  end
  if (l.zones or 4) == 2 then
    return ui.row({ gap = 0, width = PW, height = PH }, { cell(0, PW * v, PH), cell(1, PW * (1 - v), PH) })
  end
  return ui.column({ gap = 0, width = PW, height = PH }, {
    ui.row({ gap = 0 }, { cell(0, PW * v, PH * h), cell(1, PW * (1 - v), PH * h) }),
    ui.row({ gap = 0 }, { cell(2, PW * v, PH * (1 - h)), cell(3, PW * (1 - v), PH * (1 - h)) }),
  })
end

local function orderRow(key, text, isFirst, isLast, onUp, onDown, extra)
  local kids = {
    ui.label({ text = text, flexGrow = 1 }),
  }
  if extra then
    table.insert(kids, extra)
  end
  table.insert(kids, ui.button({ glyph = "chevron-up", variant = "ghost", controlSize = "sm", enabled = not isFirst, tooltip = "Earlier", onClick = onUp }))
  table.insert(kids, ui.button({ glyph = "chevron-down", variant = "ghost", controlSize = "sm", enabled = not isLast, tooltip = "Later", onClick = onDown }))
  return ui.row({ key = key, gap = 8, align = "center", paddingH = 8, radius = 6, fill = "surface_variant/0.4" }, kids)
end

local function swapIn(list, i, j)
  local out = copyList(list)
  out[i], out[j] = out[j], out[i]
  return out
end

local function zonesTab()
  local names = allMonitorNames()
  local kids = { heading("Zones"), hint("How many zones to split each screen into — 1 leaves it on default Hyprland. Changes take effect when you press Apply (the zone count applies at once).") }
  local pick = {}
  for _, name in ipairs(names) do
    local zc = zoneCountOf(name)
    table.insert(pick, ui.button({ key = "zm-" .. name, text = name .. " · " .. (zc == 1 and "off" or (zc .. " zones")), controlSize = "sm",
      variant = (name == zoneMon) and "primary" or "outline", onClick = function() zoneMon = name; render() end }))
  end
  table.insert(kids, ui.row({ gap = 6 }, pick))
  if zoneMon == nil then
    return ui.column({ gap = 10 }, kids)
  end
  local mon = zoneMon
  local zc = zoneCountOf(mon)
  table.insert(kids, ui.row({ gap = 10, align = "center" }, {
    ui.label({ text = "Zones:" }),
    ui.select({ key = "zcz-" .. mon, options = ZONE_COUNT_LABELS, width = 140, selectedIndex = (indexOf(ZONE_COUNTS, zc) or 1) - 1,
      onChange = function(idx) setZoneCount(mon, ZONE_COUNTS[(tonumber(idx) or 0) + 1] or 1); render() end }),
  }))
  if zc == 1 then
    table.insert(kids, hint("Single zone — this screen keeps Hyprland's default tiling. HyperZone still moves windows and focus to and from it; it just doesn't split it into zones."))
    return ui.column({ gap = 10 }, kids)
  end
  local l = layoutOf(mon)
  table.insert(kids, ui.row({ justify = "center" }, { zonePreview(l) }))
  table.insert(kids, labelled("Vertical divider — left column " .. math.floor((l.vsplit or 1 / 3) * 100 + 0.5) .. "%",
    ui.slider({ key = "vs-" .. mon, min = 5, max = 95, step = 1, value = math.floor((l.vsplit or 1 / 3) * 100 + 0.5),
      onChange = function(v) l.vsplit = (tonumber(v) or 33) / 100; render() end })))
  if zc == 4 then
    table.insert(kids, labelled("Horizontal divider — top row " .. math.floor((l.hsplit or 1 / 3) * 100 + 0.5) .. "%",
      ui.slider({ key = "hs-" .. mon, min = 5, max = 95, step = 1, value = math.floor((l.hsplit or 1 / 3) * 100 + 0.5),
        onChange = function(v) l.hsplit = (tonumber(v) or 33) / 100; render() end })))
  end

  table.insert(kids, hint("Fill order (top = first) · the toggle marks a zone that subdivides when a second window lands"))
  local fill = fillOf(mon)
  for i, zi in ipairs(fill) do
    local sub = l.subdivide or {}
    local on = indexOf(sub, zi) ~= nil
    table.insert(kids, orderRow("fill-" .. mon .. "-" .. zi, i .. ".  " .. ZONE_NAMES[zi + 1], i == 1, i == #fill,
      function() l.fill = swapIn(fill, i, i - 1); render() end,
      function() l.fill = swapIn(fill, i, i + 1); render() end,
      ui.row({ gap = 6, align = "center" }, {
        ui.label({ text = "subdivides", fontSize = 11, color = "on_surface_variant" }),
        ui.toggle({ checked = on, onChange = function(v)
          local s = copyList(l.subdivide)
          local at = indexOf(s, zi)
          if v == "true" and at == nil then
            table.insert(s, zi)
          elseif v ~= "true" and at ~= nil then
            table.remove(s, at)
          end
          l.subdivide = s
          render()
        end }),
      })))
  end
  local sub = l.subdivide or {}
  if #sub >= 2 then
    table.insert(kids, hint("Subdivision fill order"))
    for i, zi in ipairs(sub) do
      table.insert(kids, orderRow("sub-" .. mon .. "-" .. zi, i .. ".  " .. ZONE_NAMES[zi + 1], i == 1, i == #sub,
        function() l.subdivide = swapIn(sub, i, i - 1); render() end,
        function() l.subdivide = swapIn(sub, i, i + 1); render() end, nil))
    end
  end
  return ui.column({ gap = 10 }, kids)
end

-- ---------------------------------------------------------------- Keybinds tab
local function allKeybindGroups()
  local groups = {}
  for _, g in ipairs(KEYBIND_GROUPS) do
    table.insert(groups, g)
  end
  for _, e in ipairs(snap and snap.extensions or {}) do
    local items = {}
    for _, a in ipairs(e.actions or {}) do
      table.insert(items, { a.id, a.label or a.id })
    end
    table.insert(groups, { title = e.name or e.id, desc = ((e.desc and e.desc ~= "") and (e.desc .. " · ") or "") .. "from the “" .. tostring(e.id) .. "” extension", items = items })
  end
  return groups
end

local function comboPill(id, combo, shown)
  return ui.button({ key = "pill-" .. id .. "-" .. combo, text = shown or combo, glyph = "x", controlSize = "sm", variant = "secondary",
    tooltip = "Remove", onClick = function() removeCombo(id, combo); render() end })
end

local function keybindRow(item)
  local id, label, mode = item[1], item[2], item[3]
  local kids = { ui.label({ text = label, width = 210 }) }
  if mode == "modifier" then
    local cur = combosOf(id)[1] or ""
    table.insert(kids, ui.select({ key = "mod-" .. id, options = MODIFIERS, width = 140, controlSize = "sm",
      selectedIndex = (indexOf(MODIFIERS, cur) or 1) - 1,
      onChange = function(idx)
        local m = MODIFIERS[(tonumber(idx) or 0) + 1]
        setCombos(id, (m == nil or m == "(none)") and {} or { m })
        render()
      end }))
  elseif mode == "drag" then
    local SUFFIX = " + mouse:272"
    for _, c in ipairs(combosOf(id)) do
      local shown = (string.sub(c, -#SUFFIX) == SUFFIX) and string.sub(c, 1, #c - #SUFFIX) or c
      table.insert(kids, comboPill(id, c, shown))
    end
    table.insert(kids, ui.label({ text = "+ Left click", color = "on_surface_variant", fontSize = 12 }))
    table.insert(kids, ui.input({ key = "kbadd-" .. id .. "-" .. addRev, placeholder = "modifiers, e.g. SUPER", width = 170, controlSize = "sm",
      onSubmit = function(v)
        local mods = normalizeCombo(v, true)
        if mods == "" then
          toast("Type the modifier(s) to hold, e.g. SUPER")
          return
        end
        setCombos(id, { mods .. SUFFIX })
        addRev += 1
        render()
      end }))
  else
    for _, c in ipairs(combosOf(id)) do
      table.insert(kids, comboPill(id, c, nil))
    end
    table.insert(kids, ui.input({ key = "kbadd-" .. id .. "-" .. addRev, placeholder = "add: SUPER + …", width = 170, controlSize = "sm",
      onChange = function(v) kbDraft[id] = v end,
      onSubmit = function(v)
        if addCombo(id, v) then
          kbDraft[id] = nil
          addRev += 1
        end
        render()
      end }))
  end
  return ui.row({ key = "kb-" .. id, gap = 6, align = "center" }, kids)
end

local function keybindsTab()
  local kids = { heading("Keybinds"), hint("Shortcuts HyperZone binds in Hyprland. Type a chord in an action's field and press Enter (e.g. SUPER + CTRL + left); each action holds up to three. Changes apply when you press Apply.") }
  for _, g in ipairs(allKeybindGroups()) do
    table.insert(kids, ui.column({ key = "kbg-" .. g.title, gap = 6 }, (function()
      local rows = { ui.label({ text = g.title, fontWeight = "semibold" }) }
      if g.desc and g.desc ~= "" then
        table.insert(rows, hint(g.desc))
      end
      for _, it in ipairs(g.items) do
        table.insert(rows, keybindRow(it))
      end
      return rows
    end)()))
  end
  table.insert(kids, ui.row({}, { ui.button({ text = "Reset keybinds to defaults", variant = "outline", onClick = function()
    if snap and snap.default_keybinds then
      edit.keybinds = hz.clone(snap.default_keybinds)
      addRev += 1
      render()
    end
  end }) }))
  return ui.column({ gap = 14 }, kids)
end

-- ---------------------------------------------------------------- General tab
local function generalTab()
  local delay = tonumber(edit.adopt_delay) or 0.05
  local chips = {}
  for _, cls in ipairs(edit.deny_classes or {}) do
    table.insert(chips, ui.button({ key = "deny-" .. cls, text = cls, glyph = "x", controlSize = "sm", variant = "secondary", tooltip = "Remove",
      onClick = function()
        local out = {}
        for _, c in ipairs(edit.deny_classes or {}) do
          if c ~= cls then
            table.insert(out, c)
          end
        end
        edit.deny_classes = out
        render()
      end }))
  end
  local function addDeny(v)
    local cls = noctalia.string.trim(v or "")
    if cls == "" then
      return
    end
    local list = copyList(edit.deny_classes)
    if indexOf(list, cls) == nil then
      table.insert(list, cls)
    end
    edit.deny_classes = list
    denyDraft = ""
    addRev += 1
    render()
  end
  local migrated = snap and snap.migrated
  return ui.column({ gap = 12 }, {
    heading("General"),
    labelled("Adopt delay — seconds before a new window is tiled: " .. fmtNum(delay),
      ui.slider({ key = "adopt", min = 0, max = 0.5, step = 0.01, value = delay,
        onChange = function(v) edit.adopt_delay = math.floor((tonumber(v) or 0) * 100 + 0.5) / 100; render() end })),
    labelled("Never-tile window classes — these always open floating", ui.row({ gap = 8, align = "center" }, {
      ui.input({ key = "deny-add-" .. addRev, placeholder = "window class, e.g. org.gnome.Calculator", flexGrow = 1,
        onChange = function(v) denyDraft = v end, onSubmit = addDeny }),
      ui.button({ text = "Add", onClick = function() addDeny(denyDraft) end }),
    })),
    ui.row({ gap = 6 }, chips),
    labelled("Floating border colour — active", ui.input({ key = "bfa-" .. loadRev, value = edit.border_float or "rgb(e5a50a)",
      onChange = function(v) edit.border_float = noctalia.string.trim(v) end })),
    labelled("Floating border colour — inactive", ui.input({ key = "bfi-" .. loadRev, value = edit.border_float_inactive or "rgb(6b4d00)",
      onChange = function(v) edit.border_float_inactive = noctalia.string.trim(v) end })),
    ui.row({ gap = 8 }, {
      ui.button({ text = "Re-tile now", variant = "outline", onClick = function()
        hz.rpc("retile", {}, function(_, err) if err then toastErr("Re-tile failed: " .. err) end end)
      end }),
    }),
    ui.separator({}),
    heading("Persist display setup"),
    hint("Optional · moves your monitor setup out of hyprland.lua into a HyperZone-managed monitors.lua (a timestamped backup is kept) so display edits survive a Hyprland reload. Do this once."),
    ui.row({}, { ui.button({ text = migrated and "Displays already persisted ✓" or "Persist displays to monitors.lua", enabled = not migrated,
      onClick = function()
        hz.rpc("migrate_hyprland_config", {}, function(r, err)
          if err then
            toastErr("Persist failed: " .. err)
          elseif r and r.changed then
            toast("Displays persisted. Backup: " .. tostring(r.backup))
          else
            toast("Already persisted")
          end
          hz.rpc("get_state", {}, function(s)
            if s ~= nil and snap ~= nil then
              snap.migrated = s.migrated
              render()
            end
          end)
        end)
      end }) }),
  })
end

-- ---------------------------------------------------------------- frame
local function pendingBanner()
  if not pending then
    return nil
  end
  local remain = math.max(0, math.floor((pending.deadline or 0) - noctalia.nowMs() / 1000 + 0.5))
  return ui.row({ gap = 10, align = "center", padding = 10, radius = 10, fill = "primary/0.15", border = "primary", borderWidth = 1 }, {
    ui.label({ text = "Keep this display layout? Auto-revert in " .. remain .. "s · Apply skips displays until you decide", flexGrow = 1, maxWidth = 480, maxLines = 2 }),
    ui.button({ text = "Keep", variant = "primary", onClick = function() hz.rpc("confirm_monitor_layout", {}) end }),
    ui.button({ text = "Revert", variant = "outline", onClick = function() hz.rpc("revert_monitor_layout", {}) end }),
  })
end

function render()
  local ready = daemon.status == "ready" and snap ~= nil
  local header = {
    ui.label({ text = "HyperZone", fontSize = 16, fontWeight = "bold", color = "on_surface" }),
    ui.label({ text = ready and ("v" .. tostring(snap.version or "")) or (daemon.status == "starting" and "starting…" or "daemon not running"),
      color = "on_surface_variant", flexGrow = 1 }),
  }
  table.insert(header, ui.button({ glyph = "close", variant = "ghost", onClick = function() panel.close() end }))
  local body = { ui.row({ align = "center", gap = 8 }, header) }
  if not ready then
    table.insert(body, ui.label({ text = "Starting tiling daemon…", color = "on_surface_variant" }))
    panel.render(ui.column({ flexGrow = 1, gap = 12 }, body))
    return
  end
  local banner = pendingBanner()
  if banner then
    table.insert(body, banner)
  end
  local tabs = {}
  for i, t in ipairs(TABS) do
    table.insert(tabs, ui.button({ key = "tab-" .. t, text = t, flexGrow = 1, variant = (i == tab) and "primary" or "ghost",
      onClick = function() tab = i; render() end }))
  end
  table.insert(body, ui.row({ gap = 4 }, tabs))
  local content
  if tab == 1 then
    content = displaysTab()
  elseif tab == 2 then
    content = zonesTab()
  elseif tab == 3 then
    content = keybindsTab()
  else
    content = generalTab()
  end
  table.insert(body, ui.scroll({ key = "scroll-" .. tab, flexGrow = 1, gap = 12 }, { content }))
  local dirty = configDirty() or displaysDirty()
  table.insert(body, ui.row({ gap = 8, align = "center" }, {
    ui.label({ text = dirty and "Unsaved changes" or "", color = "on_surface_variant", flexGrow = 1 }),
    ui.button({ text = "Discard", variant = "ghost", enabled = dirty, onClick = function() reloadAll(); render() end }),
    ui.button({ text = "Apply", variant = "primary", enabled = dirty, onClick = function() saveSettings(); render() end }),
  }))
  panel.render(ui.column({ flexGrow = 1, gap = 12 }, body))
end

-- ---------------------------------------------------------------- lifecycle
noctalia.state.watch("daemon", function(v)
  daemon = v or { status = "down" }
  render()
end)

noctalia.state.watch("snapshot", function(v)
  local wasNil = snap == nil
  snap = v
  -- Like v4, a change from the daemon reloads the form — but not over unsaved edits.
  if wasNil or not (configDirty() or displaysDirty()) then
    reloadAll()
  end
  render()
end)

noctalia.state.watch("pending", function(v)
  pending = v or false
  render()
end)

function update()
  if pending then
    render() -- countdown
  end
end

function onOpen(_context)
  panel.setWantsSecondTicks(true)
  snap = noctalia.state.get("snapshot") or snap
  daemon = noctalia.state.get("daemon") or daemon
  pending = noctalia.state.get("pending") or false
  reloadAll()
  render()
  -- Always pull a fresh copy: the event stream may have been compacted to a refetch hint.
  hz.rpc("get_state", {}, function(r)
    if r ~= nil then
      snap = r
      pending = r.pending_layout or false
      if not (configDirty() or displaysDirty()) then
        reloadAll()
      end
      render()
    end
  end)
end

-- While the panel is open:
--   noctalia msg plugin shashank/hyperzone:settings all tab <1-4>
--   noctalia msg plugin shashank/hyperzone:settings all screen <connector>
function onIpc(event, payload)
  if event == "screen" and payload ~= nil and edit.managed and edit.managed[payload] ~= nil then
    zoneMon = payload
    render()
  elseif event == "tab" then
    local n = tonumber(payload)
    if n ~= nil and TABS[n] ~= nil then
      tab = n
      render()
    end
  end
end

function onClose()
  panel.setWantsSecondTicks(false)
end
