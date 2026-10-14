"""Easter-egg constellations from Hipparcos (hip.tsv), drawn exactly like the Scorpius plate, into ../assets.

Each figure is a gnomonic projection about an anchor star (north up, east left), scaled in world px per
degree and optionally rotated, as the real sky turns through the night. Orion turns so its belt points at
Sirius, as it does in the sky. Star discs and lines copy Scorpius's measured style (assets/scorpius.png):
flat discs in three sizes, and hairlines, all in its white-blue. Writes const-<key>.png (2x, like the
plates) and adds the boxes, labels and the Orionid radiant to plates.json.
"""
import json, sys
import numpy as np
from PIL import Image

dst = sys.argv[1]
meta = json.load(open(f"{dst}/plates.json"))
HIP = {}
for line in open(__file__.rsplit("/", 1)[0] + "/hip.tsv"):
    f = line.split("\t")
    if len(f) == 5 and f[0].strip().isdigit():
        HIP[int(f[0])] = (float(f[1]), float(f[2]), float(f[3]), float(f[4]))

K = 7.0  # world px per degree, about Scorpius's scale on the plate
SIRIUS = tuple(meta["flareHalo"]["c"])

FIGS = {
    "ori": dict(label="Orion", anchor=26311, at=(1115, 344), fade=0.65,  # right of the title, 10 deg above horizontal from its centre; moves with it
                aim=(25930, 26727, SIRIUS),
                stars=[27989, 25336, 26207, 25930, 26311, 26727, 27366, 24436],
                lines=[(26207, 27989), (26207, 25336), (27989, 26727), (25336, 25930), (25930, 26311), (26311, 26727),
                       (26727, 27366), (25930, 24436)],
                radiant=(95.0, 15.8)),  # Orionids (IMO): RA 6h20m, Dec +15.8
}

def gnomonic(ra, dec, ra0, dec0):
    a, d, a0, d0 = map(np.radians, (ra, dec, ra0, dec0))
    D = np.sin(d) * np.sin(d0) + np.cos(d) * np.cos(d0) * np.cos(a - a0)
    xi = np.cos(d) * np.sin(a - a0) / D
    eta = (np.sin(d) * np.cos(d0) - np.cos(d) * np.sin(d0) * np.cos(a - a0)) / D
    return -np.degrees(xi) * K, -np.degrees(eta) * K  # east is left, north is up

# Scorpius's style, measured from its plate: colour, line peak and half-width, and disc tiers by magnitude
# as (brighter than V, radius in world px, peak).
BLUE = np.array([0.71, 0.81, 1.0])
LINE_PEAK, LINE_HALF = 0.19, 0.25
TIERS = [(1.5, 1.3, 0.43), (2.5, 1.0, 0.33), (99, 0.85, 0.22)]

def place(fig):
    ra0, dec0 = HIP[fig["anchor"]][:2]
    pts = {h: np.array(gnomonic(*HIP[h][:2], ra0, dec0)) for h in fig["stars"]}
    extra = {"radiant": np.array(gnomonic(*fig["radiant"], ra0, dec0))} if "radiant" in fig else {}
    rot = fig.get("rot") or 0.0
    if "aim" in fig:  # turn the figure so a -> b points at the target
        a, b, target = fig["aim"]
        v = pts[b] - pts[a]
        w = np.array(target) - (np.array(fig["at"]) + pts[b])
        rot = np.arctan2(w[1], w[0]) - np.arctan2(v[1], v[0])
    if fig.get("rot") is None and "aim" not in fig:  # Cassiopeia: turn the W level, points down
        a, b = pts[fig["stars"][0]], pts[fig["stars"][-1]]
        rot = -np.arctan2(*(b - a)[::-1])
        if np.mean([p[1] for p in pts.values()]) < (a[1] + b[1]) / 2:
            rot += np.pi
    c, s = np.cos(rot), np.sin(rot)
    R = lambda p: np.array(fig["at"]) + np.array([c * p[0] - s * p[1], s * p[0] + c * p[1]])
    return {h: R(p) for h, p in pts.items()}, {k: R(p) for k, p in extra.items()}, np.degrees(rot)

for key, fig in FIGS.items():
    pts, extra, rot = place(fig)
    xy = np.array(list(pts.values()))
    pad = 10
    x0, y0 = np.floor(xy.min(0) - pad); x1, y1 = np.ceil(xy.max(0) + pad)
    W, H = int((x1 - x0) * 2), int((y1 - y0) * 2)
    SS = 4  # supersample
    yy, xx = (np.mgrid[0:H * SS, 0:W * SS] + 0.5) / (2 * SS)
    yy, xx = yy + y0, xx + x0
    img = np.zeros((H * SS, W * SS, 3))
    fade = fig.get("fade", 1.0)  # a fainter copy of Scorpius's style, not a different one
    line_c = BLUE * LINE_PEAK * fade
    for a, b in fig["lines"]:
        p, q = pts[a], pts[b]
        d = q - p; L = np.hypot(*d); u = d / L
        t = np.clip((xx - p[0]) * u[0] + (yy - p[1]) * u[1], 0, L)
        dist = np.hypot(xx - (p[0] + u[0] * t), yy - (p[1] + u[1] * t))
        img = np.maximum(img, line_c * np.clip((LINE_HALF + 0.25 - dist) / 0.5, 0, 1)[..., None])
    for h, p in pts.items():
        r, peak = next((r, pk) for m, r, pk in TIERS if HIP[h][2] < m)
        disc = np.clip((r + 0.18 - np.hypot(xx - p[0], yy - p[1])) / 0.36, 0, 1)
        img = np.maximum(img, BLUE * peak * fade * disc[..., None])
    img = img.reshape(H, SS, W, SS, 3).mean((1, 3))
    Image.fromarray(np.clip(img * 255 + 0.5, 0, 255).astype(np.uint8)).save(f"{dst}/const-{key}.png", optimize=True)
    entry = {"key": key, "label": fig["label"], "box": [float(x0), float(y0), float(x1 - x0), float(y1 - y0)]}
    entry.update({k: [round(float(v[0]), 2), round(float(v[1]), 2)] for k, v in extra.items()})
    meta.setdefault("constellations", {})[key] = entry
    print(key, "box", entry["box"], "rot %.1f" % rot, {k: entry[k] for k in extra})

json.dump(meta, open(f"{dst}/plates.json", "w"), indent=1)
