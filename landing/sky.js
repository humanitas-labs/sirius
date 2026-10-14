// Sirius landing: the night sky as one live scene. Static layers come from the Figma mock
// ("Landing · new moon", 38:8) via .src/plates.py; motion, water and meteors are computed here.
// World coordinates are the mock's pan-end frame: x 0..1512, horizon at y 805, sky top at y -385.

const W0 = 1512, H0 = 982, HZ = 805, SKY_TOP = -385, WATER_END = 982;
const meta = await (await fetch("assets/plates.json")).json();
const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;

const canvas = document.getElementById("sky");
const gl = canvas.getContext("webgl2", { antialias: false, alpha: false, powerPreference: "high-performance" });
const lockup = document.getElementById("lockup");
const label = document.getElementById("label");
if (!gl) {
  canvas.outerHTML = '<img class="fallback" src="assets/poster.jpg" alt="">';
  throw new Error("WebGL2 unavailable");
}

const VERT = `#version 300 es
void main() { vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2); gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0); }`;

const FRAG = `#version 300 es
precision highp float;
out vec4 outColor;
uniform vec2 uRes;        // drawing-buffer px
uniform float uPx;        // world px per buffer px
uniform vec2 uView;       // world coords of the top-left of the screen
uniform float uTime;
uniform float uLockOff;   // how far the lockup is dropped below its mock position on wide windows (world px)
uniform vec2 uHover;      // hover per constellation: Scorpius, Orion
uniform float uFade;
uniform float uWordA;
uniform vec4 uMet;        // meteor: start xy, angle, length
uniform vec3 uMetT;       // meteor progress 0..1, brightness, seconds since it burnt out
uniform vec3 uMetC;       // meteor trail tint, picked per meteor
uniform sampler2D uSky, uStars, uScorp, uShore, uWord, uFlare, uFlareHalo, uTStar;
uniform vec4 uFlareHaloP, uTStarP;  // radial profiles: centre xy, radius step, entries
uniform vec4 uScorpBox, uWordBox, uFlareBox, uOriBox;
uniform sampler2D uOri;
uniform float uSkyGain, uSkyRows, uShoreScale;

float hash(vec3 p) { p = fract(p * 0.3183099 + 0.1); p *= 17.0; return fract(p.x * p.y * p.z * (p.x + p.y + p.z)); }
float noise(vec3 x) {
  vec3 i = floor(x), f = fract(x); f = f * f * (3.0 - 2.0 * f);
  return mix(mix(mix(hash(i), hash(i + vec3(1,0,0)), f.x), mix(hash(i + vec3(0,1,0)), hash(i + vec3(1,1,0)), f.x), f.y),
             mix(mix(hash(i + vec3(0,0,1)), hash(i + vec3(1,0,1)), f.x), mix(hash(i + vec3(0,1,1)), hash(i + vec3(1,1,1)), f.x), f.y), f.z);
}
vec4 boxTex(sampler2D t, vec4 box, vec2 wp) {
  vec2 uv = (wp - box.xy) / box.zw;
  if (any(lessThan(uv, vec2(0))) || any(greaterThan(uv, vec2(1)))) return vec4(0);
  return texture(t, uv);
}
// A float radial profile, averaged over the pixel's footprint so a sub-pixel core neither aliases nor shimmers mid-pan.
vec3 radial(sampler2D t, vec4 p, vec2 wp) {
  float h = 0.25 * uPx, R = p.z * p.w;
  if (length(wp - p.xy) > R + 2.0 * h) return vec3(0);
  vec3 c = vec3(0);
  for (int i = 0; i < 4; i++) {
    vec2 o = vec2(i == 1 || i == 3 ? h : -h, i >= 2 ? h : -h);
    c += texture(t, vec2((length(wp + o - p.xy) / p.z + 0.5) / p.w, 0.5)).rgb;
  }
  return c * 0.25;
}
// A young crescent low over the water, shaded as a lit sphere: the sun sits just behind the moon, so
// Lambert shading leaves a thin crescent with tapering horns and a soft terminator. Pale cream, warming
// toward gold only low on the disc (horizon extinction); faint maria, earthshine and haze take a little
// of the night's blue.
const vec3 MOON = vec3(1186.0, 626.0, 42.0);   // big and fairly low: the moon illusion near the horizon
vec3 moon(vec2 wp) {
  vec2 d = wp - MOON.xy; float r = length(d), R = MOON.z;
  if (r > R * 7.0) return vec3(0);
  float aa = max(uPx, 0.3);
  float disc = smoothstep(R + aa, R - aa, r);
  vec2 q = d / R;
  vec3 n = vec3(q, sqrt(max(0.0, 1.0 - dot(q, q))));                        // sphere normal, z toward us
  vec3 sun = normalize(vec3(normalize(vec2(0.55, 0.84)) * 0.6, -0.8));   // below right and behind
  float ndl = dot(n, sun);
  float lit = smoothstep(-0.08, 0.22, ndl) * (0.5 + 0.5 * clamp(ndl / 0.6, 0.0, 1.0));
  lit *= mix(0.72, 1.0, sqrt(n.z));                                         // limb darkening
  float alb = 1.0 - 0.16 * smoothstep(0.42, 0.72, noise(n * 2.6 + 11.0)) - 0.06 * noise(n * 9.0 + 3.0);   // maria, kept faint
  vec3 tint = mix(vec3(1.0, 0.97, 0.9), vec3(1.0, 0.87, 0.7), smoothstep(0.1, 1.0, q.y));
  vec3 c = tint * lit * alb * disc * 1.05;
  c += vec3(0.12, 0.14, 0.2) * 0.022 * alb * disc * (1.0 - smoothstep(-0.05, 0.2, ndl));   // earthshine
  float o = max(r - R, 0.0);
  vec3 haze = vec3(0.8, 0.82, 0.9);
  c += haze * (exp(-o * o / 5000.0) * 0.016 + exp(-o * o / 400.0) * 0.012);   // haze lies in front of the disc too
  return c;
}
float shoreTop(float x) { return HZ_ - texture(uShore, vec2(x / 1512.0, 0.5)).r * 255.0 / uShoreScale; }

vec3 meteor(vec2 wp) {
  if (uMetT.y <= 0.0) return vec3(0);
  vec2 dir = vec2(cos(uMet.z), sin(uMet.z));
  float p = uMetT.x, after = uMetT.z;   // after: seconds since the head burnt out; the trail lingers
  vec2 head = uMet.xy + dir * uMet.w * p;
  float trail = uMet.w * 0.55 * min(1.0, p * 2.5);
  vec2 d = wp - head;
  float a = clamp(dot(d, -dir), 0.0, trail);
  float dist = length(d + dir * a);
  float along = 1.0 - a / max(trail, 1e-3);
  float fade = smoothstep(0.0, 0.12, p) * mix(1.0, 0.75, p) * exp(-after / 0.11) * uMetT.y;
  float line = exp(-dist * dist / (0.55 + 0.5 * along)) * along * along;
  float glow = (exp(-dot(d, d) / 18.0) * 0.6 + exp(-dot(d, d) / 1.2)) * step(after, 0.0);
  // The head burns near-white; just behind it the trail takes the meteor's own colour, vivid to the tail.
  vec3 head3 = vec3(0.95, 0.97, 1.0);
  vec3 trailC = mix(head3, uMetC * 1.15, smoothstep(0.98, 0.8, along));
  return (trailC * line * 1.1 + mix(head3, uMetC, 0.25) * glow) * fade;
}

// Meteors fly too high for their mirror images to land in the frame, but rippled water still catches them,
// as it does the moon: a broken column of glints under the head that follows it across and lingers a moment.
vec3 meteorGlade(vec2 wp, float depth, float k, float dx, float t) {
  if (uMetT.y <= 0.0) return vec3(0);
  float hx = uMet.x + cos(uMet.z) * uMet.w * uMetT.x;
  float gx = (wp.x + dx * 1.2 - hx) / (5.0 + 14.0 * k);
  float g = smoothstep(0.4, 0.9, noise(vec3(wp.x * 0.15 + 5.0, depth * 1.6, t * 1.3)));
  float f = smoothstep(0.0, 0.12, uMetT.x) * exp(-uMetT.z / 0.18) * uMetT.y;
  return mix(vec3(0.95, 0.97, 1.0), uMetC, 0.5) * exp(-gx * gx) * (0.05 + 0.7 * g * g) * f * (1.0 - 0.5 * k);
}

// Point lights only: stars, Scorpius, the meteor and the pinned flare. Cheap enough to sample many times.
vec3 lights(vec2 wp) {
  vec3 st = texture(uStars, vec2(wp.x / 1512.0, (wp.y - float(${SKY_TOP})) / float(${HZ - SKY_TOP}))).rgb;
  float tw = noise(vec3(wp * 0.45, uTime * 1.1)) * 0.6 + noise(vec3(wp * 0.9 + 40.0, uTime * 2.3)) * 0.4;
  vec3 c = st * mix(0.55, 1.35, tw) * smoothstep(MOON.z - 0.5, MOON.z + 0.5, length(wp - MOON.xy));   // the moon hides the stars behind it
  c += boxTex(uScorp, uScorpBox, wp).rgb * mix(1.0, 2.1, uHover.x);
  c += moon(wp);
  c += meteor(wp);
  // The pinned lockup's lights live in the sky so they screen over it and reflect.
  vec2 lp = wp - vec2(0, uLockOff);
  c += boxTex(uOri, uOriBox, lp).rgb * mix(1.0, 2.1, uHover.y);   // Orion sits above the title and drops with it
  c += (boxTex(uFlare, uFlareBox, wp).rgb + radial(uFlareHalo, uFlareHaloP, wp)) * (0.94 + 0.06 * sin(uTime * 0.7));
  c += radial(uTStar, uTStarP, lp) * (0.85 + 0.15 * sin(uTime * 1.05));
  return c;
}

// Everything above the water, in display units (0..1).
vec3 sky(vec2 wp, float px) {
  float v = (wp.y - float(${SKY_TOP})) / (uSkyRows * 2.0);
  vec3 c = texture(uSky, vec2(wp.x / 1512.0, clamp(v, 0.0, 1.0))).rgb / uSkyGain + lights(wp);
  float top = shoreTop(wp.x);
  float land = smoothstep(top - px, top + px, wp.y);
  return mix(c, vec3(0.0, 0.002, 0.006), land);
}

void main() {
  vec2 sp = vec2(gl_FragCoord.x, uRes.y - gl_FragCoord.y);
  vec2 wp = uView + sp * uPx;
  vec3 col;
  if (wp.y < HZ_) {
    col = sky(wp, uPx);
  } else {
    float depth = wp.y - HZ_;
    float k = depth / float(${WATER_END - HZ});
    // Ripples: horizontal displacement that grows toward the viewer, drifting slowly.
    float t = uTime;
    float rip = sin(depth * 0.55 - t * 1.1 + 2.0 * noise(vec3(wp.x * 0.012, depth * 0.05, t * 0.15)))
              + 0.6 * sin(depth * 1.3 + t * 1.7 + wp.x * 0.004);
    float dx = rip * (0.6 + 9.0 * k);
    float dy = (noise(vec3(wp.x * 0.02, depth * 0.3, t * 0.4)) - 0.5) * (1.0 + 5.0 * k);
    vec2 m = vec2(wp.x + dx, HZ_ - depth - 0.5 + dy);
    // Haze: a short vertical smear, still at the horizon, longer further out.
    vec3 r = vec3(0); float wsum = 0.0;
    float stp = 0.6 + 4.0 * k;
    for (int i = 0; i < 6; i++) {
      float w = 1.0 - float(i) / 7.0;
      r += sky(m + vec2(0, float(i) * stp), uPx) * w; wsum += w;
    }
    r /= wsum;
    // Lights: every bright point drags a long broken streak toward the viewer (reflect.py's streaks).
    vec3 hi = vec3(0);
    float lstp = 1.5 + 7.0 * k;
    for (int i = 1; i < 11; i++) {
      vec3 s = lights(m + vec2(dx * 0.3, float(i) * lstp));
      hi += max(s - 0.04, 0.0) * (1.0 - float(i) / 11.0);
    }
    float brk = smoothstep(0.25, 0.8, noise(vec3(wp.x * 0.05, depth * 0.7, t * 0.5)));
    float fres = mix(0.45, 0.22, pow(k, 0.7));
    col = vec3(0.004, 0.008, 0.024) + r * fres + hi * 0.95 * (0.35 + 0.65 * brk) * (1.0 - 0.5 * k);
    // Pinned lockup: the wordmark mirrored at the waterline and streaked, as title_reflect.py did,
    // dropped WORD_DROP world px so it sits clear of the waterline.
    vec4 wb = vec4(uWordBox.x, uWordBox.y + uLockOff, uWordBox.zw);
    vec3 wr = vec3(0);
    for (int i = 0; i < 8; i++) {
      vec2 lw = vec2(wp.x + dx * 0.35, 432.0 + WORD_DROP + uLockOff - depth + float(i) * (2.0 + 5.0 * k) + dy * 0.5);
      wr += boxTex(uWord, wb, lw).rgb * (1.0 - float(i) / 8.0);
    }
    col += wr * 0.085 * uWordA * (0.45 + 0.55 * brk) * (1.0 - 0.7 * k);
    // The flare's light path: a column of horizontal glints that widens toward the viewer.
    float gx = (wp.x + dx * 1.2 - 290.0) / (7.0 + 18.0 * k);
    float glint = smoothstep(0.5, 0.95, noise(vec3(wp.x * 0.11, depth * 1.7, t * 0.9)));
    col += vec3(0.62, 0.74, 1.0) * exp(-gx * gx) * (0.03 + 0.42 * glint * glint) * (1.0 - 0.55 * k);
    // The moon sits too high for its mirror image to fall inside the frame, so its light reaches the
    // water as a broken pale-gold column of glints below it, as moonlight does on rippled water.
    float mx = (wp.x + dx * 1.2 - MOON.x) / (6.0 + 16.0 * k);
    float mg = smoothstep(0.55, 0.95, noise(vec3(wp.x * 0.13 + 17.0, depth * 1.5, t * 0.8)));
    col += vec3(1.0, 0.88, 0.7) * exp(-mx * mx) * (0.006 + 0.2 * mg * mg) * (1.0 - 0.55 * k);
    col += meteorGlade(wp, depth, k, dx, t);
    // Swells: soft drifting bands plus a few thin dark troughs.
    float band = noise(vec3(wp.x * 0.003, depth * 0.22 - t * 0.35, 3.0));
    float trough = smoothstep(0.78, 0.95, noise(vec3(wp.x * 0.0015, depth * 0.45 - t * 0.25, 7.0)));
    col *= (0.82 + 0.3 * band) * (1.0 - 0.55 * trough);
    col *= 1.0 - 0.45 * k;
    col += vec3(0.06, 0.08, 0.12) * exp(-depth * depth / (uPx * uPx * 1.2)) * 0.5;   // waterline
  }
  // Dither below one 8-bit step so near-black gradients never band.
  float n = hash(vec3(gl_FragCoord.xy, fract(uTime) * 61.0)) + hash(vec3(gl_FragCoord.yx + 13.0, fract(uTime) * 17.0)) - 1.0;
  outColor = vec4(col * uFade + n / 255.0, 1.0);
}`.replaceAll("HZ_", `float(${HZ})`).replaceAll("WORD_DROP", "12.0");

