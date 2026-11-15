#!/usr/bin/env python3
"""Icon normalizer for the dock (spec 8.2 and the M2b and M2c amendments).

Two styles, both cached as a 256 px PNG on an identical transparent canvas:

  bare      the M2b keyline system: each icon fitted to the keyline of its class.
  squircle  the macOS look: every app is one identical continuous-corner tile
            with a gradient, an inner edge highlight and a soft drop shadow.
            Plates (icons that already are a square) fill the tile; free-form
            logos sit on a `white`, `brand` or `graphite` tile.

  normalize.py --cache DIR [--card-luminance L] TOKEN [TOKEN ...]

TOKEN is `[opts|]SOURCE`. SOURCE is an absolute file path (png or svg) or
`icon:NAME` for a themed icon name. opts is comma-separated key=value:
style=bare|squircle, mode=plate|white|brand|graphite, top=#rrggbb, bottom=#rrggbb.
Prints one JSON list on stdout: [{"src", "png", "meta"} | {"src", "error"}].
Run with `python3 -B -I` so no bytecode is written next to the script.

The sizing measure: the full bounding box (alpha at 50 percent) and a trimmed
box that holds the central 96 percent of opaque pixels, so a badge or overhang
does not decide the size. Circles are fitted by their full box, because
trimming a disc by mass takes a tenth off its width through curvature alone.
"""
import argparse, colorsys, glob, hashlib, io, json, math, os, re, subprocess, sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageStat

VERSION = 7
WORK = 1024     # working canvas, and the squircle canvas
OUT = 256       # cached canvas
THRESHOLD = 128 # 50 percent alpha: soft shadows do not count
LOWRES = 128

# ---- bare (M2b keylines) ----
TRIM = 0.02           # mass trimmed from each side of each axis
MAX_BRIGHTNESS = 0.05 # the most a very bright icon is scaled down
GUARD = 0.98          # the full shape never exceeds this much of the cell
KEYLINES = {
    "square": (0.80, 0.80),
    "circle": (0.92, 0.92),
    "tall": (0.70, 0.92),
    "wide": (0.92, 0.70),
    "irregular": 0.92,  # fits inside a circle of this diameter
}

# ---- squircle (M2c, second pass) ----
# Apple's icon geometry: a rounded square with corner radius 22.5 percent of the
# side and continuous corners, corner smoothing 60 percent, by the path math of
# figma-squircle. Shadow and edge are defined in on-screen pixels at iconSize 56
# and so scale with the tile: they are kept as fractions of the tile side.
CORNER_RADIUS = 0.225
CORNER_SMOOTHING = 0.60
CANVAS_FACTOR = 1.30              # PNG canvas as a multiple of the tile: room for the shadow
TILE = 1 / CANVAS_FACTOR          # tile side as a fraction of the cell
REF = 56.0                        # the iconSize the on-screen numbers are given at
SHADOW_Y = 2 / REF                # y offset 2 px
SHADOW_SIGMA = 2.5 / REF          # blur 5 px (CSS blur radius is twice the sigma)
SHADOW_ALPHA = 0.35               # black at 35 percent
# The bevel: a glass edge just inside the tile, the same on every tile.
BEVEL_STROKE = 1.5 / REF          # inner stroke, 1.5 px on screen
BEVEL_HAIR = 1 / REF              # a darker hairline just inside it, 1 px
BEVEL_HAIR_ALPHA = 0.10           # black
BEVEL_TOP = {"light": 0.70, "mid": 0.45, "dark": 0.30}  # white, at the top, by tile kind
# How bright the stroke is around the tile, as a share of its top: brightest at
# the top, dimmer on the sides, a slight brighter return at the bottom.
BEVEL_AROUND = [(0.0, 1.0), (0.10, 0.72), (0.45, 0.30), (0.62, 0.26), (0.90, 0.38), (1.0, 0.55)]
OVERSCAN = 1.03                   # a plate covers the tile with 3 percent to spare
WHITE_TILE = ("#F4F4F7", "#D8D8DE")  # pulled down a touch so the bevel stands out
GRAPHITE_TILE = ("#4A4A4F", "#1C1C1E")
BRAND_LIGHTER, BRAND_DARKER = 0.15, 0.10  # brand tiles and flat plates: top lighter, bottom darker
# Logo size inside the tile, as fractions of the tile side.
TILE_FIT = {"circle": (0.80, 0.80), "square": (0.70, 0.70), "tall": (0.62, 0.80), "wide": (0.80, 0.62), "irregular": 0.80}
MIN_CONTRAST = 3.0

def theme_chain():
    """The user's icon theme first, then the usual fallbacks."""
    names = []
    for ini in (os.path.expanduser("~/.config/gtk-3.0/settings.ini"), os.path.expanduser("~/.config/gtk-4.0/settings.ini")):
        try:
            for line in open(ini):
                if line.strip().startswith("gtk-icon-theme-name"):
                    names.append(line.split("=", 1)[1].strip())
        except OSError:
            pass
    try:
        out = subprocess.run(["gsettings", "get", "org.gnome.desktop.interface", "icon-theme"],
                             capture_output=True, text=True, timeout=2).stdout.strip().strip("'")
        if out:
            names.append(out)
    except Exception:
        pass
    names += ["Yaru", "hicolor", "Adwaita", "breeze"]
    seen, roots = set(), []
    for n in names:
        for base in (os.path.expanduser("~/.local/share/icons"), "/usr/share/icons"):
            r = os.path.join(base, n)
            if n not in seen and os.path.isdir(r):
                roots.append(r)
        seen.add(n)
    return roots


