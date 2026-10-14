# Sirius landing page (prototype)

The new-moon mock (Figma "Sirius · Night sky", frame 38:8) made live. The sky is one WebGL shader. The title, Download and GitHub link are HTML on top.

Run it with `python3 .src/serve.py` in this folder (a static server with caching off, so a plain reload picks up changes), then open http://127.0.0.1:8731. The page does not scroll. It plays one intro: fade up on the sky top (1.6 s), hold (1.2 s), pan down to the water (4.5 s), then SIRIUS blurs into focus (2.2 s) with its reflection fading in, and Download and GitHub follow a beat later. Timings are the constants at the top of the intro block in `sky.js`. `?pan=0..1` pins the camera, and `?meteor` freezes a meteor mid-flight (`=o` an Orionid, `=r` a random one, `&mc=0..4` its colour, `&fly` lets it fly); all are for review.

## Hosting

Vercel serves this folder as the project root. `vercel.json` makes `/download` a 302 to the latest GitHub release's `Sirius.dmg`, so a new release needs no site change. `.vercelignore` keeps `.src/` and this README off the site.

## How it works

- The static layers come from the mock. `.src/plates.py` turns the 2x Figma exports in `.src/` (A sky, B stars, C Scorpius, E title lights) into `assets/`. The Sirius flare's halo and the title star are smooth half-float radial profiles measured from E, so their falloff can't band; only the flare's spikes stay a texture.
- `.src/constellations.py` draws Orion from Hipparcos positions (`.src/hip.tsv`) in Scorpius's measured style, turned so its belt points at Sirius. Run it after `plates.py`.
- The sky texture is stored low-resolution and boosted 6×, so its near-black gradient keeps sub-8-bit precision. The shader divides the boost back out and dithers the result, so nothing bands.
- **Computed live:**
  - star twinkle
  - meteors, which only ever fall: a third radiate from the Orionid radiant by Orion's club, the rest are random; each flies at 390–1100 px/s, its trail lingers a moment after the head burns out, and it carries sodium orange, yellow, magnesium and oxygen greens, or violet
  - a young crescent moon low on the right, shaded as a lit sphere: pale cream warming to gold near its lower limb, faint maria and earthshine, and haze in front
  - Scorpius and Orion brightening on hover
  - the water, which reflects whatever is in the sky; the moon and meteors fly too high for their mirror images to land in the frame, so they cast broken columns of glints instead
  - the flare's column of glints and the streaked wordmark reflection
  - the fade-in
- The world uses the mock's pan-end coordinates (x 0–1512, horizon at y 805, sky top at y −385). The Sirius flare and the title star belong to the sky, so they drift in with it.
- `prefers-reduced-motion` gets a still frame, and browsers without WebGL2 get `assets/poster.jpg`.

## Not done

- No mobile layout: on a phone the wordmark is wider than the screen.
- The Scorpius expand state from the Figma prototype is not built; hover only brightens the constellation and shows its name.
- On wide windows SIRIUS, Download, the title star and the reflection drop together so the wordmark sits at about 41% of the height (`WORD_AT` in `sky.js`).