function shader(type, src) {
  const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
  return s;
}
const prog = gl.createProgram();
gl.attachShader(prog, shader(gl.VERTEX_SHADER, VERT));
gl.attachShader(prog, shader(gl.FRAGMENT_SHADER, FRAG));
gl.linkProgram(prog);
if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog));
gl.useProgram(prog);
gl.bindVertexArray(gl.createVertexArray());
const U = new Proxy({}, { get: (c, k) => (c[k] ??= gl.getUniformLocation(prog, k)) });

async function texture(unit, url, { mip = true, clampEdge = true } = {}) {
  const img = new Image(); img.src = url; await img.decode();
  const t = gl.createTexture();
  gl.activeTexture(gl.TEXTURE0 + unit); gl.bindTexture(gl.TEXTURE_2D, t);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, img);
  if (mip) gl.generateMipmap(gl.TEXTURE_2D);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, mip ? gl.LINEAR_MIPMAP_LINEAR : gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  const wrap = clampEdge ? gl.CLAMP_TO_EDGE : gl.REPEAT;
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, wrap); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, wrap);
  return t;
}
// A 1-px-high half-float texture of RGB per radius step: no 8-bit banding in a dim falloff.
function profile(unit, { c, step, rgb }, uniform) {
  const n = rgb.length / 3, data = new Float32Array(n * 4);
  for (let i = 0; i < n; i++) data.set([rgb[3 * i], rgb[3 * i + 1], rgb[3 * i + 2], 1], 4 * i);
  const t = gl.createTexture();
  gl.activeTexture(gl.TEXTURE0 + unit); gl.bindTexture(gl.TEXTURE_2D, t);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, n, 1, 0, gl.RGBA, gl.FLOAT, data);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  profiles.push(() => gl.uniform4f(U[uniform], c[0], c[1], step, n));
  return t;
}
const profiles = [];
await Promise.all([
  texture(0, "assets/sky.png", { mip: false }),
  texture(1, "assets/stars.png"),
  texture(2, "assets/scorpius.png"),
  texture(3, "assets/shore.png", { mip: false }),
  texture(4, "assets/wordmark.png"),
  texture(5, "assets/flare.png"),
  profile(6, meta.flareHalo, "uFlareHaloP"),
  profile(7, meta.titlestar, "uTStarP"),
  texture(8, "assets/const-ori.png"),
]);
["uSky", "uStars", "uScorp", "uShore", "uWord", "uFlare", "uFlareHalo", "uTStar", "uOri"].forEach((n, i) => gl.uniform1i(U[n], i));
gl.uniform4f(U.uScorpBox, ...meta.scorpius);
gl.uniform4f(U.uWordBox, ...meta.wordmark);
gl.uniform4f(U.uFlareBox, ...meta.flare);
const C = meta.constellations;
gl.uniform4f(U.uOriBox, ...C.ori.box);
profiles.forEach((f) => f());
gl.uniform1f(U.uSkyGain, meta.skyGain);
gl.uniform1f(U.uSkyRows, meta.skyRows);
gl.uniform1f(U.uShoreScale, meta.shoreScale);

