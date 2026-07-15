// HyperZone — settings page. A thin, dumb form over the daemon: it edits a local
// copy of the daemon's config and sends it back via set_config. All tiling/display
// logic lives in the Python daemon, so this file ports to a future Noctalia by
// re-skinning only. Sub-editors are inline components (no cross-file resolution).
//
// Reactivity note: `edit` is a var (object); reassigning it to the same reference
// does NOT emit a change, so structural edits bump `rev` (an int) and bindings that
// must re-read use the comma-expression idiom `(rev, EXPR)` — an EXPRESSION, so no
// `return` is needed (a `{ ... }` block binding would need one).
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Services.UI
import qs.Widgets

ColumnLayout {
  id: root
  property var pluginApi: null
  property int preferredWidth: 940
  readonly property var hz: pluginApi ? pluginApi.mainInstance : null

  spacing: Style.marginM

  // ---------- working copy of the config ----------
  property var edit: ({})
  property int rev: 0
  property bool loaded: false
  property string kbRecording: ""   // action id currently capturing a keybind ("" = none)

  function reload() {
    edit = JSON.parse(JSON.stringify((hz && hz.config) ? hz.config : {}))
    if (!edit.managed) edit.managed = ({})
    loaded = true
    rev++
  }
  function apply() {
    if (!hz) return
    hz.request("set_config", { config: edit }, function (r, e) {
      if (e) ToastService.showError("HyperZone", "Save failed: " + e)
    })
  }
  // The plugin popup's single "Apply" calls this. It saves the config AND commits
  // display edits — but only when the displays actually changed, and never while a
  // confirm-or-revert is already pending (the daemon would reject that; the
  // banner above the Apply button says so while it's the case).
  function saveSettings() {
    apply()
    if (!hz) return
    if (hz.pendingLayout !== null) {
      if (displaysDirty())
        ToastService.showNotice("HyperZone", "Display change waiting for Keep / Revert — new display edits not applied")
      return
    }
    if (displaysDirty()) applyDisplays()
  }

  // ---------- config helpers ----------
  function addDenyClass(cls) {
    cls = String(cls || "").trim()
    if (!cls) return
    var list = (edit.deny_classes || []).slice()
    if (list.indexOf(cls) !== -1) return
    list.push(cls)
    edit.deny_classes = list
    rev++
  }
  function removeDenyClass(cls) {
    edit.deny_classes = (edit.deny_classes || []).filter(function (c) { return c !== cls })
    rev++
  }

  // ---------- keybinds ----------
  // Actions the daemon can bind, grouped for the UI. IDs must match the daemon's
  // KEYBIND_CMDS. The daemon sends the full current map in config.keybinds, so the
  // UI never needs the defaults except for the "reset" button below.
  readonly property var keybindGroups: [
    { title: "Focus", desc: "Move focus by direction — layout-aware, crosses to the monitor beside the window",
      items: [{ id: "focus-left", label: "Focus left" }, { id: "focus-right", label: "Focus right" },
              { id: "focus-up", label: "Focus up" }, { id: "focus-down", label: "Focus down" }] },
    { title: "Move within a screen", desc: "Shuffle the focused window between zones",
      items: [{ id: "move-left", label: "Move left" }, { id: "move-right", label: "Move right" },
              { id: "move-up", label: "Move up" }, { id: "move-down", label: "Move down" }] },
    { title: "Send to monitor", desc: "Throw the window to the screen in that direction",
      items: [{ id: "tomon-left", label: "To monitor ← left" }, { id: "tomon-right", label: "To monitor → right" },
              { id: "tomon-up", label: "To monitor ↑ up" }, { id: "tomon-down", label: "To monitor ↓ down" }] },
    { title: "Move across everything", desc: "Rearrange in-screen, then spill to the next monitor at the edge",
      items: [{ id: "push-left", label: "Push left" }, { id: "push-right", label: "Push right" },
              { id: "push-up", label: "Push up" }, { id: "push-down", label: "Push down" }] },
    { title: "Swap window", desc: "Trade places with the window in that direction — works across screens too. Focus follows the AREA: the window that arrives where you were working takes focus, so you keep looking at the same spot",
      items: [{ id: "swap-left", label: "Swap ← left" }, { id: "swap-right", label: "Swap → right" },
              { id: "swap-up", label: "Swap ↑ up" }, { id: "swap-down", label: "Swap ↓ down" }] },
    { title: "Close window", desc: "Close asks the window to close — an app that lives in the tray (Discord, Steam) just hides and keeps running. Force kill SIGKILLs the process instead: no save prompt, no cleanup, and it takes EVERY window that process owns (all Chromium profile windows share one process; so do all Unreal Editor panels)",
      items: [{ id: "close-window", label: "Close window" },
              { id: "kill-window", label: "Force kill app (no save!)" }] },
    { title: "Find my cursor", desc: "Lost the pointer across all these screens? This balloons it for a moment AND pulses a bright white border around the focused window, so you can spot both at a glance",
      items: [{ id: "locate-cursor", label: "Find cursor + highlight window" }] },
    { title: "Actions", desc: "Re-tile re-snaps windows into their zones · Rearrange is a hard reset that also reclaims floated windows",
      items: [{ id: "toggle-float", label: "Toggle float" }, { id: "rearrange", label: "Rearrange all" },
              { id: "retile", label: "Re-tile / re-snap" }] },
  ]
  readonly property var defaultKeybinds: ({
    "focus-left": ["SUPER + left", "SUPER + H"], "focus-right": ["SUPER + right", "SUPER + L"],
    "focus-up": ["SUPER + up", "SUPER + K"], "focus-down": ["SUPER + down", "SUPER + J"],
    "move-left": ["SUPER + CTRL + left", "SUPER + CTRL + H"], "move-right": ["SUPER + CTRL + right", "SUPER + CTRL + L"],
    "move-up": ["SUPER + CTRL + up", "SUPER + CTRL + K"], "move-down": ["SUPER + CTRL + down", "SUPER + CTRL + J"],
    "tomon-left": ["SUPER + SHIFT + left"], "tomon-right": ["SUPER + SHIFT + right"],
    "tomon-up": ["SUPER + SHIFT + up"], "tomon-down": ["SUPER + SHIFT + down"],
    "push-left": ["SUPER + CTRL + SHIFT + left"], "push-right": ["SUPER + CTRL + SHIFT + right"],
    "push-up": ["SUPER + CTRL + SHIFT + up"], "push-down": ["SUPER + CTRL + SHIFT + down"],
    "swap-left": ["SUPER + ALT + left"], "swap-right": ["SUPER + ALT + right"],
    "swap-up": ["SUPER + ALT + up"], "swap-down": ["SUPER + ALT + down"],
    "toggle-float": ["SUPER + T"], "rearrange": ["SUPER + SHIFT + T"], "retile": ["SUPER + SHIFT + R"],
    "close-window": ["SUPER + Q"], "kill-window": ["SUPER + SHIFT + Q"],
    "locate-cursor": ["SUPER + backslash"]
  })
  function combosOf(id) { var k = edit.keybinds || {}; return (k[id] || []).slice() }
  function setCombos(id, arr) {
    if (!edit.keybinds) edit.keybinds = ({})
    edit.keybinds[id] = arr
    rev++
  }
  // Normalise a hand-typed combo to Hyprland's canonical form, e.g.
  // "super+ctrl+left" -> "SUPER + CTRL + left". Returns "" if there's no real key.
  function normalizeCombo(s) {
    var parts = String(s || "").split("+").map(function (p) { return p.trim() }).filter(function (p) { return p.length })
    if (!parts.length) return ""
    var modMap = { "super": "SUPER", "win": "SUPER", "meta": "SUPER", "mod": "SUPER", "cmd": "SUPER",
                   "ctrl": "CTRL", "control": "CTRL", "alt": "ALT", "mod1": "ALT", "shift": "SHIFT" }
    var order = ["SUPER", "CTRL", "ALT", "SHIFT"], mods = [], key = ""
    for (var i = 0; i < parts.length; i++) {
      var low = parts[i].toLowerCase()
      if (modMap[low]) { if (mods.indexOf(modMap[low]) === -1) mods.push(modMap[low]) }
      else key = parts[i]
    }
    if (!key) return ""
    mods.sort(function (a, b) { return order.indexOf(a) - order.indexOf(b) })
    var kl = key.toLowerCase()
    if (["left", "right", "up", "down", "space", "tab", "return", "escape"].indexOf(kl) !== -1) key = kl
    else if (key.length === 1) key = key.toUpperCase()
    return mods.concat([key]).join(" + ")
  }
  // Which action currently owns `combo` (or "" if free). Guards against binding one
  // chord to two things — Hyprland would fire both.
  function comboOwner(combo) {
    var k = edit.keybinds || {}
    for (var a in k) if ((k[a] || []).indexOf(combo) !== -1) return a
    return ""
  }
  function addCombo(id, raw) {
    var combo = normalizeCombo(raw)
    if (!combo) { ToastService.showNotice("HyperZone", "Type a combo like SUPER + CTRL + left"); return }
    var owner = comboOwner(combo)
    if (owner === id) return
    if (owner) { ToastService.showNotice("HyperZone", combo + " is already bound to “" + keybindLabel(owner) + "”"); return }
    var arr = combosOf(id); arr.push(combo); setCombos(id, arr)
  }
  function removeCombo(id, combo) { setCombos(id, combosOf(id).filter(function (c) { return c !== combo })) }
  function keybindLabel(id) {
    for (var g = 0; g < keybindGroups.length; g++)
      for (var i = 0; i < keybindGroups[g].items.length; i++)
        if (keybindGroups[g].items[i].id === id) return keybindGroups[g].items[i].label
    return id
  }
  function resetKeybinds() { edit.keybinds = JSON.parse(JSON.stringify(defaultKeybinds)); rev++ }
  function monEntry(name) {
    if (!edit.managed[name]) edit.managed[name] = { enabled: false, layout: defaultLayout() }
    if (!edit.managed[name].layout) edit.managed[name].layout = defaultLayout()
    return edit.managed[name]
  }
  function defaultLayout() { return { zones: 4, vsplit: 1 / 3, hsplit: 1 / 3, fill: [3, 2, 1, 0], subdivide: [1, 2] } }
  function layoutOf(name) { return monEntry(name).layout }
  function defaultFill(z) { var a = []; for (var i = 0; i < z; i++) a.push(z - 1 - i); return a }
  function fillOf(name) { var l = layoutOf(name); return l.fill || defaultFill(l.zones) }
  // Zones are named by a fixed colour, not a number — the number badge in the
  // preview is the *fill order* (which window lands where), and reusing 1/2/3/4
  // for identity was confusing. Colour is tied to the canonical cell index zi
  // (2 zones → 0=left,1=right · 4 zones → 0=TL,1=TR,2=BL,3=BR) so it never shifts.
  readonly property var zoneNames: ["Blue", "Green", "Orange", "Red"]
  readonly property var zoneEmojis: ["🟦", "🟩", "🟧", "🟥"]
  readonly property var zoneHexes: ["#4c8dff", "#3fc16a", "#f59234", "#ef5350"]
  // #AARRGGBB translucent body tints (alpha 0x38 ≈ 22%) for the zone preview.
  readonly property var zoneFills: ["#384c8dff", "#383fc16a", "#38f59234", "#38ef5350"]
  function zoneLabel(zones, zi) { return (root.zoneEmojis[zi] || "") + " " + (root.zoneNames[zi] || ("Zone " + (zi + 1))) }

  function setEnabled(name, on) { monEntry(name).enabled = on; rev++; apply() }
  function setZones(name, z) {
    var l = layoutOf(name); l.zones = z; l.fill = defaultFill(z)
    l.subdivide = (l.subdivide || []).filter(function (i) { return i < z })
    rev++
  }
  function setSplit(name, v, h) { var l = layoutOf(name); l.vsplit = v; if (h !== undefined && h !== null) l.hsplit = h }
  function setFillOrder(name, fill) { layoutOf(name).fill = fill; rev++ }
  function toggleSub(name, zi, on) {
    var l = layoutOf(name); var s = (l.subdivide || []).slice(); var i = s.indexOf(zi)
    if (on && i < 0) s.push(zi)
    if (!on && i >= 0) s.splice(i, 1)
    l.subdivide = s; rev++
  }
  function setSubOrder(name, order) { layoutOf(name).subdivide = order; rev++ }

  function fillModel(name) {
    var l = layoutOf(name); var sub = l.subdivide || []
    return fillOf(name).map(function (zi) {
      return { id: zi, text: zoneLabel(l.zones, zi), enabled: sub.indexOf(zi) !== -1, required: false }
    })
  }
  function subModel(name) {
    var l = layoutOf(name)
    return (l.subdivide || []).map(function (zi) {
      return { id: zi, text: zoneLabel(l.zones, zi), enabled: true, required: true }
    })
  }
  function managedNames() { var out = []; for (var name in edit.managed) if (edit.managed[name].enabled) out.push(name); return out }
  function isManaged(name) { var mc = edit.managed ? edit.managed[name] : null; return !!(mc && mc.enabled) }
  function allMonitorNames() { var out = []; for (var name in (edit.managed || {})) out.push(name); return out }
  // A screen is described by its zone count: 1 = unmanaged (single zone, default
  // Hyprland), 2 = vertical split, 4 = quadrants. That replaces the managed toggle.
  function zoneCountOf(name) { return isManaged(name) ? layoutOf(name).zones : 1 }
  function setZoneCount(name, n) {
    if (n === 1) { monEntry(name).enabled = false }
    else { monEntry(name).enabled = true; setZones(name, n) }
    rev++; apply()
  }

  // ---------- display editor state ----------
  property var dispEdit: []
  property int dispRev: 0
  property int dispSel: 0
  property string dispBaseline: "[]"   // dispSpecs() as of the last (re)load — for dirty check

  function reloadDisplays() {
    var ms = (hz && hz.monitors) ? hz.monitors : []
    dispEdit = ms.map(function (m) {
      return { name: m.name, mode: currentModeOf(m), x: m.x || 0, y: m.y || 0,
               scale: m.scale || 1, transform: m.transform || 0, disabled: !!m.disabled,
               noEdid: !!m.noEdid, modes: (m.availableModes || []).slice() }
    })
    if (dispSel >= dispEdit.length) dispSel = 0
    dispBaseline = JSON.stringify(dispSpecs())   // fresh load == not dirty
    dispRev++
  }
  function currentModeOf(m) {
    var pfx = m.width + "x" + m.height + "@"
    var modes = (m.availableModes || []).filter(function (s) { return String(s).indexOf(pfx) === 0 })
    var rr = Math.round(m.refreshRate || 0)
    for (var i = 0; i < modes.length; i++)
      if (Math.round(parseFloat(String(modes[i]).split("@")[1])) === rr) return modes[i]
    return modes.length ? modes[0] : (pfx + (m.refreshRate || 60).toFixed(2) + "Hz")
  }
  function selDisp() { return dispEdit[dispSel] || null }
  // Scale presets. The fractional entries let panels of different pixel density share the
  // same PHYSICAL ui size — e.g. a 27" 1440p at 1.33× renders 1920×1080 logical, the same
  // apparent size as a native 27" 1080p, so the mouse crosses between them seamlessly.
  // Hyprland snaps each request to the nearest scale that yields whole logical pixels and
  // reports it back rounded to 2 decimals, which is exactly how these keys are written.
  readonly property var scalePresets: [
    { key: "1", name: "1×" }, { key: "1.25", name: "1.25×" }, { key: "1.33", name: "1.33×" },
    { key: "1.5", name: "1.5×" }, { key: "1.6", name: "1.6×" }, { key: "1.67", name: "1.67×" },
    { key: "1.75", name: "1.75×" }, { key: "2", name: "2×" }
  ]
  // Highlight the preset nearest the live scale (within a hair) so a rounded read-back — or an
  // odd hand-set scale — still selects sensibly rather than showing blank; fall back to the raw
  // value when nothing is close, which keeps a genuinely custom scale visible.
  function scaleKey(s) {
    var v = Number(s) || 1, best = null, bd = 0.02
    for (var i = 0; i < scalePresets.length; i++) {
      var d = Math.abs(parseFloat(scalePresets[i].key) - v)
      if (d < bd) { bd = d; best = scalePresets[i].key }
    }
    return best !== null ? best : String(v)
  }
  // A hand-written timing for one display, keyed by connector name. Only ever offered
  // for a display that publishes no EDID — the daemon ignores such a pin the moment
  // that port carries a display which CAN identify itself, since a connector name does
  // not follow a panel across a cable swap.
  function modelineOf(name) {
    return (edit.modelines && edit.modelines[name]) ? String(edit.modelines[name]) : ""
  }
  function setModeline(name, text) {
    var ml = edit.modelines ? JSON.parse(JSON.stringify(edit.modelines)) : ({})
    text = String(text || "").trim()
    if (text) ml[name] = text
    else delete ml[name]
    edit.modelines = ml
    rev++
  }
  // Reassign the array (not just mutate in place) so DisplayCanvas's `monitors`
  // binding actually changes reference and resyncs its working copy — otherwise
  // scale/rotation/mode edits never show up in the preview.
  function setDisp(field, val) {
    if (!dispEdit[dispSel]) return
    dispEdit[dispSel][field] = val
    dispEdit = dispEdit.slice()
    dispRev++
  }
  function moveDisp(i, x, y) { if (dispEdit[i]) { dispEdit[i].x = x; dispEdit[i].y = y; dispRev++ } }
  // Normalised spec list sent to the daemon; also the basis for the dirty check.
  function dispSpecs() {
    return dispEdit.map(function (d) {
      return { name: d.name, mode: d.mode, x: Math.round(d.x), y: Math.round(d.y),
               scale: d.scale, transform: d.transform, disabled: d.disabled }
    })
  }
  function displaysDirty() { return JSON.stringify(dispSpecs()) !== dispBaseline }
  function applyDisplays() {
    if (!hz) return
    hz.request("apply_monitor_layout", { monitors: dispSpecs() },   // daemon default timeout
               function (r, e) { if (e) ToastService.showError("HyperZone", "Display apply failed: " + e) })
  }

  Connections {
    target: root.hz
    function onConfigChanged() { if (root.hz && root.hz.config) root.reload() }
    function onDaemonReadyChanged() { if (root.hz && root.hz.daemonReady) { root.reload(); root.reloadDisplays() } }
    function onMonitorsChanged() { root.reloadDisplays() }
  }
  Component.onCompleted: if (hz && hz.daemonReady) { reload(); reloadDisplays() }

  // =======================================================================
  // (No in-page header — the plugin settings popup already titles this pane.)

  ColumnLayout {
    Layout.fillWidth: true; Layout.topMargin: Style.marginXL
    visible: !root.hz || !root.hz.daemonReady
    spacing: Style.marginM
    NBusyIndicator { Layout.alignment: Qt.AlignHCenter; running: parent.visible }
    NText { Layout.alignment: Qt.AlignHCenter; text: "Starting tiling daemon…"; color: Color.mOnSurfaceVariant }
  }

  NTabBar {
    id: tabs
    Layout.fillWidth: true
    visible: root.hz && root.hz.daemonReady
    distributeEvenly: true
    currentIndex: tabView.currentIndex
    NTabButton { text: "Displays"; tabIndex: 0; checked: tabs.currentIndex === 0 }
    NTabButton { text: "Zones";    tabIndex: 1; checked: tabs.currentIndex === 1 }
    NTabButton { text: "Keybinds"; tabIndex: 2; checked: tabs.currentIndex === 2 }
    NTabButton { text: "General";  tabIndex: 3; checked: tabs.currentIndex === 3 }
  }

  NTabView {
    id: tabView
    Layout.fillWidth: true
    visible: root.hz && root.hz.daemonReady
    currentIndex: tabs.currentIndex

    // ================= DISPLAYS =================
    ColumnLayout {
      spacing: Style.marginM
      NLabel { label: "Displays"; description: "Drag to arrange · set resolution, scale, rotation" }

      DisplayCanvas {
        Layout.fillWidth: true
        Layout.preferredHeight: 300
        monitors: (root.dispRev, root.dispEdit)
        selectedIndex: (root.dispRev, root.dispSel)
        onSelect: (i) => root.dispSel = i
        onMoved: (i, x, y) => root.moveDisp(i, x, y)
      }

      // selected-monitor editors
      NBox {
        Layout.fillWidth: true
        visible: root.selDisp() !== null
        implicitHeight: selCol.implicitHeight + Style.marginM * 2
        ColumnLayout {
          id: selCol
          anchors.fill: parent; anchors.margins: Style.marginM; spacing: Style.marginS
          NText { text: (root.dispRev, root.selDisp() ? root.selDisp().name : ""); font.weight: Style.fontWeightSemiBold }
          GridLayout {
            Layout.fillWidth: true; columns: 4; columnSpacing: Style.marginM; rowSpacing: Style.marginS
            NComboBox {
              label: "Resolution"; minimumWidth: 220
              model: (root.dispRev, (root.selDisp() ? root.selDisp().modes : []).map(function (s) { return { key: s, name: String(s).replace("Hz", "") } }))
              currentKey: (root.dispRev, root.selDisp() ? root.selDisp().mode : "")
              onSelected: (key) => root.setDisp("mode", key)
            }
            NComboBox {
              label: "Scale"; minimumWidth: 110
              model: root.scalePresets
              currentKey: (root.dispRev, root.scaleKey(root.selDisp() ? root.selDisp().scale : 1))
              onSelected: (key) => root.setDisp("scale", parseFloat(key))
            }
            NComboBox {
              label: "Rotation"; minimumWidth: 120
              model: [{ key: "0", name: "Normal" }, { key: "1", name: "90°" }, { key: "2", name: "180°" }, { key: "3", name: "270°" }]
              currentKey: (root.dispRev, String(root.selDisp() ? root.selDisp().transform : 0))
              onSelected: (key) => root.setDisp("transform", parseInt(key))
            }
            NComboBox {
              label: "Zones"; minimumWidth: 130
              model: [{ key: "1", name: "1 · off" }, { key: "2", name: "2 zones" }, { key: "4", name: "4 zones" }]
              currentKey: (root.rev, root.selDisp() ? String(root.zoneCountOf(root.selDisp().name)) : "1")
              onSelected: (key) => { if (root.selDisp()) root.setZoneCount(root.selDisp().name, parseInt(key)) }
            }
          }

          // Only for a display that publishes no EDID. Every other monitor gets its mode
          // list from the panel itself, and a hand-written timing there is meaningless.
          ColumnLayout {
            Layout.fillWidth: true; spacing: Style.marginXS
            visible: (root.dispRev, root.selDisp() ? !!root.selDisp().noEdid : false)
            NText {
              Layout.fillWidth: true; wrapMode: Text.WordWrap
              pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant
              text: "This display publishes no EDID, so it cannot tell us what it supports — " +
                    "the resolutions above are standard VESA timings, not the panel's own. " +
                    "If none of them give a correct picture, enter a custom timing here."
            }
            NTextInput {
              Layout.fillWidth: true
              label: "Custom timing (advanced) — overrides the resolution above"
              placeholderText: "modeline 148.50 1920 2008 2052 2200 1080 1084 1089 1125 +hsync +vsync"
              text: (root.rev, root.dispRev, root.selDisp() ? root.modelineOf(root.selDisp().name) : "")
              onEditingFinished: if (root.selDisp()) root.setModeline(root.selDisp().name, text)
            }
          }
        }
      }

      // No per-tab apply button — the popup's single Apply commits display edits too
      // (live, with confirm-or-revert safety; that banner lives at the bottom of
      // this panel, right above Apply, so it's visible from any tab).
      NText {
        Layout.fillWidth: true; Layout.topMargin: Style.marginS; wrapMode: Text.WordWrap
        text: "Press Apply at the bottom to apply display changes. They take effect immediately; " +
              "you'll get a Keep / Revert prompt in case something goes dark." +
              ((root.hz && !root.hz.migrated)
                ? " Changes reset on a Hyprland reload until you use “Persist displays” in General (one-time)."
                : "")
        pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant
      }
    }

    // ================= ZONES =================
    ColumnLayout {
      spacing: Style.marginM
      NLabel { label: "Zones"; description: "How many zones to split each screen into — 1 leaves it on default Hyprland" }

      Repeater {
        model: (root.rev, root.allMonitorNames())
        delegate: NCollapsible {
          Layout.fillWidth: true
          readonly property string mon: modelData
          readonly property int zc: (root.rev, root.zoneCountOf(mon))
          label: mon + "  ·  " + (zc === 1 ? "off" : (zc + " zones"))
          expanded: index === 0

          RowLayout {
            Layout.fillWidth: true; spacing: Style.marginM
            NText { text: "Zones:"; Layout.alignment: Qt.AlignVCenter }
            NComboBox {
              minimumWidth: 130
              model: [{ key: "1", name: "1 · off" }, { key: "2", name: "2 zones" }, { key: "4", name: "4 zones" }]
              currentKey: (root.rev, String(root.zoneCountOf(mon)))
              onSelected: (key) => root.setZoneCount(mon, parseInt(key))
            }
          }

          NText {
            visible: zc === 1
            Layout.fillWidth: true; wrapMode: Text.WordWrap
            text: "Single zone — this screen keeps Hyprland's default tiling. HyperZone still moves " +
                  "windows and focus to/from it; it just doesn't split it into zones."
            pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant
          }

          ColumnLayout {
            Layout.fillWidth: true
            visible: zc >= 2
            spacing: Style.marginS

            ZoneEditor {
              Layout.fillWidth: true
              Layout.preferredHeight: 284
              zones: (root.rev, root.layoutOf(mon).zones)
              vsplit: (root.rev, root.layoutOf(mon).vsplit)
              hsplit: (root.rev, root.layoutOf(mon).hsplit)
              fill: (root.rev, root.fillOf(mon))
              subdivide: (root.rev, root.layoutOf(mon).subdivide || [])
              onSplitChanged: (v, h) => root.setSplit(mon, v, h)
            }

            NText {
              text: "Fill order (top = first) · check = subdivides when a 2nd window lands"
              pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant
            }
            NReorderCheckboxes {
              Layout.fillWidth: true
              model: (root.rev, root.fillModel(mon))
              onItemToggled: (index, enabled) => root.toggleSub(mon, root.fillOf(mon)[index], enabled)
              onItemsReordered: (from, to) => {
                var fill = root.fillOf(mon).slice(); var m = fill.splice(from, 1)[0]; fill.splice(to, 0, m)
                root.setFillOrder(mon, fill)
              }
            }

            ColumnLayout {
              Layout.fillWidth: true
              visible: (root.rev, (root.layoutOf(mon).subdivide || []).length >= 2)
              spacing: Style.marginXS
              NText { text: "Subdivision fill order"; pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant }
              NReorderCheckboxes {
                Layout.fillWidth: true
                model: (root.rev, root.subModel(mon))
                onItemsReordered: (from, to) => {
                  var s = (root.layoutOf(mon).subdivide || []).slice(); var m = s.splice(from, 1)[0]; s.splice(to, 0, m)
                  root.setSubOrder(mon, s)
                }
              }
            }
          }
        }
      }

      NText {
        Layout.fillWidth: true; Layout.topMargin: Style.marginS; wrapMode: Text.WordWrap
        text: "Changes take effect when you press Apply at the bottom of this panel."
        pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant
      }
    }

    // ================= KEYBINDS =================
    ColumnLayout {
      spacing: Style.marginS
      NLabel { label: "Keybinds"; description: "Shortcuts HyperZone binds in Hyprland" }

      NText {
        Layout.fillWidth: true; wrapMode: Text.WordWrap
        text: "Click “Record” next to an action and press the shortcut — e.g. hold Super and tap ←. " +
              "Each action can hold a few. Changes apply when you press Apply below. HyperZone owns " +
              "these keys: the matching binds in hyprland.lua are commented out (a backup is kept)."
        pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant
      }

      Repeater {
        model: root.keybindGroups
        delegate: ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.marginXS
          readonly property var group: modelData
          NText { text: group.title; font.weight: Style.fontWeightSemiBold; Layout.topMargin: Style.marginS }
          NText {
            visible: group.desc.length > 0; text: group.desc
            pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant
          }

          Repeater {
            model: group.items
            delegate: KeybindRecorder {
              Layout.fillWidth: true
              actId: modelData.id
              label: modelData.label
            }
          }
        }
      }

      NButton {
        text: "Reset keybinds to defaults"; outlined: true
        Layout.topMargin: Style.marginM
        onClicked: root.resetKeybinds()
      }
    }

    // ================= GENERAL =================
    ColumnLayout {
      spacing: Style.marginM
      NLabel { label: "General" }

      NValueSlider {
        Layout.fillWidth: true
        label: "Adopt delay (seconds before a new window is tiled)"
        from: 0; to: 0.5; stepSize: 0.01
        value: (root.rev, root.edit.adopt_delay !== undefined ? root.edit.adopt_delay : 0.05)
        onMoved: (v) => root.edit.adopt_delay = Math.round(v * 100) / 100
      }
      // Never-tile classes as removable tags. A denied window always opens
      // floating (centred on its screen) instead of being tiled or docked.
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.marginXS
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.marginM
          NTextInput {
            id: denyInput
            Layout.fillWidth: true
            label: "Never-tile window classes"
            description: "These always open floating · Enter or Add"
            placeholderText: "window class, e.g. org.gnome.Calculator"
            onAccepted: { root.addDenyClass(text); text = "" }
          }
          NButton {
            text: "Add"
            Layout.alignment: Qt.AlignBottom
            enabled: denyInput.text.trim().length > 0
            onClicked: { root.addDenyClass(denyInput.text); denyInput.text = "" }
          }
        }
        Flow {
          Layout.fillWidth: true
          spacing: Style.marginXS
          Repeater {
            model: (root.rev, root.edit.deny_classes || [])
            delegate: Rectangle {
              radius: height / 2
              color: Color.mSurfaceVariant
              border.color: Color.mOutline
              border.width: 1
              implicitWidth: chipRow.implicitWidth + Style.marginM * 2
              implicitHeight: chipRow.implicitHeight + Style.marginXS * 2
              RowLayout {
                id: chipRow
                anchors.centerIn: parent
                spacing: Style.marginXS
                NText { text: modelData; pointSize: Style.fontSizeS }
                NIconButton {
                  icon: "close"
                  baseSize: Style.baseWidgetSize * 0.55
                  tooltipText: "Remove"
                  onClicked: root.removeDenyClass(modelData)
                }
              }
            }
          }
        }
      }
      NTextInput {
        Layout.fillWidth: true
        label: "Floating border colour — active"
        text: (root.rev, root.edit.border_float || "rgb(e5a50a)")
        onEditingFinished: root.edit.border_float = text.trim()
      }
      NTextInput {
        Layout.fillWidth: true
        label: "Floating border colour — inactive"
        text: (root.rev, root.edit.border_float_inactive || "rgb(6b4d00)")
        onEditingFinished: root.edit.border_float_inactive = text.trim()
      }

      NButton {
        text: "Re-tile now"
        outlined: true
        Layout.topMargin: Style.marginS
        onClicked: if (root.hz) root.hz.request("retile", {})
      }

      // Persist displays (one-time migration). Greyed out once done — nothing left to do.
      Rectangle { Layout.fillWidth: true; Layout.topMargin: Style.marginM; Layout.preferredHeight: 1; color: Color.mOutline }
      NLabel { label: "Persist display setup"; description: "Optional · make display edits survive a Hyprland reload" }
      NText {
        Layout.fillWidth: true; wrapMode: Text.WordWrap
        text: "Moves your monitor setup out of hyprland.lua into a HyperZone-managed monitors.lua " +
              "(a timestamped backup is kept). Do this once; after that, display edits persist automatically."
        pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant
      }
      NButton {
        text: (root.hz && root.hz.migrated) ? "Displays already persisted ✓" : "Persist displays to monitors.lua"
        enabled: root.hz && !root.hz.migrated
        onClicked: root.hz.request("migrate_hyprland_config", {}, function (r, e) {
          if (e) ToastService.showError("HyperZone", "Persist failed: " + e)
          else if (r && r.changed) { ToastService.showNotice("HyperZone", "Displays persisted. Backup: " + r.backup); root.hz.refresh() }
          else { ToastService.showNotice("HyperZone", "Already persisted"); root.hz.refresh() }
        })
      }
    }
  }

  // Confirm-or-revert banner: sits at the very bottom of the panel, directly
  // above the popup's Apply/Close row, on every tab. While it's showing, Apply
  // won't touch displays (saveSettings skips them) — Keep or Revert first.
  // Bound to the daemon's pending state, so it survives popup close/reopen.
  NBox {
    Layout.fillWidth: true
    visible: root.hz && root.hz.daemonReady && root.hz.pendingLayout !== null
    implicitHeight: pendRow.implicitHeight + Style.marginM * 2
    color: Color.mSurfaceVariant
    property int remain: 0
    Timer {
      running: parent.visible; interval: 500; repeat: true
      onTriggered: parent.remain = (root.hz && root.hz.pendingLayout)
                   ? Math.max(0, Math.round(root.hz.pendingLayout.deadline - Date.now() / 1000)) : 0
    }
    RowLayout {
      id: pendRow
      anchors.fill: parent; anchors.margins: Style.marginM; spacing: Style.marginM
      NText {
        Layout.fillWidth: true; wrapMode: Text.WordWrap
        text: "Keep this display layout? Auto-revert in " + parent.parent.remain + "s · Apply is paused for displays until you decide"
        font.weight: Style.fontWeightMedium
      }
      NButton { text: "Keep"; onClicked: root.hz.request("confirm_monitor_layout", {}) }
      NButton { text: "Revert"; outlined: true; onClicked: root.hz.request("revert_monitor_layout", {}) }
    }
  }

  // ======================= inline sub-editor: keybind recorder =======================
  // One row per action: existing combos as removable pills + a "Record" pill that
  // captures a pressed chord. While recording we ask the daemon to suspend its live
  // binds (set_capture_mode) so Hyprland doesn't eat an already-bound chord before
  // the popup sees it, and flag PanelService so the panel's own key handlers stand down.
  component KeybindRecorder: RowLayout {
    id: rec
    property string actId: ""
    property string label: ""
    property int maxKeybinds: 3
    readonly property var combos: (root.rev, root.combosOf(actId))
    readonly property bool recording: root.kbRecording === rec.actId
    spacing: Style.marginM

    function keyName(key, text) {
      switch (key) {
      case Qt.Key_Left: return "left"
      case Qt.Key_Right: return "right"
      case Qt.Key_Up: return "up"
      case Qt.Key_Down: return "down"
      case Qt.Key_Space: return "space"
      case Qt.Key_Tab: return "tab"
      case Qt.Key_Return:
      case Qt.Key_Enter: return "return"
      case Qt.Key_Home: return "home"
      case Qt.Key_End: return "end"
      case Qt.Key_Delete: return "delete"
      case Qt.Key_Backspace: return "backspace"
      }
      if (key >= Qt.Key_F1 && key <= Qt.Key_F35) return "F" + (key - Qt.Key_F1 + 1)
      if (key >= Qt.Key_A && key <= Qt.Key_Z) return String.fromCharCode(key)
      if (key >= Qt.Key_0 && key <= Qt.Key_9) return String.fromCharCode(key)
      var t = String(text || "").trim()
      return t.length === 1 ? t.toUpperCase() : ""
    }
    function comboFromEvent(e) {
      var parts = []
      if (e.modifiers & Qt.MetaModifier) parts.push("SUPER")
      if (e.modifiers & Qt.ControlModifier) parts.push("CTRL")
      if (e.modifiers & Qt.AltModifier) parts.push("ALT")
      if (e.modifiers & Qt.ShiftModifier) parts.push("SHIFT")
      var k = rec.keyName(e.key, e.text)
      if (!k) return ""
      parts.push(k)
      return parts.join(" + ")
    }
    function startRec() {
      root.kbRecording = rec.actId
      PanelService.isKeybindRecording = true
      if (root.hz) root.hz.request("set_capture_mode", { "on": true })
      capture.forceActiveFocus()
    }
    function stopRec() {
      if (root.kbRecording === rec.actId) root.kbRecording = ""
      PanelService.isKeybindRecording = false
      if (root.hz) root.hz.request("set_capture_mode", { "on": false })
    }
    Component.onDestruction: if (rec.recording) rec.stopRec()

    NText {
      text: rec.label; Layout.preferredWidth: 140; Layout.alignment: Qt.AlignTop
      Layout.topMargin: Style.marginXS
    }
    Flow {
      Layout.fillWidth: true
      spacing: Style.marginXS
      Repeater {
        model: rec.combos
        delegate: Rectangle {
          radius: height / 2
          color: Color.mSurfaceVariant
          border.color: Color.mOutline; border.width: 1
          implicitWidth: pill.implicitWidth + Style.marginM * 2
          implicitHeight: pill.implicitHeight + Style.marginXS * 2
          RowLayout {
            id: pill
            anchors.centerIn: parent; spacing: Style.marginXS
            NText { text: modelData; pointSize: Style.fontSizeS }
            NIconButton {
              icon: "close"; baseSize: Style.baseWidgetSize * 0.55; tooltipText: "Remove"
              onClicked: root.removeCombo(rec.actId, modelData)
            }
          }
        }
      }
      Rectangle {
        visible: rec.recording || rec.combos.length < rec.maxKeybinds
        radius: height / 2
        color: rec.recording ? Color.mSecondary : "transparent"
        border.color: rec.recording ? Color.mPrimary : Color.mOutline
        border.width: 1
        implicitWidth: addRow.implicitWidth + Style.marginM * 2
        implicitHeight: addRow.implicitHeight + Style.marginXS * 2
        RowLayout {
          id: addRow
          anchors.centerIn: parent; spacing: Style.marginXS
          NIcon {
            icon: rec.recording ? "circle-dot" : "keyboard"
            color: rec.recording ? Color.mOnSecondary : Color.mOnSurfaceVariant
            pointSize: Style.fontSizeM
          }
          NText {
            text: rec.recording ? "Press keys…  (Esc cancels)" : "Record"
            pointSize: Style.fontSizeS
            color: rec.recording ? Color.mOnSecondary : Color.mOnSurfaceVariant
          }
        }
        MouseArea {
          anchors.fill: parent; cursorShape: Qt.PointingHandCursor
          onClicked: rec.recording ? rec.stopRec() : rec.startRec()
        }
      }
      // hidden key sink: grabs focus while recording, captures the chord
      Item {
        id: capture
        width: 0; height: 0
        Keys.onPressed: function (e) {
          if (!rec.recording) return
          if (e.key === Qt.Key_Escape) { rec.stopRec(); e.accepted = true; return }
          if (e.key === Qt.Key_Shift || e.key === Qt.Key_Control || e.key === Qt.Key_Alt
              || e.key === Qt.Key_Meta || e.key === Qt.Key_Super_L || e.key === Qt.Key_Super_R) {
            e.accepted = true; return   // wait for a real key
          }
          var combo = rec.comboFromEvent(e)
          if (combo) { root.addCombo(rec.actId, combo); rec.stopRec() }
          e.accepted = true
        }
      }
    }
  }

  // ======================= inline sub-editor: zone divider canvas =======================
  component ZoneEditor: Item {
    id: ze
    property int zones: 4
    property real vsplit: 1 / 3
    property real hsplit: 1 / 3
    property var fill: []
    property var subdivide: []
    signal splitChanged(real v, real h)

    // Zone colours come from the single palette on root (same file scope).
    function zc(zi) { return root.zoneHexes[zi] || Color.mOutline }
    function zf(zi) { return root.zoneFills[zi] || Color.mSurfaceVariant }

    // live drag state (owned here so dragging is smooth; resynced when props change)
    property real _v: vsplit
    property real _h: hsplit
    onVsplitChanged: _v = vsplit
    onHsplitChanged: _h = hsplit

    // Commit a split from any source (drag or typed %), clamping to 5–95%.
    function setV(frac) {
      var nv = Math.max(0.05, Math.min(0.95, frac))
      if (Math.abs(nv - ze._v) < 0.0005) return
      ze._v = nv
      ze.splitChanged(ze._v, ze.zones === 4 ? ze._h : null)
    }
    function setH(frac) {
      var nh = Math.max(0.05, Math.min(0.95, frac))
      if (Math.abs(nh - ze._h) < 0.0005) return
      ze._h = nh
      ze.splitChanged(ze._v, ze._h)
    }

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.marginS

      Item {
        Layout.fillWidth: true
        Layout.fillHeight: true

        Rectangle {
          id: canvas
          anchors.centerIn: parent
          width: Math.min(parent.width, parent.height * 16 / 9)
          height: width * 9 / 16
          color: "transparent"

          Repeater {
            model: {
              var v = ze._v * canvas.width, h = ze._h * canvas.height, W = canvas.width, H = canvas.height
              if (ze.zones === 2)
                return [{ zi: 0, x: 0, y: 0, w: v, h: H }, { zi: 1, x: v, y: 0, w: W - v, h: H }]
              return [{ zi: 0, x: 0, y: 0, w: v, h: h }, { zi: 1, x: v, y: 0, w: W - v, h: h },
                      { zi: 2, x: 0, y: h, w: v, h: H - h }, { zi: 3, x: v, y: h, w: W - v, h: H - h }]
            }
            delegate: Rectangle {
              x: modelData.x; y: modelData.y; width: modelData.w; height: modelData.h
              color: ze.zf(modelData.zi)
              border.color: ze.zc(modelData.zi); border.width: 2; radius: Style.radiusXS
              NText {
                anchors.centerIn: parent
                // number = fill order (which window lands here); ⊞ = subdivides
                text: (ze.fill.indexOf(modelData.zi) + 1) + (ze.subdivide.indexOf(modelData.zi) !== -1 ? "  ⊞" : "")
                color: Color.mOnSurface; pointSize: Style.fontSizeL; font.weight: Style.fontWeightBold
              }
            }
          }

          // vertical divider
          Rectangle {
            width: 6; height: canvas.height; radius: 3; color: Color.mPrimary
            x: ze._v * canvas.width - width / 2; y: 0
            MouseArea {
              anchors.fill: parent; anchors.margins: -8
              cursorShape: Qt.SplitHCursor
              onPositionChanged: {
                if (!pressed) return
                var p = mapToItem(canvas, mouseX, mouseY)
                ze.setV(p.x / canvas.width)
              }
            }
          }

          // horizontal divider (4-zone only)
          Rectangle {
            visible: ze.zones === 4
            width: canvas.width; height: 6; radius: 3; color: Color.mPrimary
            x: 0; y: ze._h * canvas.height - height / 2
            MouseArea {
              anchors.fill: parent; anchors.margins: -8
              cursorShape: Qt.SplitVCursor
              onPositionChanged: {
                if (!pressed) return
                var p = mapToItem(canvas, mouseX, mouseY)
                ze.setH(p.y / canvas.height)
              }
            }
          }
        }
      }

      // Typed percentages — the left column's width, and (4-zone) the top row's height.
      RowLayout {
        Layout.alignment: Qt.AlignHCenter
        spacing: Style.marginL

        RowLayout {
          spacing: Style.marginS
          NText { text: "Left"; Layout.alignment: Qt.AlignVCenter; color: Color.mOnSurfaceVariant; pointSize: Style.fontSizeS }
          NSpinBox {
            from: 5; to: 95; stepSize: 1; suffix: "%"
            value: Math.round(ze._v * 100)
            onValueChanged: ze.setV(value / 100)
          }
        }

        RowLayout {
          visible: ze.zones === 4
          spacing: Style.marginS
          NText { text: "Top"; Layout.alignment: Qt.AlignVCenter; color: Color.mOnSurfaceVariant; pointSize: Style.fontSizeS }
          NSpinBox {
            from: 5; to: 95; stepSize: 1; suffix: "%"
            value: Math.round(ze._h * 100)
            onValueChanged: ze.setH(value / 100)
          }
        }
      }
    }
  }

  // ======================= inline sub-editor: monitor arrangement canvas =======================
  component DisplayCanvas: Item {
    id: dc
    property var monitors: []
    property int selectedIndex: 0
    signal select(int index)
    signal moved(int index, real x, real y)

    // internal working copy so dragging is smooth (resynced when monitors change)
    property var _mons: []
    property int _rev: 0
    onMonitorsChanged: { _mons = JSON.parse(JSON.stringify(monitors || [])); _rev++ }
    Component.onCompleted: { _mons = JSON.parse(JSON.stringify(monitors || [])); _rev++ }

    function _logical(d) {
      var wh = String(d.mode).split("@")[0].split("x")
      var w = parseInt(wh[0]) / d.scale, h = parseInt(wh[1]) / d.scale
      if (d.transform % 2 === 1) { var t = w; w = h; h = t }
      return { w: w, h: h }
    }
    function _bbox() {
      if (_mons.length === 0) return { minx: 0, miny: 0, w: 1, h: 1 }
      var minx = 1e9, miny = 1e9, maxx = -1e9, maxy = -1e9
      for (var i = 0; i < _mons.length; i++) {
        var d = _mons[i], s = _logical(d)
        minx = Math.min(minx, d.x); miny = Math.min(miny, d.y)
        maxx = Math.max(maxx, d.x + s.w); maxy = Math.max(maxy, d.y + s.h)
      }
      return { minx: minx, miny: miny, w: Math.max(1, maxx - minx), h: Math.max(1, maxy - miny) }
    }
    readonly property var bb: (_rev, _bbox())
    readonly property real sc: Math.min(width / bb.w, height / bb.h) * 0.9
    readonly property real offx: (width - bb.w * sc) / 2
    readonly property real offy: (height - bb.h * sc) / 2

    // snap dragged edges to neighbours (adjacency + alignment)
    function _snap(idx, x, y) {
      var s = _logical(_mons[idx]), thr = 40 / sc, bx = x, by = y
      for (var i = 0; i < _mons.length; i++) {
        if (i === idx) continue
        var o = _mons[i], os = _logical(o)
        var cx = [o.x + os.w, o.x - s.w, o.x, o.x + os.w - s.w]
        for (var a = 0; a < cx.length; a++) if (Math.abs(x - cx[a]) < thr) bx = cx[a]
        var cy = [o.y + os.h, o.y - s.h, o.y, o.y + os.h - s.h]
        for (var b = 0; b < cy.length; b++) if (Math.abs(y - cy[b]) < thr) by = cy[b]
      }
      return { x: bx, y: by }
    }

    Repeater {
      model: (dc._rev, dc._mons.length)
      delegate: Rectangle {
        id: monRect
        readonly property var d: dc._mons[index]
        readonly property var ls: dc._logical(d)
        // Pixel drag offset layered on top of the committed (world-derived) position.
        // During a drag ONLY this changes — the bbox/scale/other rects stay frozen —
        // so dragging is smooth instead of reflowing the whole canvas every mouse move.
        property real dragDX: 0
        property real dragDY: 0
        property bool dragging: false
        x: (dc._rev, dc.offx + (d.x - dc.bb.minx) * dc.sc + dragDX)
        y: (dc._rev, dc.offy + (d.y - dc.bb.miny) * dc.sc + dragDY)
        width: (dc._rev, ls.w * dc.sc)
        height: (dc._rev, ls.h * dc.sc)
        z: dragging ? 10 : 0
        color: Color.mSurfaceVariant
        border.color: index === dc.selectedIndex ? Color.mPrimary : Color.mOutline
        border.width: index === dc.selectedIndex ? 2 : 1
        radius: Style.radiusXS
        opacity: d.disabled ? 0.4 : 1
        // Animate the settle after a drop (and any re-fit / scale / rotation change),
        // but never the drag itself.
        Behavior on x { enabled: !monRect.dragging; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
        Behavior on y { enabled: !monRect.dragging; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
        Behavior on width { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
        Behavior on height { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }

        Column {
          anchors.centerIn: parent
          NText { anchors.horizontalCenter: parent.horizontalCenter; text: monRect.d.name; pointSize: Style.fontSizeXS; font.weight: Style.fontWeightSemiBold }
          NText { anchors.horizontalCenter: parent.horizontalCenter; text: String(monRect.d.mode).split("@")[0]; pointSize: Style.fontSizeXXS; color: Color.mOnSurfaceVariant }
        }

        MouseArea {
          anchors.fill: parent
          property real startX: 0   // pointer at press, in canvas coords (stable as the rect moves)
          property real startY: 0
          property real baseDX: 0
          property real baseDY: 0
          onPressed: (m) => {
            dc.select(index)
            var p = mapToItem(dc, m.x, m.y)
            startX = p.x; startY = p.y
            baseDX = monRect.dragDX; baseDY = monRect.dragDY
            monRect.dragging = true
          }
          onPositionChanged: (m) => {
            if (!pressed) return
            var p = mapToItem(dc, m.x, m.y)
            var rawDX = baseDX + (p.x - startX)
            var rawDY = baseDY + (p.y - startY)
            // snap in world space with the scale frozen — magnetic but jitter-free
            var wx = monRect.d.x + rawDX / dc.sc
            var wy = monRect.d.y + rawDY / dc.sc
            var sn = dc._snap(index, wx, wy)
            monRect.dragDX = (sn.x - monRect.d.x) * dc.sc
            monRect.dragDY = (sn.y - monRect.d.y) * dc.sc
          }
          onReleased: {
            monRect.dragging = false
            var wx = Math.round(monRect.d.x + monRect.dragDX / dc.sc)
            var wy = Math.round(monRect.d.y + monRect.dragDY / dc.sc)
            monRect.dragDX = 0; monRect.dragDY = 0
            dc._mons[index].x = wx; dc._mons[index].y = wy
            dc._rev++                       // single reflow/re-fit after the drop
            dc.moved(index, wx, wy)
          }
        }
      }
    }
  }
}
