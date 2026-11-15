#!/usr/bin/env python3
"""Checks for tests/run.sh. Each subcommand prints a short result and exits 0
(pass) or 1 (fail). Run with python3 -B -I."""
import json, sys

def load(p):
    with open(p) as f:
        return json.load(f)

def compare(state_p, clients_p, active_p):
    """The dock's model against `hyprctl clients -j`, window by window."""
    state, clients, active = load(state_p), load(clients_p), load(active_p)
    by_addr = {c["address"][2:] if c["address"].startswith("0x") else c["address"]: c for c in clients}
    shown = {}
    for item in state["items"]:
        for w in item["windows"]:
            shown[w["address"]] = (item, w)
    ignored = {i["address"]: i for i in state["ignored"]}
    active_addr = (active.get("address") or "0x")[2:] if isinstance(active, dict) else ""
    problems = []
    for a, c in by_addr.items():
        if not c.get("mapped", True) or not c.get("workspace"):
            continue
        if a in shown:
            item, w = shown[a]
            if w["class"] != c["class"]: problems.append("class of %s: dock %r, hyprland %r" % (a, w["class"], c["class"]))
            parked = c["workspace"].get("name") == "special:minimized"  # special workspaces have no numeric id
            if not parked and w["workspace"] != c["workspace"].get("id"): problems.append("workspace of %s: dock %s, hyprland %s" % (a, w["workspace"], c["workspace"].get("id")))
            if w["minimized"] != parked: problems.append("minimized flag of %s" % a)
            if w["focused"] != (a == active_addr): problems.append("focus of %s (%s): dock %s, active is %s" % (a, c["class"], w["focused"], active_addr))
        elif a in ignored:
            if ignored[a]["reason"] not in ("noappid", "nodisplay", "special", "child"):
                problems.append("%s ignored for %s" % (a, ignored[a]["reason"]))
        elif c["class"]:
            problems.append("window %s (%s) is neither shown nor ignored" % (a, c["class"]))
    for a in shown:
        if a not in by_addr: problems.append("dock shows %s, which hyprland does not have" % a)
    # one icon per app, a pill only with a window
    keys = [i["key"] for i in state["items"]]
    if len(keys) != len(set(keys)): problems.append("two icons for one app: %s" % sorted(k for k in keys if keys.count(k) > 1))
    for item in state["items"]:
        if not item["pinned"] and not item["windows"]: problems.append("%s runs without a window" % item["key"])
    if sum(1 for _, w in shown.values() if w["focused"]) > 1: problems.append("more than one focused window")
    if problems:
        print("; ".join(problems[:4])); return 1
    print("%d windows shown, %d ignored" % (len(shown), len(ignored))); return 0

def item(state_p, key, windows=None, unmatched=None, pinned=None, minimized=None, focused=None):
    state = load(state_p)
    found = [i for i in state["items"] if i["key"] == key]
    if len(found) != 1:
        print("%d items for %s" % (len(found), key)); return 1
    i = found[0]
    if windows is not None and len(i["windows"]) != int(windows): print("%s has %d windows, expected %s" % (key, len(i["windows"]), windows)); return 1
    if unmatched is not None and i["unmatched"] != (unmatched == "1"): print("%s unmatched=%s" % (key, i["unmatched"])); return 1
    if pinned is not None and i["pinned"] != (pinned == "1"): print("%s pinned=%s" % (key, i["pinned"])); return 1
    expected = "Agent" if key.lower().startswith("org.omarchy.agent") else key  # an agent window is named Agent
    if i["unmatched"] and i["name"] != expected: print("name %r, expected %r" % (i["name"], expected)); return 1
    if minimized is not None and any(w["minimized"] != (minimized == "1") for w in i["windows"]): print("%s minimized flag wrong" % key); return 1
    if focused is not None and any(w["focused"] for w in i["windows"]) != (focused == "1"): print("%s focus is %s" % (key, not (focused == "1"))); return 1
    print("%s: %d windows" % (key, len(i["windows"]))); return 0

def absent(state_p, key):
    state = load(state_p)
    if any(i["key"] == key for i in state["items"]): print("%s is still in the dock" % key); return 1
    print("%s gone" % key); return 0

def running_after_pinned(state_p, key):
    state = load(state_p)
    order = state["order"]
    pins = [k for k in order if k in state["pinned"]]
    if key not in order or any(order.index(key) < order.index(p) for p in pins): print("%s is not in the running section" % key); return 1
    print("%s sits after the pinned apps" % key); return 0