// Layout: cover the viewport with the 1512x982 frame; the camera starts at the sky top and ends over the water.
let L = {};
const WORD_AT = 0.41, WORD_BASELINE = 426.5, DOWNLOAD_BOTTOM = 522.4;  // world px at the mock position
function layout() {
  const w = innerWidth, h = innerHeight, dpr = Math.min(devicePixelRatio || 1, 2);
  const s = Math.max(w / W0, h / H0);
  const hv = h / s;
  const left = W0 / 2 - w / (2 * s);
  const startTop = SKY_TOP, endTop = WATER_END - hv;
  canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr);
  gl.viewport(0, 0, canvas.width, canvas.height);
  // A wide window shows a shorter slice of world, which puts the mock's wordmark high on screen. Drop the
  // lockup (wordmark, Download, title star, and the reflection with them) so the baseline sits near
  // WORD_AT of the viewport height, never above its mock position and always clear of the waterline.
  const drop = Math.min(Math.max(0, endTop + WORD_AT * hv - WORD_BASELINE), HZ - 40 - DOWNLOAD_BOTTOM);
  lockup.style.setProperty("--drop", `${drop}px`);
  L = { w, h, dpr, s, left, startTop, endTop, drop };
  lockup.style.transform = `translate(${-left * s}px, ${-endTop * s}px) scale(${s})`;
}
addEventListener("resize", layout);
layout();

