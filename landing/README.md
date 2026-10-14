# Sirius landing page (prototype)

The new-moon mock (Figma "Sirius · Night sky", frame 38:8) made live. The sky is one WebGL shader. The title, Download and GitHub link are HTML on top.

Run it with `python3 .src/serve.py` in this folder (a static server with caching off, so a plain reload picks up changes), then open http://127.0.0.1:8731. The page does not scroll. It plays one intro: fade up on the sky top (1.6 s), hold (1.2 s), pan down to the water (4.3 s, easing in and settling slowly), then SIRIUS blurs into focus (2.2 s) with its reflection fading in, and Download and GitHub follow a beat later. Timings are the constants at the top of the intro block in `sky.js`. `?pan=0..1` pins the camera, `?haze=0` shows the old smooth haze, and `?meteor` freezes a meteor mid-flight (`=o` an Orionid, `=r` a random one, `&mc=0..4` its colour, `&fly` lets it fly); all are for review.

## Hosting

Vercel serves this folder as the project root. `vercel.json` makes `/download` a 302 to the latest GitHub release's `Sirius.dmg`, so a new release needs no site change. `.vercelignore` keeps `.src/` and this README off the site.

## How it works

- The static layers come from the mock. `.src/plates.py` turns the 2x Figma exports in `.src/` (A sky, B stars, C Scorpius, E title lights) into `assets/`. The Sirius flare's halo and the title star are smooth half-float radial profiles measured from E, so their falloff can't band. The flare's spikes are computed in the shader: six thin, tapering spikes of uneven length with a slight chromatic fringe and a slow scintillation (`?flare=img` shows the old spikes image for comparison). The title star above SIRIUS draws its measured profile 1.8× larger (`TSTAR_SCALE`), with a near-white core, a steel-blue (181, 209, 255) rim and soft halo, and a small steady flare on an upright axis (`TSTAR_AXIS`, 90°, 33° off Sirius's 57° so the two never read as copies): six spikes under half as long, two thirds as bright and thinner, without the twinkle in length, so it never competes with Sirius.
- `.src/constellations.py` draws Orion from Hipparcos positions (`.src/hip.tsv`) in Scorpius's measured style, turned so its belt points at Sirius. Run it after `plates.py`.
- The sky texture is stored low-resolution and boosted 6×, so its near-black gradient keeps sub-8-bit precision. The shader divides the boost back out and dithers its final output with interleaved gradient noise (±0.5/255, keyed on the pixel only, so it is stable frame to frame), so nothing bands.
- The mock's haze is a few blurred ellipses, smooth to the edge, and is broken up at load. A haze-free base is taken from the sky texture with a wide minimum filter (in JS, at an eighth of its size), and two one-off render-to-texture passes bake the haze alone (blurred so the texture's 8-bit steps cannot show) and a noise field: doubly domain-warped fBm (5 octaves) for wisps and uneven density, a slow clumping along the band, sparse ridged filaments for a few dark dust lanes, and a warp that bends the ellipses' outlines. The live shader pays three lookups for it. Thin haze turns slightly bluer and dense haze slightly warmer and greyer, the moon's glow takes the same wisps, and the sky's mean brightness stays within about 2% of the mock. It is static. `?haze=0` shows the old smooth haze for comparison.
- **Computed live:**
  - star twinkle
  - meteors, which only ever fall: a third radiate from the Orionid radiant by Orion's club, the rest are random; each flies at 390–1100 px/s, its trail lingers a moment after the head burns out, and it carries sodium orange, yellow, magnesium and oxygen greens, or violet
  - a young crescent moon low on the right, shaded as a lit sphere: cool white-blue like the stars, with faint maria, a barely-there earthshine and haze in front
  - Scorpius and Orion brightening on hover
  - the water, which reflects whatever is in the sky; the moon and meteors fly too high for their mirror images to land in the frame, so they cast broken columns of glints instead
  - the flare's column of glints and the streaked wordmark reflection
  - the fade-in
- The world uses the mock's pan-end coordinates (x 0–1512, horizon at y 805, sky top at y −385). The Sirius flare and the title star belong to the sky, so they drift in with it.
- `prefers-reduced-motion` gets a still frame, and browsers without WebGL2 get `assets/poster.jpg`.

## Narrow screens and phones

- A window narrower than the mock crops its sides. `layout()` in `sky.js` keeps the moon and Sirius at least a fifth of the view in from their edges; on a phone in portrait it also raises Sirius clear of the title star and lowers the moon a little, and on a short window it keeps Sirius below the cropped top. Their water glints follow them. On a phone in portrait the whole lockup (title star, wordmark, tagline, Download, and their reflection) also drops a further 3.5% of the view height (`PHONE_LOWER`). A full-width window keeps the mock's positions exactly.
- On narrow screens SIRIUS shrinks about its centre so its letters span at most 78% of the width, and its reflection shrinks with it.
- On touch or phone-sized screens (`(pointer: coarse), (max-width: 640px)`, in both `style.css` and `index.html`) Download keeps its look at 38 px tall (44 px tap target, 36 px on a phone on its side), reads "AirDrop to Mac" on iOS and iPadOS and "Send to your Mac" elsewhere (Android has no AirDrop), and tapping it opens the share sheet with the page's title, description and URL instead of downloading, since a Mac app can't be installed from a phone. Without `navigator.share` it copies https://trysirius.app and reads "Link copied" for 2 s. A share or copy sends a `share` analytics event; a dismissed share sheet sends nothing. On desktop it still goes to `/download` and sends `download`.

## Link previews

`assets/og.png` (1200×630) is rendered from the live scene, framed like the Figma frame "OG image · 1200×630" (58:18): world x 156–1356, y 92–722 at scale 1, found by template-matching the Figma export (`.src/og-base.png`) against a pan-end render. `.src/og-card.sh` renders it from the page itself with the dev server up (`.src/shot.mjs`, Playwright with a stubbed clock): Download and GitHub hidden, SIRIUS lifted 26 px, the tagline at 24 px, and both lines nudged so their glyphs centre on x 600 (`.src/og-glyphs.py` measures them). It renders with `?card`, which leaves out Sirius and the moon, so only the title star, the background stars, the haze and the constellations remain. `assets/poster.jpg` is the page at 1512×982 pan-end, a full screenshot at JPEG quality 90. `index.html` carries the Open Graph and Twitter card tags for it, and `assets/apple-touch-icon.png` is `assets/icon.svg` rendered at 180×180 on a full square, since iOS rounds the corners itself.

## Not done

- The Scorpius expand state from the Figma prototype is not built; hover only brightens the constellation and shows its name.
- On wide windows SIRIUS, Download, the title star and the reflection drop together so the wordmark sits at about 41% of the height (`WORD_AT` in `sky.js`).
