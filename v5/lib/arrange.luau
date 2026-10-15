--!nonstrict
-- To-scale monitor arrangement canvas for the settings panel — the v5 stand-in for the
-- DisplayCanvas drag editor in Settings.qml.
--
-- The declarative ui.* vocabulary has no absolute positioning and no stacked layers, so the
-- canvas is built as a mosaic: the arrangement (plus a margin around it) is cut into horizontal
-- bands at every monitor's top and bottom edge, and each band into cells at every monitor's left
-- and right edge. Every cell gets its exact logical size times the canvas scale, so the picture
-- is to scale; a monitor is the cells it covers, painted in its own colour.
--
-- Moving a monitor uses the host's drag and drop: each monitor is a ui.dragSource, and every
-- cell is a ui.dropZone whose value says where a drop there puts the monitor:
--   * empty space is cut into small cells; dropping on one puts the monitor's top-left corner
--     there, then the same magnetic snap as v4 pulls its edges onto nearby monitor edges
--   * each monitor is ringed by four strips and a centre: drop on another monitor's left /
--     right / top / bottom strip to dock beside it, edge to edge; drop on its centre to swap
-- The host draws the drag ghost and highlights the strip or cell under the pointer.

local M = {}

M.DRAG_TYPE = "hzmon"
local FINE_PX = 16          -- size of the free-placement cells in empty space (screen px)
local SNAP_PX = 40          -- v4's snap distance (screen px)
local STRIP = 0.25          -- edge strip thickness, as a fraction of the monitor piece
local COLORS = { "#4c8dff", "#3fc16a", "#f59234", "#ef5350", "#ab47bc", "#26a69a", "#ffca28", "#8d6e63" }

-- Logical (layout) size of a display entry {mode, scale, transform, pw, ph}: the mode's pixels
-- divided by the scale, sides swapped for 90 / 270 degree rotations. Same as v4's _logical.
function M.logical(d)
  local w, h = string.match(tostring(d.mode or ""), "^(%d+)x(%d+)")
  w = tonumber(w) or d.pw or 1920
  h = tonumber(h) or d.ph or 1080
  local s = tonumber(d.scale) or 1
  if s <= 0 then
    s = 1
  end
  w, h = w / s, h / s
  if (tonumber(d.transform) or 0) % 2 == 1 then
    w, h = h, w
  end
  return w, h
end

-- v4's magnetic snap: pull x / y onto a neighbour's edge (adjacent or aligned) when within thr.
function M.snap(disps, idx, x, y, thr)
  local sw, sh = M.logical(disps[idx])
  local bx, by = x, y
  for i, o in ipairs(disps) do
    if i ~= idx then
      local ow, oh = M.logical(o)
      for _, cx in ipairs({ o.x + ow, o.x - sw, o.x, o.x + ow - sw }) do
        if math.abs(x - cx) < thr then
          bx = cx
        end
      end
      for _, cy in ipairs({ o.y + oh, o.y - sh, o.y, o.y + oh - sh }) do
        if math.abs(y - cy) < thr then
          by = cy
        end
      end
    end
  end
  return bx, by
end

-- Pairs of enabled displays whose rectangles overlap (v4 allowed it silently; we warn).
function M.overlaps(disps)
  local out = {}
  for i = 1, #disps do
    for j = i + 1, #disps do
      local a, b = disps[i], disps[j]
      if not a.disabled and not b.disabled then
        local aw, ah = M.logical(a)
        local bw, bh = M.logical(b)
        if a.x < b.x + bw - 0.5 and b.x < a.x + aw - 0.5 and a.y < b.y + bh - 0.5 and b.y < a.y + ah - 0.5 then
          table.insert(out, { a.name, b.name })
        end
      end
    end
  end
  return out
end

local function bounds(disps)
  local minx, miny, maxx, maxy, big = math.huge, math.huge, -math.huge, -math.huge, 0
  for _, d in ipairs(disps) do
    local w, h = M.logical(d)
    minx, miny = math.min(minx, d.x), math.min(miny, d.y)
    maxx, maxy = math.max(maxx, d.x + w), math.max(maxy, d.y + h)
    big = math.max(big, w, h)
  end
  if minx == math.huge then
    return 0, 0, 1920, 1080, 1920
  end
  return minx, miny, maxx, maxy, big
end