// The intro: fade up on the sky top, hold, pan down to the water, then the title focuses in.
const FADE = 1.6, HOLD = 1.2, PAN = 4.5, TITLE = 2.2;
const ease = (x) => x * x * (3 - 2 * x);
const smoother = (x) => x * x * x * (x * (6 * x - 15) + 10);
const q = new URLSearchParams(location.search);   // review: ?pan=0..1 pins the camera, ?meteor freezes one (=o an Orionid, =r a random one; &mc=0..4 its colour; &fly lets it fly)
const pinned = q.has("pan") ? +q.get("pan") : null;
const panAt = (e) => (pinned ?? (reduced ? 1 : smoother(Math.min(1, Math.max(0, (e - HOLD) / PAN)))));
const camAt = (e) => L.startTop + (L.endTop - L.startTop) * panAt(e);

let camTop = camAt(0);
// Hover targets, in uHover order. Hovering one brightens it and shows its name above it.
const FIGS = [{ label: "Scorpius", box: meta.scorpius, lock: false }, { ...C.ori, lock: true }];
const figBox = (f) => (f.lock ? [f.box[0], f.box[1] + L.drop, f.box[2], f.box[3]] : f.box);
const hover = [0, 0];
let hoverOn = false, hoverIdx = 0;
addEventListener("pointermove", (e) => {
  const wx = L.left + e.clientX / L.s, wy = camTop + e.clientY / L.s;
  const i = FIGS.findIndex((f) => { const [x, y, bw, bh] = figBox(f); return wx > x && wx < x + bw && wy > y && wy < y + bh; });
  hoverOn = i >= 0;
  if (hoverOn && i !== hoverIdx) { hoverIdx = i; label.textContent = FIGS[i].label; }
  label.classList.toggle("on", hoverOn);
});

