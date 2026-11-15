#!/bin/bash
# Dock test run: prints a PASS or FAIL table. It opens a few lightweight windows
# (foot terminals with test app ids), focuses, minimizes and closes them through
# Hyprland, and compares the dock's model (dumpState) with `hyprctl clients -j`
# after every step. It pins, unpins and reorders through the IPC hooks and checks
# the order survives omarchy-restart-shell. It checks the icon metrics and scans
# the shell log for warnings and errors from the plugin. It restores your pins,
# settings and focus when it ends. No input injection.
#
#   tests/run.sh            run everything
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="python3 -B -I $HERE/check.py"
IPC="omarchy-shell omarchy.dock"
TMP=$(mktemp -d)
SETTINGS="$HOME/.local/state/omarchy/koetsuji.dock/settings.json"
LOG="qs log -p ${OMARCHY_PATH:-/usr/share/omarchy}/shell"
rows=(); failed=0
record() { rows+=("$2|$1|$3"); [[ $2 == FAIL ]] && failed=$((failed + 1)); }
step() { local name="$1"; shift; local out; if out=$("$@" 2>&1); then record "$name" PASS "$out"; else record "$name" FAIL "$out"; fi; }

state() { $IPC dumpState >"$TMP/state.json" 2>/dev/null; }
snapshot() { state; hyprctl clients -j >"$TMP/clients.json"; hyprctl activewindow -j >"$TMP/active.json"; }
# the dock follows Hyprland's events, so give it a moment: retry for 3 s
settle() { local i out; for i in $(seq 1 12); do snapshot; if out=$("$@" 2>&1); then echo "$out"; return 0; fi; sleep 0.25; done; echo "$out"; return 1; }
compare() { settle $CHECK compare "$TMP/state.json" "$TMP/clients.json" "$TMP/active.json"; }
wait_clients() { local class="$1" want="$2" i; for i in $(seq 1 40); do [[ $(hyprctl clients -j | jq "[.[] | select(.class == \"$class\")] | length") -eq $want ]] && return 0; sleep 0.25; done; return 1; }
addrs() { hyprctl clients -j | jq -r ".[] | select(.class == \"$1\") | .address" | sort; }
open_win() { setsid -f foot --app-id "$1" sleep 300 >/dev/null 2>&1; }
# this Hyprland takes Lua dispatchers
focus() { hyprctl dispatch "hl.dsp.focus({ window = \"address:$1\" })" >/dev/null; }
close_win() { hyprctl dispatch "hl.dsp.window.close({ window = \"address:$1\" })" >/dev/null; }

ORIG_ACTIVE=$(hyprctl activewindow -j | jq -r '.address // empty')
state; ORIG_PINS=$($CHECK pins "$TMP/state.json")
ORIG_SIZE=$(jq -r '.iconSize // 56' "$SETTINGS")
ORIG_MAG=$(jq -r '.magnification // 1.4' "$SETTINGS")
ORIG_OPACITY=$(jq -r '.cardOpacity // 0.5' "$SETTINGS")
cleanup() {
  for c in koetsuji.dock.test.a koetsuji.dock.test.b; do for a in $(addrs $c); do close_win "$a"; done; done
  [[ -n "$(jq -r '.dock.pinned | join(" ")' ~/.config/omarchy/shell.json)" && "$(jq -r '.dock.pinned | join(" ")' ~/.config/omarchy/shell.json)" != "$ORIG_PINS" ]] && omarchy dock pinned $ORIG_PINS >/dev/null 2>&1
  $IPC closeMenu >/dev/null 2>&1
  $IPC pointerLeave >/dev/null 2>&1
  $IPC setSetting magnification "$ORIG_MAG" >/dev/null 2>&1
  $IPC setSetting cardOpacity "$ORIG_OPACITY" >/dev/null 2>&1
  $IPC setSetting iconSize "$ORIG_SIZE" >/dev/null 2>&1
  [[ -n "$ORIG_ACTIVE" ]] && focus "$ORIG_ACTIVE"
  rm -rf "$TMP"
}
trap cleanup EXIT