def find_icon(name):
    """A themed icon name to a file: an SVG if any, else the largest PNG."""
    for root in theme_chain():
        for pattern in (root + "/scalable/*/" + name + ".svg", root + "/*/scalable/" + name + ".svg",
                        root + "/*/*/" + name + ".svg", root + "/*/" + name + ".svg"):
            hits = sorted(glob.glob(pattern))
            if hits:
                return hits[0]
        best, best_size = None, -1
        for pattern in (root + "/*/*/" + name + ".png", root + "/*/" + name + ".png"):
            for hit in glob.glob(pattern):
                if size_hint(hit) > best_size:
                    best, best_size = hit, size_hint(hit)
        if best:
            return best
    for extra in ("/usr/share/pixmaps/" + name + ".png", "/usr/share/pixmaps/" + name + ".svg"):
        if os.path.exists(extra):
            return extra
    raise FileNotFoundError("no icon named " + name)


def resolve(src):
    return find_icon(src[5:]) if src.startswith("icon:") else src


def better_source(path):
    """Prefer an SVG, else the largest PNG, of the same icon in its theme."""
    if path.lower().endswith(".svg"):
        return path
    m = re.match(r"(.*?/icons/[^/]+)/", path)
    name = os.path.splitext(os.path.basename(path))[0]
    roots = [m.group(1)] if m else []
    roots.append("/usr/share/icons/hicolor")
    for root in roots:
        for pattern in (root + "/scalable/*/" + name + ".svg", root + "/*/scalable/" + name + ".svg",
                        root + "/*/" + name + ".svg", root + "/*/*/" + name + ".svg"):
            hits = sorted(glob.glob(pattern))
            if hits:
                return hits[0]
    best, best_size = path, size_hint(path)
    for root in roots:
        for pattern in (root + "/*/*/" + name + ".png", root + "/*/" + name + ".png"):
            for hit in glob.glob(pattern):
                size = size_hint(hit)
                if size > best_size:
                    best, best_size = hit, size
    return best


def size_hint(path):
    m = re.search(r"/(\d+)x\d+(?:@\d+x)?/", path) or re.search(r"/(\d+)/", path)
    return int(m.group(1)) if m else 0


