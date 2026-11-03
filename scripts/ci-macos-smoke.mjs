// macOS CI smoke test for the real Ekagrachit.app.
//
// Launches the bundled app with an isolated support directory, then plays
// "Chrome + extension" against the real bundled ekagrachit-host over stdio:
//   host_status(appConnected) → hello → hello_ack + sync(null)
//   hello{standalone session} → app adopts → sync(session, preparing)
//   session_closed(sid) → sync(null)
// This exercises app startup, the Unix socket bridge, protocol parsing and the
// coordinator/state machine on macOS. It cannot verify overlays or window
// focus (no Chrome window exists); see docs/testing.md for the manual checklist.
//
// Usage: node scripts/ci-macos-smoke.mjs apps/macos/build/Ekagrachit.app
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';

const app = resolve(process.argv[2] ?? 'apps/macos/build/Ekagrachit.app');
const support = mkdtempSync(join(tmpdir(), 'ek-smoke-'));
const sock = join(support, 'bridge.sock');
const env = { ...process.env, EKAGRACHIT_SUPPORT_DIR: support, EKAGRACHIT_SOCKET: sock };
const fail = (msg) => {
  console.error(`SMOKE FAIL: ${msg}`);
  cleanup();
  process.exit(1);
};

// Simulate a downloaded install: the bundled host carries the quarantine flag;
// the app must clear it at launch so Chrome can execute it.
spawnSync('xattr', ['-w', 'com.apple.quarantine', '0081;00000000;Safari;', join(app, 'Contents/MacOS/ekagrachit-host')]);
const appProc = spawn(join(app, 'Contents/MacOS/Ekagrachit'), [], { env, stdio: ['ignore', 'inherit', 'inherit'] });
let host;
function cleanup() {
  host?.kill();
  appProc.kill();
}
appProc.on('exit', (code, sig) => {
  if (!done) fail(`app exited early (code ${code}, signal ${sig})`);
});

let done = false;
const deadline = Date.now() + 20_000;
while (!existsSync(sock)) {
  if (Date.now() > deadline) fail('bridge socket never appeared');
  await new Promise((r) => setTimeout(r, 200));
}
console.log('app started; socket ready');
// Zero-terminal install: a fresh launch registers the native host with Chrome
// and syncs the bundled extension to a loadable folder.
{
  const { readFileSync } = await import('node:fs');
  const { homedir } = await import('node:os');
  const manifestPath = join(homedir(), 'Library/Application Support/Google/Chrome/NativeMessagingHosts/io.github.thunderboltsid.ekagrachit.json');
  if (!existsSync(manifestPath)) fail('native host manifest was not registered');
  const m = JSON.parse(readFileSync(manifestPath, 'utf8'));
  if (m.path !== join(app, 'Contents/MacOS/ekagrachit-host')) fail(`manifest points at ${m.path}`);
  if (!m.allowed_origins.includes('chrome-extension://dpbpdbflelamfpmehknioljngeaagaeb/')) fail('manifest origin');
  if (!existsSync(join(support, 'Chrome Extension/manifest.json'))) fail('extension folder not synced');
  const q = spawnSync('xattr', ['-p', 'com.apple.quarantine', join(app, 'Contents/MacOS/ekagrachit-host')]);
  if (q.status === 0) fail('quarantine flag still set on the bundled host');
  console.log('host registered, quarantine cleared, extension folder synced');
}
// First launch without an extension: the setup window should appear after ~4 s.
await new Promise((r) => setTimeout(r, 5500));
if (process.env.EK_ARTIFACTS) {
  spawn('screencapture', ['-x', join(process.env.EK_ARTIFACTS, '00-setup-window.png')]);
  await new Promise((r) => setTimeout(r, 1000));
}

host = spawn(join(app, 'Contents/MacOS/ekagrachit-host'), ['chrome-extension://dpbpdbflelamfpmehknioljngeaagaeb/'], { env, stdio: ['pipe', 'pipe', 'inherit'] });
let buf = Buffer.alloc(0);
const inbox = [];
host.stdout.on('data', (d) => {
  buf = Buffer.concat([buf, d]);
  while (buf.length >= 4) {
    const len = buf.readUInt32LE(0);
    if (buf.length < 4 + len) break;
    inbox.push(JSON.parse(buf.subarray(4, 4 + len).toString('utf8')));
    buf = buf.subarray(4 + len);
  }
});
const send = (m) => {
  const body = Buffer.from(JSON.stringify({ v: 1, ...m }));
  const head = Buffer.alloc(4);
  head.writeUInt32LE(body.length);
  host.stdin.write(Buffer.concat([head, body]));
};
async function expect(pred, label, ms = 10_000) {
  const end = Date.now() + ms;
  for (;;) {
    const i = inbox.findIndex(pred);
    if (i >= 0) return inbox.splice(i, 1)[0];
    if (Date.now() > end) fail(`timed out waiting for ${label}; inbox=${JSON.stringify(inbox)}`);
    await new Promise((r) => setTimeout(r, 50));
  }
}

