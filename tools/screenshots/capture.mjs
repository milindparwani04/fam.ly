// Phone-sized README screenshots of the stock demo family (the Carters). Local only.
//
// Needs: local Supabase running (`pnpm db:start`), a fresh database (`pnpm db:reset`), the web app running
// (`pnpm --filter @famly/web dev`), Docker, and Chrome or Edge installed.
//   node tools/screenshots/capture.mjs            → docs/screenshots/*.png
// Set BROWSER=/path/to/chrome if it isn't found automatically.
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const OUT = join(ROOT, "docs/screenshots");
const APP = "http://127.0.0.1:5173";
const API = "http://127.0.0.1:54321";
const MAILPIT = "http://127.0.0.1:54324";
const DB_CONTAINER = "supabase_db_famly";
const EMAIL = "alex@demo.local";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function anonKey() {
  const env = readFileSync(join(ROOT, "apps/web/.env.local"), "utf8");
  const m = /^VITE_SUPABASE_ANON_KEY=(.+)$/m.exec(env);
  if (!m) throw new Error("VITE_SUPABASE_ANON_KEY missing from apps/web/.env.local");
  return m[1].trim();
}

function psql(sql, file) {
  const args = ["exec", "-i", DB_CONTAINER, "psql", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-q"];
  if (sql) args.push("-c", sql);
  return execFileSync("docker", args, { input: file ? readFileSync(file) : undefined, encoding: "utf8" });
}

async function signIn(key) {
  const headers = { apikey: key, "content-type": "application/json" };
  const sent = Date.now();
  let r = await fetch(`${API}/auth/v1/otp`, { method: "POST", headers, body: JSON.stringify({ email: EMAIL, create_user: true }) });
  if (!r.ok) throw new Error(`OTP request failed: ${r.status} ${await r.text()}`);
  let code = null;
  for (let i = 0; i < 20 && !code; i++) {
    await sleep(500);
    const list = await (await fetch(`${MAILPIT}/api/v1/messages`)).json();
    const msg = list.messages.find((m) => m.To.some((t) => t.Address === EMAIL) && Date.parse(m.Created) >= sent - 2000);
    code = msg ? /\b(\d{6})\b/.exec(msg.Snippet)?.[1] ?? null : null;
  }
  if (!code) throw new Error("No sign-in code arrived in Mailpit");
  r = await fetch(`${API}/auth/v1/verify`, { method: "POST", headers, body: JSON.stringify({ type: "email", email: EMAIL, token: code }) });
  if (!r.ok) throw new Error(`Verify failed: ${r.status} ${await r.text()}`);
  return r.json();
}

function findBrowser() {
  const candidates = [
    process.env.BROWSER,
    "C:/Program Files/Google/Chrome/Application/chrome.exe",
    `${process.env.LOCALAPPDATA}/Google/Chrome/Application/chrome.exe`,
    "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
    "C:/Program Files/Microsoft/Edge/Application/msedge.exe",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
  ].filter(Boolean);
  const hit = candidates.find((p) => existsSync(p));
  if (!hit) throw new Error("No Chrome/Edge found; set BROWSER=/path/to/browser");
  return hit;
}

async function cdp() {
  const port = 9333;
  const profile = mkdtempSync(join(tmpdir(), "famly-shots-"));
  const proc = spawn(findBrowser(), [`--headless=new`, `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`,
    "--no-first-run", "--hide-scrollbars", "--force-color-profile=srgb", "about:blank"], { stdio: "ignore" });
  let pages;
  for (let i = 0; i < 40 && !pages; i++) {
    await sleep(250);
    try { pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json(); } catch { /* not up yet */ }
  }
  const page = pages.find((p) => p.type === "page");
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener("open", r, { once: true }));
  let id = 0;
  const waiting = new Map();
  ws.addEventListener("message", (e) => {
    const msg = JSON.parse(e.data);
    if (msg.id && waiting.has(msg.id)) {
      const { ok, fail } = waiting.get(msg.id);
      waiting.delete(msg.id);
      msg.error ? fail(new Error(msg.error.message)) : ok(msg.result);
    }
  });
  const send = (method, params = {}) => new Promise((ok, fail) => {
    const n = ++id;
    waiting.set(n, { ok, fail });
    ws.send(JSON.stringify({ id: n, method, params }));
  });
  return { send, close: () => { ws.close(); proc.kill(); } };
}

async function main() {
  mkdirSync(OUT, { recursive: true });
  const key = anonKey();
  psql(`insert into app.signup_allowlist (email) values ('${EMAIL}') on conflict do nothing`);
  const session = await signIn(key);
  console.log(psql(null, join(ROOT, "supabase/demo/demo_family.sql")).trim());

  const b = await cdp();
  await b.send("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 3, mobile: true });
  await b.send("Page.enable");
  const js = async (expression) => (await b.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })).result.value;
  const go = async (path, wait = 2500) => { await b.send("Page.navigate", { url: APP + path }); await sleep(wait); };
  const click = async (selector, text) => {
    const ok = await js(`(() => { const els = [...document.querySelectorAll(${JSON.stringify(selector)})];
      const el = ${text ? `els.find((e) => e.textContent.trim().includes(${JSON.stringify(text)}))` : "els[0]"};
      if (el) el.click(); return !!el; })()`);
    if (!ok) throw new Error(`Nothing to click: ${selector} ${text ?? ""}`);
    await sleep(900);
  };
  const shot = async (name) => {
    const { data } = await b.send("Page.captureScreenshot", { format: "png" });
    writeFileSync(join(OUT, `${name}.png`), Buffer.from(data, "base64"));
    console.log(`docs/screenshots/${name}.png`);
  };

  await go("/sign-in", 1500);
  await js(`localStorage.setItem("sb-127-auth-token", ${JSON.stringify(JSON.stringify(session))});
            localStorage.setItem("famly.groupId", "0000dead-0000-4000-8000-0000000000aa"); true`);

  await go("/");
  await shot("01-today");
  await click(".wait-card.rate .wait-primary");
  await click(".star-picker button:nth-child(5)");
  await shot("02-rate");
  await go("/family");
  await shot("03-plans");
  await go("/family?view=stays");
  await js(`(() => { const cells = [...document.querySelectorAll(".mday")];
    const i = cells.findIndex((c) => c.getAttribute("aria-label").includes("Aunt May"));
    cells[i].click(); setTimeout(() => cells[i + 2].click(), 200); return i; })()`);
  await sleep(900);
  await shot("04-stays");
  await go("/activity?show=meals");
  await shot("05-meals");
  await click(".meal-row", "falafel");
  await sleep(800);
  await shot("06-meal-ratings");
  await go("/activity");
  await shot("07-activity");
  await go("/cars");
  await shot("08-cars");
  await go("/");
  await click(".leave-btn");
  await shot("09-leaving");
  await go("/");
  await click(".member", "Maya");
  await shot("10-profile");
  await go("/family/create");
  await shot("11-new-plan");
  b.close();
}

main().catch((e) => { console.error(e); process.exit(1); });
