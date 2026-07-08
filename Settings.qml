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
  function saveSettings() { apply() }

  // ---------- config helpers ----------
  function monEntry(name) {
    if (!edit.managed[name]) edit.managed[name] = { enabled: false, layout: defaultLayout() }
    if (!edit.managed[name].layout) edit.managed[name].layout = defaultLayout()
    return edit.managed[name]
  }
  function defaultLayout() { return { zones: 4, vsplit: 1 / 3, hsplit: 1 / 3, fill: [3, 2, 1, 0], subdivide: [1, 2] } }
  function layoutOf(name) { return monEntry(name).layout }
  function defaultFill(z) { var a = []; for (var i = 0; i < z; i++) a.push(z - 1 - i); return a }
  function fillOf(name) { var l = layoutOf(name); return l.fill || defaultFill(l.zones) }
  function zoneLabel(zones, zi) {
    if (zones === 2) return zi === 0 ? "Zone 1 (left)" : "Zone 2 (right)"
    return ["Zone 1 (top-left)", "Zone 2 (top-right)", "Zone 3 (bottom-left)", "Zone 4 (bottom-right)"][zi]
  }

  function setEnabled(name, on) { monEntry(name).enabled = on; rev++; apply() }
  function setZones(name, z) {
    var l = layoutOf(name); l.zones = z; l.fill = defaultFill(z)
    l.subdivide = (l.subdivide || []).filter(function (i) { return i < z })
    rev++
  }
  function setSplit(name, v, h) { var l = layoutOf(name); l.vsplit = v; if (h !== undefined && h !== null) l.hsplit = h }
  function setFillOrder(name, fill) { layoutOf(name).fill = fill }
  function toggleSub(name, zi, on) {
    var l = layoutOf(name); var s = (l.subdivide || []).slice(); var i = s.indexOf(zi)
    if (on && i < 0) s.push(zi)
    if (!on && i >= 0) s.splice(i, 1)
    l.subdivide = s; rev++
  }
  function setSubOrder(name, order) { layoutOf(name).subdivide = order }

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

  // ---------- display editor state ----------
  property var dispEdit: []
  property int dispRev: 0
  property int dispSel: 0

  function reloadDisplays() {
    var ms = (hz && hz.monitors) ? hz.monitors : []
    dispEdit = ms.map(function (m) {
      return { name: m.name, mode: currentModeOf(m), x: m.x || 0, y: m.y || 0,
               scale: m.scale || 1, transform: m.transform || 0, disabled: !!m.disabled,
               modes: (m.availableModes || []).slice() }
    })
    if (dispSel >= dispEdit.length) dispSel = 0
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
  function setDisp(field, val) { if (dispEdit[dispSel]) { dispEdit[dispSel][field] = val; dispRev++ } }
  function moveDisp(i, x, y) { if (dispEdit[i]) { dispEdit[i].x = x; dispEdit[i].y = y } }
  function applyDisplays() {
    if (!hz) return
    hz.request("apply_monitor_layout", { timeout_s: 15, monitors: dispEdit.map(function (d) {
      return { name: d.name, mode: d.mode, x: Math.round(d.x), y: Math.round(d.y),
               scale: d.scale, transform: d.transform, disabled: d.disabled }
    }) }, function (r, e) { if (e) ToastService.showError("HyperZone", "Apply failed: " + e) })
  }

  Connections {
    target: root.hz
    function onConfigChanged() { if (root.hz && root.hz.config) root.reload() }
    function onDaemonReadyChanged() { if (root.hz && root.hz.daemonReady) { root.reload(); root.reloadDisplays() } }
    function onMonitorsChanged() { root.reloadDisplays() }
  }
  Component.onCompleted: if (hz && hz.daemonReady) { reload(); reloadDisplays() }

  // =======================================================================
  NHeader { Layout.fillWidth: true; label: "HyperZone"; description: "Zone tiling + display editor for Hyprland" }

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
    NTabButton { text: "General";  tabIndex: 2; checked: tabs.currentIndex === 2 }
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
              label: "Scale"; minimumWidth: 100
              model: [{ key: "1", name: "1×" }, { key: "1.25", name: "1.25×" }, { key: "1.5", name: "1.5×" }, { key: "1.6", name: "1.6×" }, { key: "2", name: "2×" }]
              currentKey: (root.dispRev, String(root.selDisp() ? root.selDisp().scale : 1))
              onSelected: (key) => root.setDisp("scale", parseFloat(key))
            }
            NComboBox {
              label: "Rotation"; minimumWidth: 120
              model: [{ key: "0", name: "Normal" }, { key: "1", name: "90°" }, { key: "2", name: "180°" }, { key: "3", name: "270°" }]
              currentKey: (root.dispRev, String(root.selDisp() ? root.selDisp().transform : 0))
              onSelected: (key) => root.setDisp("transform", parseInt(key))
            }
            NToggle {
              label: "Managed"
              checked: (root.rev, root.selDisp() ? root.isManaged(root.selDisp().name) : false)
              onToggled: (v) => { if (root.selDisp()) root.setEnabled(root.selDisp().name, v) }
            }
          }
        }
      }

      // confirm-or-revert banner (bound to the daemon's pending state, so it
      // survives this popup being closed and reopened mid-countdown)
      NBox {
        Layout.fillWidth: true
        visible: root.hz && root.hz.pendingLayout !== null
        implicitHeight: pendRow.implicitHeight + Style.marginM * 2
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
            Layout.fillWidth: true
            text: "Keep this display layout? Reverting in " + parent.parent.remain + "s"
            font.weight: Style.fontWeightMedium
          }
          NButton { text: "Keep"; onClicked: root.hz.request("confirm_monitor_layout", {}) }
          NButton { text: "Revert"; outlined: true; onClicked: root.hz.request("revert_monitor_layout", {}) }
        }
      }

      // migration gate + apply
      ColumnLayout {
        Layout.fillWidth: true
        visible: root.hz && !root.hz.migrated
        spacing: Style.marginXS
        NText {
          Layout.fillWidth: true; wrapMode: Text.WordWrap
          text: "To edit displays, HyperZone moves your monitor setup out of hyprland.lua into a " +
                "generated monitors.lua it manages (a timestamped backup is kept). One-time."
          pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant
        }
        NButton {
          text: "Migrate hyprland.lua → monitors.lua"
          onClicked: root.hz.request("migrate_hyprland_config", {}, function (r, e) {
            if (e) ToastService.showError("HyperZone", "Migration failed: " + e)
            else if (r && r.changed) { ToastService.showNotice("HyperZone", "Migrated. Backup: " + r.backup); root.hz.refresh() }
            else ToastService.showNotice("HyperZone", "Already migrated")
          })
        }
      }
      NButton {
        text: "Apply display layout"
        visible: root.hz && root.hz.migrated
        enabled: root.hz && root.hz.pendingLayout === null
        onClicked: root.applyDisplays()
      }
    }

    // ================= ZONES =================
    ColumnLayout {
      spacing: Style.marginM
      NLabel { label: "Zone layout"; description: "How windows tile on each managed screen" }

      NText {
        Layout.fillWidth: true
        visible: (root.rev, root.managedNames().length === 0)
        text: "No managed screens yet — enable one under Displays."
        color: Color.mOnSurfaceVariant
      }

      Repeater {
        model: (root.rev, root.managedNames())
        delegate: NCollapsible {
          Layout.fillWidth: true
          label: modelData
          expanded: index === 0
          readonly property string mon: modelData

          RowLayout {
            Layout.fillWidth: true; spacing: Style.marginM
            NText { text: "Zones:"; Layout.alignment: Qt.AlignVCenter }
            NComboBox {
              minimumWidth: 120
              model: [{ key: "2", name: "2 zones" }, { key: "4", name: "4 zones" }]
              currentKey: (root.rev, String(root.layoutOf(mon).zones))
              onSelected: (key) => root.setZones(mon, parseInt(key))
            }
          }

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

      RowLayout {
        Layout.fillWidth: true; Layout.topMargin: Style.marginS; spacing: Style.marginM
        NButton { text: "Apply zone layout"; onClicked: root.apply() }
        NButton { text: "Re-tile now"; outlined: true; onClicked: if (root.hz) root.hz.request("retile", {}) }
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
      NTextInput {
        Layout.fillWidth: true
        label: "Never-tile window classes (comma-separated)"
        text: (root.rev, (root.edit.deny_classes || []).join(", "))
        onEditingFinished: root.edit.deny_classes = text.split(",").map(function (s) { return s.trim() }).filter(function (s) { return s.length })
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
      NButton { text: "Apply"; Layout.topMargin: Style.marginS; onClicked: root.apply() }
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
              color: Color.mSurfaceVariant; border.color: Color.mOutline; border.width: 1; radius: Style.radiusXS
              NText {
                anchors.centerIn: parent
                text: (ze.fill.indexOf(modelData.zi) + 1) + (ze.subdivide.indexOf(modelData.zi) !== -1 ? "  ⊞" : "")
                color: Color.mOnSurfaceVariant; pointSize: Style.fontSizeS
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
        readonly property var d: dc._mons[index]
        readonly property var ls: dc._logical(d)
        x: (dc._rev, dc.offx + (d.x - dc.bb.minx) * dc.sc)
        y: (dc._rev, dc.offy + (d.y - dc.bb.miny) * dc.sc)
        width: (dc._rev, ls.w * dc.sc)
        height: (dc._rev, ls.h * dc.sc)
        color: Color.mSurfaceVariant
        border.color: index === dc.selectedIndex ? Color.mPrimary : Color.mOutline
        border.width: index === dc.selectedIndex ? 2 : 1
        radius: Style.radiusXS
        opacity: d.disabled ? 0.4 : 1

        Column {
          anchors.centerIn: parent
          NText { anchors.horizontalCenter: parent.horizontalCenter; text: d.name; pointSize: Style.fontSizeXS; font.weight: Style.fontWeightSemiBold }
          NText { anchors.horizontalCenter: parent.horizontalCenter; text: String(d.mode).split("@")[0]; pointSize: Style.fontSizeXXS; color: Color.mOnSurfaceVariant }
        }

        MouseArea {
          anchors.fill: parent
          property real ox: 0
          property real oy: 0
          onPressed: (m) => { dc.select(index); ox = m.x; oy = m.y }
          onPositionChanged: (m) => {
            if (!pressed) return
            var wx = d.x + (m.x - ox) / dc.sc
            var wy = d.y + (m.y - oy) / dc.sc
            var sn = dc._snap(index, wx, wy)
            dc._mons[index].x = sn.x; dc._mons[index].y = sn.y; dc._rev++
          }
          onReleased: dc.moved(index, dc._mons[index].x, dc._mons[index].y)
        }
      }
    }
  }
}
