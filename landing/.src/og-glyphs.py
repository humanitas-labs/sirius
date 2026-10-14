# glyphs.py card.png [bg.png] : glyph bounds of the wordmark and tagline on a 1200x630 card, from its difference with the bare background
import sys, numpy as np; from PIL import Image
C = np.asarray(Image.open(sys.argv[1]).convert('RGB')).astype(float)
if len(sys.argv) > 2: Bg = np.asarray(Image.open(sys.argv[2]).convert('RGB')).astype(float)
else: Bg = np.zeros_like(C)
D = (C - Bg).mean(2)
def box(y0, y1, thr):
  m = D[y0:y1] > thr; ys, xs = np.nonzero(m)
  if len(xs) == 0: return None
  # drop isolated star pixels: keep columns/rows with enough hits
  return xs.min(), xs.max(), ys.min() + y0, ys.max() + y0
for name, (y0, y1, thr) in {'wordmark': (240, 330, 90), 'tagline': (330, 380, 45)}.items():
  b = box(y0, y1, thr)
  x0, x1, t, bt = b
  print(f'{name}: x {x0}-{x1} (centre {(x0 + x1 + 1) / 2:.1f}), y {t}-{bt} (centre {(t + bt + 1) / 2:.1f})')