# ---- the plugin is up
step "shell answers, plugin loaded" bash -c "[[ \$(omarchy-shell shell ping) == ok ]] && $IPC dumpState | jq -e '.build' && $LOG --tail 2000 2>&1 | grep -q 'koetsuji.dock build'"
step "model matches Hyprland at the start" compare

# ---- windows come and go
open_win koetsuji.dock.test.a; wait_clients koetsuji.dock.test.a 1
step "a window no desktop entry claims gets its own item, named by its class" settle $CHECK item "$TMP/state.json" koetsuji.dock.test.a 1 1 0
step "it sits in the running section" settle $CHECK running_after_pinned "$TMP/state.json" koetsuji.dock.test.a
step "model matches Hyprland after opening" compare
geo_token() { local i out; for i in $(seq 1 30); do $IPC geometry >"$TMP/geo.json" 2>/dev/null; if out=$($CHECK token "$TMP/geo.json" "$1" "$2" 2>&1); then echo "$out"; return 0; fi; sleep 1; done; echo "$out"; return 1; }
step "an unknown window gets the designed window glyph" geo_token koetsuji.dock.test.a window.svg
state
if [[ $($CHECK has_item "$TMP/state.json" org.omarchy.agent) == 1 ]]; then
  step "an agent window gets the agent icon and the name Agent" bash -c "$CHECK item $TMP/state.json org.omarchy.agent && true"
  step "the agent icon is the designed one" geo_token org.omarchy.agent agent.svg
fi
open_win koetsuji.dock.test.a; wait_clients koetsuji.dock.test.a 2
step "two windows of one app share one icon" settle $CHECK item "$TMP/state.json" koetsuji.dock.test.a 2
open_win koetsuji.dock.test.b; wait_clients koetsuji.dock.test.b 1
step "model matches Hyprland with two apps" compare

mapfile -t A < <(addrs koetsuji.dock.test.a); mapfile -t B < <(addrs koetsuji.dock.test.b)
focus "${A[0]}"; step "focus on the first window follows" compare
focus "${B[0]}"; step "focus on the other app follows" compare
focus "${A[1]}"; sleep 0.4
# repeated clicks on an app cycle its windows, most recent first
$IPC activate koetsuji.dock.test.a >/dev/null; sleep 0.6; snapshot
step "a click on the app focuses its other window" bash -c "[[ \$($CHECK focused_window $TMP/state.json koetsuji.dock.test.a 0) == 0 ]]"
$IPC activate koetsuji.dock.test.a >/dev/null; sleep 0.6; snapshot
step "a second click goes back to the first" bash -c "[[ \$($CHECK focused_window $TMP/state.json koetsuji.dock.test.a 0) == 1 ]]"
focus "${B[0]}"; sleep 0.4; $IPC activate koetsuji.dock.test.b >/dev/null; sleep 0.5
step "a click on the focused single-window app changes nothing" compare

# minimize and restore through the dock
omarchy-hyprland-window-minimize "${B[0]}" >/dev/null 2>&1; sleep 0.6
step "a minimized window stays in the dock, flagged" settle $CHECK item "$TMP/state.json" koetsuji.dock.test.b 1 1 0 1
step "model matches Hyprland while minimized" compare
$IPC activate koetsuji.dock.test.b >/dev/null; sleep 1
step "a click restores it and focuses it" settle $CHECK item "$TMP/state.json" koetsuji.dock.test.b 1 1 0 0 1

