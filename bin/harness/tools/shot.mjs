#!/usr/bin/env node
// Bildschirmaufnahme mit echter Gerätebreite.
// Ein Chrome-Fenster ist nie schmaler als 500 px – ein Handy schon. Mit „--window-size=390“ rechnet die Seite deshalb
// mit 500 px, und die Aufnahme schneidet rechts ab. Hier wird die Breite über die Geräte-Emulation gesetzt und
// zusätzlich gemessen, ob der Inhalt breiter ist als der Bildschirm.
//
// Aufruf: node shot.mjs <chrome> <url> <datei.png> <breite> <höhe> [mobil]
// Ausgabe (eine Zeile JSON): {"width":390,"content":390,"overflow":0} – overflow > 0: Inhalt ist breiter als der Bildschirm
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [chrome, url, file, w = '390', h = '844', mobile = ''] = process.argv.slice(2);
if (!chrome || !url || !file) { console.error('usage: shot.mjs <chrome> <url> <file.png> <width> <height> [mobil]'); process.exit(64); }
if (typeof WebSocket === 'undefined' || typeof fetch === 'undefined') { console.error('node too old (needs WebSocket and fetch)'); process.exit(3); }

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const profile = mkdtempSync(join(tmpdir(), 'aos-shot-'));
const proc = spawn(chrome, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run', '--no-default-browser-check',
  ...(process.platform === 'linux' ? ['--no-sandbox'] : []),
  `--user-data-dir=${profile}`, '--remote-debugging-port=0', 'about:blank'], { stdio: 'ignore' });
let finished = false;
const done = async (code, msg) => {
  if (finished) return; finished = true;
  if (msg) console.error(msg);
  const gone = new Promise((res) => { proc.once('exit', res); setTimeout(res, 3000); });
  try { proc.kill('SIGKILL'); } catch {}
  await gone;
  for (let i = 0; i < 5; i++) {
    try { rmSync(profile, { recursive: true, force: true, maxRetries: 3, retryDelay: 150 }); break; } catch { await sleep(200); }
  }
  process.exit(code);
};
setTimeout(() => done(2, 'timeout'), 50000).unref?.();
proc.on('error', (e) => done(4, 'chrome: ' + e.message));

try {
  let port = '';
  for (let i = 0; i < 150 && !port; i++) {
    await sleep(100);
    try { port = readFileSync(join(profile, 'DevToolsActivePort'), 'utf8').split('\n')[0].trim(); } catch {}
  }
  if (!port) await done(5, 'chrome did not start');
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const page = targets.find((t) => t.type === 'page');
  if (!page) await done(5, 'no page');
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error('websocket')); });
  let id = 0; const waiting = new Map(); let onLoad = () => {};
  ws.onmessage = (m) => {
    const d = JSON.parse(m.data);
    if (d.id && waiting.has(d.id)) { waiting.get(d.id)(d); waiting.delete(d.id); }
    else if (d.method === 'Page.loadEventFired') onLoad();
  };
  const send = (method, params = {}) => new Promise((res) => { const i = ++id; waiting.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
  const width = Math.max(240, parseInt(w, 10) || 390), height = Math.max(240, parseInt(h, 10) || 844);
  await send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: mobile ? 2 : 1, mobile: !!mobile });
  if (mobile) await send('Emulation.setTouchEmulationEnabled', { enabled: true });
  await send('Page.enable');
  const loaded = new Promise((res) => { onLoad = res; });
  const nav = await send('Page.navigate', { url });
  if (nav.result?.errorText) await done(6, 'navigate: ' + nav.result.errorText);
  await Promise.race([loaded, sleep(25000)]);
  await sleep(1800);   // Schriften, Bilder, Einblend-Animationen
  const m = await send('Runtime.evaluate', { returnByValue: true, expression:
    '({w: window.innerWidth, c: Math.max(document.documentElement.scrollWidth, document.body ? document.body.scrollWidth : 0)})' });
  const v = m.result?.result?.value ?? {};
  const shot = await send('Page.captureScreenshot', { format: 'png' });
  if (!shot.result?.data) await done(7, 'no screenshot');
  writeFileSync(file, Buffer.from(shot.result.data, 'base64'));
  // Handys verkleinern eine zu breite Seite, statt zu scrollen: dann wächst die Rechenbreite über die Gerätebreite hinaus.
  const content = Math.max(v.c ?? width, v.w ?? width);
  console.log(JSON.stringify({ width, content, overflow: Math.max(0, content - width) }));
  await done(0);
} catch (e) {
  await done(1, String(e?.message ?? e));
}