// Meteors: one at a time, every few seconds, inside the visible sky; the first comes after the title.
// Trail colours after real meteor emission: sodium orange and yellow, magnesium and oxygen greens, and
// violet, weighted toward the greens (60%) and violet (20%). The head stays near-white; the trail carries
// the colour. Weights sum to 1.
const METEOR_C = [[[1.0, 0.5, 0.16], 0.14], [[1.0, 0.8, 0.28], 0.06], [[0.32, 1.0, 0.36], 0.38], [[0.3, 0.95, 0.62], 0.22], [[0.74, 0.5, 1.0], 0.2]];
const pickColour = (r = Math.random()) => METEOR_C.find(([, w]) => (r -= w) < 0)?.[0] ?? METEOR_C[0][0];
const ORIONIDS = 1 / 3;   // share of meteors that radiate from the Orionid radiant by Orion's club
let met = null, nextMet = Infinity;
function spawn(t) {
  const hv = L.h / L.s;
  const len = 160 + Math.random() * 180, speed = 390 + Math.random() * 710;   // world px/s, between the old pace and 2.8x it
  let x, y, a;
  if (q.get("meteor") === "o" || (q.get("meteor") !== "r" && Math.random() < ORIONIDS)) {
    // Away from the radiant in any direction, starting a little out from it as real ones appear; the
    // radiant sits high, and meteors here only ever fall.
    const rx = C.ori.radiant[0], ry = C.ori.radiant[1] + L.drop;
    a = Math.random() * 2 * Math.PI;
    if (Math.sin(a) < 0) a = -a;   // only ever down the sky
    const off = 25 + Math.random() * 90;
    x = rx + Math.cos(a) * off; y = ry + Math.sin(a) * off;
  } else {
    const right = Math.random() < 0.5;
    const ang = (right ? 1 : -1) * (0.2 + Math.random() * 0.32);
    x = L.left + (0.15 + Math.random() * 0.7) * (L.w / L.s); y = camTop + (0.05 + Math.random() * 0.45) * Math.min(hv, HZ - camTop);
    a = right ? ang : Math.PI - ang;
  }
  met = { x, y, a, len, t0: t, dur: len / speed, b: 0.55 + Math.random() * 0.45, c: q.has("mc") ? METEOR_C[+q.get("mc")][0] : pickColour() };
  nextMet = t + 1.8 + Math.random() * 4.6;
}