def svg_text(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return b""


def is_template(path):
    """An SVG that carries an %ACCENT% placeholder, filled in from the theme accent:
    %ACCENT%, %ACCENT_TOP% (15 percent lighter) and %ACCENT_BOTTOM% (10 percent darker)."""
    return path.lower().endswith(".svg") and b"%ACCENT" in svg_text(path)


def fill_template(data, accent):
    base = hex_rgb(accent or "#7AA2F7")
    top, bottom = mix(base, (255, 255, 255), 0.15), mix(base, (0, 0, 0), 0.10)
    return (data.replace(b"%ACCENT_TOP%", rgb_hex(top).encode()).replace(b"%ACCENT_BOTTOM%", rgb_hex(bottom).encode())
            .replace(b"%ACCENT%", rgb_hex(base).encode()))


def rasterize(path, accent=None):
    """Returns (RGBA image on the WORK canvas, source pixel size or None)."""
    if path.lower().endswith(".svg"):
        if is_template(path):
            data = fill_template(svg_text(path), accent)
            cmd = ["rsvg-convert", "-w", str(WORK), "-h", str(WORK), "-a", "-f", "png"]
            out = subprocess.run(cmd, input=data, capture_output=True, timeout=15, check=True).stdout
        else:
            out = subprocess.run(["rsvg-convert", "-w", str(WORK), "-h", str(WORK), "-a", "-f", "png", path],
                                 capture_output=True, timeout=15, check=True).stdout
        img = Image.open(io.BytesIO(out)).convert("RGBA")
        source = None
    else:
        img = Image.open(path).convert("RGBA")
        source = max(img.size)
        scale = WORK / max(img.size)
        img = img.resize((max(1, round(img.width * scale)), max(1, round(img.height * scale))), Image.LANCZOS)
    canvas = Image.new("RGBA", (WORK, WORK), (0, 0, 0, 0))
    canvas.paste(img, ((WORK - img.width) // 2, (WORK - img.height) // 2))
    return canvas, source


def trim_axis(profile, fraction):
    total = sum(profile)
    lo = hi = None
    acc = 0
    for i, v in enumerate(profile):
        acc += v
        if lo is None and acc >= fraction * total:
            lo = i
        if hi is None and acc >= (1 - fraction) * total:
            hi = i + 1
            break
    return lo, hi


def measure(img):
    mask = img.getchannel("A").point(lambda v: 255 if v >= THRESHOLD else 0)
    box = mask.getbbox()
    if not box:
        raise ValueError("empty icon")
    cols = list(mask.resize((WORK, 1), Image.BOX).tobytes())
    rows = list(mask.resize((1, WORK), Image.BOX).tobytes())
    x0, x1 = trim_axis(cols, TRIM)
    y0, y1 = trim_axis(rows, TRIM)
    return mask, box, (x0, y0, x1, y1)


def corners_empty(mask, box):
    """How many of the four corners of the full box are (almost) empty."""
    x0, y0, x1, y1 = box
    side = round(0.2 * min(x1 - x0, y1 - y0))
    empty = 0
    for cx, cy in ((x0, y0), (x1 - side, y0), (x0, y1 - side), (x1 - side, y1 - side)):
        part = mask.crop((cx, cy, cx + side, cy + side))
        if part.histogram()[255] / max(1, side * side) < 0.20:
            empty += 1
    return empty


def classify(aspect, fill, corners):
    if 0.85 <= aspect <= 1.18 and fill >= 0.85:
        return "square"
    # A circle may carry a tail (a speech bubble), so three empty corners do.
    if 0.9 <= aspect <= 1.1 and 0.72 <= fill <= 0.84 and corners >= 3:
        return "circle"
    if aspect < 0.85:
        return "tall"
    if aspect > 1.18:
        return "wide"
    return "irregular"


def radius_of(mask, centre, quantile=0.98):
    """Distance from the centre that holds 98 percent of the opaque pixels."""
    small = mask.resize((128, 128), Image.BOX).tobytes()
    k = 128 / WORK
    dist = []
    for i, v in enumerate(small):
        if v >= 128:
            x, y = i % 128 + 0.5, i // 128 + 0.5
            dist.append(math.hypot(x / k - centre[0], y / k - centre[1]))
    dist.sort()
    return dist[min(len(dist) - 1, int(quantile * len(dist)))] if dist else 1.0


def bare_fit(src, card_luminance):
    path = better_source(src)
    img, source_px = rasterize(path)
    mask, box, trimmed = measure(img)
    w, h = box[2] - box[0], box[3] - box[1]
    area = mask.histogram()[255]
    fill = area / (w * h)
    tw, th = trimmed[2] - trimmed[0], trimmed[3] - trimmed[1]
    aspect = tw / th
    cls = classify(aspect, fill, corners_empty(mask, box))
    centre = ((trimmed[0] + trimmed[2]) / 2, (trimmed[1] + trimmed[3]) / 2)
    if cls == "circle":
        # A circle's keyline is its own diameter. Trimming a disc by mass takes
        # about a tenth off its width through curvature alone, so the circle is
        # fitted by its full box.
        centre = ((box[0] + box[2]) / 2, (box[1] + box[3]) / 2)
        s = min(KEYLINES["circle"][0] * OUT / w, KEYLINES["circle"][1] * OUT / h)
        keyline = "circle %.2f" % KEYLINES["circle"][0]
    elif cls == "irregular":
        s = KEYLINES["irregular"] * OUT / 2 / radius_of(mask, centre)
        keyline = "circle %.2f" % KEYLINES["irregular"]
    else:
        kw, kh = KEYLINES[cls]
        s = min(kw * OUT / tw, kh * OUT / th)
        keyline = "%.2f x %.2f" % (kw, kh)
    fit = s
    # Brightness: icons much brighter than the card look heavier.
    lum = ImageStat.Stat(img.convert("L"), mask).mean[0] / 255
    headroom = max(1e-6, 1 - card_luminance)
    correction = MAX_BRIGHTNESS * max(0.0, min(1.0, (lum - card_luminance) / headroom))
    s *= 1 - correction
    guard = max(w, h) * s > GUARD * OUT
    if guard:
        s = GUARD * OUT / max(w, h)
    size = max(1, round(WORK * s))
    scaled = img.resize((size, size), Image.LANCZOS)
    canvas = Image.new("RGBA", (OUT, OUT), (0, 0, 0, 0))
    canvas.paste(scaled, (round(OUT / 2 - centre[0] * s), round(OUT / 2 - centre[1] * s)))
    meta = {
        "class": cls,
        "aspect": round(aspect, 4),          # of the trimmed box
        "fill": round(fill, 4),              # opaque area over the full box
        "trimmed": [round(tw * s / OUT, 4), round(th * s / OUT, 4)],  # trimmed box, fractions of the cell
        "extent": [round(w * s / OUT, 4), round(h * s / OUT, 4)],     # full shape, fractions of the cell
        "keyline": keyline,
        "meanLuminance": round(lum, 4),
        "cardLuminance": round(card_luminance, 4),
        "brightnessCorrection": round(correction, 4),
        "fitScale": round(fit * WORK / OUT, 4),
        "finalScale": round(s * WORK / OUT, 4),  # of the 512 source canvas against the cell
        "guarded": guard,
        "lowRes": source_px is not None and source_px < LOWRES,
        "source": path,
        "version": VERSION,
        "style": "bare",
    }
    return canvas, meta




# ======================= squircle tiles =======================

def hex_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def rgb_hex(c):
    return "#%02X%02X%02X" % tuple(max(0, min(255, round(v))) for v in c)


def mix(c, target, f):
    return tuple(c[i] + (target[i] - c[i]) * f for i in range(3))


def relative_luminance(c):
    def lin(v):
        v /= 255
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    return 0.2126 * lin(c[0]) + 0.7152 * lin(c[1]) + 0.0722 * lin(c[2])


def contrast(a, b):
    la, lb = relative_luminance(a), relative_luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


_masks = {}


def corner_params(radius, smoothing, budget):
    """The control distances of one continuous corner (figma-squircle)."""
    p = (1 + smoothing) * radius
    smoothing = min(smoothing, budget / radius - 1)
    p = min(p, budget)
    arc_measure = 90 * (1 - smoothing)
    arc_len = math.sin(math.radians(arc_measure / 2)) * radius * math.sqrt(2)
    alpha = (90 - arc_measure) / 2
    p3p4 = radius * math.tan(math.radians(alpha / 2))
    beta = 45 * smoothing
    c = p3p4 * math.cos(math.radians(beta))
    d = c * math.tan(math.radians(beta))
    b = (p - arc_len - c - d) / 3
    return 2 * b, b, c, d, p, arc_len, math.radians(arc_measure)


def bezier(p0, p1, p2, p3, n=28):
    pts = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        pts.append((u ** 3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * p3[0],
                    u ** 3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * p3[1]))
    return pts


def top_right_corner(radius, smoothing, budget):
    """The top-right corner as points, its vertex at the origin: from (-p, 0)
    along the top edge to (0, p) down the right edge."""
    a, b, c, d, p, arc, theta = corner_params(radius, smoothing, budget)
    p0, p1, p2, p3 = (-p, 0), (-p + a, 0), (-p + a + b, 0), (-p + a + b + c, d)
    pts = bezier(p0, p1, p2, p3)
    p4 = (p3[0] + arc, p3[1] + arc)
    mid = ((p3[0] + p4[0]) / 2, (p3[1] + p4[1]) / 2)
    dist = radius * math.cos(theta / 2)
    cx, cy = mid[0] - dist / math.sqrt(2), mid[1] + dist / math.sqrt(2)
    phi0 = math.atan2(p3[1] - cy, p3[0] - cx)
    for i in range(1, 25):
        phi = phi0 + theta * i / 24
        pts.append((cx + radius * math.cos(phi), cy + radius * math.sin(phi)))
    pts += bezier(p4, (p4[0] + d, p4[1] + c), (p4[0] + d, p4[1] + b + c), (p4[0] + d, p4[1] + a + b + c))[1:]
    return pts


def squircle_points(side, radius_fraction=None):
    radius = (radius_fraction or CORNER_RADIUS) * side
    tr = top_right_corner(radius, CORNER_SMOOTHING, side / 2)
    pts = [(side + x, y) for x, y in tr]                       # top right
    pts += [(side - y, side + x) for x, y in tr]               # bottom right: rotated 90
    pts += [(-x, side - y) for x, y in tr]                     # bottom left: rotated 180
    pts += [(y, -x) for x, y in tr]                            # top left: rotated 270
    return pts


def squircle(side, inset=0, canvas=None, radius=None):
    """One identical mask: Apple's rounded square with continuous corners, drawn supersampled."""
    key = (side, inset, canvas, radius)
    if key not in _masks:
        ss = 3
        inner = side - 2 * inset
        big = inner * ss
        m = Image.new("L", (big, big), 0)
        ImageDraw.Draw(m).polygon(squircle_points(big, radius), fill=255)
        m = m.resize((inner, inner), Image.LANCZOS)
        if inset or canvas:
            full = Image.new("L", (canvas or side, canvas or side), 0)
            off = ((canvas or side) - inner) // 2
            full.paste(m, (off, off))
            m = full
        _masks[key] = m
    return _masks[key]


def vertical_gradient(size, top, bottom):
    w, h = size
    ramp = Image.linear_gradient("L").resize((w, h), Image.BILINEAR)  # black at the top
    return Image.composite(Image.new("RGB", size, tuple(round(v) for v in bottom)),
                           Image.new("RGB", size, tuple(round(v) for v in top)), ramp)


def main_colour(img):
    """The logo's most populous colour among its opaque pixels, bucketed to 3 bits."""
    small = img.resize((128, 128), Image.BOX)
    data = small.tobytes()
    buckets = {}
    total = 0
    for i in range(0, len(data), 4):
        r, g, b, a = data[i], data[i + 1], data[i + 2], data[i + 3]
        if a < 128:
            continue
        total += 1
        k = (r >> 5, g >> 5, b >> 5)
        n, sr, sg, sb = buckets.get(k, (0, 0, 0, 0))
        buckets[k] = (n + 1, sr + r, sg + g, sb + b)
    if not buckets:
        return (128, 128, 128), 0
    n, sr, sg, sb = max(buckets.values())
    return (sr / n, sg / n, sb / n), total


def colour_census(img):
    """Shares of near-white, strong-colour and other opaque pixels, the strong
    hue families present, and the mean colour of the strongest family."""
    small = img.resize((128, 128), Image.BOX)
    total = white = strong = 0
    hues = [0] * 12
    sums = [[0, 0, 0, 0] for _ in range(12)]
    data = small.tobytes()
    for i in range(0, len(data), 4):
        r, g, b, a = data[i], data[i + 1], data[i + 2], data[i + 3]
        if a < 128:
            continue
        total += 1
        if min(r, g, b) >= 200:
            white += 1
            continue
        h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
        if s > 0.45 and v > 0.25:
            strong += 1
            k = int(h * 12) % 12
            hues[k] += 1
            sums[k][0] += 1; sums[k][1] += r; sums[k][2] += g; sums[k][3] += b
    total = max(1, total)
    best = max(range(12), key=lambda k: hues[k])
    # neighbouring hue bins are one family
    family = hues[best] + hues[(best - 1) % 12] + hues[(best + 1) % 12]
    others = strong - family
    n = max(1, sums[best][0])
    mean = (sums[best][1] / n, sums[best][2] / n, sums[best][3] / n)
    return {"white": white / total, "strong": strong / total, "family": family / total,
            "others": others / total, "mean": mean}


def white_symbol(img, mask):
    """The near-white parts of the logo as a white symbol: alpha only. Returns
    (alpha image, share of opaque area, share of its pixels that are partial)."""
    r, g, b, a = img.split()
    low = ImageChops.darker(ImageChops.darker(r, g), b)  # whiteness: the weakest channel
    alpha = low.point(lambda v: 0 if v <= 190 else (255 if v >= 235 else round((v - 190) * 255 / 45)))
    alpha = ImageChops.multiply(alpha, a)
    area = mask.histogram()[255] or 1
    solid = alpha.point(lambda v: 255 if v >= 128 else 0).histogram()[255]
    partial = alpha.point(lambda v: 255 if 38 <= v <= 217 else 0).histogram()[255]
    return alpha, solid / area, partial / max(1, solid + partial)


def frame_inset(img, box):
    """Thickness, in working px, of a thin frame or ring along the edge of a
    plate that differs sharply from the fill inside it. 0 when there is none."""
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    side = min(w, h)
    maxd = max(4, int(0.12 * side))
    rgb, alpha = img.convert("RGB").load(), img.getchannel("A").load()

    def profile(points, step):
        out = []
        for d in range(maxd + 1):
            sr = sg = sb = n = 0
            for (px, py) in points:
                x, y = px + step[0] * d, py + step[1] * d
                if alpha[x, y] >= THRESHOLD:
                    r, g, b = rgb[x, y]
                    sr += r; sg += g; sb += b; n += 1
            out.append((sr / n, sg / n, sb / n) if n else None)
        return out

    def span(a, b, k=9):
        return [round(a + (b - a) * (0.3 + 0.4 * i / (k - 1))) for i in range(k)]

    sides = [
        profile([(x, y0) for x in span(x0, x1 - 1)], (0, 1)),
        profile([(x, y1 - 1) for x in span(x0, x1 - 1)], (0, -1)),
        profile([(x0, y) for y in span(y0, y1 - 1)], (1, 0)),
        profile([(x1 - 1, y) for y in span(y0, y1 - 1)], (-1, 0)),
    ]
    found = []
    for p in sides:
        if any(v is None for v in p):
            return 0
        jumps = [sum(abs(p[d + 1][i] - p[d][i]) for i in range(3)) for d in range(maxd)]
        d = max(range(min(len(jumps), int(0.08 * side) or 1)), key=lambda i: jumps[i])
        settle = sum(abs(p[min(maxd, d + 3)][i] - p[maxd][i]) for i in range(3))
        if jumps[d] > 70 and settle < 45:
            found.append(d + 1)
    if len(found) >= 3:
        found.sort()
        return found[len(found) // 2] + 2  # a little extra: the ring's anti-aliased inner edge
    return 0


def ramp_image(size, top, bottom):
    """A mask going from `top` (0..1) at the top to `bottom` at the bottom."""
    ramp = Image.linear_gradient("L").resize((size, size), Image.BILINEAR)
    return ramp.point(lambda v: round(255 * (top + (bottom - top) * v / 255)))


def edge_kind(layer, tile_px, radius):
    """Light, mid or dark, from the luminance in a band just inside the tile's edge."""
    near, far = max(1, round(0.02 * tile_px)), round(0.06 * tile_px)
    band = ImageChops.subtract(squircle(tile_px, inset=near, canvas=tile_px, radius=radius),
                               squircle(tile_px, inset=far, canvas=tile_px, radius=radius))
    lum = ImageStat.Stat(layer.convert("L"), band).mean[0] / 255
    return ("dark" if lum < 0.35 else "light" if lum > 0.72 else "mid"), lum


def around_mask(size, top_alpha):
    """A mask going around the tile: bright at the top, dim on the sides, a little back at the bottom."""
    lut = []
    for v in range(256):
        t = v / 255
        for (t0, f0), (t1, f1) in zip(BEVEL_AROUND, BEVEL_AROUND[1:]):
            if t0 <= t <= t1:
                f = f0 + (f1 - f0) * (t - t0) / (t1 - t0)
                break
        lut.append(round(255 * top_alpha * f))
    return Image.linear_gradient("L").resize((size, size), Image.BILINEAR).point(lut)


def render_tile(content, tile_colours, flat_overlay, radius):
    """Composes the finished 256 px icon: shadow, tile, content, rim. `content`
    is a callable that returns an RGBA layer of the tile's size. Returns
    (canvas, rim meta)."""
    tile_px = round(WORK * TILE)
    off = (WORK - tile_px) // 2
    mask = squircle(tile_px, radius=radius)
    layer = Image.new("RGBA", (tile_px, tile_px), (0, 0, 0, 0))
    if tile_colours:
        base = vertical_gradient((tile_px, tile_px), tile_colours[0], tile_colours[1]).convert("RGBA")
        layer.alpha_composite(base)
    layer.alpha_composite(content(tile_px))
    if flat_overlay:  # the brand gradient over a flat plate: lighter top, darker bottom
        ramp = Image.linear_gradient("L").resize((tile_px, tile_px), Image.BILINEAR)
        top_a, bottom_a = round(255 * BRAND_LIGHTER), round(255 * BRAND_DARKER)
        top = Image.new("RGBA", (tile_px, tile_px), (255, 255, 255, 0))
        top.putalpha(ramp.point(lambda v: max(0, round(top_a * (1 - v / 128))) if v < 128 else 0))
        bottom = Image.new("RGBA", (tile_px, tile_px), (0, 0, 0, 0))
        bottom.putalpha(ramp.point(lambda v: round(bottom_a * (v - 128) / 127) if v > 128 else 0))
        layer.alpha_composite(top)
        layer.alpha_composite(bottom)
    layer.putalpha(ImageChops.multiply(layer.getchannel("A"), mask))

    canvas = Image.new("RGBA", (WORK, WORK), (0, 0, 0, 0))
    # shadow: the tile's shape, lowered, softened
    sh = Image.new("L", (WORK, WORK), 0)
    sh.paste(mask, (off, off + round(SHADOW_Y * tile_px)))
    sh = sh.filter(ImageFilter.GaussianBlur(SHADOW_SIGMA * tile_px)).point(lambda v: round(v * SHADOW_ALPHA))
    shadow = Image.new("RGBA", (WORK, WORK), (0, 0, 0, 0))
    shadow.putalpha(sh)
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(layer, (off, off))

    # bevel: a 1.5 px (on screen) specular stroke just inside the edge, brightest at the
    # top, and a 1 px darker hairline just inside that, so it also reads on white tiles
    kind, lum = edge_kind(layer, tile_px, radius)
    stroke_px = max(2, round(BEVEL_STROKE * tile_px))
    hair_px = max(1, round(BEVEL_HAIR * tile_px))
    outer = squircle(tile_px, radius=radius)
    inner = squircle(tile_px, inset=stroke_px, canvas=tile_px, radius=radius)
    deeper = squircle(tile_px, inset=stroke_px + hair_px, canvas=tile_px, radius=radius)
    hair = Image.new("RGBA", (tile_px, tile_px), (0, 0, 0, 0))
    hair.putalpha(ImageChops.subtract(inner, deeper).point(lambda v: round(v * BEVEL_HAIR_ALPHA)))
    canvas.alpha_composite(hair, (off, off))
    stroke = Image.new("RGBA", (tile_px, tile_px), (255, 255, 255, 0))
    stroke.putalpha(ImageChops.multiply(ImageChops.subtract(outer, inner), around_mask(tile_px, BEVEL_TOP[kind])))
    canvas.alpha_composite(stroke, (off, off))
    rim = {"kind": kind, "edgeLuminance": round(lum, 3), "strokeTopAlpha": BEVEL_TOP[kind],
           "strokePx": round(stroke_px * OUT / WORK, 2), "hairPx": round(hair_px * OUT / WORK, 2)}
    return canvas.resize((OUT, OUT), Image.LANCZOS), rim


def place(img, k, centre, size):
    """The logo scaled by k, with `centre` (working px) at the middle of a layer."""
    scaled = img.resize((max(1, round(img.width * k)), max(1, round(img.height * k))), Image.LANCZOS)
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    layer.paste(scaled, (round(size / 2 - centre[0] * k), round(size / 2 - centre[1] * k)))
    return layer


def plate_content(img, box, ring):
    """A plate cropped inside its frame, scaled to cover the tile with overscan."""
    x0, y0, x1, y1 = box
    crop = img.crop((x0 + ring, y0 + ring, x1 - ring, y1 - ring))
    cw, ch = crop.size
    a = crop.getchannel("A").point(lambda v: 255 if v >= THRESHOLD else 0)
    inner = Image.new("L", (cw, ch), 0)
    m = round(0.08 * min(cw, ch))
    inner.paste(255, (m, m, cw - m, ch - m))
    band = ImageChops.subtract(a, inner)
    stat = ImageStat.Stat(crop.convert("RGB"), band)
    fill = tuple(stat.mean)
    # Flat: most of the border band sits close to one colour (a glyph or a
    # little art may reach into it).
    small = crop.convert("RGB").resize((64, 64), Image.BOX).tobytes()
    bandsmall = band.resize((64, 64), Image.BOX).tobytes()
    px = [(small[i * 3], small[i * 3 + 1], small[i * 3 + 2]) for i in range(64 * 64) if bandsmall[i] >= 128]
    flat = False
    if px:
        med = tuple(sorted(p[k] for p in px)[len(px) // 2] for k in range(3))
        near = sum(1 for p in px if sum(abs(p[k] - med[k]) for k in range(3)) / 3 < 14)
        flat = near / len(px) >= 0.80
    return crop, fill, flat


def tile_for(token_src, opts, card_luminance):
    path = better_source(token_src)
    radius = max(0.15, min(0.30, float(opts.get("radius", CORNER_RADIUS))))
    img, source_px = rasterize(path, opts.get("accent"))
    mask, box, trimmed = measure(img)
    w, h = box[2] - box[0], box[3] - box[1]
    area = mask.histogram()[255]
    fill = area / (w * h)
    tw, th = trimmed[2] - trimmed[0], trimmed[3] - trimmed[1]
    aspect = tw / th
    cls = classify(aspect, fill, corners_empty(mask, box))
    plate = is_plate(mask, box)
    census = colour_census(img)
    # The logo's main colour: the mean of its strongest hue family when colour
    # carries the logo, else its most populous colour.
    main = census["mean"] if census["strong"] >= 0.35 else main_colour(img)[0]
    lum = ImageStat.Stat(img.convert("L"), mask).mean[0] / 255
    multicolour = census["strong"] > 0.10 and census["others"] > 0.25 * max(census["family"], 1e-6) and census["others"] > 0.04

    # which tile modes are possible, with their colours and contrast
    modes = {}
    if plate:
        modes["plate"] = {"colors": None, "contrast": None}
    def tile_mode(name, colours):
        mid = mix(hex_rgb(colours[0]), hex_rgb(colours[1]), 0.5)
        c = contrast(main, mid)
        if c >= MIN_CONTRAST:
            modes[name] = {"colors": list(colours), "contrast": round(c, 2)}
        return c
    contrast_white = tile_mode("white", WHITE_TILE)
    contrast_graphite = tile_mode("graphite", GRAPHITE_TILE)
    symbol = None
    brand_note = ""
    if not plate and not multicolour and census["strong"] >= 0.35 and census["white"] >= 0.15 and census["others"] <= 0.20:
        sym_alpha, sym_share, sym_partial = white_symbol(img, mask)
        if 0.05 <= sym_share <= 0.55 and sym_partial <= 0.30:
            base = census["mean"]
            top, bottom = mix(base, (255, 255, 255), BRAND_LIGHTER), mix(base, (0, 0, 0), BRAND_DARKER)
            modes["brand"] = {"colors": [rgb_hex(top), rgb_hex(bottom)],
                              "contrast": round(contrast((255, 255, 255), mix(top, bottom, 0.5)), 2)}
            symbol = sym_alpha
        else:
            brand_note = "symbol does not cut out cleanly"

    # the mode the rules pick
    if plate:
        picked = "plate"
    elif "graphite" in modes and (census["white"] >= 0.55 or lum >= 0.85):
        picked = "graphite"
    elif "brand" in modes:
        picked = "brand"
    elif "white" in modes:
        picked = "white"
    elif "graphite" in modes:
        picked = "graphite"
    else:
        picked = "white"
        modes["white"] = {"colors": list(WHITE_TILE), "contrast": round(contrast_white, 2), "forced": True}
    mode = opts.get("mode") or picked
    if mode not in modes:  # an override may ask for a mode the rules would skip
        colours = {"white": WHITE_TILE, "graphite": GRAPHITE_TILE}.get(mode)
        modes[mode] = {"colors": list(colours) if colours else None, "contrast": None, "override": True}
    colours = modes[mode]["colors"]
    if opts.get("top") and opts.get("bottom"):
        colours = [opts["top"], opts["bottom"]]
    tile_colours = (hex_rgb(colours[0]), hex_rgb(colours[1])) if colours else None

    ring, flat = 0, False
    if mode == "plate":
        ring = frame_inset(img, box) if plate else 0
        crop, edge_fill, flat = plate_content(img, box, ring)
        def content(size):
            cover = round(size * OVERSCAN)
            k = cover / min(crop.size)
            scaled = crop.resize((round(crop.width * k), round(crop.height * k)), Image.LANCZOS)
            # the plate's own corners are clear: the fill colour shows through them
            under = Image.new("RGBA", (size, size), tuple(round(v) for v in edge_fill) + (255,))
            under.paste(scaled, (round((size - scaled.width) / 2), round((size - scaled.height) / 2)), scaled)
            return under
        canvas, rim = render_tile(content, None, flat, radius)
    else:
        fit = TILE_FIT[cls]
        if cls == "circle":
            centre = ((box[0] + box[2]) / 2, (box[1] + box[3]) / 2)
            k_of = lambda size: min(fit[0] * size / w, fit[1] * size / h)
        elif cls == "irregular":
            centre = ((trimmed[0] + trimmed[2]) / 2, (trimmed[1] + trimmed[3]) / 2)
            rad = radius_of(mask, centre)
            k_of = lambda size: fit * size / 2 / rad
        else:
            centre = ((trimmed[0] + trimmed[2]) / 2, (trimmed[1] + trimmed[3]) / 2)
            k_of = lambda size: min(fit[0] * size / tw, fit[1] * size / th)
        if mode == "brand" and symbol is not None:
            logo = Image.new("RGBA", img.size, (255, 255, 255, 0))
            logo.putalpha(symbol)
        elif mode == "brand":
            logo = img
        else:
            logo = img
        def content(size):
            return place(logo, k_of(size), centre, size)
        canvas, rim = render_tile(content, tile_colours, False, radius)

    tile_box = canvas.getchannel("A").point(lambda v: 255 if v >= THRESHOLD else 0).getbbox()
    meta = {
        "style": "squircle", "tileBox": tile_box, "canvasFactor": CANVAS_FACTOR, "radius": radius, "rim": rim, "class": cls, "plate": plate, "mode": mode, "picked": picked,
        "modes": modes, "brandNote": brand_note,
        "colors": colours, "contrast": modes[mode]["contrast"],
        "mainColor": rgb_hex(main), "meanLuminance": round(lum, 4),
        "aspect": round(aspect, 4), "fill": round(fill, 4), "multicolour": multicolour,
        "frameInset": ring, "flatPlate": flat,
        "lowRes": source_px is not None and source_px < LOWRES, "source": path, "version": VERSION,
    }
    return canvas, meta


def is_plate(mask, box):
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    if not 0.92 <= w / h <= 1.08:
        return False
    t = max(2, round(min(w, h) * 0.012))  # a thin strip along the edge
    strips = [(x0 + w // 4, y0, x1 - w // 4, y0 + t), (x0 + w // 4, y1 - t, x1 - w // 4, y1),
              (x0, y0 + h // 4, x0 + t, y1 - h // 4), (x1 - t, y0 + h // 4, x1, y1 - h // 4)]
    for s in strips:
        part = mask.crop(s)
        if part.histogram()[255] / max(1, part.width * part.height) < 0.90:
            return False
    return True


def slot_fit(src, opts):
    """Downloads and Trash: bare logos inside the same box as a tile, bottom on
    the tile's bottom, never taller or wider than the tile, about 0.92 of its
    height or width."""
    path = better_source(src)
    img, source_px = rasterize(path, opts.get("accent"))
    mask, box, trimmed = measure(img)
    w, h = box[2] - box[0], box[3] - box[1]
    tile_out = OUT * TILE
    s = min(0.92 * tile_out / w, 0.92 * tile_out / h)
    size = max(1, round(WORK * s))
    scaled = img.resize((size, size), Image.LANCZOS)
    canvas = Image.new("RGBA", (OUT, OUT), (0, 0, 0, 0))
    # Centred on the tile's centre line, which is the canvas centre: the shadow margin is
    # symmetric and plays no part in finding it.
    cx, cy = (box[0] + box[2]) / 2, (box[1] + box[3]) / 2
    canvas.paste(scaled, (round(OUT / 2 - cx * s), round(OUT / 2 - cy * s)))
    drawn = canvas.getchannel("A").point(lambda v: 255 if v >= THRESHOLD else 0).getbbox()
    meta = {"style": "slot", "class": "slot", "canvasFactor": CANVAS_FACTOR, "mode": "slot", "box": drawn,
            "extent": [round(w * s / tile_out, 4), round(h * s / tile_out, 4)],  # fractions of the tile side
            "lowRes": source_px is not None and source_px < LOWRES, "source": path, "version": VERSION}
    return canvas, meta


# ======================= driver =======================

def parse_token(token):
    opts = {}
    src = token
    if "|" in token:
        head, src = token.split("|", 1)
        for pair in head.split(","):
            if "=" in pair:
                k, v = pair.split("=", 1)
                opts[k.strip()] = v.strip()
    return opts, src


def key_for(src, opts, card_luminance):
    st = os.stat(src)
    # the accent only matters for an SVG template
    keyed = {k: v for k, v in opts.items() if k != "accent" or is_template(src)}
    flat = ",".join("%s=%s" % (k, keyed[k]) for k in sorted(keyed))
    raw = "|".join([str(VERSION), flat, "%.2f" % card_luminance, os.path.realpath(src), str(st.st_mtime_ns)])
    return hashlib.sha1(raw.encode()).hexdigest()[:20]


def process(token, cache, card_luminance):
    opts, name = parse_token(token)
    style = opts.get("style", "squircle")
    src = resolve(name)
    key = key_for(src, opts, card_luminance)
    png, meta_path = os.path.join(cache, key + ".png"), os.path.join(cache, key + ".json")
    if not (os.path.exists(png) and os.path.exists(meta_path)):
        if style == "bare":
            canvas, meta = bare_fit(src, card_luminance)
        elif style == "slot":
            canvas, meta = slot_fit(src, opts)
        else:
            canvas, meta = tile_for(src, opts, card_luminance)
        os.makedirs(cache, exist_ok=True)
        canvas.save(png + ".tmp", "PNG")
        with open(meta_path + ".tmp", "w") as f:
            json.dump(meta, f)
        os.replace(png + ".tmp", png)  # the PNG last: its presence means ready
        os.replace(meta_path + ".tmp", meta_path)
    with open(meta_path) as f:
        return {"src": token, "png": png, "meta": json.load(f)}


def prune(cache):
    """Drops cache entries of older normalizer versions."""
    try:
        for name in os.listdir(cache):
            if not name.endswith(".json"):
                continue
            path = os.path.join(cache, name)
            try:
                with open(path) as f:
                    stale = json.load(f).get("version") != VERSION
            except Exception:
                stale = True
            if stale:
                os.remove(path)
                if os.path.exists(path[:-5] + ".png"):
                    os.remove(path[:-5] + ".png")
    except OSError:
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", required=True)
    ap.add_argument("--card-luminance", type=float, default=0.1)
    ap.add_argument("sources", nargs="+")
    a = ap.parse_args()
    lum = round(max(0.0, min(1.0, a.card_luminance)) / 0.02) * 0.02
    results = []
    for src in a.sources:
        try:
            results.append(process(src, a.cache, lum))
        except Exception as e:  # one bad icon never stops the batch
            results.append({"src": src, "error": "%s: %s" % (type(e).__name__, e)})
    json.dump(results, sys.stdout)
    prune(a.cache)


if __name__ == "__main__":
    main()
