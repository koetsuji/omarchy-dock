#!/usr/bin/env python3
"""Drag and drop scenarios (section 10.4), driven through the same window functions the pointer
gesture calls (hooks dragStart, dragMove, dragEnd, dragCancel). Prints `PASS|name|detail` lines.
It opens two test windows whose app ids match unpinned desktop entries (imv, mpv) so there are
running unpinned apps to drag, and restores the pins and closes them at the end."""
import json, os, subprocess, sys, time

IPC = ["omarchy-shell", "omarchy.dock"]
TILE, PAD = 56, 12

def ipc(*a):
    try:
        return subprocess.run(IPC + [str(x) for x in a], capture_output=True, text=True, timeout=15).stdout.strip()
    except subprocess.TimeoutExpired:
        return ""
def geo(): return json.loads(ipc("geometry"))[0]
def state(): return json.loads(ipc("dumpState"))
def hypr(cmd): subprocess.run(["hyprctl", "dispatch", cmd], capture_output=True)
def sleep(t): time.sleep(t)

out = []
def check(name, ok, detail=""):
    out.append(ok); print(("PASS" if ok else "FAIL") + "|" + name + "|" + detail, flush=True)

def at_rest():
    ipc("pointerLeave"); sleep(0.7)
    return geo()
def centre(g, key):
    it = next(i for i in g["items"] if i["key"] == key); return it["restLeft"] + it["restWidth"] / 2
def row_y(g): return g["card"]["y"] + PAD + TILE / 2

def drag(key, to_x, to_y=None, step=10, end=True, start_y=None):
    """Drags `key` from its own centre to (to_x, to_y), a step at a time, and drops it."""
    g = at_rest(); cx = centre(g, key); y0 = row_y(g) if start_y is None else start_y; ty = y0 if to_y is None else to_y
    r = ipc("dragStart", key, cx, y0)
    if r != "ok": return r
    n = max(1, int(abs(to_x - cx) / step))
    for k in range(1, n + 1):
        ipc("dragMove", cx + (to_x - cx) * k / n, y0 + (ty - y0) * k / n)
    ipc("dragMove", to_x, ty)
    if end: ipc("dragEnd", to_x, ty); sleep(0.6)
    return "ok"

def pinned(): return state()["pinned"]
def running_keys():
    s = state(); return [i["key"] for i in s["items"] if not i["pinned"]]
def order_keys(): return state()["order"]