# the context menu: opens, and goes with its app
menu_state() { sleep 0.5; $IPC geometry >"$TMP/geo.json" 2>/dev/null; $CHECK menu "$TMP/geo.json" "$@"; }
$IPC openMenu koetsuji.dock.test.a >/dev/null
step "the app menu opens" menu_state 1 app
step "no menu warning in the log while it is open" bash -c "! $LOG --tail 400 2>&1 | grep -E 'WARN|ERROR' | grep 'koetsuji.dock' | grep -v qmlscanner | grep ."
$IPC closeMenu >/dev/null
step "the menu closes on command" menu_state 0
$IPC openMenu trash >/dev/null
step "the trash menu opens" menu_state 1 trash
$IPC closeMenu >/dev/null
$IPC openMenu koetsuji.dock.test.a >/dev/null; sleep 0.5

# windows close
for a in "${A[@]}" "${B[@]}"; do close_win "$a"; done
step "a menu closes when its app disappears" menu_state 0
step "closed windows leave the dock" bash -c "sleep 1; $IPC dumpState >$TMP/state.json; $CHECK absent $TMP/state.json koetsuji.dock.test.a && $CHECK absent $TMP/state.json koetsuji.dock.test.b"
step "model matches Hyprland after closing" compare

# ---- launching: every pinned app opens from a click (the `activate` hook runs the click handler)
state; PINNED_NOW=$($CHECK pins "$TMP/state.json")
launch_app() {
  local key="$1" running before after new a i how
  state; running=$(jq -r --arg k "$key" '[.items[] | select(.key == $k) | .windows | length] | add // 0' "$TMP/state.json")
  before=$(hyprctl clients -j | jq -r '.[].address' | sort)
  if [[ $running -eq 0 ]]; then how="started"; $IPC activate "$key" >/dev/null; else how="new window"; $IPC newWindow "$key" >/dev/null; fi
  new=""
  for i in $(seq 1 32); do sleep 0.25; after=$(hyprctl clients -j | jq -r '.[].address' | sort); new=$(comm -13 <(echo "$before") <(echo "$after")); [[ -n "$new" ]] && break; done
  if [[ -z "$new" ]]; then echo "no window within 8 s ($how)"; return 1; fi
  sleep 1; state
  # the dock must show the new window under this app
  for a in $new; do if ! jq -e --arg k "$key" --arg a "${a#0x}" '.items[] | select(.key == $k) | .windows[] | select(.address == $a)' "$TMP/state.json" >/dev/null; then
    for b in $new; do close_win "$b"; done; echo "a window opened but not under $key"; return 1; fi; done
  for a in $new; do close_win "$a"; done
  sleep 1; echo "$how, window in $(( i * 250 )) ms"
}
for key in $PINNED_NOW; do step "launching $key from a click opens a window" launch_app "$key"; done

