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
uniform float uFlareImg;            // review: 1 draws the old spikes image instead of the computed spikes
uniform vec4 uScorpBox, uWordBox, uFlareBox, uOriBox;
uniform sampler2D uOri;
uniform float uSkyGain, uSkyRows, uShoreScale;
uniform vec3 uMoon;       // moon centre xy and radius, world px; layout() pulls it inward on narrow screens
uniform vec2 uSirOff;     // how far layout() moves Sirius from its mock position on narrow screens
uniform float uWordMirror;  // world y the wordmark reflection mirrors about, before the lockup drop
uniform sampler2D uSkyBase, uSkyHaze, uHazeN;  // the sky without its haze; baked: the haze alone (times 8), the haze noise
uniform float uHaze;      // review: 0 keeps the sky texture's smooth haze as it was

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
// The baked haze field: x is the haze density multiplier, about one on average, y the dust lanes, zw a
// displacement in world px that bends the haze's outline.
vec4 hazeNoise(vec2 wp) {
  vec4 t = texture(uHazeN, vec2(wp.x / 1512.0, (wp.y - float(${SKY_TOP})) / float(${HZ - SKY_TOP})));
  return vec4(t.r * 2.2 * (1.0 - 0.6 * t.g), t.g, (t.ba - 0.5) * 90.0);
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
// Lambert shading leaves a thin crescent with tapering horns and a soft terminator. Cool white-blue like
// the stars, with faint maria, a barely-there earthshine and haze in front.
vec3 moon(vec2 wp) {
  vec2 d = wp - uMoon.xy; float r = length(d), R = uMoon.z;
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
  vec3 tint = vec3(0.93, 0.94, 0.97);   // the scene's white-blue, a touch warm
  vec3 c = tint * lit * alb * disc * 1.05;
  c += vec3(0.12, 0.14, 0.2) * 0.022 * alb * disc * (1.0 - smoothstep(-0.05, 0.2, ndl));   // earthshine
  float o = max(r - R, 0.0);
  vec3 haze = vec3(0.77, 0.81, 0.97);
  float hm = uHaze > 0.5 ? mix(1.0, hazeNoise(wp).x, 0.5) : 1.0;   // the same wisps thin and thicken its glow
  c += haze * hm * (exp(-o * o / 5830.0) * 0.016 + exp(-o * o / 467.0) * 0.012);   // haze lies in front of the disc too
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

// Sirius's diffraction spikes, computed: six thin spikes of uneven length off the mock's 57 degree axis, so
// the star reads as Sirius's own rather than a four-point sparkle. Each tapers to its tip and fades as the
// old image did (about exp(-(a/L)^2.2)); its width never drops below the pixel's footprint, with the energy
// kept, so it neither aliases nor shimmers mid-pan. Red reaches a little further than blue, as diffraction
// spreads it, and the whole star scintillates slowly in brightness and hue.
const float SPIKE_LEN[6] = float[6](30.0, 14.0, 10.0, 27.0, 17.0, 8.0);
const float SPIKE_PEAK[6] = float[6](0.6, 0.32, 0.22, 0.55, 0.36, 0.2);
float spike(vec2 d, vec2 u, float len, float w0) {
  float a = dot(d, u);
  if (a <= 0.0) return 0.0;
  float p = d.x * u.y - d.y * u.x, t = a / len;
  float w = w0 * (1.0 - 0.45 * min(t, 1.5));
  float we = sqrt(w * w + 0.3 * uPx * uPx);
  return exp(-p * p / (2.0 * we * we)) * (w / we) * exp(-pow(t, 2.2)) * smoothstep(1.5, 7.0, a);
}
vec3 flareSpikes(vec2 d) {
  if (dot(d, d) > 90.0 * 90.0) return vec3(0);
  vec3 c = vec3(0);
  for (int i = 0; i < 6; i++) {
    float ang = radians(57.0 + 60.0 * float(i));
    vec2 u = vec2(cos(ang), sin(ang));
    float len = SPIKE_LEN[i] * (0.9 + 0.2 * noise(vec3(float(i) * 7.3, uTime * 0.3, 1.0)));   // each breathes on its own
    c += SPIKE_PEAK[i] * vec3(spike(d, u, len * 1.035, 0.53), spike(d, u, len, 0.5), spike(d, u, len * 0.965, 0.47));
  }
  return c;
}
vec3 flare(vec2 wp) {
  vec3 halo = radial(uFlareHalo, uFlareHaloP, wp);
  float n1 = noise(vec3(uTime * 0.45, 3.0, 5.0)), n2 = noise(vec3(uTime * 0.23, 9.0, 1.0));
  float bright = 0.9 + 0.2 * n1;
  if (uFlareImg > 0.5) return (boxTex(uFlare, uFlareBox, wp).rgb + halo) * (0.94 + 0.06 * sin(uTime * 0.7));
  vec3 tint = mix(vec3(0.8, 0.9, 1.0), vec3(0.97, 0.93, 1.0), n2);   // drifts between steel blue and violet-white
  return (flareSpikes(wp - uFlareHaloP.xy) * tint * 1.1 + halo * mix(vec3(1.0), tint * 1.08, 0.35)) * bright;
}

// The title star above SIRIUS: the mock's measured profile drawn TSTAR_SCALE times larger, its glow turned to
// the Sirius steel blue (181, 209, 255) while the core stays near-white, a soft blue halo, and a small flare in
// the style of Sirius's: six spikes on an upright axis, under half as long, two thirds as bright and thinner, steady,
// so it never competes with Sirius itself.
const float TSTAR_SCALE = 1.8;
const float TSTAR_AXIS = 90.0;   // upright, 33 degrees off Sirius's 57 so the two flares never read as copies
const vec3 STEEL = vec3(181.0, 209.0, 255.0) / 255.0;
const float TSPIKE_LEN[6] = float[6](13.0, 6.0, 4.5, 12.0, 7.5, 4.0);
const float TSPIKE_PEAK[6] = float[6](0.4, 0.2, 0.14, 0.36, 0.22, 0.12);
vec3 titleStar(vec2 wp) {
  vec2 d = wp - uTStarP.xy;
  if (dot(d, d) > 60.0 * 60.0) return vec3(0);
  float l = radial(uTStar, vec4(uTStarP.xy, uTStarP.z * TSTAR_SCALE, uTStarP.w), wp).g;
  vec3 c = l * mix(STEEL, vec3(0.95, 0.97, 1.0), smoothstep(0.9, 1.0, l));
  float r2 = dot(d, d);
  c += STEEL * STEEL * (0.11 * exp(-r2 / 50.0) + 0.035 * exp(-r2 / 400.0));
  vec3 sp = vec3(0);
  for (int i = 0; i < 6; i++) {
    float ang = radians(TSTAR_AXIS + 60.0 * float(i));
    sp += TSPIKE_PEAK[i] * spike(d, vec2(cos(ang), sin(ang)), TSPIKE_LEN[i], 0.32);
  }
  return c + sp * mix(STEEL, vec3(1.0), 0.4);
}

// Point lights only: stars, Scorpius, the meteor and the pinned flare. Cheap enough to sample many times.
vec3 lights(vec2 wp) {
  vec3 st = texture(uStars, vec2(wp.x / 1512.0, (wp.y - float(${SKY_TOP})) / float(${HZ - SKY_TOP}))).rgb;
  float tw = noise(vec3(wp * 0.45, uTime * 1.1)) * 0.6 + noise(vec3(wp * 0.9 + 40.0, uTime * 2.3)) * 0.4;
  vec3 c = st * mix(0.55, 1.35, tw) * smoothstep(uMoon.z - 0.5, uMoon.z + 0.5, length(wp - uMoon.xy));   // the moon hides the stars behind it
  c += boxTex(uScorp, uScorpBox, wp).rgb * mix(1.0, 2.1, uHover.x);
  c += moon(wp);
  c += meteor(wp);
  // The pinned lockup's lights live in the sky so they screen over it and reflect.
  vec2 lp = wp - vec2(0, uLockOff);
  c += boxTex(uOri, uOriBox, lp).rgb * mix(1.0, 2.1, uHover.y);   // Orion sits above the title and drops with it
  c += flare(wp - uSirOff);
  c += titleStar(lp) * (0.85 + 0.15 * sin(uTime * 1.05));
  return c;
}

// The mock's haze is a few blurred ellipses, smooth to the edge. Split the sky into its haze-free base and
// the haze above it, then break the haze up with the baked noise: domain-warped fBm thins and thickens it
// into wisps, density clumps along the band, and a few dark dust lanes cross it. Thin haze turns slightly
// bluer and dense haze slightly warmer and greyer. The noise averages to one, so the sky keeps its brightness.
vec3 hazeLook(vec3 c, vec2 uv, vec2 wp) {
  vec3 base = min(texture(uSkyBase, uv).rgb, c);
  vec4 n = hazeNoise(wp);
  vec3 h = texture(uSkyHaze, uv + n.zw / vec2(1512.0, uSkyRows * 2.0)).rgb / 8.0;
  vec3 hn = h * n.x;
  float thick = smoothstep(0.004, 0.04, dot(hn, vec3(0.3, 0.5, 0.2)));
  hn *= mix(vec3(0.9, 0.97, 1.1), vec3(1.08, 1.03, 0.9), thick);
  hn = mix(hn, vec3(dot(hn, vec3(0.3, 0.5, 0.2))), 0.2 * thick);
  return base * (1.0 - 0.1 * n.y * smoothstep(0.0, 0.02, h.b)) + hn;
}

// Everything above the water, in display units (0..1).
vec3 sky(vec2 wp, float px) {
  float v = (wp.y - float(${SKY_TOP})) / (uSkyRows * 2.0);
  vec2 uv = vec2(wp.x / 1512.0, clamp(v, 0.0, 1.0));
  vec3 c = texture(uSky, uv).rgb / uSkyGain;
  if (uHaze > 0.5) c = hazeLook(c, uv, wp);
  c += lights(wp);
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
      vec2 lw = vec2(wp.x + dx * 0.35, uWordMirror + WORD_DROP + uLockOff - depth + float(i) * (2.0 + 5.0 * k) + dy * 0.5);
      wr += boxTex(uWord, wb, lw).rgb * (1.0 - float(i) / 8.0);
    }
    col += wr * 0.085 * uWordA * (0.45 + 0.55 * brk) * (1.0 - 0.7 * k);
    // The flare's light path: a column of horizontal glints that widens toward the viewer.
    float gx = (wp.x + dx * 1.2 - 290.0 - uSirOff.x) / (7.0 + 18.0 * k);
    float glint = smoothstep(0.5, 0.95, noise(vec3(wp.x * 0.11, depth * 1.7, t * 0.9)));
    col += vec3(0.62, 0.74, 1.0) * exp(-gx * gx) * (0.03 + 0.42 * glint * glint) * (1.0 - 0.55 * k);
    // The moon sits too high for its mirror image to fall inside the frame, so its light reaches the
    // water as a broken column of glints below it, as moonlight does on rippled water.
    float mx = (wp.x + dx * 1.2 - uMoon.x) / (6.5 + 17.3 * k);
    float mg = smoothstep(0.55, 0.95, noise(vec3(wp.x * 0.13 + 17.0, depth * 1.5, t * 0.8)));
    col += vec3(0.85, 0.89, 0.97) * exp(-mx * mx) * (0.006 + 0.2 * mg * mg) * (1.0 - 0.55 * k);
    col += meteorGlade(wp, depth, k, dx, t);
    // Swells: soft drifting bands plus a few thin dark troughs.
    float band = noise(vec3(wp.x * 0.003, depth * 0.22 - t * 0.35, 3.0));
    float trough = smoothstep(0.78, 0.95, noise(vec3(wp.x * 0.0015, depth * 0.45 - t * 0.25, 7.0)));
    col *= (0.82 + 0.3 * band) * (1.0 - 0.55 * trough);
    col *= 1.0 - 0.45 * k;
    col += vec3(0.06, 0.08, 0.12) * exp(-depth * depth / (uPx * uPx * 1.2)) * 0.5;   // waterline
  }
  // Dither below one 8-bit step so near-black gradients never band: interleaved gradient noise
  // (Jimenez 2014), keyed on the pixel only, so it is +-0.5/255 and stable frame to frame.
  vec2 fc = floor(gl_FragCoord.xy);
  float n = fract(52.9829189 * fract(dot(fc, vec2(0.06711056, 0.00583715)))) - 0.5;
  outColor = vec4(col * uFade + n / 255.0, 1.0);
}`.replaceAll("HZ_", `float(${HZ})`).replaceAll("WORD_DROP", "17.5");

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

const loadImg = async (url) => { const img = new Image(); img.src = url; await img.decode(); return img; };
async function texture(unit, src, { mip = true, clampEdge = true } = {}) {
  const img = typeof src === "string" ? await loadImg(src) : src;
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
const skyImg = await loadImg("assets/sky.png");
await Promise.all([
  texture(0, skyImg, { mip: false }),
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
gl.uniform4f(U.uFlareBox, ...meta.flare);
gl.uniform1f(U.uFlareImg, new URLSearchParams(location.search).get("flare") === "img" ? 1 : 0);
const C = meta.constellations;
gl.uniform4f(U.uOriBox, ...C.ori.box);
profiles.forEach((f) => f());
gl.uniform1f(U.uSkyGain, meta.skyGain);
gl.uniform1f(U.uSkyRows, meta.skyRows);
gl.uniform1f(U.uShoreScale, meta.shoreScale);

// The haze-free sky under the mock's haze: the sky texture at an eighth of its size, a wide minimum filter that
// reaches past the haze to the clear sky around it, then a blur. Rows at and below the shore are left out,
// since the land there is black. Half-float, in display units.
const SHORE_ROW = Math.floor((HZ - 35 - SKY_TOP) / 2);   // sky texture row; the shore rises at most about 30 world px
function skyBase(unit, img) {
  const cv = document.createElement("canvas"); cv.width = img.width; cv.height = img.height;
  const cx = cv.getContext("2d", { willReadFrequently: true }); cx.drawImage(img, 0, 0);
  const src = cx.getImageData(0, 0, img.width, img.height).data;
  const K = 8, w = Math.ceil(img.width / K), h = Math.ceil(img.height / K), rows = Math.floor(SHORE_ROW / K);
  // A box mean or minimum over 2r+1 texels along x or y, clamped at the edges and at the shore.
  const filter = (a, r, horiz, min) => {
    const b = new Float32Array(w * h);
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      let acc = min ? Infinity : 0;
      for (let k = -r; k <= r; k++) {
        const v = horiz ? a[y * w + Math.min(w - 1, Math.max(0, x + k))] : a[Math.min(rows - 1, Math.max(0, y + k)) * w + x];
        acc = min ? Math.min(acc, v) : acc + v;
      }
      b[y * w + x] = min ? acc : acc / (2 * r + 1);
    }
    return b;
  };
  const out = new Float32Array(w * h * 4).fill(1);
  for (let ch = 0; ch < 3; ch++) {
    let a = new Float32Array(w * h);
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      let sum = 0, n = 0;
      for (let j = 0; j < K; j++) for (let i = 0; i < K; i++) {
        const sx = x * K + i, sy = y * K + j;
        if (sx < img.width && sy < img.height) { sum += src[(sy * img.width + sx) * 4 + ch]; n++; }
      }
      a[y * w + x] = sum / n;
    }
    a = filter(filter(a, 20, true, true), 20, false, true);
    for (let i = 0; i < 2; i++) a = filter(filter(a, 7, true), 7, false);
    for (let i = 0; i < w * h; i++) out[i * 4 + ch] = a[i] / 255 / meta.skyGain;
  }
  const t = gl.createTexture();
  gl.activeTexture(gl.TEXTURE0 + unit); gl.bindTexture(gl.TEXTURE_2D, t);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, h, 0, gl.RGBA, gl.FLOAT, out);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
}

// One-off render-to-texture passes. Each draws a fragment shader once into an RGBA8 texture on the given unit.
function bake(unit, w, h, frag, setup = () => {}) {
  const p = gl.createProgram();
  gl.attachShader(p, shader(gl.VERTEX_SHADER, VERT)); gl.attachShader(p, shader(gl.FRAGMENT_SHADER, frag));
  gl.linkProgram(p);
  if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
  const t = gl.createTexture();
  gl.activeTexture(gl.TEXTURE0 + unit); gl.bindTexture(gl.TEXTURE_2D, t);
  gl.texStorage2D(gl.TEXTURE_2D, 1, gl.RGBA8, w, h);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  const fb = gl.createFramebuffer();
  gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t, 0);
  gl.viewport(0, 0, w, h);
  gl.useProgram(p); setup(p); gl.drawArrays(gl.TRIANGLES, 0, 3);
  gl.bindFramebuffer(gl.FRAMEBUFFER, null); gl.deleteFramebuffer(fb); gl.deleteProgram(p);
  gl.useProgram(prog);
}

// The haze alone: the sky texture box-blurred over about 14 texels, so its 8-bit steps cannot show once the
// haze is warped, less the base, stored times 8. Rows below the shore repeat the last sky row.
const HAZE_SKY = `#version 300 es
precision highp float;
out vec4 o;
uniform sampler2D uSky, uSkyBase;
uniform vec2 uSize;
uniform float uGain, uShore;
void main() {
  vec2 uv = gl_FragCoord.xy / uSize;
  vec3 s = vec3(0);
  for (int j = -3; j <= 3; j++) for (int i = -3; i <= 3; i++) {
    vec2 t = (gl_FragCoord.xy + 2.0 * vec2(i, j)) / uSize;
    s += texture(uSky, vec2(t.x, min(t.y, uShore))).rgb;
  }
  o = vec4(clamp((s / 49.0 / uGain - texture(uSkyBase, vec2(uv.x, min(uv.y, uShore))).rgb) * 8.0, 0.0, 1.0), 1.0);
}`;

// The haze noise at one texel per world px over the sky, so the live shader pays one lookup for it.
// Coordinates run along and across the band, stretched along it, so the wisps and lanes lie with the band.
// r: doubly domain-warped fBm (5 octaves) times a slow clumping along the band, the density multiplier over
// 2.2; g: thin ridged filaments where a sparse mask allows, the dust lanes; ba: the second warp, reused as
// the outline displacement.
const HAZE_NOISE = `#version 300 es
precision highp float;
out vec4 o;
float hash(vec2 p) { vec3 q = fract(vec3(p.xyx) * 0.1031); q += dot(q, q.yzx + 33.33); return fract((q.x + q.y) * q.z); }
float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p); f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
  return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