orig = pinned()
procs = []
def open_app(app_id):
    # not capture_output: foot would keep the pipe open for as long as it runs
    subprocess.run(["setsid", "-f", "foot", "--app-id", app_id, "sleep", "300"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(40):
        sleep(0.25)
        if any(i["key"] == app_id and i["windows"] for i in state()["items"]): return True
    return False
def close_apps():
    clients = json.loads(subprocess.run(["hyprctl", "clients", "-j"], capture_output=True, text=True).stdout)
    for c in clients:
        if c["class"] in ("imv", "mpv", "koetsuji.dock.test.drag"):
            hypr('hl.dsp.window.close({ window = "address:%s" })' % c["address"])
def restore():
    """Puts the original pins back and waits until the dock shows them."""
    subprocess.run(["omarchy", "dock", "pinned"] + orig, capture_output=True)
    for _ in range(30):
        sleep(0.25)
        if pinned() == orig: break
    sleep(0.4)

def cleanup():
    ipc("dragCancel"); ipc("pointerLeave"); ipc("setSetting", "locked", "false"); close_apps()
    restore()

try:
    # 1. pinned apps reorder freely
    P = pinned(); key = P[1]
    expect = [k for k in P if k != key]; expect.insert(5, key)
    g = at_rest(); target = centre(g, P[5]) + 30
    drag(key, target)
    check("a pinned app dragged right lands after the app it passed", pinned() == expect, " ".join(pinned()))
    # back to the start
    P2 = pinned(); g = at_rest()
    drag(key, centre(g, P2[0]) - 30)
    check("and dragged back to the front", pinned()[0] == key, " ".join(pinned()))
    restore()

    # 2. while dragging: the item follows the pointer one to one, the hover amount is 0, the gap is open
    P = pinned(); g = at_rest(); cx = centre(g, P[2]); y = row_y(g)
    ipc("dragStart", P[2], cx + 10, y)       # grabbed 10 px right of its centre
    ipc("dragMove", cx + 150, y - 20); sleep(0.4); d = geo()["drag"]
    check("the dragged item follows the pointer one to one, grab offset kept", abs(d["centreX"] - (cx + 140)) < 0.01 and abs(d["centreY"] - (y - 20 - 0)) < 0.01 + 0, "centre %.2f, expected %.2f" % (d["centreX"], cx + 140))
    check("the hover amount stays 0 during a drag", d["hover"] < 0.01, "hover %.3f" % d["hover"])
    check("a gap is open at the insertion point", d["gap"] is not None and d["section"] == "p", "gap %s" % d["gap"])
    ipc("dragCancel"); sleep(0.5)
    check("a canceled drag changes nothing", pinned() == P, " ".join(pinned()))

    # 3. hysteresis: the insertion point does not flicker within 6 px of a slot's middle
    g = at_rest(); P = pinned(); cx = centre(g, P[2]); y = row_y(g)
    ipc("dragStart", P[2], cx, y); idxs = []
    boundary = (centre(g, P[2]) + centre(g, P[3])) / 2          # the middle between this slot and the next
    for dx in (-4, -2, 0, 2, 4, 5, 3, -3, 0, 4, 2, 0):
        ipc("dragMove", boundary + dx, y); idxs.append(geo()["drag"]["index"])
    ipc("dragMove", boundary + 9, y); after = geo()["drag"]["index"]
    ipc("dragMove", boundary - 9, y); back = geo()["drag"]["index"]
    ipc("dragCancel"); sleep(0.4)
    check("the insertion point holds within 6 px of a slot's middle, flips once beyond it", len(set(idxs)) == 1 and after == idxs[0] + 1 and back == idxs[0], "indexes %s, +9: %s, -9: %s" % (sorted(set(idxs)), after, back))

    # 4. released outside the dock (not far enough to remove): back to its slot
    g = at_rest(); P = pinned(); cx = centre(g, P[3]); y = row_y(g)
    drag(P[3], cx + 120, g["card"]["y"] - TILE * 1.2)
    check("released outside the dock, it goes back to its slot", pinned() == P, " ".join(pinned()))
    # right click or Escape cancel (the hook's cancel is the same path)
    drag(P[3], cx + 120, end=False); ipc("dragCancel"); sleep(0.5)
    check("canceling mid-drag leaves the pins alone", pinned() == P, " ".join(pinned()))

    # 5. the Apps button, Downloads, Trash and separators do not take drops
    g = at_rest(); P = pinned(); dl = next(i for i in g["items"] if i["key"] == "downloads"); tr = next(i for i in g["items"] if i["key"] == "trash")
    drag(P[0], tr["restLeft"] + 60)
    check("dropping beyond Downloads and Trash does not move the app into them", pinned()[-1] == P[0] and pinned()[:-1] == P[1:], " ".join(pinned()))
    restore()

    # 6. running unpinned apps: pin by dragging into the pinned section, reorder, unpin by REMOVE
    ok1 = open_app("imv"); ok2 = open_app("mpv")
    check("two running unpinned apps to drag (imv, mpv)", ok1 and ok2 and "imv" in running_keys() and "mpv" in running_keys(), "running: %s" % running_keys())
    P = pinned(); g = at_rest()
    # reorder among the running apps: mpv (opened last) dragged left of imv
    r = running_keys(); before = r.index("mpv") > r.index("imv")
    drag("mpv", centre(g, "imv") - 30)
    r2 = running_keys()
    check("a running unpinned app can be reordered among the running apps", before and r2.index("mpv") < r2.index("imv") and pinned() == P, "running %s, pins unchanged %s" % (r2, pinned() == P))
    # pin: dragged into the pinned section, at the spot
    g = at_rest(); target = centre(g, P[2]) - 30
    drag("imv", target)
    check("a running unpinned app dragged into the pinned section is pinned at that spot", pinned() == P[:2] + ["imv"] + P[2:], " ".join(pinned()))
    # remove gesture: more than 1.5 tiles above the card
    g = at_rest(); P2 = pinned()
    drag("imv", centre(g, "imv"), g["card"]["y"] - TILE * 1.5 - 14)
    check("a pinned app dragged more than 1.5 tiles above the card is unpinned", "imv" not in pinned() and pinned() == P, " ".join(pinned()))
    check("and, as it is running, it moves to the running section", "imv" in running_keys(), "running %s" % running_keys())
    s = state(); order = s["order"]
    check("no app is ever shown twice", len(order) == len(set(order)), "order %s" % order)

    # 7. windows opening during a drag do not reshuffle the row; they appear after the drop
    g = at_rest(); P = pinned(); cx = centre(g, P[1]); y = row_y(g)
    ipc("dragStart", P[1], cx, y); ipc("dragMove", cx + 60, y)
    before_rows = [i["key"] for i in geo()["items"]]
    open_app("koetsuji.dock.test.drag")
    sleep(0.8)
    during_rows = [i["key"] for i in geo()["items"]]
    ipc("dragCancel"); sleep(1.2)
    after_rows = [i["key"] for i in geo()["items"]]
    check("a window opening mid-drag does not change the row until the drop", before_rows == during_rows and "koetsuji.dock.test.drag" in after_rows, "during %d items, after %d" % (len(during_rows), len(after_rows)))

    # 8. locked turns dragging off
    ipc("setSetting", "locked", "true"); sleep(1.2); g = at_rest(); r = ipc("dragStart", pinned()[0], centre(g, pinned()[0]), row_y(g))
    check("locked: true turns dragging off", r == "locked" and not geo()["drag"]["active"], "answer %s" % r)
    ipc("setSetting", "locked", "false"); sleep(1.2)

    # 9. the order survives a shell restart (the pins are saved)
    P = pinned(); g = at_rest(); drag(P[0], centre(g, P[3]) + 30); moved = pinned()
    sleep(1.5)
    subprocess.run(["omarchy-restart-shell"], capture_output=True)
    for _ in range(60):
        sleep(1)
        try:
            if json.loads(ipc("dumpState"))["items"]: break
        except Exception: pass
    sleep(1); check("a dragged order survives omarchy-restart-shell", pinned() == moved and moved != P, " ".join(pinned()))
finally:
    cleanup()
sys.exit(0 if all(out) else 1)
