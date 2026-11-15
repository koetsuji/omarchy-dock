#!/usr/bin/env python3
"""Measures every tile's visible size from a real screenshot of the dock (not from item sizes).
For each item it takes the luminance profile across the tile's left and right edges (averaged over
the middle of the tile) and across its top and bottom edges, finds each outer edge where the profile
crosses half way between the card behind it and the tile's bright rim, and reports width and height
in logical px. Run: python3 -B -I measure_tiles.py geometry.json OUT.png
(the dock must be at rest, pointer away)."""
import json, subprocess, sys
from PIL import Image

geo = json.load(open(sys.argv[1]))[0]
out_png = sys.argv[2]
scale = float(subprocess.run(["hyprctl", "monitors", "-j"], capture_output=True, text=True).stdout and
              json.loads(subprocess.run(["hyprctl", "monitors", "-j"], capture_output=True, text=True).stdout)[0]["scale"])
layers = json.loads(subprocess.run(["hyprctl", "layers", "-j"], capture_output=True, text=True).stdout)
win = next(s for m in layers.values() for lvl in m["levels"].values() for s in lvl if s["namespace"] == "omarchy-dock")
x0 = int(min(i["x"] for i in geo["items"]) - 40); x1 = int(max(i["x"] + i["slot"] for i in geo["items"]) + 40)
y0 = int(win["y"] + geo["card"]["y"] - 24); y1 = int(win["y"] + geo["card"]["y"] + geo["card"]["h"] + 20)
subprocess.run(["grim", "-g", "%d,%d %dx%d" % (x0, y0, x1 - x0, y1 - y0), out_png], check=True)
im = Image.open(out_png).convert("L")
S = im.width / (x1 - x0)           # physical px per logical px
lum = im.load()

def crossing(profile, lo_level, hi_level, outward_from_inside=True):
    """Position (in profile samples, sub-pixel) of the outer edge: walking from the inside out, the
    first sample that drops below half way between the bright rim and the background."""
    half = (lo_level + hi_level) / 2
    for k in range(len(profile) - 1):
        a, b = profile[k], profile[k + 1]
        if a >= half > b: return k + (a - half) / (a - b)
    return None

def edge(points, rim_to, bg_from):
    """points: luminance along a line from 4 px inside the nominal edge outwards, S samples per px.
    Bright tiles: the rim is the brightest sample in the first `rim_to` samples (the stroke or the
    body just inside the edge, never the logo further in), the background the mean from `bg_from`,
    and the edge where the profile falls half way between them. Dark tiles on a dark card have
    almost no rim: then the edge is the outermost place where the profile leaves the background."""
    bg = sum(points[bg_from:]) / max(1, len(points) - bg_from)
    rim = max(points[:rim_to])
    if rim - bg >= 10:
        e = crossing(points[rim_to - 1:], bg, rim)
        return (None if e is None else (e, rim_to - 1)), "rim"
    # outermost deviation: walk inwards from the background
    for k in range(bg_from - 1, 0, -1):
        if abs(points[k] - bg) >= 4:
            inner = [points[j] for j in range(max(0, k - 3), k + 1)]
            peak = max(inner, key=lambda v: abs(v - bg)) - bg
            if abs(peak) < 6: return None, "none"
            half = bg + peak / 2
            # sub-pixel: where the profile crosses `half`, going inwards from k
            for j in range(k, 0, -1):
                a, b = points[j] - half, points[j - 1] - half
                if a == 0: return (j, 0), "dev"
                if (a < 0) != (b < 0): return (j - a / (b - a), 0), "dev"
            return (k, 0), "dev"
    return None, "none"

def line(cx, cy, dx, dy, start, length, spread):
    """Average over `spread` parallel lines of the luminance from the tile edge region outwards."""
    out = []
    for k in range(length):
        acc = 0
        for t in range(-spread, spread + 1):
            px = (cx + dx * (start + k / S) - dy * (t / S) - x0) * S
            py = (cy + dy * (start + k / S) + dx * (t / S) - y0) * S
            acc += lum[min(max(int(px), 0), im.width - 1), min(max(int(py), 0), im.height - 1)]
        out.append(acc / (2 * spread + 1))
    return out

print("%-20s %8s %8s   (logical px, from the screenshot)" % ("item", "width", "height"))
rows = []
for it in geo["items"]:
    if it["section"] == "utility": continue
    cx = it["x"] + it["slot"] / 2; cy = win["y"] + it["y"] + it["slot"] / 2 - 0.0
    cy_screen = cy
    half = it["slot"] / 2
    res = []
    methods = set()
    for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
        # from 4 px inside the nominal edge to 8 px outside it
        prof = line(cx, cy_screen, dx, dy, half - 4, int(12 * S), 6)
        found, how = edge(prof, int(3.0 * S), int(8.0 * S))
        methods.add(how)
        if found is None: res.append(None); continue
        e, base = found
        res.append((half - 4) + (base + e) / S)
    if None in res: print("%-20s %8s %8s   (edge not visible)" % (it["key"], "-", "-")); continue
    w = res[0] + res[1]; h = res[2] + res[3]
    exact = methods == {"rim"}   # all four edges had a visible rim against the card
    rows.append((it["key"], w, h, exact))
    print("%-20s %8.2f %8.2f   %s" % (it["key"], w, h, "" if exact else "(rough: faint edge on this card)"))
exact = [r for r in rows if r[3]]
if len(exact) >= 3:
    ws = [r[1] for r in exact]; hs = [r[2] for r in exact]
    med = sorted(ws + hs)[len(ws + hs) // 2]
    agent = [r for r in exact if r[0].lower().startswith("org.omarchy.agent")]
    print("%d tiles measured exactly: width spread %.2f px, height spread %.2f px (target 0.5; measurement noise about 0.5, one device pixel is 0.63)" % (len(exact), max(ws) - min(ws), max(hs) - min(hs)))
    # one device pixel is 0.63 logical px at this scale, and each edge is found to about half of that
    bad = max(ws) - min(ws) > 1.0 or max(hs) - min(hs) > 1.0 or any(abs(r[1] - med) > 0.8 or abs(r[2] - med) > 0.8 for r in agent)
    sys.exit(1 if bad else 0)
print("too few tiles with a visible rim to compare"); sys.exit(1)