# ---- hover magnification (the pointer hook sets what a real hover event sets)
$IPC pointerLeave >/dev/null; sleep 0.6; $IPC geometry >"$TMP/rest.json"
CARD_L=$(jq '.[0].card.x | floor' "$TMP/rest.json"); CARD_R=$(jq '.[0].card | (.x + .w) | ceil' "$TMP/rest.json")
step "at rest nothing is magnified" bash -c "jq -e '[.[0].items[].scale] | all(. == 1)' $TMP/rest.json >/dev/null && echo 'all scales 1'"
$IPC pointer $((CARD_L + 40)) >/dev/null; sleep 0.5
: >"$TMP/sweep.ndjson"
for x in $(seq $((CARD_L - 10)) 8 $((CARD_R + 10))); do $IPC pointer $x >/dev/null; $IPC geometry >>"$TMP/sweep.ndjson"; done
step "a sweep across the dock: constant gaps, pointer fixed to its point, no jumps" $CHECK hover_sweep "$TMP/sweep.ndjson" 8
$IPC pointer $(jq '.[0].items[3] | (.restLeft + .restWidth / 2)' "$TMP/rest.json") >/dev/null; sleep 0.4; $IPC geometry >"$TMP/g.json"
step "magnification 1.4 (the default) peaks at 1.4" $CHECK hover_scale "$TMP/g.json" 1.4
$IPC setSetting magnification 1.8 >/dev/null; sleep 1; $IPC geometry >"$TMP/g.json"
step "magnification 1.8 applies at once" $CHECK hover_scale "$TMP/g.json" 1.8
$IPC setSetting magnification 1.2 >/dev/null; sleep 1; $IPC geometry >"$TMP/g.json"
step "magnification 1.2 applies at once" $CHECK hover_scale "$TMP/g.json" 1.2
$IPC setSetting magnification 1 >/dev/null; sleep 1; $IPC geometry >"$TMP/g.json"
step "magnification 1.0 turns scaling off" bash -c "jq -e '[.[0].items[].scale] | all(. == 1)' $TMP/g.json >/dev/null && echo 'all scales 1'"
$IPC setSetting magnification "$ORIG_MAG" >/dev/null; sleep 0.8
# the hover amount: up in about 120 ms, down after a 60 ms grace in about 180 ms
$IPC pointerLeave >/dev/null; sleep 0.6
sample() { local t0=$(date +%s%N) i; for i in $(seq 1 ${1:-8}); do echo "$(( ($(date +%s%N) - t0) / 1000000 )) $($IPC geometry | jq '.[0].hover.amount')"; done; }
$IPC pointer 900 >/dev/null; sample >"$TMP/up.txt"
step "the hover amount ramps up" $CHECK hover_amounts "$TMP/up.txt" up
sleep 0.5; $IPC pointerLeave >/dev/null; sample 16 >"$TMP/down.txt"
step "the hover amount eases back down" $CHECK hover_amounts "$TMP/down.txt" down
$IPC pointerLeave >/dev/null

# ---- Qt's hover delivery, offscreen: the structure the dock uses must see every pointer move
qt_hover() {
  local out; out=$(QT_QPA_PLATFORM=offscreen timeout 60 /usr/lib/qt6/bin/qmltestrunner -input "$HERE/tst_hover_structure.qml" 2>&1 | grep 'structure')
  echo "$out" | grep -q 'OLD structure.*hovered=false' || { echo "the old structure no longer shows the problem: $out"; return 1; }
  echo "$out" | grep -q 'NEW structure, pointer over a tile: hovered=true' || { echo "$out"; return 1; }
  echo "$out" | grep -q 'press on the tile still reaches its MouseArea: true' || { echo "$out"; return 1; }
  echo "a handler on top sees the pointer over tiles, and presses still reach them"
}
step "the pointer handler sees hover over the tiles (Qt, offscreen)" qt_hover

# ---- pins: pin, unpin, reorder, survive a restart
state; BEFORE=$($CHECK pins "$TMP/state.json")
$IPC pin imv >/dev/null; sleep 0.6; state
step "pinning an app adds it to the pins" bash -c "$CHECK pins $TMP/state.json | tr ' ' '\n' | grep -qx imv"
state; BEFORE=$($CHECK pins "$TMP/state.json")
$IPC movePinned 0 2 >/dev/null; sleep 0.6; state
step "moving a pinned app reorders the pins" $CHECK expect_move "$TMP/state.json" 0 2 "$BEFORE"
AFTER=$($CHECK pins "$TMP/state.json")
sleep 1.5
omarchy-restart-shell >/dev/null 2>&1
for i in $(seq 1 60); do $IPC dumpState >"$TMP/state.json" 2>/dev/null && jq -e '.items | length > 0' "$TMP/state.json" >/dev/null 2>&1 && break; sleep 1; done
step "the order survives omarchy-restart-shell" bash -c "[[ \"\$($CHECK pins $TMP/state.json)\" == \"$AFTER\" && \"\$(jq -r '.dock.pinned | join(\" \")' ~/.config/omarchy/shell.json)\" == \"$AFTER\" ]] && echo \"$AFTER\""
$IPC unpin imv >/dev/null; sleep 0.6; state
step "unpinning removes it from the pins" bash -c "! $CHECK pins $TMP/state.json | tr ' ' '\n' | grep -qx imv"
omarchy dock pinned $ORIG_PINS >/dev/null 2>&1; sleep 1.5; state
step "your original pins are back" bash -c "[[ \"\$($CHECK pins $TMP/state.json)\" == \"$ORIG_PINS\" ]]"

