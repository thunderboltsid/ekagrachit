/**
 * Desktop-level E2E on macOS (runs on the macos CI runner, or locally on a Mac):
 * real Ekagrachit.app + real ekagrachit-host + real Chromium with the extension,
 * observed from outside through the window server (ekagrachit-probe) and
 * screenshots. Covers Test B and the native half of Test D.
 *
 * Env: EK_APP (path to Ekagrachit.app), EK_PROBE (path to ekagrachit-probe),
 *      EK_ARTIFACTS (screenshot dir). Requires HEADED=1 (a real display).
 */
import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { type ChildProcess, execFileSync, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DOC_A, JIRA, type Harness, TestServer, allTabs, inSW, launch, session, sleep, waitFor } from '../e2e/harness.ts';

const here = dirname(fileURLToPath(import.meta.url));
const APP = resolve(process.env.EK_APP ?? join(here, '../../../../apps/macos/build/Ekagrachit.app'));
const PROBE = resolve(process.env.EK_PROBE ?? join(here, '../../../../apps/macos/.build/release/ekagrachit-probe'));
const ART = resolve(process.env.EK_ARTIFACTS ?? join(here, '../../test-artifacts'));
const OVERLAY_LAYER = 26; // NSWindow.Level.statusBar (25) + 1
const HOST_NAME = 'io.github.thunderboltsid.ekagrachit';

interface Win { number: number; pid: number; owner: string; layer: number; alpha: number; x: number; y: number; w: number; h: number }
interface Rect { x: number; y: number; w: number; h: number }
interface Screen extends Rect { visible: Rect }
interface Env { axTrusted: boolean; screens: Screen[]; frontmost: { pid: number; bundle: string; name: string } }

const probe = <T>(...args: string[]): T => JSON.parse(execFileSync(PROBE, args, { encoding: 'utf8' })) as T;
const windows = () => probe<Win[]>('windows');
const frontmost = () => probe<Env['frontmost']>('frontmost');
const shot = (name: string) => {
  try {
    execFileSync('screencapture', ['-x', join(ART, `${name}.png`)]);
  } catch (e) {
    console.log(`screenshot ${name} failed: ${e}`);
  }
};
const inter = (a: Rect, b: Rect): number => {
  const w = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
  const h = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y);
  return w > 0 && h > 0 ? w * h : 0;
};

function extensionId(): string {
  const manifest = JSON.parse(readFileSync(join(here, '../../manifest.json'), 'utf8')) as { key: string };
  const hash = createHash('sha256').update(Buffer.from(manifest.key, 'base64')).digest('hex').slice(0, 32);
  return [...hash].map((c) => String.fromCharCode(97 + parseInt(c, 16))).join('');
}

const isMac = process.platform === 'darwin';

