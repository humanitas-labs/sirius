"""Turn the Figma plate exports (2x, world x 0..1512, y -385..982) into shader textures in ../assets."""
import json, sys
import numpy as np
from PIL import Image, ImageFilter

src, dst = sys.argv[1], sys.argv[2]
Y0 = -385  # world y of plate row 0
H_ROW = lambda wy: int((wy - Y0) * 2)
load = lambda k: Image.open(f"{src}/{k}.png").convert("RGB")
meta = {}

# Sky without stars: min filter removes points, area downsample keeps sub-8-bit precision, stored x GAIN.
A = load("A")
GAIN = 6.0
sky = A.filter(ImageFilter.MinFilter(7)).resize((756, 684), Image.BOX)
s = np.asarray(sky.resize((756, 684)), np.float32)
s = np.asarray(A.filter(ImageFilter.MinFilter(7)), np.float32)
s = s.reshape(684, 4, 756, 4, 3).mean((1, 3)) if s.shape[0] == 2736 else s[:2734 - 2734 % 4].reshape(683, 4, 756, 4, 3).mean((1, 3))
print("sky max", s.max(), "->", s.max() * GAIN)
Image.fromarray(np.clip(s * GAIN + 0.5, 0, 255).astype(np.uint8)).save(f"{dst}/sky.png", optimize=True)
meta["skyGain"] = GAIN
meta["skyRows"] = s.shape[0]

# Far shore: per 2x column, height of the silhouette top above the waterline, in world px.
a = np.asarray(A, np.float32).sum(2)
hz = H_ROW(805)
top = np.full(a.shape[1], hz, np.float32)
for x in range(a.shape[1]):
    col = a[H_ROW(760):hz, x] > 1.5
    lit = np.where(col)[0]
    top[x] = H_ROW(760) + (lit.max() + 1 if len(lit) else 0)
height = (hz - top) / 2.0  # world px
height = np.convolve(height, np.ones(5) / 5, mode="same")
print("shore height world px: min %.1f max %.1f" % (height.min(), height.max()))
Image.fromarray(np.clip(height * 8 + 0.5, 0, 255).astype(np.uint8)[None, :].repeat(2, 0), "L").save(f"{dst}/shore.png")
meta["shoreScale"] = 8

def crop(k, name, box_world=None, pad=8):
    im = load(k); a = np.asarray(im, np.float32).sum(2)
    if box_world:
        x0, y0, x1, y1 = box_world
        b = (int(x0 * 2), H_ROW(y0), int(x1 * 2), H_ROW(y1))
    else:
        ys, xs = np.where(a > 3)
        b = (max(xs.min() - pad, 0), max(ys.min() - pad, 0), xs.max() + pad, ys.max() + pad)
    im.crop(b).save(f"{dst}/{name}.png", optimize=True)
    meta[name] = [b[0] / 2, b[1] / 2 + Y0, (b[2] - b[0]) / 2, (b[3] - b[1]) / 2]  # world x, y, w, h

# Stars (all but Scorpius), sky region only.
B = load("B").crop((0, 0, 3024, H_ROW(805)))
B.save(f"{dst}/stars.png", optimize=True)
meta["stars"] = [0, Y0, 1512, 805 - Y0]
crop("C", "scorpius", pad=16)

# Flare and title star: the 8-bit export bands in the dim halo (1/255 rings) and the star's falloff is grainy,
# so the radially symmetric part becomes a smooth float profile drawn in the shader. Only the flare's spikes,
# minus that profile, stay a texture, cropped well clear of the light and windowed to zero before the edge.
E = np.asarray(load("E"), np.float64)
yy, xx = np.mgrid[0:E.shape[0], 0:E.shape[1]]

def centroid(wx, wy, r=3):
    cx, cy, R = int(wx * 2), H_ROW(wy), int(r * 2)
    sub = E[cy - R:cy + R + 1, cx - R:cx + R + 1].sum(2); w = np.clip(sub - sub.max() * 0.6, 0, None)
    oy, ox = np.mgrid[-R:R + 1, -R:R + 1]
    return (cx + (w * ox).sum() / w.sum()) / 2, (cy + (w * oy).sum() / w.sum()) / 2 + Y0

def radius(c):
    return np.hypot((xx + 0.5) / 2 - c[0], (yy + 0.5) / 2 + Y0 - c[1])

def profile(c, rmax, step=0.25):
    """Trimmed angular mean (drops spikes), smoothed with a widening kernel, tail refit as an exponential."""
    r = radius(c); m = r < rmax + 1; rr, v, L = r[m], E[m] / 255, E[m].sum(1)
    rs = np.arange(0, rmax, step); p = []
    for r0 in rs:
        sel = np.abs(rr - r0) < max(step, 0.6)
        keep = L[sel] <= np.quantile(L[sel], 0.6) if sel.sum() > 8 else slice(None)
        p.append(v[sel][keep].mean(0))
    p = np.array(p)
    sm = np.empty_like(p)
    for i, r0 in enumerate(rs):
        w = np.exp(-0.5 * ((rs - r0) / (0.12 * r0 + 0.15)) ** 2); sm[i] = (w[:, None] * p).sum(0) / w.sum()
    lum = sm.sum(1)
    lo, hi = np.argmax(lum < 3 * 14 / 255), np.argmax(lum < 3 * 3 / 255)  # fit where steps are still >= 3 levels
    if hi > lo + 4:
        for ch in range(3):
            k, b = np.polyfit(rs[lo:hi], np.log(np.maximum(sm[lo:hi, ch], 1e-4)), 1)
            sm[hi:, ch] = np.exp(b + k * rs[hi:])
    sm *= (1 - np.clip((rs / rmax - 0.75) / 0.25, 0, 1) ** 2)[:, None]  # reach zero at rmax
    return sm, step

def radial_meta(name, c, rmax):
    p, step = profile(c, rmax)
    meta[name] = {"c": [round(c[0], 3), round(c[1], 3)], "step": step, "rgb": np.round(p, 5).ravel().tolist()}
    return p, step

fc = centroid(317.5, 280); FR = 66
fp, fstep = radial_meta("flareHalo", fc, FR)
r = radius(fc)
halo = np.stack([np.interp(r, np.arange(len(fp)) * fstep, fp[:, ch], right=0) for ch in range(3)], -1)
spikes = np.clip(E / 255 - halo - 1.5 / 255, 0, None) * (1 - np.clip((r / FR - 0.8) / 0.2, 0, 1) ** 2)[..., None]
x0, y0 = int((fc[0] - FR) * 2), H_ROW(fc[1] - FR); n = FR * 4
Image.fromarray(np.clip(spikes[y0:y0 + n, x0:x0 + n] * 255 + 0.5, 0, 255).astype(np.uint8)).save(f"{dst}/flare.png", optimize=True)
meta["flare"] = [x0 / 2, y0 / 2 + Y0, n / 2, n / 2]
radial_meta("titlestar", centroid(755, 288.5), 16)
crop("E", "wordmark", (540, 360, 972, 456))
json.dump(meta, open(f"{dst}/plates.json", "w"), indent=1)
print(json.dumps(meta))
