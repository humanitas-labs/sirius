// Needs playwright-core (npm) and Playwright's Chromium; run with the dev server (serve.py) up.
// node shot1.mjs out.png w h dpr "query" ["extra css"] ["clip x,y,w,h"]  -> one deterministic shot (stubbed clock), logs to stdout
import { chromium } from "playwright-core";
const [out, w, h, dpr, qs, css = "", clip = ""] = process.argv.slice(2);
const exe = process.env.HOME + "/Library/Caches/ms-playwright/chromium-1208/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing";
const b = await chromium.launch({ executablePath: exe, args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"] });
const ctx = await b.newContext({ viewport: { width: +w, height: +h }, deviceScaleFactor: +dpr });
const p = await ctx.newPage();
const logs = [];
p.on("console", (m) => logs.push(m.type() + ": " + m.text()));
p.on("pageerror", (e) => logs.push("pageerror: " + e.message));
p.on("requestfailed", (r) => logs.push("reqfailed: " + r.url()));
p.on("response", (r) => { if (r.status() >= 400) logs.push(r.status() + " " + r.url()); });
await p.addInitScript(() => {
  let t = 5000, q = [];
  performance.now = () => t;
  window.requestAnimationFrame = (cb) => { q.push(cb); return q.length; };
  window.__step = (ms) => { t += ms; const run = q; q = []; run.forEach((cb) => cb(t)); return t; };
});
await p.goto("http://127.0.0.1:8731/?" + qs);
await p.waitForLoadState("networkidle");
if (css) await p.addStyleTag({ content: css });
await p.evaluate(() => document.fonts.ready);
await p.waitForTimeout(800);
await p.evaluate(() => __step(12000));
await p.waitForTimeout(4500);
await p.evaluate(() => __step(2600));
await p.waitForTimeout(600);
const opt = { path: out };
if (clip) { const [x, y, cw, ch] = clip.split(",").map(Number); opt.clip = { x, y, width: cw, height: ch }; }
await p.screenshot(opt);
console.log(JSON.stringify(logs));
await b.close();