describe('Test B: desktop isolation on macOS', { skip: !isMac && 'macOS only' }, () => {
  const server = new TestServer();
  const support = mkdtempSync('/tmp/ek-mac-');
  const sock = join(support, 'b.sock');
  const appEnv = { ...process.env, EKAGRACHIT_SUPPORT_DIR: support, EKAGRACHIT_SOCKET: sock, EKAGRACHIT_ALLOW_WITHOUT_ACCESSIBILITY: '1' };
  let appProc: ChildProcess;
  let h: Harness;
  let env: Env;
  let screen: Screen;

  const appPid = () => appProc.pid!;
  const overlays = () => windows().filter((w) => w.pid === appPid() && w.layer === OVERLAY_LAYER);
  const appWindows = () => windows().filter((w) => w.pid === appPid());
  const popupBounds = async (): Promise<Rect> => {
    const s = (await session(h))!;
    const w = await inSW(h, (id) => chrome.windows.get(id), s.windowId!);
    return { x: w.left!, y: w.top!, w: w.width!, h: w.height! };
  };
  const browserPid = async (): Promise<number> => {
    const b = await popupBounds();
    const w = windows().find((x) => x.layer === 0 && Math.abs(x.x - b.x) < 5 && Math.abs(x.y - b.y) < 5 && Math.abs(x.w - b.w) < 5);
    assert.ok(w, `native window for popup ${JSON.stringify(b)} not found in ${JSON.stringify(windows().filter((x) => x.layer === 0))}`);
    return w.pid;
  };
  /**
   * Independent oracle for the isolation layout:
   *  - expected uncovered area = popup ∩ visible frame (menu bar and Dock stay
   *    covered), or the whole screen for a full-screen popup;
   *  - overlays must cover everything else and nothing of that area;
   *  - pixels: a screenshot must show the page (white) inside that area, not the overlay.
   */
  const assertHoleAround = (popup: Rect, label = 'hole') => {
    const fullscreen = popup.x <= screen.x + 2 && popup.y <= screen.y + 2 && popup.w >= screen.w - 4 && popup.h >= screen.h - 4;
    const v = fullscreen ? screen : screen.visible;
    const hx = Math.max(popup.x, v.x), hy = Math.max(popup.y, v.y);
    const hole: Rect = { x: hx, y: hy, w: Math.min(popup.x + popup.w, v.x + v.w) - hx, h: Math.min(popup.y + popup.h, v.y + v.h) - hy };
    const all = windows();
    const ov = all.filter((w) => w.pid === appPid() && w.layer === OVERLAY_LAYER);
    const slack = 2 * (hole.w + hole.h);
    const overlapHole = ov.reduce((a, o) => a + inter(o, hole), 0);
    assert.ok(overlapHole <= slack, `overlays cover ${overlapHole} px² of the focus window's visible area ${JSON.stringify(hole)}`);
    const coveredOutside = ov.reduce((a, o) => a + inter(o, screen) - inter(o, hole), 0);
    const expected = screen.w * screen.h - inter(hole, screen);
    assert.ok(Math.abs(coveredOutside - expected) <= 4 * (screen.w + screen.h), `overlays cover ${coveredOutside} outside the hole, expected ≈${expected}`);
    for (const hud of all.filter((w) => w.pid === appPid() && w.layer === OVERLAY_LAYER + 1)) {
      assert.equal(inter(hud, popup), 0, `time pill ${JSON.stringify(hud)} overlaps the focus window ${JSON.stringify(popup)}`);
    }
    // Pixels: the page body (white) must be visible in the middle of the hole.
    const file = join(ART, `check-${label}.png`);
    execFileSync('screencapture', ['-x', file]);
    const region = { x: hole.x + 40, y: hole.y + 120, w: Math.max(20, hole.w - 80), h: Math.max(20, Math.min(200, hole.h - 160)) };
    const { brightness } = probe<{ brightness: number }>('brightness', file, ...[region.x, region.y, region.w, region.h].map(String));
    assert.ok(brightness > 0.9, `focus window content not visible in screenshot (brightness ${brightness.toFixed(2)} in ${JSON.stringify(region)})`);
    // …and the area outside it must be covered (the overlay is a uniform tint, never the white page).
    if (hole.y > screen.y + 60 || hole.x + hole.w < screen.x + screen.w - 60) {
      const outside = hole.y > screen.y + 60 ? { x: screen.x + 10, y: screen.y + 30, w: screen.w - 20, h: 20 } : { x: hole.x + hole.w + 10, y: hole.y + 100, w: 30, h: 100 };
      const o = probe<{ brightness: number }>('brightness', file, ...[outside.x, outside.y, outside.w, outside.h].map(String));
      assert.ok(o.brightness < 0.85, `area outside the focus window looks uncovered (brightness ${o.brightness.toFixed(2)})`);
    }
  };
  /** No flicker: the visible part of the focus window stays uncovered across ~2 s of samples. */
  const assertStable = async (popup: Rect) => {
    const v = screen.visible;
    const hx = Math.max(popup.x, v.x), hy = Math.max(popup.y, v.y);
    const hole: Rect = { x: hx, y: hy, w: Math.min(popup.x + popup.w, v.x + v.w) - hx, h: Math.min(popup.y + popup.h, v.y + v.h) - hy };
    let bad = 0;
    for (let i = 0; i < 15; i++) {
      const covered = overlays().reduce((a, o) => a + inter(o, hole), 0);
      if (covered > hole.w * hole.h * 0.05) bad++;
      await sleep(130);
    }
    assert.equal(bad, 0, `focus window was covered in ${bad}/15 samples (flicker)`);
  };
  const waitActive = (label: string) => waitFor(async () => overlays().length, (n) => n >= 1, 20_000, label);
  const startSession = async (minutes: number) => {
    const r = (await inSW(h, (a) => (globalThis as any).__ekagrachit.requestStart(a.t, a.m), { t: DOC_A, m: minutes })) as { ok: boolean; error?: string };
    assert.ok(r.ok, `start failed: ${r.error}`);
    await waitFor(() => session(h), (s) => !!s?.windowId, 15_000, 'focus window created');
    await waitActive('overlays shown (session active)');
    await sleep(700);
  };
  const launchApp = () => {
    appProc = spawn(join(APP, 'Contents/MacOS/Ekagrachit'), [], { env: appEnv, stdio: 'inherit' });
  };

  before(async () => {
    mkdirSync(ART, { recursive: true });
    assert.ok(existsSync(APP), `app bundle missing: ${APP}`);
    assert.ok(existsSync(PROBE), `probe missing: ${PROBE}`);
    env = probe<Env>('env');
    screen = env.screens[0]!;
    console.log('desktop env:', JSON.stringify(env));
    await server.start();
    launchApp();
    await waitFor(async () => existsSync(sock), (x) => x, 20_000, 'app bridge socket');

    // Native messaging manifest pointing at the bundled host, wired to our test socket.
    const wrapper = join(support, 'host.sh');
    writeFileSync(wrapper, `#!/bin/sh\nEKAGRACHIT_SOCKET='${sock}' exec '${join(APP, 'Contents/MacOS/ekagrachit-host')}' "$@"\n`);
    chmodSync(wrapper, 0o755);
    const id = extensionId();
    const manifest = { name: HOST_NAME, description: 'test', path: wrapper, type: 'stdio', allowed_origins: [`chrome-extension://${id}/`] };
    for (const dir of ['Chromium', 'Google/Chrome for Testing', 'Google/Chrome']) {
      const d = join(homedir(), 'Library/Application Support', dir, 'NativeMessagingHosts');
      mkdirSync(d, { recursive: true });
      writeFileSync(join(d, `${HOST_NAME}.json`), JSON.stringify(manifest));
    }
    h = await launch({ server, extId: id, nativeHostManifest: () => manifest });
    await waitFor(() => inSW(h, () => (globalThis as any).__ekagrachit.bridge.status as string), (s) => s === 'app_connected', 20_000, 'extension connected to app');
  });

  after(async () => {
    shot('99-final');
    await h?.close();
    appProc?.kill('SIGKILL');
    await server.stop();
  });

  test('session becomes active: popup is the only uncovered thing on screen', async () => {
    await startSession(10);
    const popup = await popupBounds();
    shot('01-active');
    const native = windows().find((w) => w.layer === 0 && Math.abs(w.x - popup.x) < 5 && Math.abs(w.y - popup.y) < 5);
    console.log('chrome.windows bounds', popup, 'native', native);
    assert.ok(native, 'chrome.windows bounds equal the window server bounds (identification assumption)');
    assertHoleAround(popup, 'active');
    await assertStable(popup);
    const front = frontmost();
    assert.equal(front.pid, await browserPid(), `browser is frontmost (got ${JSON.stringify(front)})`);
    const top = windows().find((w) => w.layer === 0);
    assert.equal(top?.number, native.number, 'focus window is the topmost normal window');
  });

  test('switching to another app (Cmd+Tab equivalent) is reversed', async () => {
    const bpid = await browserPid();
    probe('activate', 'com.apple.finder');
    const t0 = Date.now();
    await waitFor(async () => frontmost().pid, (pid) => pid === bpid, 3_000, 'browser frontmost again');
    console.log(`refocused after ${Date.now() - t0} ms`);
    await sleep(500);
    assertHoleAround(await popupBounds());
    shot('02-after-app-switch');
  });

  test('clicking the covered desktop/Dock area does not activate anything', async () => {
    const bpid = await browserPid();
    probe('click', String(screen.x + 5), String(screen.y + screen.h - 5)); // bottom-left: Dock area
    probe('click', String(screen.x + screen.w - 5), String(screen.y + screen.h / 2));
    await sleep(600);
    assert.equal(frontmost().pid, bpid);
    assertHoleAround(await popupBounds());
  });

  test('real Cmd+T and Cmd+N in the focus window do not leave anything open', async () => {
    const tabsBefore = (await allTabs(h)).length;
    probe('key', '17', 'cmd'); // T
    await sleep(1500);
    probe('key', '45', 'cmd'); // N
    await sleep(1500);
    await waitFor(() => allTabs(h), (t) => t.length === tabsBefore, 5_000, 'new tabs/windows closed');
    const bpid = await browserPid();
    await waitFor(async () => frontmost().pid, (p) => p === bpid, 3_000, 'browser frontmost');
    const popup = await popupBounds();
    const top = windows().find((w) => w.layer === 0);
    assert.ok(top && Math.abs(top.x - popup.x) < 5 && Math.abs(top.w - popup.w) < 5, 'focus window back on top');
    assert.equal(server.hits('acme.atlassian.net'), 0);
    shot('03-after-cmd-t-n');
  });

  test('another browser window brought to front is reversed', async () => {
    const before = await inSW(h, () => chrome.windows.getAll().then((w) => w.length));
    await inSW(h, (u) => chrome.windows.create({ url: u, focused: true }).then(() => undefined), JIRA);
    await waitFor(() => inSW(h, () => chrome.windows.getAll().then((w) => w.length)), (n) => n === before, 5_000, 'window closed');
    await sleep(500);
    assertHoleAround(await popupBounds());
  });

  test('moving and resizing the focus window (into the Dock area): the hole follows, the Dock stays covered', async () => {
    const s = (await session(h))!;
    await inSW(h, (id) => chrome.windows.update(id, { left: 120, top: 140, width: 900, height: 600 }).then(() => undefined), s.windowId!);
    await sleep(1200);
    const popup = await popupBounds();
    assert.equal(popup.w, 900);
    assertHoleAround(popup, 'moved');
    await assertStable(popup);
    shot('04-moved');
  });

  test('minimising the focus window is reversed', async () => {
    const s = (await session(h))!;
    await inSW(h, (id) => chrome.windows.update(id, { state: 'minimized' }).then(() => undefined), s.windowId!);
    await waitFor(() => inSW(h, (id) => chrome.windows.get(id).then((w) => w.state), s.windowId!), (st) => st !== 'minimized', 5_000, 'unminimised');
    await sleep(600);
    assertHoleAround(await popupBounds());
  });

  test('full-screen focus window (its own Space): app switch returns to it', async () => {
    const s = (await session(h))!;
    const bpid = await browserPid();
    await inSW(h, (id) => chrome.windows.update(id, { state: 'fullscreen' }).then(() => undefined), s.windowId!);
    await sleep(2500); // Space transition animation
    shot('05a-fullscreen');
    assert.equal(await inSW(h, (id) => chrome.windows.get(id).then((w) => w.state), s.windowId!), 'fullscreen');
    probe('activate', 'com.apple.finder'); // forces a Space switch away
    const t0 = Date.now();
    await waitFor(async () => frontmost().pid, (pid) => pid === bpid, 6_000, 'browser frontmost again');
    console.log(`full-screen: refocused after ${Date.now() - t0} ms`);
    await sleep(2000);
    assert.equal(await inSW(h, (id) => chrome.windows.get(id).then((w) => w.state), s.windowId!), 'fullscreen', 'still full screen');
    const top = windows().find((w) => w.layer === 0);
    assert.equal(top?.pid, bpid, 'the full-screen focus window is visible');
    shot('05b-fullscreen-after-switch');
    await inSW(h, (id) => chrome.windows.update(id, { state: 'normal' }).then(() => undefined), s.windowId!);
    await sleep(2500);
    assertHoleAround(await popupBounds());
  });

  test('emergency shortcut: Escape cancels, a short press does nothing, holding ends', async () => {
    const confirmPanel = () => appWindows().find((w) => w.layer === OVERLAY_LAYER + 2);
    probe('key', '14', 'ctrl,opt,cmd'); // ⌃⌥⌘E
    await waitFor(async () => confirmPanel(), (w) => !!w, 3_000, 'confirmation panel');
    shot('05-confirm');
    probe('key', '53'); // Escape
    await waitFor(async () => confirmPanel(), (w) => !w, 3_000, 'panel dismissed by Escape');
    assert.ok(overlays().length > 0, 'still in session after cancel');

    probe('key', '14', 'ctrl,opt,cmd');
    await waitFor(async () => confirmPanel(), (w) => !!w, 3_000, 'panel again');
    probe('keydown', '49'); // Space, released early
    await sleep(800);
    probe('keyup', '49');
    await sleep(600);
    assert.ok(overlays().length > 0, 'short press does not end the session');

    probe('keydown', '49'); // hold Space > 2.5 s
    await sleep(3200);
    probe('keyup', '49');
    const s = await session(h);
    await waitFor(async () => overlays().length, (n) => n === 0, 5_000, 'overlays removed');
    await waitFor(() => session(h), (x) => x === null, 5_000, 'browser restrictions lifted');
    if (s?.windowId) {
      await waitFor(() => inSW(h, (id) => chrome.windows.get(id).then(() => true, () => false), s.windowId!), (e) => !e, 5_000, 'focus window closed');
    }
    assert.equal(appWindows().filter((w) => w.layer >= OVERLAY_LAYER).length, 0, 'no leftover overlay/HUD/panel windows');
    shot('06-ended');
  });

  test('app killed mid-session: overlays vanish; relaunch resumes the session', async () => {
    await startSession(10);
    const sid = (await session(h))!.sid;
    const oldPid = appPid();
    appProc.kill('SIGKILL');
    await waitFor(async () => windows().filter((w) => w.pid === oldPid).length, (n) => n === 0, 5_000, 'no orphaned windows');
    shot('07-app-killed');
    await waitFor(() => inSW(h, () => chrome.action.getBadgeText({})), (b) => b === '!', 8_000, 'extension shows degraded');
    assert.equal((await session(h))?.sid, sid, 'browser enforcement continues');
    launchApp();
    await waitActive('session resumed by relaunched app');
    assert.equal((await session(h))?.sid, sid, 'same session resumed');
    await sleep(800);
    assertHoleAround(await popupBounds());
    shot('08-resumed');
    await inSW(h, (x) => (globalThis as any).__ekagrachit.requestEnd(x), sid);
    await waitFor(async () => overlays().length, (n) => n === 0, 8_000, 'ended');
  });

  test('a 1-minute session expires on its own and restores the desktop', { timeout: 120_000 }, async () => {
    await startSession(1);
    const s = (await session(h))!;
    await waitFor(async () => overlays().length, (n) => n === 0, 75_000, 'overlays removed at expiry');
    await waitFor(() => session(h), (x) => x === null, 10_000, 'extension session ended');
    await waitFor(() => inSW(h, (id) => chrome.windows.get(id).then(() => true, () => false), s.windowId!), (e) => !e, 5_000, 'focus window closed');
    shot('09-expired');
  });

  test('Mission Control: opening and leaving it returns to the focus window', async () => {
    await startSession(10);
    const bpid = await browserPid();
    execFileSync('open', ['-a', 'Mission Control']);
    await sleep(1500);
    shot('10-mission-control');
    probe('key', '53'); // Escape leaves Mission Control
    await sleep(1500);
    await waitFor(async () => frontmost().pid, (p) => p === bpid, 4_000, 'browser frontmost');
    assertHoleAround(await popupBounds(), 'after-mission-control');
  });

  test('Stage Manager enabled: isolation still holds', async () => {
    execFileSync('defaults', ['write', 'com.apple.WindowManager', 'GloballyEnabled', '-bool', 'true']);
    try {
      await sleep(3000);
      const bpid = await browserPid();
      probe('activate', 'com.apple.finder');
      await waitFor(async () => frontmost().pid, (p) => p === bpid, 4_000, 'browser frontmost with Stage Manager');
      await sleep(1500);
      shot('11-stage-manager');
      assertHoleAround(await popupBounds(), 'stage-manager');
      await assertStable(await popupBounds());
    } finally {
      execFileSync('defaults', ['write', 'com.apple.WindowManager', 'GloballyEnabled', '-bool', 'false']);
      const s = await session(h);
      if (s) await inSW(h, (x) => (globalThis as any).__ekagrachit.requestEnd(x), s.sid);
    }
  });
});