def focused_window(state_p, key, index):
    """Which window of `key` is focused: its position among that app's windows sorted by address."""
    state = load(state_p)
    ws = sorted(next(i for i in state["items"] if i["key"] == key)["windows"], key=lambda w: w["address"])
    which = [n for n, w in enumerate(ws) if w["focused"]]
    print(which[0] if which else -1); return 0

def pins(state_p):
    print(" ".join(load(state_p)["pinned"])); return 0

def geometry(geo_p, size):
    g = load(geo_p)
    if not g: print("no dock window"); return 1
    problems = []
    for d in g:
        if not d["shown"]: continue
        if d["iconSize"] != int(size): problems.append("iconSize %s, expected %s" % (d["iconSize"], size))
        items = d["items"]
        apps = [i for i in items if i["section"] != "utility"]
        if any(not i["ready"] for i in items): problems.append("not normalized yet: %s" % [i["key"] for i in items if not i["ready"]])
        if len({round(i["slot"], 2) for i in items}) != 1: problems.append("slots differ")
        if len({round(i["canvas"], 2) for i in items}) != 1: problems.append("canvases differ")
        sizes = [round(i["tile"], 2) for i in apps]
        if sizes and (max(sizes) - min(sizes) > 0.01 or min(sizes) <= 0): problems.append("app tile sizes %s" % sorted(set(sizes)))
        for i in items:
            if abs(i["centreY"] - i["slotCentreY"]) > 0.5:
                problems.append("%s is %.2f px off the tiles' centre line" % (i["key"], i["centreY"] - i["slotCentreY"]))
            if i["section"] == "utility":
                e = i.get("extent")
                if not e or max(e) > 0.93 or max(e) < 0.9: problems.append("%s extent %s not about 0.92 of the tile" % (i["key"], e))
        if not problems: print("%d items, app tiles %s px, utilities fitted" % (len(items), sorted(set(sizes)))); return 0
    print("; ".join(problems[:3])); return 1

def menu(geo_p, want_open, kind=None):
    g = load(geo_p)[0]["menu"]
    if g["open"] != (want_open == "1"): print("menu open=%s, expected %s" % (g["open"], want_open)); return 1
    if want_open == "1" and not g["visible"]: print("menu open but not visible"); return 1
    if kind and g["kind"] != kind: print("menu kind %s" % g["kind"]); return 1
    print("menu %s" % ("open: %s (%d rows)" % (g["key"], g["rows"]) if g["open"] else "closed")); return 0

def token(geo_p, key, filename):
    """The item's icon comes from `filename` and is normalized."""
    for d in load(geo_p):
        for i in d["items"]:
            if i["key"] == key:
                if filename not in i["token"]: print("%s uses %s" % (key, i["token"].split("|")[-1][-40:])); return 1
                if not i["ready"]: print("%s not normalized yet" % key); return 1
                print("%s uses %s" % (key, filename)); return 0
    print("no item %s" % key); return 1

def has_item(state_p, prefix):
    print("1" if any(i["key"].lower().startswith(prefix.lower()) for i in load(state_p)["items"]) else "0"); return 0

def _elements(geo):
    """Items and separators of one snapshot, in order along the row."""
    els = [{"id": i["id"], "item": True, "left": i["left"], "width": i["width"], "scale": i["scale"], "restLeft": i["restLeft"], "restWidth": i["restWidth"]} for i in geo["items"]]
    els += [{"id": s_["id"], "item": False, "left": s_["left"], "width": s_["width"], "scale": 1, "restLeft": s_["restLeft"], "restWidth": s_["restWidth"]} for s_ in geo["separators"]]
    return sorted(els, key=lambda e: e["left"])