-- Canvas geometry for a layout: world bounds (with margin) and the world->screen scale.
function M.geometry(disps, width, height)
  local minx, miny, maxx, maxy, big = bounds(disps)
  local margin = big * 0.22
  local g = { x0 = minx - margin, y0 = miny - margin, x1 = maxx + margin, y1 = maxy + margin }
  g.sc = math.min(width / (g.x1 - g.x0), height / (g.y1 - g.y0))
  g.snapThr = SNAP_PX / g.sc
  return g
end

local function sortedUnique(list)
  table.sort(list)
  local out = {}
  for _, v in ipairs(list) do
    if #out == 0 or math.abs(v - out[#out]) > 0.01 then
      table.insert(out, v)
    end
  end
  return out
end

-- Split [a, b] into pieces no bigger than step.
local function fine(a, b, step)
  local n = math.max(1, math.ceil((b - a) / step - 0.001))
  local out = {}
  for i = 0, n - 1 do
    table.insert(out, { a + (b - a) * i / n, a + (b - a) * (i + 1) / n })
  end
  return out
end

local function fmt(n)
  return tostring(math.floor(n + 0.5))
end

-- Build the canvas tree.
-- opts = { disps, sel (index), width, height, onSelect(i), onDrop(payload, value) }
function M.build(opts)
  local disps, sc = opts.disps, nil
  local g = M.geometry(disps, opts.width, opts.height)
  sc = g.sc
  local step = FINE_PX / sc

  -- horizontal bands: every monitor's top and bottom edge, plus fine cuts where no monitor is
  local ys = { g.y0, g.y1 }
  for _, d in ipairs(disps) do
    local _, h = M.logical(d)
    table.insert(ys, d.y)
    table.insert(ys, d.y + h)
  end
  ys = sortedUnique(ys)
  local bands = {}
  for i = 1, #ys - 1 do
    local a, b = ys[i], ys[i + 1]
    local any = false
    for _, d in ipairs(disps) do
      local _, h = M.logical(d)
      if d.y < b - 0.01 and d.y + h > a + 0.01 then
        any = true
        break
      end
    end
    if any then
      table.insert(bands, { a, b })
    else
      for _, p in ipairs(fine(a, b, step)) do
        table.insert(bands, p)
      end
    end
  end

  -- each monitor is labelled in its tallest band
  local labelBand = {}
  for i, d in ipairs(disps) do
    local _, h = M.logical(d)
    local best, bestH = nil, -1
    for bi, bd in ipairs(bands) do
      local top, bot = math.max(bd[1], d.y), math.min(bd[2], d.y + h)
      if bot - top > bestH then
        best, bestH = bi, bot - top
      end
    end
    labelBand[i] = best
  end

  local rowH = 0 -- height of the band being built (set per band below)
  local function emptyCell(key, x0, x1, y0)
    return ui.dropZone({
      key = key, accepts = { M.DRAG_TYPE }, value = "at:" .. fmt(x0) .. ":" .. fmt(y0), onDrop = opts.onDrop,
      width = (x1 - x0) * sc, height = rowH,
    })
  end

  local function zone(key, target, where, w, h, children)
    return ui.dropZone({
      key = key, accepts = { M.DRAG_TYPE }, value = where .. ":" .. target, onDrop = opts.onDrop,
      width = w, height = h, align = "center", justify = "center",
    }, children or {})
  end

  local function piece(bi, i, d, x0, x1, y0, y1)
    local w, h = (x1 - x0) * sc, (y1 - y0) * sc
    local color = COLORS[(i - 1) % #COLORS + 1]
    local selected = i == opts.sel
    local label = {}
    if labelBand[i] == bi then
      local lw, lh = M.logical(d)
      local lines = { d.name }
      if w * (1 - 2 * STRIP) >= 64 and h * (1 - 2 * STRIP) >= 30 then
        table.insert(lines, fmt(lw) .. "×" .. fmt(lh))
      end
      for li, text in ipairs(lines) do
        table.insert(label, ui.label({ key = "l" .. li, text = text, fontSize = li == 1 and 10 or 9,
          fontWeight = li == 1 and "semibold" or "normal", color = "on_surface", maxLines = 1,
          maxWidth = math.max(8, w * (1 - 2 * STRIP)) }))
      end
    end
    local sw, sh = w * STRIP, h * STRIP
    local cw, ch = w - 2 * sw, h - 2 * sh
    local k = "p" .. bi .. "-" .. d.name
    local body = ui.row({ key = k .. "-body", width = w, height = h, gap = 0,
      fill = color .. (selected and "b0" or "55"),
      -- always pass a border: the reconciler keeps a prop that merely disappears
      border = selected and "primary" or "#00000000", borderWidth = selected and 2 or 0,
      opacity = d.disabled and 0.4 or 1,
      onClick = function() opts.onSelect(i) end }, {
      zone(k .. "-L", d.name, "left", sw, h),
      ui.column({ key = k .. "-mid", gap = 0, width = cw, height = h }, {
        zone(k .. "-T", d.name, "above", cw, sh),
        zone(k .. "-C", d.name, "swap", cw, ch, label),
        zone(k .. "-B", d.name, "below", cw, sh),
      }),
      zone(k .. "-R", d.name, "right", sw, h),
    })
    return ui.dragSource({ key = k, dragType = M.DRAG_TYPE, payload = d.name, previewAncestor = 0,
      width = w, height = h }, { body })
  end

  local rows = {}
  for bi, bd in ipairs(bands) do
    local y0, y1 = bd[1], bd[2]
    rowH = (y1 - y0) * sc
    local hits = {}
    for i, d in ipairs(disps) do
      local w, h = M.logical(d)
      if d.y < y1 - 0.01 and d.y + h > y0 + 0.01 then
        table.insert(hits, { i = i, d = d, x0 = d.x, x1 = d.x + w })
      end
    end
    table.sort(hits, function(a, b) return a.x0 < b.x0 end)
    local cells, cursor = {}, g.x0
    local function gap(a, b)
      for ci, p in ipairs(fine(a, b, step)) do
        table.insert(cells, emptyCell("e" .. bi .. "-" .. fmt(a) .. "-" .. ci, p[1], p[2], y0))
      end
    end
    for _, hit in ipairs(hits) do
      if hit.x0 > cursor + 0.01 then
        gap(cursor, hit.x0)
      end
      local a = math.max(cursor, hit.x0)
      if hit.x1 > a + 0.01 then -- an overlapped monitor shows only its uncovered part
        table.insert(cells, piece(bi, hit.i, hit.d, a, hit.x1, y0, y1))
        cursor = hit.x1
      end
    end
    if g.x1 > cursor + 0.01 then
      gap(cursor, g.x1)
    end
    table.insert(rows, ui.row({ key = "band" .. bi, gap = 0, height = (y1 - y0) * sc }, cells))
  end
  return ui.column({ key = "arrange", gap = 0, width = (g.x1 - g.x0) * sc, height = (g.y1 - g.y0) * sc,
    radius = 6, fill = "surface_variant/0.35" }, rows)
end

-- Where a drop puts the dragged display. Returns x, y or nil (no change), plus an optional
-- second {index, x, y} for a swap.
function M.resolve(disps, payload, value, thr)
  local di = nil
  for i, d in ipairs(disps) do
    if d.name == payload then
      di = i
    end
  end
  if di == nil then
    return nil
  end
  local D = disps[di]
  local w, h = M.logical(D)
  local ax, ay = string.match(value, "^at:(%-?%d+):(%-?%d+)$")
  if ax ~= nil then
    local x, y = M.snap(disps, di, tonumber(ax), tonumber(ay), thr)
    return di, x, y
  end
  local where, target = string.match(value, "^(%a+):(.+)$")
  local ti = nil
  for i, d in ipairs(disps) do
    if d.name == target then
      ti = i
    end
  end
  if ti == nil or ti == di then
    return nil
  end
  local T = disps[ti]
  local tw, th = M.logical(T)
  if where == "swap" then
    return di, T.x, T.y, { ti, D.x, D.y }
  end
  local x, y = D.x, D.y
  if where == "left" or where == "right" then
    x = (where == "left") and (T.x - w) or (T.x + tw)
    if not (D.y < T.y + th and T.y < D.y + h) then
      y = T.y -- not side by side yet: line the tops up
    end
  else
    y = (where == "above") and (T.y - h) or (T.y + th)
    if not (D.x < T.x + tw and T.x < D.x + w) then
      x = T.x
    end
  end
  -- keep the docked edge exact, let the other axis snap into alignment like v4
  local sx, sy = M.snap(disps, di, x, y, thr)
  if where == "left" or where == "right" then
    return di, x, sy
  end
  return di, sx, y
end

return M
