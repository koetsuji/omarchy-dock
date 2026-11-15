import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import QtQuick.Effects

// One screen's dock: a card of the widget family along the bottom edge. It
// shows on every workspace type and reserves its resting band, so tiled
// windows end above it. The surface is taller than that band so that
// magnified items, labels and menus can overflow upwards; its input mask
// covers the card only, and everything else is click-through.
PanelWindow {
  id: window

  property var dock: null
  readonly property var settings: dock ? dock.settings : null

  readonly property var monitor: screen ? Hyprland.monitorFor(screen) : null
  readonly property var workspace: monitor ? monitor.activeWorkspace : null
  readonly property int workspaceId: workspace ? workspace.id : -1

  // Hyprland counts 1 as maximized, 2 and 3 as fullscreen. The dock hides and
  // gives its space back under a fullscreen window.
  readonly property int fullscreenMode: {
    var mode = 0
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var toplevel = toplevels[i]
      if (!toplevel.workspace || toplevel.workspace.id !== workspaceId) continue
      var ipc = toplevel.lastIpcObject
      mode = Math.max(mode, ipc && ipc.fullscreen ? ipc.fullscreen : 0)
    }
    return mode
  }
  readonly property bool shown: !!dock && fullscreenMode < 2

  // Every dimension derives from the tile size.
  readonly property int tile: settings ? settings.iconSize : 56
  readonly property int gap: Math.round(tile * 10 / 48)
  readonly property int pad: gap
  readonly property int cardHeight: tile + pad * 2
  // 14 px, like the desktop widgets.
  readonly property int edgeGap: 14
  readonly property int band: cardHeight + edgeGap
  // Room above the band for magnified items, a label and the tallest menu.
  readonly property int overflow: tile + 28 + Style.spacing.popupRowHeight * 14 + Style.spacing.sm * 4

  Look { id: tokens; cardOpacity: window.settings ? window.settings.cardOpacity : 0.5 }

  color: "transparent"
  WlrLayershell.namespace: "omarchy-dock"
  WlrLayershell.layer: WlrLayer.Top
  // The dock never takes the keyboard from the user's window, except while one
  // of its menus is open: then Escape has to reach it.
  // Only a menu takes the keyboard. Taking it at drag start reconfigures the layer surface, which
  // made the compositor end the pointer grab (the drag stopped the moment it began), so a drag is
  // canceled by a right click, not by Escape.
  WlrLayershell.keyboardFocus: window.menuOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

  // Bottom, left and right anchored: three edges, so the exclusive zone
  // applies to the bottom one.
  anchors { top: false; bottom: true; left: true; right: true }
  implicitWidth: 0
  implicitHeight: band + overflow
  exclusionMode: ExclusionMode.Normal
  exclusiveZone: shown ? band : 0

  // ---- Hover magnification, like macOS (section 10.2) ---------------------------
  // The whole row is laid out explicitly, in one pass, from the items' resting
  // positions and the pointer. Positions are never animated: only the hover amount is.
  // 1.0 is off; reduced motion turns scaling off too (a highlight instead).
  readonly property real magnification: settings && !Style.reduceMotion ? Math.max(1, settings.magnification) : 1
  readonly property bool showDownloads: !!settings && settings.showDownloads
  readonly property bool showTrash: !!settings && settings.showTrash
  // A test can stand in for the pointer (the `pointer` hook): it sets the same state a real
  // hover event sets. fakeHover is only ever set by that hook.
  property bool fakeHover: false
  readonly property bool hovering: pointer.hovered || fakeHover
  property real lastLoggedX: -1000
  property real lastLoggedAt: 0
  function fakePointer(x) { window.fakeHover = true; window.pointerX = x; window.pointerY = card.y + card.height / 2 }
  function fakeLeave() { window.fakeHover = false }
  // The pointer, as the layout sees it (window coordinates). It is never smoothed.
  property real pointerX: -1
  property real pointerY: -1
  // The hover amount, 0 to 1: up in about 120 ms, down in about 180 ms after a 60 ms grace,
  // so brushing the gap between two icons does not collapse the row.
  property real hover: 0

  NumberAnimation { id: enterAnim; target: window; property: "hover"; to: 1; duration: Style.duration(120); easing.type: Easing.OutCubic }
  SequentialAnimation {
    id: leaveAnim
    PauseAnimation { duration: Style.duration(60) }
    NumberAnimation { target: window; property: "hover"; to: 0; duration: Style.duration(180); easing.type: Easing.OutCubic }
  }
  // While an item is dragged the hover amount goes to 0 and stays there.
  readonly property bool hoverWanted: hovering && !dragging
  NumberAnimation { id: fastOut; target: window; property: "hover"; to: 0; duration: Style.duration(140); easing.type: Easing.OutCubic }
  onHoveringChanged: window.logEvent(hovering ? "hover enter" : "hover leave")
  onHoverWantedChanged: {
    if (hoverWanted) { leaveAnim.stop(); fastOut.stop(); enterAnim.restart() }
    else { enterAnim.stop(); if (dragging) fastOut.restart(); else leaveAnim.restart() }
  }

  // The row, left to right: pinned apps, a separator, running apps, a separator, Downloads and Trash.
  readonly property var elements: dragging ? buildDragElements(true) : buildElements(pinned.count, running.count, showDownloads, showTrash)
  readonly property var lay: computeLayout(elements, pointerX, hover, magnification, tile, gap, pad, width)

  function buildElements(p, r, downloads, trash) {
    var out = []
    for (var i = 0; i < p; i++) out.push({ id: "p" + i, item: true })
    var utilities = (downloads ? 1 : 0) + (trash ? 1 : 0)
    if (p > 0 && r > 0) out.push({ id: "sepA", item: false })
    for (var j = 0; j < r; j++) out.push({ id: "r" + j, item: true })
    if (utilities > 0 && (p > 0 || r > 0)) out.push({ id: "sepB", item: false })
    if (downloads) out.push({ id: "dl", item: true })
    if (trash) out.push({ id: "tr", item: true })
    return out
  }

  // s = 1 + (m - 1) * a * cos((pi / 2) * min(1, |d| / R))^2, with d the distance of the pointer
  // from the item's RESTING centre (never from the magnified layout, or the row would jitter)
  // and R = 3 pitches. The scaled items are laid out with the constant gap, then the whole row
  // is shifted so the resting point under the pointer stays under the pointer.
  function computeLayout(elements, px, a, m, tile, gap, pad, W) {
    var n = elements.length
    var restLeft = [], widths = []
    var x = 0
    for (var i = 0; i < n; i++) {
      var w = elements[i].item ? tile : 1
      restLeft.push(x)
      widths.push(w)
      x += w + gap
    }
    var restWidth = n > 0 ? x - gap : 0
    var start = Math.round((W - (restWidth + 2 * pad)) / 2) + pad
    for (i = 0; i < n; i++) restLeft[i] += start

    // Magnification is a continuous stretch of the resting axis: a point at resting position t
    // is stretched by s(t) = 1 + (m - 1) * a * cos((pi / 2) * min(1, |t - px| / R))^2, and the
    // magnified position of t is X(t) = X0 + the integral of s from the row's start to t, with X0
    // chosen so that X(px) = px: the resting point under the pointer stays under the pointer.
    // An item's scale is how much its own span is stretched. Because s is smooth, so is every
    // position as a function of the pointer: the row has no steps in its speed (the earlier
    // item-and-gap mapping had one at every icon edge, which showed as shaking in a fast sweep).
    // The gaps stretch by the same curve, so they only ever grow from the resting gap: nothing overlaps.
    var active = m > 1 && a > 0 && px >= 0
    var radius = 3 * (tile + gap)
    var k = (m - 1) * a
    function stretched(d) {   // the integral of the stretch beyond 1, from the pointer to distance d
      if (d > radius) return k * radius / 2
      if (d < -radius) return -k * radius / 2
      return k * (d / 2 + radius * Math.sin(Math.PI * d / radius) / (2 * Math.PI))
    }
    function span(u0, u1) { return (u1 - u0) + (active ? stretched(u1 - px) - stretched(u0 - px) : 0) }
    var x0 = active ? px - span(start, px) : start
    var left = [], scaled = [], scale = [], centre = []
    for (i = 0; i < n; i++) {
      var l = x0 + span(start, restLeft[i])
      var r = x0 + span(start, restLeft[i] + widths[i])
      left.push(l)
      scaled.push(r - l)
      scale.push(elements[i].item ? (r - l) / widths[i] : 1)
      centre.push((l + r) / 2)
    }
    var index = {}
    for (i = 0; i < n; i++) index[elements[i].id] = i
    // The item under (or nearest to) the pointer.
    var under = -1, best = 1e9
    for (i = 0; i < n; i++) {
      if (!elements[i].item) continue
      var dist = px < left[i] ? left[i] - px : (px > left[i] + scaled[i] ? px - left[i] - scaled[i] : 0)
      if (dist < best) { best = dist; under = i }
    }
    return { ids: elements.map(function(e) { return e.id }), index: index, left: left, width: scaled, scale: scale, centre: centre, restLeft: restLeft, restWidth: widths,
      cardLeft: n > 0 ? left[0] - pad : Math.round(W / 2), cardWidth: n > 0 ? left[n - 1] + scaled[n - 1] - left[0] + 2 * pad : 2 * pad,
      under: under, anchor: n > 0 ? x0 + span(start, px) : px }
  }

  // The row only animates its positions while an item is dragged or settling (the gap opening
  // with a 160 ms ease); under the pointer, positions are never animated.
  readonly property bool animateRow: dragging || settleKey !== ""
  readonly property real rowY: card.y + pad
  function indexOf(id) { var i = lay.index[id]; return i === undefined ? -1 : i }
  function centreOf(id) { var i = indexOf(id); return i < 0 ? 0 : lay.centre[i] }
  function leftOf(id) { var i = indexOf(id); return i < 0 ? 0 : lay.left[i] }
  function scaleOf(id) { var i = indexOf(id); return i < 0 ? 1 : lay.scale[i] }

  // The hover zone: the card, up by the magnification overflow, down to the screen edge.
  readonly property int zoneUp: Math.round((magnification - 1) * tile) + 12
  Item {
    id: zone
    x: card.x
    width: card.width
    y: card.y - window.zoneUp
    height: card.height + window.zoneUp + window.edgeGap
  }

  mask: Region {
    item: window.shown ? (window.hovering || window.hover > 0.001 ? zone : card) : null
    Region { item: menu.visible ? menu : null }
  }

  // A light blur behind the card (setting dockBlur), asked of the compositor
  // through the background-effect protocol, so no Hyprland rule is needed.
  BackgroundEffect.blurRegion: window.shown && window.settings && window.settings.dockBlur ? blurRegion : null
  Region { id: blurRegion; item: card; radius: Style.cornerRadius }

  function logEvent(what) { if (dock) dock.logEvent(what) }

  // ---- The context menu ----------------------------------------------------
  // Opened on release. It stays until a click on one of its items, a new click outside
  // both the dock and the menu, Escape, or its app disappearing. Close requests from the
  // focus grab in the first 200 ms, or while the pointer is over the dock or the menu, are
  // not clicks outside and are ignored.
  property string menuKind: ""      // "app" or "trash"
  property string menuKey: ""
  property Item menuSlot: null
  property bool trashConfirm: false
  property real menuOpenedAt: 0
  property bool grabArmed: true
  property int grabRearms: 0
  // Set by the test hook: a menu opened without the pointer has no focus grab to arm.
  property bool testMenu: false
  readonly property bool menuOpen: menuKind !== ""
  // The pointer over the dock's card or the menu, by position (the single handler sees all of it).
  readonly property bool pointerOverUi: hovering && ((pointerX >= card.x && pointerX <= card.x + card.width && pointerY >= card.y && pointerY <= card.y + card.height)
    || (menu.visible && pointerX >= menu.x && pointerX <= menu.x + menu.width && pointerY >= menu.y && pointerY <= menu.y + menu.height))

  function openMenu(kind, key, slot) {
    if (window.menuOpen && window.menuKind === kind && window.menuKey === key) { window.closeMenu("toggled"); return }
    window.trashConfirm = false
    window.menuSlot = slot
    window.menuKind = kind
    window.menuKey = key
    window.menuOpenedAt = Date.now()
    window.grabArmed = true
    window.grabRearms = 0
    window.logEvent("menu open " + kind + " " + key)
  }

  function closeMenu(reason) {
    if (window.menuOpen) window.logEvent("menu close: " + (reason || "unknown") + " (" + window.menuKind + " " + window.menuKey + ", open " + (Date.now() - window.menuOpenedAt) + " ms)")
    window.testMenu = false
    window.menuKind = ""
    window.menuKey = ""
    window.menuSlot = null
    window.trashConfirm = false
  }

  onShownChanged: if (!shown) closeMenu("dock hidden")
  onMenuOpenChanged: if (menuOpen) keyCatcher.forceActiveFocus()

  // The grab includes this window, which holds both the dock and the menu.
  HyprlandFocusGrab {
    active: window.menuOpen && !window.testMenu && window.grabArmed
    windows: [window]
    onActiveChanged: window.logEvent("grab active=" + active)
    onCleared: {
      window.logEvent("grab cleared (pointer over dock or menu: " + window.pointerOverUi + ", x=" + Math.round(window.pointerX) + " y=" + Math.round(window.pointerY) + ")")
      if (!window.menuOpen) return
      if (Date.now() - window.menuOpenedAt < 200 || window.pointerOverUi) {
        if (window.grabRearms < 5) { window.grabRearms++; window.grabArmed = false; rearm.restart() }
        else window.closeMenu("grab cleared repeatedly")
        return
      }
      window.closeMenu("click outside")
    }
  }
  Timer { id: rearm; interval: 30; onTriggered: window.grabArmed = true }

  Item {
    id: keyCatcher
    Keys.onEscapePressed: { if (window.dragging) window.endDrag(0, 0, true); else window.closeMenu("escape") }
  }

  // The app a menu belongs to goes away: the menu goes with it.
  Connections {
    target: window.dock
    function onItemsChanged() {
      if (window.menuKind === "app" && window.dock && !window.dock.itemFor(window.menuKey)) window.closeMenu("app gone")
      if (window.dragging && window.dock && !window.dock.itemFor(window.dragKey)) window.endDrag(0, 0, true)
    }
  }

  function clip(text, length) {
    var value = String(text || "")
    return value.length > length ? value.slice(0, length - 1) + "…" : value
  }

  // Placed above the dock, centered on its slot.
  function popupX(slot, popup) {
    if (!slot) return 0
    var center = slot.mapToItem(window.contentItem, slot.width / 2, 0).x
    return Math.max(window.gap, Math.min(window.width - popup.width - window.gap, center - popup.width / 2))
  }

  function popupY(slot, popup) {
    return card.y - window.gap - popup.height
  }

  // The grid reports drags of its apps here; dropping onto the dock comes in
  // a later milestone.
  function moveExternalDrag(screenX, screenY) {}
  function dropExternalDrag(screenX, screenY, key) {}
  function endExternalDrag() {}

  // Slot, canvas and drawn tile of one item: for the geometry dump.
  function describe(tile, icon, key, section, token, id) {
    var at = tile.mapToItem(window.contentItem, 0, 0)
    var entry = window.dock.iconCache[token]
    var meta = entry ? entry.meta : null
    var box = meta && meta.tileBox ? meta.tileBox : null
    var canvas = icon ? icon.canvasWidth : 0
    // Where the drawn tile (or the fitted icon) is, against the slot's centre line. The
    // canvas is centred on the slot, and its shadow margin plays no part: the centre comes
    // from the picture's own 50 percent alpha box.
    var drawn = meta ? (meta.tileBox || meta.box) : null
    var canvasTop = icon ? icon.mapToItem(window.contentItem, 0, 0).y + (icon.height - canvas) / 2 : 0
    var centre = drawn ? canvasTop + (drawn[1] + drawn[3]) / 2 / 256 * canvas : 0
    var i = window.indexOf(id)
    return { key: key, id: id, section: section, x: at.x, y: at.y, slot: tile.width, canvas: canvas,
      centreY: centre, slotCentreY: at.y + tile.height / 2,
      left: i < 0 ? 0 : lay.left[i], width: i < 0 ? 0 : lay.width[i], scale: i < 0 ? 1 : lay.scale[i],
      restLeft: i < 0 ? 0 : lay.restLeft[i], restWidth: i < 0 ? 0 : lay.restWidth[i],
      ready: !!icon && icon.ready, mode: meta ? (meta.mode || meta.style) : "raw",
      tile: box ? (box[2] - box[0]) / 256 * canvas : 0, extent: meta && meta.extent ? meta.extent : null, token: token }
  }

  // Opens an app's menu (or the trash's) as a right click would: for tests.
  function openMenuFor(key) {
    window.testMenu = true
    if (key === "trash") { window.openMenu("trash", "trash", trash); return true }
    var sections = [pinned, running]
    for (var s = 0; s < sections.length; s++) {
      for (var i = 0; i < sections[s].count; i++) {
        var app = sections[s].itemAt(i)
        if (app && app.key === key) { window.openMenu("app", key, app); return true }
      }
    }
    return false
  }

  function geometry() {
    var items = []
    var sections = [["pinned", pinned], ["running", running]]
    for (var s = 0; s < sections.length; s++) {
      for (var i = 0; i < sections[s][1].count; i++) {
        var app = sections[s][1].itemAt(i)
        if (app && app.modelData) items.push(window.describe(app, app.iconItem, app.key, sections[s][0], window.dock.iconToken(app.modelData), app.elementId))
      }
    }
    if (downloads.visible) items.push(window.describe(downloads, downloadsIcon, "downloads", "utility", window.dock.utilityToken(window.dock.downloadsIcon), "dl"))
    if (trash.visible) items.push(window.describe(trash, trashIcon, "trash", "utility", window.dock.utilityToken(trashIcon.source), "tr"))
    var separators = []
    for (var e = 0; e < elements.length; e++) if (!elements[e].item) separators.push({ id: elements[e].id, left: lay.left[e], width: lay.width[e], restLeft: lay.restLeft[e], restWidth: lay.restWidth[e] })
    return { screen: screen ? screen.name : "", iconSize: window.tile, shown: window.shown,
      hover: { amount: window.hover, hovering: window.hovering, pointerX: window.pointerX, magnification: window.magnification, gap: window.gap,
        under: lay.under >= 0 ? elements[lay.under].id : "", anchor: lay.anchor },
      drag: { active: window.dragging, key: window.dragKey, section: window.dragSection, index: window.dragIndex, removing: window.dragRemoving,
        outside: window.dragOutside, centreX: window.dragCentreX, centreY: window.dragCentreY, hover: window.hover,
        gap: lay.index["gap"] === undefined ? null : { left: lay.left[lay.index["gap"]], width: lay.width[lay.index["gap"]] } },
      menu: { open: window.menuOpen, kind: window.menuKind, key: window.menuKey, visible: menu.visible, rows: menuColumn.children.length },
      card: { x: card.x, y: card.y, w: card.width, h: card.height }, separators: separators, items: items }
  }

  Rectangle {
    id: card
    visible: window.shown
    x: window.lay.cardLeft
    width: window.lay.cardWidth
    Behavior on x { enabled: window.animateRow; NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
    Behavior on width { enabled: window.animateRow; NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
    height: window.cardHeight
    y: window.height - window.edgeGap - height
    radius: Style.cornerRadius
    color: tokens.card
    border.width: 1
    border.color: tokens.cardBorder
  }

  // ---- The row: positioned by the layout, in window coordinates ----------------
  Repeater {
    id: pinned
    model: window.dock ? window.dock.pinnedModel : null
    delegate: AppTile { prefix: "p" }
  }

  Repeater {
    id: running
    model: window.dock ? window.dock.runningModel : null
    delegate: AppTile { prefix: "r" }
  }

  Separator { eid: "sepA" }
  Separator { eid: "sepB" }

  // Right end, like macOS: a thin separator, then Downloads and Trash.
  DockTile {
    id: downloads
    visible: window.showDownloads && window.shown
    size: window.tile
    x: window.centreOf("dl") - width / 2
    Behavior on x { enabled: window.animateRow; NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
    y: window.rowY
    hovered: window.hoverId === "dl"
    magnify: window.scaleOf("dl")
    bottomReach: (window.pad + window.edgeGap) / magnify
    highlightOnHover: window.magnification <= 1
    onEvent: function(what) { window.logEvent(what + " downloads") }
    onActivated: function(button, modifiers) { window.closeMenu("click on downloads"); if (window.dock && button === Qt.LeftButton) window.dock.openDownloads() }
    DockIcon {
      id: downloadsIcon
      anchors.fill: parent
      factor: window.dock ? window.dock.scaleFor("downloads") : 1
      raw: window.dock ? window.dock.downloadsIcon : ""
      canvas: window.dock ? window.dock.canvasScale : 1
      normalized: window.dock ? window.dock.normalizedFor(window.dock.utilityToken(window.dock.downloadsIcon)) : ""
    }
  }

  DockTile {
    id: trash
    visible: window.showTrash && window.shown
    size: window.tile
    x: window.centreOf("tr") - width / 2
    Behavior on x { enabled: window.animateRow; NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
    y: window.rowY
    hovered: window.hoverId === "tr"
    magnify: window.scaleOf("tr")
    bottomReach: (window.pad + window.edgeGap) / magnify
    highlightOnHover: window.magnification <= 1
    onEvent: function(what) { window.logEvent(what + " trash") }
    onActivated: function(button, modifiers) { window.closeMenu("click on trash"); if (window.dock && button === Qt.LeftButton) window.dock.openTrash() }
    onContextRequested: window.openMenu("trash", "trash", trash)
    DockIcon {
      id: trashIcon
      readonly property string source: window.dock ? (window.dock.trashFull ? window.dock.trashFullIcon : window.dock.trashEmptyIcon) : ""
      anchors.fill: parent
      factor: window.dock ? window.dock.scaleFor("trash") : 1
      raw: source
      canvas: window.dock ? window.dock.canvasScale : 1
      normalized: window.dock ? window.dock.normalizedFor(window.dock.utilityToken(source)) : ""
    }
  }


  // ---- Drag and drop (section 10.4) ----------------------------------------------
  // A pointer gesture inside the dock surface. The dragged app leaves the row; the others open a gap
  // at the insertion point (160 ms ease). Pinned apps reorder freely. A running unpinned app can be
  // reordered among the running apps, or dragged into the pinned section to pin it at that spot.
  // A pinned app dragged more than 1.5 tiles above the card is removed from the pins on release
  // (REMOVE); released anywhere else outside the dock it goes back to its slot.
  property string dragKey: ""
  property string dragSource: ""       // "pinned" or "running"
  property int dragSourceIndex: -1
  property string dragSection: ""      // where the gap is: "p", "r", or "" while the item is being removed
  property int dragIndex: -1           // the gap's index among the other items of that section
  property real dragPX: 0              // the pointer, window coordinates
  property real dragPY: 0
  property real dragDX: 0              // the grab offset: the pointer minus the item's centre
  property real dragDY: 0
  property bool dragRemoving: false
  property bool dragOutside: false
  property bool dragFinishing: false
  property real dragFade: 0
  property string settleKey: ""
  property real settleDX: 0
  property real settleDY: 0
  property real settleAmount: 0
  readonly property bool dragging: dragKey !== ""
  readonly property real dragCentreX: dragPX - dragDX
  readonly property real dragCentreY: dragPY - dragDY

  // The row while dragging: the others, a gap placeholder at the target, separators as needed.
  function buildDragElements(withGap) {
    var pinnedIds = [], runningIds = []
    for (var i = 0; i < pinned.count; i++) if (!(dragSource === "pinned" && i === dragSourceIndex)) pinnedIds.push("p" + i)
    for (var j = 0; j < running.count; j++) if (!(dragSource === "running" && j === dragSourceIndex)) runningIds.push("r" + j)
    if (withGap && dragSection === "p") pinnedIds.splice(Math.min(Math.max(dragIndex, 0), pinnedIds.length), 0, "gap")
    if (withGap && dragSection === "r") runningIds.splice(Math.min(Math.max(dragIndex, 0), runningIds.length), 0, "gap")
    var out = []
    pinnedIds.forEach(function(id) { out.push({ id: id, item: true }) })
    if (pinnedIds.length > 0 && runningIds.length > 0) out.push({ id: "sepA", item: false })
    runningIds.forEach(function(id) { out.push({ id: id, item: true }) })
    if ((showDownloads || showTrash) && (pinnedIds.length > 0 || runningIds.length > 0)) out.push({ id: "sepB", item: false })
    if (showDownloads) out.push({ id: "dl", item: true })
    if (showTrash) out.push({ id: "tr", item: true })
    return out
  }

  // The row's own slots, as they sit at rest with the dragged item in place: static, so the
  // gap opening never feeds back into where the dragged item is compared.
  readonly property var slotLayout: dragging ? computeLayout(buildElements(pinned.count, running.count, showDownloads, showTrash), -1, 0, 1, tile, gap, pad, width) : null

  function setDragTarget(section, index) {
    if (section === dragSection && index === dragIndex) return
    dragSection = section
    dragIndex = index
    logEvent("drag target " + (section === "" ? "none" : section + " " + index))
  }

  // Where the gap goes: the slot nearest the dragged centre, changing only when the centre crosses
  // the middle between two slots by 6 px, so it cannot flicker. A running app can also go into the
  // pinned section, which has one more slot (after the last pinned app) than it has pinned apps.
  function updateDragTarget() {
    if (!dragging || !slotLayout) return
    var L = slotLayout
    var h = 6
    var pitch = tile + gap
    var pc = [], rc = []
    for (var i = 0; i < L.ids.length; i++) {
      var id = L.ids[i]
      if (id.charAt(0) === "p") pc.push(L.centre[i])
      else if (id.charAt(0) === "r") rc.push(L.centre[i])
    }
    var cx = dragCentreX
    var home = dragSource === "pinned" ? "p" : "r"
    var inside = dragPY >= card.y - tile && cx > L.cardLeft - tile && cx < L.cardLeft + L.cardWidth + tile
    var removing = dragSource === "pinned" && dragPY < card.y - 1.5 * tile
    dragRemoving = removing
    dragOutside = removing || !inside
    if (removing) { setDragTarget("", -1); return }
    if (dragOutside) { setDragTarget(home, dragSourceIndex); return }
    var sec = dragSection !== "" ? dragSection : home
    var slots
    if (dragSource === "running") {
      // pinned slots: the existing ones, then one after the last (or one before the first running app)
      var pinnedSlots = pc.slice()
      pinnedSlots.push(pc.length > 0 ? pc[pc.length - 1] + pitch : rc[0] - pitch)
      var boundary = (pinnedSlots[pinnedSlots.length - 1] + rc[0]) / 2
      if (sec === "r" && cx < boundary - h) sec = "p"
      else if (sec === "p" && cx > boundary + h) sec = "r"
      slots = sec === "p" ? pinnedSlots : rc
    } else {
      sec = "p"
      slots = pc
    }
    var j = dragIndex
    if (sec !== dragSection || j < 0) {
      j = 0
      for (var k = 1; k < slots.length; k++) if (Math.abs(cx - slots[k]) < Math.abs(cx - slots[j])) j = k
    }
    while (j < slots.length - 1 && cx > (slots[j] + slots[j + 1]) / 2 + h) j++
    while (j > 0 && cx < (slots[j - 1] + slots[j]) / 2 - h) j--
    setDragTarget(sec, j)
  }

  function modelKeys(model) {
    var out = []
    for (var i = 0; i < model.count; i++) out.push(model.get(i).key)
    return out
  }

  function beginDrag(tile, px, py) {
    if (dragging || !dock || (settings && settings.locked)) return false
    closeMenu("drag start")
    var inPinned = tile.prefix === "p"
    dragSource = inPinned ? "pinned" : "running"
    dragSourceIndex = tile.index
    dragDX = px - centreOf(tile.elementId)
    dragDY = py - (rowY + window.tile / 2)
    dragPX = px
    dragPY = py
    dragRemoving = false
    dragOutside = false
    dragFinishing = false
    dragFade = 0
    settleKey = ""
    dragSection = inPinned ? "p" : "r"
    dragIndex = tile.index
    dragKey = tile.key
    dock.frozen = true
    logEvent("drag begin " + tile.key + " from " + dragSource + " " + tile.index)
    return true
  }

  function dragTo(px, py) {
    if (!dragging || dragFinishing) return
    dragPX = px
    dragPY = py
    updateDragTarget()
  }

  function finishDrag() {
    dragKey = ""
    dragSection = ""
    dragIndex = -1
    dragRemoving = false
    dragOutside = false
    dragFinishing = false
    dragFade = 0
    if (dock) dock.frozen = false
  }

  function endDrag(px, py, canceled) {
    if (!dragging || dragFinishing) return
    if (!canceled) { pointerX = px; pointerY = py; dragTo(px, py) }
    var key = dragKey
    var pk = modelKeys(dock.pinnedModel), rk = modelKeys(dock.runningModel)
    var before = pk.join("|") + "#" + rk.join("|")
    var removing = !canceled && dragRemoving
    logEvent("drag end " + key + (canceled ? " canceled" : removing ? " remove" : " drop " + dragSection + " " + dragIndex + (dragOutside ? " (outside: back to its slot)" : "")))
    if (removing) {
      dragFinishing = true
      removeAnim.restart()
      return
    }
    var section = dragSection, index = dragIndex
    if (canceled || dragOutside) { section = dragSource === "pinned" ? "p" : "r"; index = dragSourceIndex }
    var gapAt = lay.index["gap"]
    var slotX = gapAt === undefined ? dragCentreX : lay.centre[gapAt]
    var fromX = dragCentreX, fromY = dragCentreY
    pk = pk.filter(function(k) { return k !== key })
    rk = rk.filter(function(k) { return k !== key })
    if (section === "p") pk.splice(Math.min(index, pk.length), 0, key)
    else rk.splice(Math.min(index, rk.length), 0, key)
    if (pk.join("|") + "#" + rk.join("|") !== before) dock.applyLayout(pk, rk)
    // the item settles from where it was dropped to its slot
    settleKey = key
    settleDX = fromX - slotX
    settleDY = fromY - (rowY + tile / 2)
    settleAmount = 1
    settleAnim.restart()
    finishDrag()
  }

  // REMOVE: the item scales down and fades, then it is taken out of the pins. If it is running it
  // moves to the running section.
  function finishRemove() {
    var key = dragKey
    if (!key) return
    var pk = modelKeys(dock.pinnedModel).filter(function(k) { return k !== key })
    var rk = modelKeys(dock.runningModel).filter(function(k) { return k !== key })
    rk.unshift(key)
    dock.applyLayout(pk, rk)
    finishDrag()
  }

  NumberAnimation { id: removeAnim; target: window; property: "dragFade"; from: 0; to: 1; duration: Style.duration(160); easing.type: Easing.OutCubic; onStopped: window.finishRemove() }
  NumberAnimation { id: settleAnim; target: window; property: "settleAmount"; from: 1; to: 0; duration: Style.duration(180); easing.type: Easing.OutCubic; onStopped: window.settleKey = "" }

  // The tile for an app key, for tests.
  function tileForKey(key) {
    var sections = [pinned, running]
    for (var s = 0; s < sections.length; s++)
      for (var i = 0; i < sections[s].count; i++) { var app = sections[s].itemAt(i); if (app && app.key === key) return app }
    return null
  }

  function dragStartKey(key, px, py) {
    var tile = tileForKey(key)
    if (!tile) return "unknown"
    if (settings && settings.locked) return "locked"
    return beginDrag(tile, px, py) ? "ok" : "busy"
  }

  // The REMOVE label, above the dragged item.
  Rectangle {
    visible: window.dragging && window.dragRemoving && window.dragFade < 0.5
    width: removeRow.implicitWidth + 20
    height: 26
    x: window.dragCentreX - width / 2
    y: window.dragCentreY - window.tile * 0.6 - height - 6
    z: 200
    radius: Style.cornerRadius
    color: tokens.tone(Commons.Color.background, 0.90)
    border.width: 1
    border.color: tokens.cardBorder
    Row {
      id: removeRow
      anchors.centerIn: parent
      spacing: 8
      Rectangle { width: 3; height: 10; radius: 1; color: tokens.urgent; anchors.verticalCenter: parent.verticalCenter }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "REMOVE"
        color: tokens.dim
        font.family: "monospace"
        font.pixelSize: 10
        font.letterSpacing: 2
      }
    }
  }

  // ---- The name label (section 7.7): above the hovered item, no delay, follows it, hidden in menus ----
  readonly property string hoverId: window.hovering && lay.under >= 0 ? elements[lay.under].id : ""
  function nameOfElement(id) {
    if (id === "dl") return "Downloads"
    if (id === "tr") return "Trash"
    if (!window.dock || !id) return ""
    var model = id.charAt(0) === "p" ? window.dock.pinnedModel : window.dock.runningModel
    var at = parseInt(id.slice(1))
    if (at >= model.count) return ""
    return window.dock.nameFor(window.dock.itemFor(model.get(at).key))
  }

  Rectangle {
    id: label
    readonly property string name: window.nameOfElement(window.hoverId)
    readonly property int at: window.indexOf(window.hoverId)
    visible: window.shown && !window.menuOpen && !window.dragging && name !== "" && at >= 0
    width: labelRow.implicitWidth + 20
    height: 26
    x: at < 0 ? 0 : Math.max(8, Math.min(window.width - width - 8, window.lay.centre[at] - width / 2))
    y: at < 0 ? 0 : window.rowY + window.tile - window.tile * window.lay.scale[at] - 8 - height
    radius: Style.cornerRadius
    color: tokens.tone(Commons.Color.background, 0.90)
    border.width: 1
    border.color: tokens.cardBorder

    Row {
      id: labelRow
      anchors.centerIn: parent
      spacing: 8
      Rectangle { width: 3; height: 10; radius: 1; color: tokens.accent; anchors.verticalCenter: parent.verticalCenter }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: label.name.toUpperCase()
        color: tokens.dim
        font.family: "monospace"
        font.pixelSize: 10
        font.letterSpacing: 2
      }
    }
  }

  // 1 px vertical line, 55 percent of the tile height, moved by the layout.
  component Separator: Item {
    property string eid: ""
    readonly property int at: window.indexOf(eid)
    visible: window.shown && at >= 0
    width: 1
    height: window.tile
    x: window.leftOf(eid)
    Behavior on x { enabled: window.animateRow; NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
    y: window.rowY
    Rectangle {
      anchors.centerIn: parent
      width: 1
      height: Math.round(window.tile * 0.55)
      color: tokens.separator
    }
  }

  component AppTile: DockTile {
    id: app

    required property string key
    required property int index
    property string prefix: "p"
    readonly property string elementId: prefix + index
    readonly property var modelData: window.dock ? window.dock.itemFor(key) : null
    readonly property int windowCount: modelData ? modelData.windows.length : 0
    readonly property bool focused: {
      if (!modelData) return false
      for (var i = 0; i < modelData.windows.length; i++) {
        if (modelData.windows[i].toplevel && modelData.windows[i].toplevel.activated) return true
      }
      return false
    }
    readonly property bool launching: !!window.dock && window.dock.isLaunching(key)
    // Launch feedback: the icon hops about a fifth of its height twice a second
    // (bounce), or its opacity pulses; reduced motion always gets a still, dimmed icon.
    readonly property bool bounce: launching && !Style.reduceMotion && !!window.settings && window.settings.launchFeedback === "bounce"
    property real pulse: 1
    property real hop: 0
    property alias iconItem: appIcon
    Behavior on hop {
      enabled: !hopper.running && !Style.reduceMotion
      SpringAnimation { spring: 5; damping: 0.3; epsilon: 0.01 }
    }

    // Dragging (section 10.4). The dragged item follows the pointer one to one, with the grab
    // offset kept and no easing; it lifts (scale 1.12, a soft shadow, a little transparent). After
    // the drop it settles from the pointer to its slot. Windows opening or closing do not move the row.
    readonly property bool isDragged: window.dragKey === key
    readonly property bool isSettling: window.settleKey === key
    property real lift: isDragged ? 1 : 0
    Behavior on lift { enabled: !Style.reduceMotion; SpringAnimation { spring: 5; damping: 0.45; epsilon: 0.001 } }

    size: window.tile
    x: isDragged ? window.dragCentreX - width / 2
      : window.centreOf(elementId) - width / 2 + (isSettling ? window.settleDX * window.settleAmount : 0)
    y: isDragged ? window.dragCentreY - height / 2
      : window.rowY + (isSettling ? window.settleDY * window.settleAmount : 0)
    Behavior on x { enabled: window.animateRow && !app.isDragged && !app.isSettling; NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
    hovered: window.hoverId === elementId
    magnify: ((isDragged ? 1 : window.scaleOf(elementId)) + 0.12 * lift) * (isDragged ? 1 - 0.7 * window.dragFade : 1)
    opacity: (1 - 0.12 * lift) * (isDragged ? 1 - window.dragFade : 1)
    z: isDragged || isSettling ? 100 : 0
    bottomReach: (window.pad + window.edgeGap) / magnify
    highlightOnHover: window.magnification <= 1
    visible: window.shown
    dragEnabled: !!window.settings && !window.settings.locked && !!modelData
    onDragStarted: function(x, y) { window.beginDrag(app, x, y) }
    onDragMoved: function(x, y) { window.dragTo(x, y) }
    onDragFinished: function(x, y) { window.endDrag(x, y, false) }
    onDragCanceled: window.endDrag(0, 0, true)

    onEvent: function(what) { window.logEvent(what + " " + app.key) }
    onActivated: function(button, modifiers) {
      if (!window.dock || !app.modelData) return
      window.closeMenu("click on " + app.key)
      // Middle click or Shift + click opens a new window.
      if (button === Qt.MiddleButton || (button === Qt.LeftButton && (modifiers & Qt.ShiftModifier))) window.dock.launch(app.modelData, true)
      else if (button === Qt.LeftButton) window.dock.activate(app.modelData)
    }
    onScrolled: function(direction) { if (window.dock && app.modelData) window.dock.cycle(app.modelData, direction) }
    onContextRequested: window.openMenu("app", app.key, app)

    DockIcon {
      id: appIcon
      readonly property string source: window.dock && app.modelData ? window.dock.iconFor(app.modelData) : ""
      anchors.fill: parent
      raw: source
      canvas: window.dock ? window.dock.canvasFor(app.modelData) : 1
      normalized: window.dock && app.modelData ? window.dock.normalizedFor(window.dock.iconToken(app.modelData)) : ""
      showRaw: !!window.dock && !!app.modelData && window.dock.iconFailed[window.dock.iconToken(app.modelData)] === true
      fade: app.launching ? (Style.reduceMotion ? 0.6 : app.pulse) : 1
      factor: window.dock ? window.dock.scaleFor(app.key) : 1
      transform: Translate { y: -app.hop }
      layer.enabled: app.lift > 0.01
      layer.effect: MultiEffect {
        shadowEnabled: true
        shadowColor: "black"
        shadowOpacity: 0.45 * app.lift
        shadowBlur: 0.9
        shadowVerticalOffset: 10 * app.lift
      }
    }

    // Running pill under the tile, not scaled: 6 px for a running app, 14 px with focus,
    // and up to three 4 px segments for several windows.
    fixed: Row {
      visible: app.windowCount > 0
      spacing: 3
      x: Math.round((app.width - width) / 2)
      y: app.height + Math.round((window.pad - 2) / 2)
      Repeater {
        model: app.windowCount > 1 ? Math.min(3, app.windowCount) : (app.windowCount > 0 ? 1 : 0)
        delegate: Rectangle {
          required property int index
          readonly property bool single: app.windowCount === 1
          width: single ? (app.focused ? 14 : 6) : 4
          height: 2
          radius: 1
          color: tokens.accent
          opacity: single || app.focused ? 1 : 0.6
          Behavior on width { NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }
        }
      }
    }

    SequentialAnimation {
      id: hopper
      running: app.bounce
      loops: Animation.Infinite
      onRunningChanged: if (!running) app.hop = 0
      NumberAnimation { target: app; property: "hop"; from: 0; to: window.tile * 0.2; duration: 220; easing.type: Easing.OutCubic }
      NumberAnimation { target: app; property: "hop"; to: 0; duration: 280; easing.type: Easing.OutBounce }
    }

    SequentialAnimation {
      running: app.launching && !app.bounce && !Style.reduceMotion
      loops: Animation.Infinite
      onRunningChanged: if (!running) app.pulse = 1
      NumberAnimation { target: app; property: "pulse"; from: 1; to: 0.5; duration: Style.duration(500); easing.type: Easing.InOutSine }
      NumberAnimation { target: app; property: "pulse"; to: 1; duration: Style.duration(500); easing.type: Easing.InOutSine }
    }
  }

  // ---- The menu surface: the shell's own (BorderSurface and PopupMenuRow) ----
  BorderSurface {
    id: menu

    readonly property var item: window.menuKind === "app" && window.dock ? window.dock.itemFor(window.menuKey) : null
    readonly property var entry: item && window.dock ? window.dock.entryFor(item) : null
    readonly property bool running: !!item && item.windows.length > 0

    visible: window.shown && ((window.menuKind === "app" && !!item) || window.menuKind === "trash")
    width: Math.max(Style.space(260), menuColumn.implicitWidth) + padding * 2
    height: menuColumn.implicitHeight + padding * 2
    x: window.popupX(window.menuSlot, menu)
    y: window.popupY(window.menuSlot, menu)
    radius: Style.cornerRadius
    color: Commons.Color.popups.background
    borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Style.normalBorderWidth)
    padding: Style.spacing.sm

    Column {
      id: menuColumn
      x: menu.contentLeftInset
      y: menu.contentTopInset
      width: menu.width - menu.contentLeftInset - menu.contentRightInset

      // The app's name, in the widgets' header style: an accent tab, then small spaced capitals.
      Item {
        width: parent.width
        height: Style.spacing.popupRowHeight
        Rectangle {
          id: nameTab
          x: Style.spacing.controlPaddingX
          anchors.verticalCenter: parent.verticalCenter
          width: 3
          height: 10
          radius: 1
          color: Commons.Color.accent
        }
        Text {
          anchors.left: nameTab.right
          anchors.leftMargin: 8
          anchors.right: parent.right
          anchors.rightMargin: Style.spacing.controlPaddingX
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: (window.menuKind === "trash" ? "Trash" : (menu.item && window.dock ? window.dock.nameFor(menu.item) : "")).toUpperCase()
          color: tokens.dim
          font.family: "monospace"
          font.pixelSize: 10
          font.letterSpacing: 2
        }
      }

      // The app's open windows, by title and workspace; a click focuses one.
      Repeater {
        model: menu.running ? Math.min(8, menu.item.windows.length) : 0
        delegate: PopupMenuRow {
          required property int index
          readonly property var win: menu.item ? menu.item.windows[index] : null
          text: win ? window.clip(win.title || win.cls, 34) + "  \u00b7  " + (win.minimized ? "minimized" : "workspace " + win.workspaceId) : ""
          checked: !!win && !!win.toplevel && win.toplevel.activated === true
          onTriggered: { if (win) window.dock.bringForward(win); window.closeMenu("item click") }
        }
      }

      Rectangle {
        visible: menu.running
        width: parent.width
        height: 1
        color: tokens.separator
      }

      PopupMenuRow {
        visible: !!menu.entry
        text: Commons.I18n.t("dock.newWindow")
        onTriggered: { window.dock.launch(menu.item, true); window.closeMenu("item click") }
      }

      // The desktop entry's own actions, if it declares any.
      Repeater {
        model: menu.entry && menu.entry.actions ? menu.entry.actions : []
        delegate: PopupMenuRow {
          required property var modelData
          // The dock already offers New Window itself.
          visible: String(modelData.name).toLowerCase() !== "new window"
          text: modelData.name
          onTriggered: { modelData.execute(); window.closeMenu("item click") }
        }
      }

      PopupMenuRow {
        visible: !!menu.entry
        text: menu.item && menu.item.pinned ? Commons.I18n.t("dock.removeFromDock") : Commons.I18n.t("dock.keepInDock")
        onTriggered: { window.dock.setPinned(menu.item.key, !menu.item.pinned); window.closeMenu("item click") }
      }

      // A polite close: the app is asked to close, never killed.
      PopupMenuRow {
        visible: menu.running
        text: menu.item && menu.item.windows.length > 1 ? "Close All Windows" : "Close Window"
        onTriggered: { window.dock.quit(menu.item); window.closeMenu("item click") }
      }

      // Trash: emptying it asks first.
      PopupMenuRow {
        visible: window.menuKind === "trash" && !window.trashConfirm
        text: "Empty Trash\u2026"
        onTriggered: window.trashConfirm = true
      }
      PopupMenuRow {
        visible: window.menuKind === "trash" && window.trashConfirm
        text: "Empty Trash now (cannot be undone)"
        onTriggered: { window.dock.emptyTrash(); window.closeMenu("item click") }
      }
      PopupMenuRow {
        visible: window.menuKind === "trash" && window.trashConfirm
        text: "Cancel"
        onTriggered: window.closeMenu("cancel")
      }
    }
  }

  // ---- The pointer: one handler, above everything -----------------------------
  // It sees every move over the dock, the grown icons and the menu in window coordinates.
  // Nothing under it tracks hover (a MouseArea with hoverEnabled would swallow it).
  Item {
    anchors.fill: parent
    z: 1000
    HoverHandler {
      id: pointer
      cursorShape: window.hoverId !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
      onPointChanged: {
        if (!hovered) return
        window.pointerY = point.position.y
        if (window.menuOpen) return
        window.pointerX = point.position.x
        // the debug log gets a sample of the pointer now and then, not every event
        if (Date.now() - window.lastLoggedAt > 250 && Math.abs(point.position.x - window.lastLoggedX) > 8) {
          window.lastLoggedAt = Date.now()
          window.lastLoggedX = point.position.x
          window.logEvent("pointer x=" + Math.round(point.position.x) + " y=" + Math.round(point.position.y) + " hover=" + window.hover.toFixed(2) + " over=" + window.hoverId)
        }
      }
    }
  }
}
