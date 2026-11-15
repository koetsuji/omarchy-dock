# Upstream

Cloned from `omarchy.dock` (Omarchy 4.0.0.r7620.gd9cc361-1, 2026-11-15) with `omarchy plugin clone omarchy.dock`.

## Changes so far (M1)

- `Dock.qml`: kept the data layer (identity, pins, launching, minimize and restore, app grid, IPC `refresh` and `apps`). Removed `position`, `vertical`, `autohide` and the floating-workspace mode reading (`modes`, `modeProc`, `isFloating`, `readMode`). `refresh()` now resyncs monitors, workspaces and toplevels. Items go to two list models, `pinnedModel` and `runningModel`, instead of one `itemModel`. `dockConfig` is read from `shell.json` with a watched `FileView`, because a clone's `shell` is the plugin API and has no `shellConfig`. Added `build` stamp and `settings`.
- `DockWindow.qml`: rewritten. Card in the desktop widgets' look, on every workspace, with an exclusive zone for its resting band.
- New: `Settings.qml`, `Look.qml`, `DockTile.qml`.
- `AppGrid.qml`, `DockModel.js`: unchanged.
- Dropped for now: the old context menus, drag to reorder, auto-hide, side positions (later milestones or out of scope).

To merge a later Omarchy update, diff `/usr/share/omarchy/shell/plugins/dock/{Dock.qml,DockModel.js,AppGrid.qml}` against this folder.

## Changes in M2

- `Dock.qml`: icon normalizer runner (`requestIcons`, `normalizerDone`, 30 s timeout), `normalizedFor`, Downloads and Trash (`FolderListModel` watcher, `openDownloads`, `openTrash`), default `iconSize` 56.
- `DockWindow.qml`: no Apps button, no tiles. Layout: pinned, separator, running, separator, Downloads, Trash. Card at `cardOpacity`, optional blur through `BackgroundEffect`. Edge gap 14.
- `DockTile.qml` is now a hit area with a spring on press, no surface. New `DockIcon.qml` (normalized PNG with a raw cross-fade) and `icons/normalize.py`.

## Changes in M2, second pass

- `icons/normalize.py` is a keyline system now (version 3): trimmed-box measure, five classes, keyline fit, brightness correction, cache pruning, `--card-luminance`.
- `Settings.qml`: `iconOverrides`, `iconScaleOverrides`. `Dock.qml`: overrides in `iconFor`, `scaleFor`, `cardLuminance` (renormalizes on a theme change), one log line per icon. `DockIcon.qml`: `factor`.

## Changes in M2c

- `icons/normalize.py` version 4: `squircle` style (tile modes plate, white, brand, graphite; finish: gradient, edge highlight, shadow) next to the M2b `bare` keyline fit. Tokens carry their options.
- `Settings.qml`: `iconStyle` default `squircle`, `tileOverrides`. `Dock.qml`: `iconToken`, `utilityToken`, `canvasScale`. `DockIcon.qml`: `canvas`. `DockWindow.qml`: passes tokens and the canvas factor.

## Changes in M2c, second pass

- `icons/normalize.py` version 5: figma-squircle geometry, canvas 1.30 x tile, gradients (brand +15 / -10 percent, white to #DCDCE2, graphite #4A4A4F to #1C1C1E), shadow and edge as fractions of the tile, sturdier flat-plate test, `tileBox` and `canvasFactor` in the meta.
- `Dock.qml`: `canvasScale` 1.30, IPC `geometry`. `DockWindow.qml`: `geometry()` and `describe()`. `DockIcon.qml`: `canvasWidth`.

## Changes in the last icon fixes and M3

- `icons/normalize.py` version 6: `slot` style, rim by edge luminance, `radius=` option, SVG `%ACCENT%` templates, `icons/terminal.svg`.
- `DockModel.js`: `ignoreReason` (unmatched windows belong), recency `stamp` in `pickWindow`.
- `Dock.qml`: `windowInfo`, unmatched log, `appIdOverrides`, launch guard and timeout log, activation stamps, `cycle`, `emptyTrash`, `stateObject` and the IPC hooks, tokens with radius, accent and slot, shell.json and settings watchers on `textChanged`.
- `DockTile.qml`: release semantics, 8 px threshold, wheel steps. `DockWindow.qml`: the app and trash menu, keyboard focus only for a menu, launch hop, geometry and menu state for tests. `Settings.qml`: `iconCornerRadius`, `set()`.

## Changes in the three visual fixes

- `icons/normalize.py` version 7: bevel (stroke, hairline, per-kind top alpha), white tile #F4F4F7 to #D8D8DE, `%ACCENT_TOP%` and `%ACCENT_BOTTOM%` placeholders, `slot` centred on the canvas centre with its alpha `box` in the meta. New `icons/agent.svg` and `icons/window.svg`.
- `Dock.qml`: `unknownKind`, `isUnmatched`, the icon of an unmatched window, the name "Agent". `DockWindow.qml`: the menu's name header, `centreY` and `slotCentreY` in the geometry dump.

## Changes in the hand-test fixes and M4

- New `AppLibrary.qml` and `AppSearch.js`: verbatim copies of `shell/services/AppLibrary.qml` and `AppSearch.js` (Omarchy 4.0.0.r7620), because a clone is not handed `shell.appLibrary` (only `menu` plugins are). Re-copy them after an Omarchy update.
- `Dock.qml`: local `AppLibrary`, `logEvent`, launch logging, hooks `newWindow`, `pointer`, `pointerLeave`. `Settings.qml`: `debugEvents`, magnification default 1.4.
- `DockTile.qml`: rewritten for magnification (scaler, hit area, overlay, event signal). `DockWindow.qml`: the layout engine, hover handling, label, menu opening and closing rules. `DockIcon.qml`: 256 px source.

## Hover fix

- `DockWindow.qml`: one top-level `HoverHandler`, `pointerY`, `pointerOverUi` by position. `DockTile.qml`: `hovered` is a plain property; no `hoverEnabled`.

## Changes in the hover shake fix and M5 (drag and drop)

- `DockWindow.qml`: `computeLayout` stretches the resting axis continuously (no steps in the row's speed); the drag engine (`beginDrag`, `dragTo`, `endDrag`, `updateDragTarget`, `slotLayout`, REMOVE label, settle); the tile positions animate only while dragging or settling.
- `DockTile.qml`: the drag gesture and its signals. `Dock.qml`: `frozen`, `applyLayout`, pins authoritative for the pinned order, hooks `dragStart`, `dragMove`, `dragEnd`, `dragCancel`.
