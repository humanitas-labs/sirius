# Renders assets/og.png: the page at 1512x982 pan-end, the lockup restyled for the 1200x630 card, clipped at
# world (156, 92), where the Figma frame "OG image · 1200×630" sits (template-matched, scale 1). Args: wordmark
# and tagline x nudges and the tagline's top in world px; -0.5 0.5 427 centres both lines on their glyphs.
# Then: python og-glyphs.py out.png bg.png to check the centring. Run from this folder.
WDX=${1:--0.5}; TDX=${2:-0.5}; TTOP=${3:-427}; OUT=${4:-../assets/og.png}
CSS=".download,.gh,.label{display:none!important}
.wordmark{margin-top:-26px!important;translate:${WDX}px 0}
.tagline{top:${TTOP}px!important;margin-top:0!important;font-size:24px!important;line-height:30px!important;letter-spacing:.02em;color:rgba(200,222,255,.62)!important;translate:${TDX}px 0}"
node shot.mjs "$OUT" 1512 982 1 "pan=1&card" "$CSS" "156,92,1200,630"