const born = performance.now() / 1000;
let settled = null;   // time the camera came to rest
function frame(now) {
  const t = now / 1000, e = t - born;
  camTop = camAt(e);
  if (settled === null && panAt(e) >= 1) {
    settled = t;
    document.body.classList.add("settled");
    nextMet = q.has("meteor") ? t : t + TITLE + 2.5;
  }
  const k = 1 - Math.exp(-Math.min(0.05, t - (frame.last ?? t)) * 4);
  for (let i = 0; i < hover.length; i++) hover[i] += ((hoverOn && i === hoverIdx ? 1 : 0) - hover[i]) * k;
  frame.last = t;
  if (!reduced && t > nextMet && !met) spawn(t);
  let mp = 0, mb = 0, ma = 0;   // progress, brightness, afterglow age
  if (met) {
    const age = t - met.t0;
    mp = q.has("meteor") && !q.has("fly") ? 0.55 : Math.min(1, age / met.dur); mb = met.b; ma = Math.max(0, age - met.dur);
    if (q.has("meteor") && !q.has("fly")) ma = 0;
    else if (ma > 0.5) { met = null; mp = 0; mb = 0; ma = 0; }
  }

  gl.uniform2f(U.uRes, canvas.width, canvas.height);
  gl.uniform1f(U.uPx, 1 / (L.s * L.dpr));
  gl.uniform2f(U.uView, L.left, camTop);
  gl.uniform1f(U.uTime, reduced ? 0 : t % 1000);
  gl.uniform1f(U.uLockOff, L.drop);
  gl.uniform1f(U.uWordA, settled === null ? 0 : reduced ? 1 : ease(Math.min(1, (t - settled) / TITLE)));
  gl.uniform2f(U.uHover, ...hover);
  gl.uniform1f(U.uFade, reduced ? 1 : ease(Math.min(1, e / FADE)));
  gl.uniform4f(U.uMet, met ? met.x : 0, met ? met.y : 0, met ? met.a : 0, met ? met.len : 0);
  gl.uniform3f(U.uMetT, mp, mb, ma);
  gl.uniform3f(U.uMetC, ...(met ? met.c : METEOR_C[0][0]));
  gl.drawArrays(gl.TRIANGLES, 0, 3);

  const [x, y, bw] = figBox(FIGS[hoverIdx]);
  label.style.transform = `translate(${(x + bw / 2 - L.left) * L.s}px, ${(y - 14 - camTop) * L.s}px) translateX(-50%)`;
  if (!reduced || hoverOn || Math.max(...hover) > 0.01) requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
if (reduced) addEventListener("pointermove", () => requestAnimationFrame(frame));
addEventListener("resize", () => requestAnimationFrame(frame));