const mat2 ROT = mat2(0.8, -0.6, 0.6, 0.8);
float fbm(vec2 p) {
  float s = 0.0, a = 0.5;
  for (int i = 0; i < 5; i++) { s += a * noise(p); p = ROT * p * 2.03 + 17.0; a *= 0.5; }
  return s / 0.96875;
}
void main() {
  vec2 wp = vec2(gl_FragCoord.x, ${SKY_TOP}.0 + gl_FragCoord.y);
  vec2 ax = normalize(vec2(0.14, 1.0));   // the band runs from upper left of the title down through it
  vec2 d = wp - vec2(700.0, 0.0);
  vec2 q = vec2(dot(d, vec2(ax.y, -ax.x)), dot(d, ax) * 0.65) / 230.0;
  vec2 w1 = vec2(fbm(q + vec2(1.7, 9.2)), fbm(q + vec2(8.3, 2.8)));
  vec2 w2 = vec2(fbm(q + 3.0 * w1 + vec2(4.1, 7.3)), fbm(q + 3.0 * w1 + vec2(6.2, 1.3)));
  float dens = smoothstep(0.2, 0.8, fbm(q + 2.2 * w2));
  float clump = fbm(vec2(dot(d, ax) / 380.0, 3.7));
  float m = mix(0.35, 1.4, dens) * mix(0.75, 1.25, clump);
  float ridge = 1.0 - abs(2.0 * fbm(q * 1.2 + 1.4 * w2 + vec2(31.0, 5.0)) - 1.0);
  float lane = pow(ridge, 7.0) * smoothstep(0.58, 0.74, fbm(q * 0.5 + vec2(50.0, 12.0)));
  o = vec4(m / 2.2, lane, w2);
}`;
const hazeOn = new URLSearchParams(location.search).get("haze") !== "0";   // review: ?haze=0 shows the old smooth haze
if (hazeOn) {
  skyBase(9, skyImg);
  bake(11, skyImg.width, skyImg.height, HAZE_SKY, (p) => {
    gl.uniform1i(gl.getUniformLocation(p, "uSky"), 0); gl.uniform1i(gl.getUniformLocation(p, "uSkyBase"), 9);
    gl.uniform2f(gl.getUniformLocation(p, "uSize"), skyImg.width, skyImg.height);
    gl.uniform1f(gl.getUniformLocation(p, "uGain"), meta.skyGain);
    gl.uniform1f(gl.getUniformLocation(p, "uShore"), (SHORE_ROW - 0.5) / skyImg.height);
  });
  bake(10, W0, HZ - SKY_TOP, HAZE_NOISE);
}
gl.uniform1i(U.uSkyBase, 9); gl.uniform1i(U.uSkyHaze, 11); gl.uniform1i(U.uHazeN, 10);
gl.uniform1f(U.uHaze, hazeOn ? 1 : 0);

// Layout: cover the viewport with the 1512x982 frame; the camera starts at the sky top and ends over the water.
let L = {};
const phoneUI = matchMedia("(pointer: coarse), (max-width: 640px)");   // as in style.css and index.html
const PHONE_LOWER = 0.035;
const CARD = new URLSearchParams(location.search).has("card");   // review: ?card renders without Sirius and the moon, for assets/og.png
const WORD_AT = 0.41, WORD_BASELINE = 426.5, DOWNLOAD_BOTTOM = 522.4;  // world px at the mock position
const MOON = [1186, 626, 45.4];   // big and fairly low: the moon illusion near the horizon
const SIRIUS = meta.flareHalo.c;
const WORD_CX = 756, WORD_CY = 407, WORD_GLYPHS = 390, WORD_MIRROR = 432;   // wordmark centre, glyph span, mirror line
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
  // A phone in portrait drops the whole lockup a further PHONE_LOWER of the view, so it doesn't sit high.
  const lower = phoneUI.matches && h > w ? PHONE_LOWER * hv : 0;
  const drop = Math.min(Math.max(0, endTop + WORD_AT * hv - WORD_BASELINE) + lower, HZ - 40 - DOWNLOAD_BOTTOM);
  lockup.style.setProperty("--drop", `${drop}px`);
  lockup.style.setProperty("--s", s);
  // A window narrower than the mock crops its sides, and on a phone in portrait that loses both the moon and
  // Sirius. Keep each at least a fifth of the view in from its edge, and on the narrowest screens raise
  // Sirius clear of the title star and settle the moon a little lower. A short window crops the top, so
  // Sirius also stays an eighth of the view below it. A full-width window keeps the mock.
  const vw = w / s, narrow = Math.min(1, Math.max(0, (1 - vw / W0) / 0.7));
  const moon = [Math.min(MOON[0], left + 0.8 * vw), MOON[1] + 35 * narrow, MOON[2]];
  const sir = [Math.max(SIRIUS[0], left + 0.2 * vw) - SIRIUS[0], Math.max(-110 * narrow, endTop + 0.12 * hv - SIRIUS[1])];
  if (CARD) { moon[0] += 1e5; sir[0] += 1e5; }   // the OG card leaves both out
  gl.uniform3f(U.uMoon, ...moon);
  gl.uniform2f(U.uSirOff, ...sir);
  // The wordmark shrinks about its centre to fit a narrow screen, and its reflection with it.
  const ws = Math.min(1, (0.78 * vw) / WORD_GLYPHS);
  lockup.style.setProperty("--ws", ws < 1 ? ws : "none");
  const [bx, by, bw, bh] = meta.wordmark;
  gl.uniform4f(U.uWordBox, WORD_CX + (bx - WORD_CX) * ws, WORD_CY + (by - WORD_CY) * ws, bw * ws, bh * ws);
  gl.uniform1f(U.uWordMirror, WORD_CY + (WORD_MIRROR - WORD_CY) * ws);
  L = { w, h, dpr, s, left, startTop, endTop, drop };
  lockup.style.transform = `translate(${-left * s}px, ${-endTop * s}px) scale(${s})`;
}
addEventListener("resize", layout);
layout();

// The intro: fade up on the sky top, hold, pan down to the water, then the title focuses in.
const FADE = 1.6, HOLD = 1.2, PAN = 4.3, TITLE = 2.2;
const ease = (x) => x * x * (3 - 2 * x);
// CSS-style cubic-bezier: a smootherstep-like start, then a long, gentle deceleration so the camera creeps in.
const bezier = (x1, y1, x2, y2) => (x) => {
  if (x <= 0 || x >= 1) return x <= 0 ? 0 : 1;   // exact ends: the bisection only gets close, and the settle check needs 1
  const f = (t, a, b) => 3 * a * t * (1 - t) ** 2 + 3 * b * t * t * (1 - t) + t ** 3;
  let lo = 0, hi = 1;
  for (let i = 0; i < 24; i++) { const m = (lo + hi) / 2; f(m, x1, x2) < x ? (lo = m) : (hi = m); }
  return f((lo + hi) / 2, y1, y2);
};
const panEase = bezier(0.45, 0, 0.15, 1);
const q = new URLSearchParams(location.search);   // review: ?pan=0..1 pins the camera, ?meteor freezes one (=o an Orionid, =r a random one; &mc=0..4 its colour; &fly lets it fly)
const pinned = q.has("pan") ? +q.get("pan") : null;
const panAt = (e) => (pinned ?? (reduced ? 1 : panEase(Math.min(1, Math.max(0, (e - HOLD) / PAN)))));
const camAt = (e) => L.startTop + (L.endTop - L.startTop) * panAt(e);

let camTop = camAt(0);
// Hover targets, in uHover order. Hovering one brightens it and shows its name above it.
const FIGS = [{ key: "sco", label: "Scorpius", box: meta.scorpius, lock: false }, { ...C.ori, lock: true }];
const figBox = (f) => (f.lock ? [f.box[0], f.box[1] + L.drop, f.box[2], f.box[3]] : f.box);
const figAt = (e) => {
  const wx = L.left + e.clientX / L.s, wy = camTop + e.clientY / L.s;
  return FIGS.findIndex((f) => { const [x, y, bw, bh] = figBox(f); return wx > x && wx < x + bw && wy > y && wy < y + bh; });
};
const hover = [0, 0];
let hoverOn = false, hoverIdx = 0;
addEventListener("pointermove", (e) => {
  const i = figAt(e);
  hoverOn = i >= 0;
  if (hoverOn && i !== hoverIdx) { hoverIdx = i; label.textContent = FIGS[i].label; }
  label.classList.toggle("on", hoverOn);
  canvas.style.cursor = hoverOn ? "pointer" : "";
});
// Clicking or tapping a figure sends a "constellation" event.
canvas.addEventListener("click", (e) => {
  const i = figAt(e);
  if (i >= 0) dispatchEvent(new CustomEvent("constellation", { detail: FIGS[i].key }));
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