await expect((m) => m.type === 'host_status' && m.appConnected === true, 'host_status(appConnected)');
console.log('host connected to app');

send({ type: 'hello', protocol: 1, extVersion: 'smoke', extensionId: 'dpbpdbflelamfpmehknioljngeaagaeb', standalone: null });
const ack = await expect((m) => m.type === 'hello_ack', 'hello_ack');
if (ack.protocol !== 1) fail('protocol mismatch');
await expect((m) => m.type === 'sync' && m.session === null, 'sync(null)');
console.log('handshake ok');

// Garbage must be ignored, not crash anything.
send({ type: 'window_ready', sid: 'x' });
send({ type: 'nonsense' });

// Reconnect as an extension that has a browser-only session running: the app adopts it.
const sid = 'smoke0000000000000001';
send({ type: 'hello', protocol: 1, extVersion: 'smoke', extensionId: 'x', standalone: { sid, target: 'https://docs.google.com/document/d/SMOKE/edit', remainingMs: 600_000 } });
const adopted = await expect((m) => m.type === 'sync' && m.session && m.session.sid === sid, 'sync(adopted session)');
if (adopted.session.phase !== 'preparing') fail(`expected preparing, got ${adopted.session.phase}`);
if (!(adopted.session.remainingMs > 590_000 && adopted.session.remainingMs <= 600_000)) fail(`bad remainingMs ${adopted.session.remainingMs}`);
console.log('adoption ok:', adopted.session.phase, Math.round(adopted.session.remainingMs / 1000), 's');
if (!existsSync(join(support, 'session.json'))) fail('session was not persisted');

// The extension ends it (e.g. the user held "end" in the browser).
send({ type: 'session_closed', sid, reason: 'user_ended' });
await expect((m) => m.type === 'sync' && m.session === null, 'sync(null) after end');
await new Promise((r) => setTimeout(r, 300));
if (existsSync(join(support, 'session.json'))) fail('persisted session not cleared');
console.log('end ok; persisted state cleared');

// Chrome closes the port: host must exit; app must survive.
host.stdin.end();
await new Promise((r) => host.on('exit', r));
await new Promise((r) => setTimeout(r, 500));
if (appProc.exitCode !== null) fail('app died after host disconnect');

done = true;
cleanup();
console.log('SMOKE OK');

// Appearance captures for review: Settings (light), setup + Settings (dark).
if (process.env.EK_ARTIFACTS) {
  for (const [name, args, extra] of [
    ['00c-settings-light', [], { EKAGRACHIT_NO_SETUP_WINDOW: '1' }],
    ['00d-setup-settings-dark', [], { EKAGRACHIT_APPEARANCE: 'dark' }],
    ['00e-about-light', [], { EKAGRACHIT_NO_SETUP_WINDOW: '1', EKAGRACHIT_OPEN_SETTINGS: '0', EKAGRACHIT_OPEN_ABOUT: '1' }],
    ['00f-about-dark', [], { EKAGRACHIT_NO_SETUP_WINDOW: '1', EKAGRACHIT_OPEN_SETTINGS: '0', EKAGRACHIT_OPEN_ABOUT: '1', EKAGRACHIT_APPEARANCE: 'dark' }],
  ]) {
    const dir = mkdtempSync(join(tmpdir(), 'ek-shot-'));
    const p = spawn(join(app, 'Contents/MacOS/Ekagrachit'), args, {
      env: { ...process.env, EKAGRACHIT_SUPPORT_DIR: dir, EKAGRACHIT_SOCKET: join(dir, 'b.sock'), EKAGRACHIT_NO_HOST_REGISTRATION: '1', EKAGRACHIT_OPEN_SETTINGS: '1', ...extra },
      stdio: 'ignore',
    });
    await new Promise((r) => setTimeout(r, 6500));
    await new Promise((r) => spawn('screencapture', ['-x', join(process.env.EK_ARTIFACTS, `${name}.png`)]).on('exit', r));
    // The Settings window must have real content (a grouped Form once collapsed it to 0 pt).
    const probeBin = join(dirname(app), '..', '.build', 'release', 'ekagrachit-probe');
    if (existsSync(probeBin)) {
      const { execFileSync } = await import('node:child_process');
      const wins = JSON.parse(execFileSync(probeBin, ['windows'], { encoding: 'utf8' })).filter((w) => w.pid === p.pid && w.layer === 0);
      console.log(name, 'app windows:', JSON.stringify(wins.map((w) => [w.w, w.h])));
      if (!wins.some((w) => w.h >= 300 && w.w >= 400)) fail(`${name}: no window with content`);
    }
    p.kill();
    await new Promise((r) => setTimeout(r, 500));
  }
}
