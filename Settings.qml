import QtQuick
import Quickshell
import Quickshell.Io

// The dock's own settings, read live from the runtime folder. A missing or
// broken file never breaks the dock: every key falls back to its default and
// one warning is logged until a good file is read again.
Item {
  id: root

  readonly property string path: Quickshell.env("HOME") + "/.local/state/omarchy/koetsuji.dock/settings.json"

  property int iconSize: 56
  property real magnification: 1.4
  // squircle: macOS-style tiles; bare: logos straight on the card.
  property string iconStyle: "squircle"
  property real logoScale: 0.58
  property bool locked: false
  // One line per pointer, menu and launch event to events.log in the runtime folder.
  property bool debugEvents: false
  property bool dockBlur: true
  property real cardOpacity: 0.5
  property string launchFeedback: "bounce"
  property bool showAppsButton: true
  property bool showDownloads: true
  property bool showTrash: true
  property string monitors: "all"
  property var appIdOverrides: ({})
  // App id (or "downloads", "trash") to an icon name or file path, and to a
  // size factor from 0.85 to 1.15. Overrides win over everything.
  property var iconOverrides: ({})
  property var iconScaleOverrides: ({})
  // App id to { mode: plate | white | brand | graphite, colors: ["#top", "#bottom"] }.
  property var tileOverrides: ({})
  // Corner radius of a squircle tile, as a fraction of its side (18 to 24 percent).
  property real iconCornerRadius: 0.225
  property bool mediaEnabled: true
  property int mediaHideAfterPausedSeconds: 120
  property string mediaPlayers: "all"

  property bool warned: false

  function warn(message) {
    if (root.warned) return
    root.warned = true
    console.warn("koetsuji.dock settings: " + message + ", using defaults for what is wrong")
  }

  function num(value, fallback, min, max) {
    var n = Number(value)
    return isFinite(n) && value !== null && value !== "" ? Math.max(min, Math.min(max, n)) : fallback
  }

  function pick(value, allowed, fallback) {
    return allowed.indexOf(value) >= 0 ? value : fallback
  }

  function flag(value, fallback) {
    return typeof value === "boolean" ? value : fallback
  }

  function plain(value) {
    return value && typeof value === "object" && !Array.isArray(value) ? value : ({})
  }

  function textMap(value) {
    var source = plain(value)
    var out = ({})
    for (var key in source) if (typeof source[key] === "string" && source[key] !== "") out[key] = source[key]
    return out
  }

  function tileMap(value) {
    var source = plain(value)
    var out = ({})
    var hex = /^#[0-9a-fA-F]{6}$/
    for (var key in source) {
      var item = plain(source[key])
      if (["plate", "white", "brand", "graphite"].indexOf(item.mode) < 0) { root.warn("tileOverrides." + key + " has no valid mode"); continue }
      var entry = { mode: item.mode }
      if (Array.isArray(item.colors) && item.colors.length === 2 && hex.test(item.colors[0]) && hex.test(item.colors[1])) entry.colors = [item.colors[0], item.colors[1]]
      out[key] = entry
    }
    return out
  }

  function factorMap(value) {
    var source = plain(value)
    var out = ({})
    for (var key in source) {
      var n = Number(source[key])
      if (isFinite(n) && source[key] !== null && source[key] !== "") out[key] = Math.max(0.85, Math.min(1.15, n))
    }
    return out
  }

  function apply(raw) {
    var data = null
    try { data = JSON.parse(raw) } catch (e) { data = null }
    var ok = data !== null && typeof data === "object" && !Array.isArray(data)
    if (!ok) {
      data = ({})
      root.warn("settings.json is missing or not a JSON object")
    } else {
      root.warned = false
    }
    var media = data.media && typeof data.media === "object" ? data.media : ({})
    root.iconSize = Math.round(num(data.iconSize, 56, 36, 72))
    root.magnification = num(data.magnification, 1.4, 1.0, 2.0)
    root.iconStyle = pick(data.iconStyle, ["squircle", "bare"], "squircle")
    root.logoScale = num(data.logoScale, 0.58, 0.3, 0.72)
    root.locked = flag(data.locked, false)
    root.debugEvents = flag(data.debugEvents, false)
    root.dockBlur = flag(data.dockBlur, true)
    root.cardOpacity = num(data.cardOpacity, 0.5, 0.2, 1.0)
    root.launchFeedback = pick(data.launchFeedback, ["bounce", "pulse"], "bounce")
    root.showAppsButton = flag(data.showAppsButton, true)
    root.showDownloads = flag(data.showDownloads, true)
    root.showTrash = flag(data.showTrash, true)
    root.monitors = typeof data.monitors === "string" && data.monitors ? data.monitors : "all"
    root.appIdOverrides = data.appIdOverrides && typeof data.appIdOverrides === "object" && !Array.isArray(data.appIdOverrides) ? data.appIdOverrides : ({})
    root.iconOverrides = textMap(data.iconOverrides)
    root.iconScaleOverrides = factorMap(data.iconScaleOverrides)
    root.tileOverrides = tileMap(data.tileOverrides)
    var radius = Number(data.iconCornerRadius)
    if (!isFinite(radius) || data.iconCornerRadius === null || data.iconCornerRadius === "") radius = 0.225
    else if (radius > 1) radius = radius / 100
    root.iconCornerRadius = Math.max(0.18, Math.min(0.24, radius))
    root.mediaEnabled = flag(media.enabled, true)
    root.mediaHideAfterPausedSeconds = Math.round(num(media.hideAfterPausedSeconds, 120, 5, 86400))
    root.mediaPlayers = typeof media.players === "string" && media.players ? media.players : "all"
  }

  // Writes one key of the settings file (the value as JSON text, or a plain
  // string), atomically, and answers with the result. The watcher reads it back.
  property string lastRaw: "{}"
  function set(key, valueText) {
    var data
    try { data = JSON.parse(root.lastRaw) } catch (e) { data = ({}) }
    if (!data || typeof data !== "object" || Array.isArray(data)) data = ({})
    var value
    try { value = JSON.parse(valueText) } catch (e) { value = valueText }
    data[key] = value
    file.setText(JSON.stringify(data, null, 2) + "\n")
    return "ok"
  }

  FileView {
    id: file
    path: root.path
    watchChanges: true
    printErrors: false
    // A reload does not signal `loaded` again, only that the text changed.
    onFileChanged: reload()
    onSaved: reload()
    onLoaded: { root.lastRaw = text(); root.apply(text()) }
    onTextChanged: { root.lastRaw = text(); root.apply(text()) }
    onLoadFailed: function(error) { root.apply("") }
  }
}