def hover_sweep(snaps_p, step):
    """A sweep of the pointer across the dock, one geometry snapshot per step."""
    snaps = [json.loads(l)[0] for l in open(snaps_p) if l.strip()]
    step = float(step); problems = []; last = None; last_vel = {}; last_under = -1; worst_step = 0.0
    for n, g in enumerate(snaps):
        px = g["hover"]["pointerX"]; gap = g["hover"]["gap"]; els = _elements(g)
        # nothing overlaps: a gap never gets smaller than the resting gap (it only grows with the stretch)
        for a, b in zip(els, els[1:]):
            gp = b["left"] - (a["left"] + a["width"])
            if gp < gap - 0.5 or gp > gap * 1.6:
                problems.append("step %d: gap between %s and %s is %.2f" % (n, a["id"], b["id"], gp)); break
        # the resting point under the pointer stays exactly under the pointer
        if abs(g["hover"]["anchor"] - px) > 0.01: problems.append("step %d: the point under the pointer is %.3f px off" % (n, g["hover"]["anchor"] - px))
        for e in els:
            if e["item"] and e["restLeft"] <= px <= e["restLeft"] + e["restWidth"] and not (e["left"] - 0.01 <= px <= e["left"] + e["width"] + 0.01):
                problems.append("step %d: pointer left %s" % (n, e["id"]))
        # smooth: positions, scales and above all the row's SPEED change by small amounts per step
        if last:
            prev_els = {q["id"]: q for q in _elements(last)}
            for e in els:
                prev = prev_els.get(e["id"])
                if not prev: continue
                if abs(e["left"] - prev["left"]) > 2.5 * step + 0.5: problems.append("step %d: %s jumped %.1f px" % (n, e["id"], e["left"] - prev["left"]))
                if abs(e["scale"] - prev["scale"]) > 0.03: problems.append("step %d: %s scale jumped %.3f" % (n, e["id"], e["scale"] - prev["scale"]))
                vel = (e["left"] - prev["left"]) / step
                if e["id"] in last_vel:
                    jump = abs(vel - last_vel[e["id"]]); worst_step = max(worst_step, jump)
                    if jump > 0.12: problems.append("step %d: %s changed speed by %.2f (a shake)" % (n, e["id"], jump))
                last_vel[e["id"]] = vel
        if abs(g["card"]["h"] - snaps[0]["card"]["h"]) > 0.01: problems.append("step %d: card height changed" % n)
        ids = [e["id"] for e in els]
        under = ids.index(g["hover"]["under"]) if g["hover"]["under"] in ids else -1
        if under < last_under: problems.append("step %d: hovered item went back to %s" % (n, g["hover"]["under"]))
        last_under = max(last_under, under); last = g
    if problems: print("; ".join(problems[:3]), "(%d problems in %d steps)" % (len(problems), len(snaps))); return 1
    peak = max(i["scale"] for g in snaps for i in g["items"])
    print("%d steps: gaps never below resting, anchor exact, no jumps, row speed changes at most %.3f per 8 px, peak scale %.3f" % (len(snaps), worst_step, peak)); return 0

def hover_scale(geo_p, want):
    """The biggest scale in a snapshot is the magnification (within 2 percent)."""
    g = load(geo_p)[0]; peak = max(i["scale"] for i in g["items"])
    if abs(peak - float(want)) > 0.02 * float(want): print("peak scale %.3f, expected %s" % (peak, want)); return 1
    print("peak scale %.3f" % peak); return 0

def hover_amounts(path, mode):
    """Hover amount samples: 'time_ms amount' per line."""
    rows = [tuple(map(float, l.split())) for l in open(path) if l.strip()]
    amounts = [a for _, a in rows]
    if mode == "up":
        ok = amounts[0] < 0.99 and all(b >= a - 0.01 for a, b in zip(amounts, amounts[1:])) and amounts[-1] > 0.98
    else:
        ok = amounts[0] > 0.3 and all(b <= a + 0.01 for a, b in zip(amounts, amounts[1:])) and amounts[-1] < 0.02
    print("%s: %s" % (mode, " ".join("%.0fms:%.2f" % r for r in rows))); return 0 if ok else 1

def geometry_size(geo_p):
    g = load(geo_p); print(g[0]["iconSize"] if g else 0); return 0

def expect_move(state_p, from_i, to_i, before):
    """After movePinned(from, to) the pins are the old pins with the app at `from` moved to `to`."""
    state = load(state_p); order_before = before.split(); k = order_before[int(from_i)]
    rest = [x for x in order_before if x != k]; rest.insert(int(to_i), k)
    want = [x for x in rest if x in state["pinned"]]
    got = [x for x in state["pinned"]]
    if got[:len(want)] != want and got != want: print("pins %s, expected %s" % (got, want)); return 1
    print("pins now %s" % " ".join(got)); return 0

if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    sys.exit(globals()[cmd](*args))
