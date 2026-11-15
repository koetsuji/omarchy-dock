import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Qt.labs.folderlistmodel
import qs.Commons
import qs.Commons as Commons
import "DockModel.js" as DockModel

// An app dock that shows on floating workspaces. A floating workspace has no
// tiles to hand the apps out, so the dock gives back a place to find them:
// pinned apps, running apps, and a grid of every app.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // A clone is handed the plugin API, whose appLibrary exists only for `menu` plugins, so
  // the dock keeps its own copy of the shell's AppLibrary (AppLibrary.qml, AppSearch.js):
  // the same launch command, launch OSD and app list that the built-in dock and the grid use.
  AppLibrary { id: library }
  readonly property var appLibrary: library
  // A clone gets the plugin API rather than the shell itself (no shellConfig),
  // so the dock: subtree is read from shell.json directly, watched live. Pins
  // are still written only through `omarchy dock`.
  property var dockConfig: ({})
  property var defaultDockConfig: ({})

  function parseDock(raw) {
    try {
      var data = JSON.parse(raw)
      return data && typeof data.dock === "object" && data.dock !== null && !Array.isArray(data.dock) ? data.dock : ({})
    } catch (e) {
      return ({})
    }
  }

  FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.dockConfig = root.parseDock(text())
    onTextChanged: root.dockConfig = root.parseDock(text())
    onLoadFailed: root.dockConfig = ({})
  }

  FileView {
    path: (Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy") + "/config/omarchy/shell.json"
    printErrors: false
    onLoaded: root.defaultDockConfig = root.parseDock(text())
  }

  // Bump on every edit and confirm it in the shell log before judging a fix.
  readonly property string build: "m5-6"
  property alias settings: settings
  Settings { id: settings }

  // The dock's order for the session, as desktop ids, set when the user moves
  // an app: a drag moves it, and keeping it in the dock puts it at the end. An
  // app the order does not know yet goes at the end. Pins are saved in this
  // order.
  property var order: []

  // A reorder shows at once rather than when the saved config comes back.
  property var pendingPins: null
  onDockConfigChanged: pendingPins = null

  // Entries that can claim a terminal app's window: those run in a terminal,
  // and those that hand the terminal an app id of their own.
  readonly property var terminalEntries: {
    var values = DesktopEntries.applications.values
    var out = []
    for (var i = 0; i < values.length; i++) {
      var entry = values[i]
      if (entry.runInTerminal || String(entry.execString || "").indexOf("--app-id=") >= 0)
        out.push({ id: entry.id, execString: entry.execString, command: entry.command, runInTerminal: entry.runInTerminal })
    }
    return out
  }

  function entryForAppId(appId) {
    // appIdOverrides in the settings wins over the built-in matching.
    var forced = root.settings.appIdOverrides[appId]
    if (forced) {
      var chosen = DesktopEntries.byId(String(forced))
      if (chosen) return chosen
    }
    var entry = DesktopEntries.heuristicLookup(appId)
    if (entry) return entry
    var id = DockModel.claimingEntryId(appId, root.terminalEntries)
    return id ? DesktopEntries.byId(id) : null
  }

  // A pinned app that is not installed has nothing to launch, so it is left
  // out until it is. Windows are matched to the desktop entry that claims them.
  // Every toplevel Hyprland knows, looked at once: the windows the dock may show,
  // and the ones it ignores with the reason (no app id, a child window, a
  // special workspace, a hidden helper entry). The model and the state dump both
  // read this, so they cannot disagree.
  readonly property var windowInfo: {
    var appsRevision = DesktopEntries.applications.values.length
    var candidates = []
    var ignored = []
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var toplevel = toplevels[i].wayland
      var address = root.plainAddress(toplevels[i].address)
      if (!toplevel) { ignored.push({ address: address, class: "", reason: "unmapped" }); continue }
      if (!toplevel.appId) { ignored.push({ address: address, class: "", reason: "noappid" }); continue }
      if (toplevel.parent) { ignored.push({ address: address, class: toplevel.appId, reason: "child" }); continue }
      var entry = root.entryForAppId(toplevel.appId)
      var workspace = toplevels[i].workspace
      candidates.push({
        key: entry ? entry.id : toplevel.appId,
        cls: toplevel.appId,
        title: String(toplevels[i].title || toplevel.title || ""),
        hasEntry: !!entry && !entry.noDisplay,
        unmatched: !entry,
        workspaceId: workspace ? workspace.id : -1,
        minimized: !!workspace && DockModel.isMinimizedWorkspace(workspace.name),
        address: toplevels[i].address,
        toplevel: toplevel
      })
    }
    var windows = []
    for (var j = 0; j < candidates.length; j++) {
      var reason = DockModel.ignoreReason(candidates[j])
      if (reason) ignored.push({ address: root.plainAddress(candidates[j].address), class: candidates[j].cls, reason: reason })
      else windows.push(candidates[j])
    }
    return { windows: windows, ignored: ignored }
  }

  function plainAddress(address) {
    var text = String(address || "").toLowerCase()
    return text.indexOf("0x") === 0 ? text.slice(2) : text
  }

  // A pinned app that is not installed has nothing to launch, so it is left
  // out until it is. Windows are matched to the desktop entry that claims them.
  readonly property var items: {
    var appsRevision = DesktopEntries.applications.values.length
    var pinned = (root.pendingPins || DockModel.pinnedIds(dockConfig, defaultDockConfig)).filter(function(id) {
      return !!DesktopEntries.byId(id)
    })
    // The pins are the authority for the pinned apps' order; the session order only orders the
    // running apps that are not pinned.
    var built = DockModel.buildItems(pinned, root.windowInfo.windows)
    var pinnedItems = built.filter(function(item) { return item.pinned })
    var runningItems = DockModel.orderItems(built.filter(function(item) { return !item.pinned }), root.order)
    return pinnedItems.concat(runningItems)
  }

  // A window that matches no desktop entry is logged once, by class, so the
  // user can map it with appIdOverrides.
  property var loggedUnmatched: ({})
  onWindowInfoChanged: {
    var windows = root.windowInfo.windows
    for (var i = 0; i < windows.length; i++) {
      var cls = windows[i].cls
      if (windows[i].unmatched && !root.loggedUnmatched[cls]) {
        root.loggedUnmatched[cls] = true
        var file = Quickshell.env("HOME") + "/.local/state/omarchy/koetsuji.dock/unmatched.log"
        Util.execDetached("grep -qxF " + Util.shellQuote(cls) + " " + Util.shellQuote(file) + " 2>/dev/null || echo " + Util.shellQuote(cls) + " >> " + Util.shellQuote(file))
      }
    }
  }

  readonly property var itemsByKey: {
    var byKey = {}
    for (var i = 0; i < root.items.length; i++) byKey[root.items[i].key] = root.items[i]
    return byKey
  }

  function itemFor(key) {
    return root.itemsByKey[key] || null
  }

  // The dock's slots follow these models rather than the items list itself,
  // so a slot survives a window opening or closing instead of being rebuilt
  // under the pointer, and a reorder moves slots rather than replacing them.
  // Both are views of the one items list: pinned apps, then running apps that
  // are not pinned.
  property alias pinnedModel: pinnedModel
  property alias runningModel: runningModel

  ListModel { id: pinnedModel }
  ListModel { id: runningModel }

  onItemsChanged: syncItemModel()

  function shownKeys() {
    return root.items.map(function(item) { return item.key })
  }

  function syncList(model, keys) {
    for (var i = 0; i < keys.length; i++) {
      if (i < model.count && model.get(i).key === keys[i]) continue
      var found = -1
      for (var j = i + 1; j < model.count; j++) {
        if (model.get(j).key === keys[i]) { found = j; break }
      }
      if (found >= 0) model.move(found, i, 1)
      else model.insert(i, { key: keys[i] })
    }
    if (model.count > keys.length) model.remove(keys.length, model.count - keys.length)
  }

  // While a drag is on, the rows do not change under the pointer: structural changes
  // (a window opening or closing, a reorder) wait and are applied after the drop.
  property bool frozen: false
  property bool syncPending: false
  onFrozenChanged: if (!frozen && syncPending) { syncPending = false; syncItemModel() }

  function syncItemModel() {
    if (root.frozen) { root.syncPending = true; return }
    var pinned = []
    var running = []
    for (var i = 0; i < root.items.length; i++) {
      var item = root.items[i]
      if (item.pinned) pinned.push(item.key)
      else running.push(item.key)
    }
    root.syncList(pinnedModel, pinned)
    root.syncList(runningModel, running)
    root.settleLaunches()
    iconDebounce.restart()
  }

  // An app launched from the dock pulses its dot until a new window of it
  // shows up, or for ten seconds if none does.
  property var launches: ({})
  readonly property int launchTimeout: 10000

  function isLaunching(key) {
    return root.launches[key] !== undefined
  }

  function settleLaunches() {
    var next = {}
    var changed = false
    var now = Date.now()
    for (var key in root.launches) {
      var launch = root.launches[key]
      var item = root.itemsByKey[key]
      var windows = item ? item.windows.length : 0
      if (windows > launch.windows) {
        changed = true
        root.logEvent("launch result " + key + " window appeared after " + (now - launch.at) + " ms")
      } else if (now - launch.at > root.launchTimeout) {
        changed = true
        root.logEvent("launch result " + key + " no window in " + root.launchTimeout + " ms")
        console.warn("koetsuji.dock launch of " + key + " showed no window in " + (root.launchTimeout / 1000) + " s, feedback stopped")
      } else next[key] = launch
    }
    if (changed) root.launches = next
  }

  Timer {
    interval: 1000
    repeat: true
    running: Object.keys(root.launches).length > 0
    onTriggered: root.settleLaunches()
  }

  function entryFor(item) {
    return item ? DesktopEntries.byId(item.key) : null
  }

  // ---- Windows no desktop entry claims ----------------------------------------
  // An agent window (org.omarchy.agent, the fixed app id of every agent terminal
  // Omarchy launches) gets the agent icon and the name "Agent"; another terminal gets
  // the terminal icon; anything else a designed fallback. All three are SVGs in the
  // plugin folder, so they are tile-shaped plates with the same finish as the rest.
  readonly property string iconDir: String(Qt.resolvedUrl("icons")).replace(/^file:\/\//, "")
  readonly property var terminalPattern: /(^|[.\-_])(alacritty|kitty|foot|footclient|ghostty|wezterm|xterm|urxvt|konsole|tilix|terminal|gnome-terminal|st)([.\-_]|$)/i

  function isUnmatched(item) {
    return !!item && item.windows.length > 0 && item.windows[0].unmatched === true
  }

  function unknownKind(item) {
    var cls = String(item ? item.key : "")
    if (/^org\.omarchy\.agent/i.test(cls)) return "agent"
    if (root.terminalPattern.test(cls)) return "terminal"
    return "window"
  }

  function iconFor(item) {
    var override = item ? root.settings.iconOverrides[item.key] : ""
    // An override is an icon name, or a file path.
    if (override) {
      if (override.charAt(0) === "/") return "file://" + override
      return root.appLibrary ? root.appLibrary.iconSource(override) : Quickshell.iconPath(override, true)
    }
    if (root.isUnmatched(item)) {
      var files = { agent: "agent.svg", terminal: "terminal.svg", window: "window.svg" }
      return "file://" + root.iconDir + "/" + files[root.unknownKind(item)]
    }
    var entry = entryFor(item)
    var icon = entry && entry.icon ? entry.icon : (item ? item.key : "")
    var source = root.appLibrary ? root.appLibrary.iconSource(icon) : Quickshell.iconPath(icon, true)
    // A window no entry claims, in a theme without the generic icon: let the
    // normalizer find it in its own theme chain.
    return source ? source : "image://icon/application-x-executable"
  }

  // Launches an app (or, with newWindow, another window of it). Left clicks on an
  // app that is starting are ignored for its first second, so nothing launches twice.
  // The debug event log (setting debugEvents): one line per event, with the time.
  function logEvent(what) {
    if (!root.settings.debugEvents) return
    var d = new Date()
    var pad = function(n, width) { var t = String(n); while (t.length < width) t = "0" + t; return t }
    var stamp = pad(d.getHours(), 2) + ":" + pad(d.getMinutes(), 2) + ":" + pad(d.getSeconds(), 2) + "." + pad(d.getMilliseconds(), 3)
    var file = Quickshell.env("HOME") + "/.local/state/omarchy/koetsuji.dock/events.log"
    Util.execDetached("printf '%s %s\\n' " + Util.shellQuote(stamp) + " " + Util.shellQuote(String(what)) + " >> " + Util.shellQuote(file))
  }

  function launch(item, newWindow) {
    var entry = entryFor(item)
    if (!entry) { root.logEvent("launch " + (item ? item.key : "?") + " ignored: no desktop entry"); return }
    var existing = root.launches[item.key]
    if (!newWindow && existing && Date.now() - existing.at < 1000) { root.logEvent("launch " + item.key + " ignored: already starting"); return }
    root.logEvent("launch start " + item.key + (newWindow ? " (new window)" : "") + " id=" + entry.id)
    var next = Object.assign({}, root.launches)
    next[item.key] = { at: Date.now(), windows: item.windows.length }
    root.launches = next
    root.launchEntry(entry)
  }

  function launchEntry(entry) {
    if (entry && root.appLibrary) root.appLibrary.launch(entry.id, entry.name)
  }

  // When each window last took focus (a counter, kept from Hyprland's events),
  // so repeated clicks cycle an app's windows most recent first.
  property var activation: ({})
  property int activationCounter: 0

  function stampFor(address) {
    return root.activation[root.plainAddress(address)] || 0
  }

  function noteActivation(address) {
    var plain = root.plainAddress(address)
    if (plain) root.activation[plain] = ++root.activationCounter
  }

  function activate(item) {
    if (!item) return
    if (item.windows.length === 0) {
      root.launch(item, false)
      return
    }
    var monitor = Hyprland.focusedMonitor
    var workspaceId = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
    var list = item.windows.map(function(window) {
      return { workspaceId: window.workspaceId, minimized: window.minimized, activated: window.toplevel.activated, stamp: root.stampFor(window.address) }
    })
    // The focused app with a single window: nothing to do beyond the press feedback.
    if (list.length === 1 && list[0].activated && !list[0].minimized) return
    root.bringForward(item.windows[DockModel.pickWindow(list, workspaceId)])
  }

  // Scrolling over an app steps through its windows.
  function cycle(item, direction) {
    if (!item || item.windows.length === 0) return
    var n = item.windows.length
    var current = -1
    for (var i = 0; i < n; i++) if (item.windows[i].toplevel.activated) current = i
    if (n === 1) {
      if (current < 0) root.bringForward(item.windows[0])
      return
    }
    root.bringForward(item.windows[current < 0 ? 0 : (current + direction + n) % n])
  }

  function nameFor(item) {
    if (root.isUnmatched(item) && root.unknownKind(item) === "agent") return "Agent"
    var entry = entryFor(item)
    return entry && entry.name ? entry.name : (item ? item.key : "")
  }

  function emptyTrash() {
    Util.execDetached("gio trash --empty")
  }

  // A window the dock brings forward lands on top of the others, focused; a
  // minimized one first comes back to the workspace in front of the user.
  function bringForward(window) {
    var address = String(window.address || "")
    if (!address) {
      window.toplevel.activate()
      return
    }
    if (address.indexOf("0x") !== 0) address = "0x" + address
    var target = "window = \"address:" + address + "\""
    var steps = []
    var after = []
    if (window.minimized) {
      var monitor = Hyprland.focusedMonitor
      var workspace = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
      if (!(workspace >= 1)) return
      // A restored window is simply there again, without animating in.
      steps.push("hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"1\", " + target + " })")
      steps.push("hl.dsp.window.move({ workspace = \"" + workspace + "\", " + target + " })")
      after.push("hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"unset\", " + target + " })")
    }
    steps.push("hl.dsp.focus({ " + target + " })")
    steps.push("hl.dsp.window.alter_zorder({ mode = \"top\", " + target + " })")
    var dispatch = function(step) { return "hyprctl dispatch " + Util.shellQuote(step) }
    var command = steps.map(dispatch).join(" && ")
    if (after.length > 0) command += "; sleep 0.4; " + after.map(dispatch).join("; ")
    Util.execDetached(command)
  }

  function quit(item) {
    if (!item) return
    var windows = item.windows.slice()
    for (var i = 0; i < windows.length; i++) windows[i].toplevel.close()
  }

  // ---- Icons ---------------------------------------------------------------
  // Every icon goes once through icons/normalize.py, which caches a 256 px PNG
  // on an identical canvas, sized by optical weight. Nothing is normalized in
  // the render path: until a PNG is ready the raw icon shows, then cross-fades.
  readonly property string iconCacheDir: Quickshell.env("HOME") + "/.local/state/omarchy/koetsuji.dock/icons"
  readonly property string normalizerPath: String(Qt.resolvedUrl("icons/normalize.py")).replace(/^file:\/\//, "")
  property var iconCache: ({})
  property var iconFailed: ({})
  property var iconBatch: []
  property bool prewarming: false

  // What the normalizer is asked for: a file path, or icon:NAME for the
  // shell's themed icons (image://icon/NAME), which the script looks up itself.
  function sourcePath(url) {
    var text = String(url || "")
    if (text.indexOf("file://") === 0) return decodeURIComponent(text.slice(7))
    if (text.indexOf("image://icon/") === 0) return "icon:" + decodeURIComponent(text.slice(13))
    return text.charAt(0) === "/" ? text : ""
  }

  // What the normalizer is asked for, and what the cache is keyed by:
  // "opts|source". Apps follow the icon style and their tileOverrides; the
  // Downloads and Trash items stay bare, like on macOS.
  function iconToken(item) {
    var path = root.sourcePath(root.iconFor(item))
    if (!path) return ""
    var opts = ["style=" + root.settings.iconStyle]
    var tile = item ? root.settings.tileOverrides[item.key] : null
    if (root.settings.iconStyle === "squircle") {
      opts.push("radius=" + root.settings.iconCornerRadius, "accent=" + root.accentHex)
      if (tile) {
        opts.push("mode=" + tile.mode)
        if (tile.colors) opts.push("top=" + tile.colors[0], "bottom=" + tile.colors[1])
      }
    }
    return opts.join(",") + "|" + path
  }

  // Downloads and Trash: no tile, fitted inside a tile's box (slot), or bare
  // keylines when the whole dock is bare.
  function utilityToken(url) {
    var path = root.sourcePath(url)
    if (!path) return ""
    return root.settings.iconStyle === "squircle" ? "style=slot|" + path : "style=bare|" + path
  }

  readonly property string accentHex: String(Commons.Color.accent)
  onAccentHexChanged: iconDebounce.restart()

  function normalizedFor(token) {
    var entry = root.iconCache[token]
    return entry ? "file://" + entry.png : ""
  }

  // The cached PNG's canvas, against the slot an item takes in the layout. A
  // squircle tile is 1 / 1.30 of its canvas (CANVAS_FACTOR in normalize.py) and
  // the slot is the tile, so the canvas and its shadow margin reach past the slot.
  readonly property real canvasScale: root.settings.iconStyle === "squircle" ? 1.30 : 1

  function firstIcon(names) {
    for (var i = 0; i < names.length; i++) {
      var path = Quickshell.iconPath(names[i], true)
      if (path.length > 0) return path
    }
    return Quickshell.iconPath("folder", true)
  }

  // Utility items go through the same pipeline as the apps.
  readonly property string downloadsIcon: root.firstIcon(["folder-download", "folder-downloads", "user-home", "folder"])
  readonly property string trashEmptyIcon: root.firstIcon(["user-trash", "edit-delete"])
  readonly property string trashFullIcon: root.firstIcon(["user-trash-full", "user-trash"])

  function wantedIcons() {
    var tokens = [root.utilityToken(root.downloadsIcon), root.utilityToken(root.trashEmptyIcon), root.utilityToken(root.trashFullIcon)]
    for (var i = 0; i < root.items.length; i++) tokens.push(root.iconToken(root.items[i]))
    var wanted = []
    for (var j = 0; j < tokens.length; j++) {
      var token = tokens[j]
      if (token && !root.iconCache[token] && !root.iconFailed[token] && wanted.indexOf(token) < 0) wanted.push(token)
    }
    root.prewarming = false
    if (wanted.length > 0) return wanted
    // Nothing on screen waits: make the tile of every installed app, a few at a time, in the
    // background, so an app that opens later finds its tile ready and appears at once.
    var entries = DesktopEntries.applications.values
    for (var k = 0; k < entries.length && wanted.length < 12; k++) {
      if (entries[k].noDisplay) continue
      var warm = root.iconToken({ key: entries[k].id, windows: [] })
      if (warm && !root.iconCache[warm] && !root.iconFailed[warm] && wanted.indexOf(warm) < 0) wanted.push(warm)
    }
    root.prewarming = wanted.length > 0
    return wanted
  }

  function requestIcons() {
    if (normalizer.running) return
    var wanted = root.wantedIcons()
    if (wanted.length === 0) return
    root.iconBatch = wanted
    // Background work runs at the lowest priority.
    normalizer.command = (root.prewarming ? ["nice", "-n", "19"] : []).concat(["python3", "-B", "-I", root.normalizerPath, "--cache", root.iconCacheDir,
      "--card-luminance", String(root.cardLuminance)]).concat(wanted)
    normalizer.running = true
    normalizerTimeout.restart()
  }

  function normalizerDone(raw) {
    var results = []
    try { results = JSON.parse(raw) } catch (e) { results = [] }
    var cache = Object.assign({}, root.iconCache)
    var failed = Object.assign({}, root.iconFailed)
    var seen = {}
    for (var i = 0; i < results.length; i++) {
      var result = results[i]
      seen[result.src] = true
      if (result.png) {
        cache[result.src] = { png: result.png, meta: result.meta }
        var m = result.meta
        console.log("koetsuji.dock icon " + result.src + " class=" + m.class + (m.style === "squircle" ? " mode=" + m.mode + " (picked " + m.picked + ") contrast=" + m.contrast + " rim=" + m.rim.kind : (m.style === "slot" ? " slot extent=" + m.extent.join("x") : " keyline=" + m.keyline + " brightness=" + m.brightnessCorrection)))
      }
      else { failed[result.src] = true; console.warn("koetsuji.dock icon not normalized: " + result.src + " " + result.error) }
    }
    // A source the script never answered for would be asked for forever.
    for (var j = 0; j < root.iconBatch.length; j++) {
      if (!seen[root.iconBatch[j]]) failed[root.iconBatch[j]] = true
    }
    root.iconCache = cache
    root.iconFailed = failed
    root.iconBatch = []
  }

  Process {
    id: normalizer
    stdout: StdioCollector { onStreamFinished: root.normalizerDone(text) }
    // Deferred: the process still reports running while it signals exit.
    onExited: { normalizerTimeout.stop(); Qt.callLater(root.requestIcons) }
  }

  // A hung normalizer must never hold the dock: stop it, show raw icons.
  Timer {
    id: normalizerTimeout
    interval: 30000
    onTriggered: {
      var failed = Object.assign({}, root.iconFailed)
      root.iconBatch.forEach(function(path) { failed[path] = true })
      root.iconFailed = failed
      console.warn("koetsuji.dock icon normalizer timed out")
      normalizer.running = false
    }
  }

  // Installed apps appear (or the list changes): warm their tiles too.
  Connections { target: DesktopEntries.applications; function onValuesChanged() { iconDebounce.restart() } }
  Timer { id: iconDebounce; interval: 30; onTriggered: root.requestIcons() }
  Connections { target: root.appLibrary; function onIconIndexChanged() { iconDebounce.restart() } }
  // The card's luminance, in steps of 0.02, decides how much brighter icons
  // are scaled down. A theme switch that moves it renormalizes.
  readonly property real cardLuminance: Math.round((0.299 * Commons.Color.background.r + 0.587 * Commons.Color.background.g + 0.114 * Commons.Color.background.b) / 0.02) * 0.02
  onCardLuminanceChanged: { root.iconCache = ({}); root.iconFailed = ({}); iconDebounce.restart() }
  // Tokens carry the style and the tile overrides, so a change just asks again.
  Connections {
    target: root.settings
    function onIconOverridesChanged() { iconDebounce.restart() }
    function onTileOverridesChanged() { iconDebounce.restart() }
    function onIconStyleChanged() { iconDebounce.restart() }
  }

  // A size factor from the settings, 0.85 to 1.15, for the one icon that still
  // looks off. Keys are app ids, or "downloads" and "trash".
  function scaleFor(key) {
    var factor = root.settings.iconScaleOverrides[key]
    return typeof factor === "number" ? factor : 1
  }

  // ---- Downloads and Trash ---------------------------------------------------
  // The trash looks full while its files folder holds anything. A watcher on
  // the folder, no polling.
  FolderListModel {
    id: trashFolder
    folder: "file://" + Quickshell.env("HOME") + "/.local/share/Trash/files"
    showHidden: true
    showDirs: true
    showDotAndDotDot: false
  }
  readonly property bool trashFull: trashFolder.count > 0

  function openDownloads() {
    Util.execDetached("xdg-open \"$(xdg-user-dir DOWNLOAD)\"")
  }

  function openTrash() {
    Util.execDetached("gio open trash:///")
  }

  function openApps() {
    appGrid.open()
  }

  readonly property var pinnedKeys: root.pendingPins || DockModel.pinnedIds(root.dockConfig, root.defaultDockConfig)

  function isPinned(key) {
    return root.pinnedKeys.indexOf(key) >= 0
  }

  // Moves an app to a slot in the dock's order, pinning it there; the pins are
  // saved in the new order. The index counts the slots once the app has left
  // its own.
  function placeAt(key, index) {
    if (!key) return
    root.order = DockModel.orderWithKeyAt(root.shownKeys(), key, index)
    var pinned = {}
    root.pinnedKeys.forEach(function(other) { pinned[other] = true })
    pinned[key] = true
    root.savePins(DockModel.pinsInOrder(root.order, pinned, root.pinnedKeys))
  }

  // A reorder shows at once; the saved config catches up after.
  // The dock's new order, as dragged: the pinned apps and the running unpinned apps, each in
  // order. An app that moved out of the first list is unpinned, one that moved into it pinned.
  // Pins the dock is not showing (their app is not installed) stay as they were.
  function applyLayout(pinnedKeys, runningKeys) {
    root.order = pinnedKeys.concat(runningKeys)
    var current = root.pinnedKeys
    var next = pinnedKeys.slice()
    for (var i = 0; i < current.length; i++) {
      if (next.indexOf(current[i]) < 0 && root.order.indexOf(current[i]) < 0) next.push(current[i])
    }
    if (next.join("|") === current.join("|")) return
    if (next.length === 0) {
      root.pendingPins = []
      for (var j = 0; j < current.length; j++) Util.execDetached("omarchy-dock unpin " + Util.shellQuote(current[j]))
      return
    }
    root.savePins(next)
  }

  function savePins(pins) {
    root.pendingPins = pins
    Util.execDetached("omarchy-dock pinned " + pins.map(function(id) { return Util.shellQuote(id) }).join(" "))
  }

  function moveItem(fromIndex, toIndex) {
    if (fromIndex !== toIndex) root.placeAt(root.shownKeys()[fromIndex], toIndex)
  }

  // An app dropped before the slot at index, counted as the slots stand.
  function pinAt(key, index) {
    var from = root.shownKeys().indexOf(key)
    root.placeAt(key, from >= 0 && from < index ? index - 1 : index)
  }

  // Keeping an app in the dock puts it at the end; taking one out leaves it in
  // its slot while it still runs.
  function setPinned(key, pinned) {
    if (!key) return
    if (pinned) {
      root.placeAt(key, root.shownKeys().length)
    } else {
      root.pendingPins = root.pinnedKeys.filter(function(other) { return other !== key })
      Util.execDetached("omarchy-dock unpin " + Util.shellQuote(key))
    }
  }

  // Called by the layout commands and after a config reload: one full resync
  // of what Hyprland knows.
  function refresh() {
    Hyprland.refreshMonitors()
    Hyprland.refreshWorkspaces()
    Hyprland.refreshToplevels()
    syncItemModel()
  }

  Component.onCompleted: {
    console.log("koetsuji.dock build " + root.build)
    refresh()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event ? String(event.name) : ""
      if (name === "activewindowv2") root.noteActivation(event.data)
      else if (name === "monitoradded" || name === "monitorremoved" || name === "monitoraddedv2" || name === "monitorremovedv2") root.refresh()
      if (name === "configreloaded") root.refresh()
      // Hyprland's window and workspace lists do not follow fullscreen on
      // their own.
      else if (name === "fullscreen") {
        Hyprland.refreshWorkspaces()
        Hyprland.refreshToplevels()
      }
    }
  }

  ShellIpc {
    target: "omarchy.dock"

    // The layout commands call this after changing a workspace's mode.
    function refresh(): void { root.refresh() }
    function apps(): void { appGrid.toggle() }

    // The model as JSON: pins, items with their windows and focus, and the
    // windows ignored with the reason. Tests compare it with `hyprctl clients`.
    function dumpState(): string { return JSON.stringify(root.stateObject()) }
    function pin(key: string): string { root.setPinned(key, true); return "ok" }
    function unpin(key: string): string { root.setPinned(key, false); return "ok" }
    function movePinned(from: string, to: string): string {
      root.moveItem(parseInt(from), parseInt(to))
      return "ok"
    }
    function setSetting(key: string, value: string): string { return root.settings.set(key, value) }
    // Open an app's menu, or the trash's, as a right click would; close any menu.
    function openMenu(key: string): string {
      for (var i = 0; i < docks.instances.length; i++) if (docks.instances[i].openMenuFor(key)) return "ok"
      return "unknown"
    }
    function closeMenu(): string {
      for (var i = 0; i < docks.instances.length; i++) docks.instances[i].closeMenu()
      return "ok"
    }
    // Drag and drop, for tests: the same window functions the pointer gesture calls.
    function dragStart(key: string, x: string, y: string): string {
      for (var i = 0; i < docks.instances.length; i++) { var r = docks.instances[i].dragStartKey(key, parseFloat(x), parseFloat(y)); if (r !== "unknown") return r }
      return "unknown"
    }
    function dragMove(x: string, y: string): string {
      for (var i = 0; i < docks.instances.length; i++) docks.instances[i].dragTo(parseFloat(x), parseFloat(y))
      return "ok"
    }
    function dragEnd(x: string, y: string): string {
      for (var i = 0; i < docks.instances.length; i++) docks.instances[i].endDrag(parseFloat(x), parseFloat(y), false)
      return "ok"
    }
    function dragCancel(): string {
      for (var i = 0; i < docks.instances.length; i++) docks.instances[i].endDrag(0, 0, true)
      return "ok"
    }
    // What a left click on an app does, and one step of scrolling over it.
    function activate(key: string): string {
      var item = root.itemFor(key)
      if (!item) return "unknown"
      root.activate(item)
      return "ok"
    }
    // A stand-in for the pointer, for tests: the dock lays out as if the pointer were at x
    // (window coordinates), hovering, until pointerLeave.
    function pointer(x: string): string {
      for (var i = 0; i < docks.instances.length; i++) docks.instances[i].fakePointer(parseFloat(x))
      return "ok"
    }
    function pointerLeave(): string {
      for (var i = 0; i < docks.instances.length; i++) docks.instances[i].fakeLeave()
      return "ok"
    }
    // A middle click or Shift + click: another window of the app.
    function newWindow(key: string): string {
      var item = root.itemFor(key)
      if (!item) return "unknown"
      root.launch(item, true)
      return "ok"
    }
    function cycle(key: string, direction: string): string {
      var item = root.itemFor(key)
      if (!item) return "unknown"
      root.cycle(item, parseInt(direction))
      return "ok"
    }

    // Every item's slot, canvas and drawn tile size on every monitor, as JSON.
    function geometry(): string {
      var out = []
      for (var i = 0; i < docks.instances.length; i++) {
        var window = docks.instances[i]
        if (window && window.geometry) out.push(window.geometry())
      }
      return JSON.stringify(out)
    }
  }

  function stateObject() {
    var items = root.items.map(function(item) {
      return {
        key: item.key, name: root.nameFor(item), pinned: item.pinned, unmatched: item.windows.length > 0 && item.windows[0].unmatched === true,
        launching: root.isLaunching(item.key),
        windows: item.windows.map(function(window) {
          return { address: root.plainAddress(window.address), class: window.cls, title: window.title, workspace: window.workspaceId,
            minimized: window.minimized, focused: window.toplevel.activated === true }
        })
      }
    })
    return { build: root.build, pinned: root.pinnedKeys, order: root.shownKeys(), items: items, ignored: root.windowInfo.ignored }
  }

  // An app dragged out of the app grid: the grid holds the pointer and
  // reports where it is, and the dock on that screen shows where it would land.
  function dockOn(screen) {
    var windows = docks.instances
    for (var i = 0; i < windows.length; i++) {
      if (windows[i].screen === screen) return windows[i]
    }
    return null
  }

  function moveExternalDrag(screen, x, y) {
    var windows = docks.instances
    for (var i = 0; i < windows.length; i++) {
      if (windows[i].screen === screen) windows[i].moveExternalDrag(x, y)
      else windows[i].endExternalDrag()
    }
  }

  function dropExternalDrag(screen, x, y, key) {
    var target = root.dockOn(screen)
    if (target) target.dropExternalDrag(x, y, key)
    root.endExternalDrag()
  }

  function endExternalDrag() {
    var windows = docks.instances
    for (var i = 0; i < windows.length; i++) windows[i].endExternalDrag()
  }

  Variants {
    id: docks
    model: Quickshell.screens

    delegate: Component {
      DockWindow {
        required property var modelData

        screen: modelData
        dock: root
      }
    }
  }

  AppGrid {
    id: appGrid
    appLibrary: root.appLibrary
    dock: root
  }
}