# ---- icon metrics
geo_ok() { local i; for i in $(seq 1 40); do $IPC geometry >"$TMP/geo.json" 2>/dev/null; if out=$($CHECK geometry "$TMP/geo.json" "$ORIG_SIZE" 2>&1); then echo "$out"; return 0; fi; sleep 1; done; echo "$out"; return 1; }
step "every icon normalized, tiles identical, Downloads and Trash fitted" geo_ok
$IPC setSetting iconSize 48 >/dev/null; sleep 2; $IPC geometry >"$TMP/geo.json"
step "setSetting resizes the dock live" bash -c "[[ \$($CHECK geometry_size $TMP/geo.json) == 48 ]] && jq -e '.cardOpacity != null and .iconOverrides != null' $SETTINGS >/dev/null"
$IPC setSetting iconSize "$ORIG_SIZE" >/dev/null; sleep 1.5

# ---- tile sizes measured on a real screenshot (the card is made opaque for a moment so every rim shows)
tiles_on_screen() {
  local op; op=$(jq -r '.cardOpacity // 0.5' "$SETTINGS")
  $IPC pointerLeave >/dev/null; $IPC setSetting cardOpacity 1 >/dev/null; sleep 1.5
  $IPC geometry >"$TMP/geo.json"
  python3 -B -I "$HERE/measure_tiles.py" "$TMP/geo.json" "$TMP/measure.png" >"$TMP/measure.txt" 2>&1; local rc=$?
  $IPC setSetting cardOpacity "$op" >/dev/null; sleep 0.8
  tail -1 "$TMP/measure.txt"; return $rc
}
step "every measurable tile is the same size on a real screenshot (agent tile included)" tiles_on_screen

# ---- drag and drop: the tile's real mouse gesture (Qt, offscreen) and the scenarios of section 10.4
qt_dragtile() {
  local out; out=$(cd "$HERE/qt" && QT_QPA_PLATFORM=offscreen timeout 60 /usr/lib/qt6/bin/qmltestrunner -import stubs -input tst_dragtile.qml 2>&1 | grep RESULT | sed 's/.*RESULT //' | sort)
  local want=$'4 px: \ndisabled: \ndrag: start,move,finish\nright click: start,move,cancel\nwobble: click'
  [[ "$out" == "$want" ]] && { echo "4 px: nothing; past 8 px: start, move, finish; right click cancels; a wobble is a click"; return 0; }
  echo "$out" | tr '\n' ';'; return 1
}
step "the tile's drag gesture: 8 px threshold, finish, right-click cancel, wobble is a click" qt_dragtile
while IFS='|' read -r status name detail; do
  [[ $status == PASS || $status == FAIL ]] && record "drag: $name" "$status" "$detail"
done < <(python3 -B -I "$HERE/drag_tests.py" 2>&1)

# ---- the log
step "no warnings or errors from the plugin in the shell log" bash -c "! $LOG --tail 4000 2>&1 | grep -E 'WARN|ERROR' | grep 'koetsuji.dock' | grep -v 'qmlscanner' | tail -3 | grep ."

# ---- the table
echo
printf '%-5s  %-66s  %s\n' RESULT CHECK DETAIL
for r in "${rows[@]}"; do IFS='|' read -r status name detail <<<"$r"; printf '%-5s  %-66s  %s\n' "$status" "$name" "${detail:0:70}"; done
echo
if (( failed )); then echo "$failed FAILED"; exit 1; else echo "all ${#rows[@]} checks passed"; fi
