/**
 * Full chain: Chromium + extension  <-native messaging->  real ekagrachit-host
 * (Swift)  <-unix socket->  FakeApp (this file, speaking protocol v1 as
 * Ekagrachit.app does). Validates Spike 4 and the sync/ack/stale/reconnect
 * semantics without macOS. Skipped if the host binary has not been built.
 */
import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync, chmodSync } from 'node:fs';
import { createServer, type Server, type Socket } from 'node:net';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DOC_A, JIRA, type Harness, TestServer, allTabs, focusPage, inSW, launch, session, sleep, waitFor } from './harness.ts';

const here = dirname(fileURLToPath(import.meta.url));
const HOST_BIN = process.env.EKAGRACHIT_HOST_BINARY ?? join(here, '../../../../apps/macos/.build/debug/ekagrachit-host');
const SID = 'feedfacecafebeef0001';

function extensionIdFromManifestKey(): string {
  const manifest = JSON.parse(readFileSync(join(here, '../../manifest.json'), 'utf8')) as { key: string };
  const hash = createHash('sha256').update(Buffer.from(manifest.key, 'base64')).digest('hex').slice(0, 32);
  return [...hash].map((c) => String.fromCharCode(97 + parseInt(c, 16))).join('');
}

type Msg = Record<string, any>;

/** Minimal stand-in for Ekagrachit.app's BridgeServer + coordinator. */
class FakeApp {
  server!: Server;
  sock: Socket | null = null;
  received: Msg[] = [];
  epoch = 'epoch-1';
  seq = 0;
  private buf = Buffer.alloc(0);
  autoAck = true;
  ackDelayMs = 0;

  readonly path: string;
  constructor(path: string) {
    this.path = path;
  }

  async start(): Promise<void> {
    this.server = createServer((s) => {
      this.sock = s;
      s.on('data', (d) => this.onData(d));
      s.on('close', () => { if (this.sock === s) this.sock = null; });
    });
    await new Promise<void>((r) => this.server.listen(this.path, r));
  }

  private onData(d: Buffer): void {
    this.buf = Buffer.concat([this.buf, d]);
    while (this.buf.length >= 4) {
      const len = this.buf.readUInt32LE(0);
      if (this.buf.length < 4 + len) break;
      const msg = JSON.parse(this.buf.subarray(4, 4 + len).toString('utf8')) as Msg;
      this.buf = this.buf.subarray(4 + len);
      this.received.push(msg);
      if (msg.type === 'hello' && this.autoAck) {
        setTimeout(() => {
          this.send({ type: 'hello_ack', protocol: 1, appVersion: 'fake', epoch: this.epoch });
          this.sync(null);
        }, this.ackDelayMs);
      }
    }
  }

  send(m: Msg): void {
    const body = Buffer.from(JSON.stringify({ v: 1, ...m }));
    const head = Buffer.alloc(4);
    head.writeUInt32LE(body.length);
    this.sock?.write(Buffer.concat([head, body]));
  }

  sync(session: Msg | null, seq?: number): void {
    this.seq = seq ?? this.seq + 1;
    this.send({ type: 'sync', epoch: this.epoch, seq: this.seq, session });
  }

  async waitFor(pred: (m: Msg) => boolean, label: string, timeoutMs = 10_000): Promise<Msg> {
    const m = await waitFor(async () => this.received.find(pred) ?? null, (x) => x !== null, timeoutMs, label);
    return m!;
  }

  /** Simulates the app quitting: stop listening and drop the host connection. */
  async down(): Promise<void> {
    this.dropClient();
    await new Promise<void>((r) => this.server.close(() => r()));
    rmSync(this.path, { force: true });
  }

  dropClient(): void {
    this.sock?.destroy();
    this.sock = null;
  }

  async stop(): Promise<void> {
    this.dropClient();
    if (this.server.listening) await new Promise<void>((r) => this.server.close(() => r()));
  }
}

describe('Native bridge: extension <-> ekagrachit-host <-> app', { skip: !existsSync(HOST_BIN) && `host binary not built (${HOST_BIN})` }, () => {
  const server = new TestServer();
  const dir = mkdtempSync(join(tmpdir(), 'ek-'));
  const sockPath = join(dir, 'b.sock');
  const app = new FakeApp(sockPath);
  let h: Harness;

  before(async () => {
    await server.start();
    await app.start();
    // Chrome launches the host from the manifest; a wrapper points it at our test socket.
    const wrapper = join(dir, 'host.sh');
    writeFileSync(wrapper, `#!/bin/sh\nEKAGRACHIT_SOCKET='${sockPath}' exec '${HOST_BIN}' "$@"\n`);
    chmodSync(wrapper, 0o755);
    const extId = extensionIdFromManifestKey();
    h = await launch({
      server,
      extId,
      nativeHostManifest: (id) => ({
        name: 'io.github.thunderboltsid.ekagrachit',
        description: 'Ekagrachit native messaging host',
        path: wrapper,
        type: 'stdio',
        allowed_origins: [`chrome-extension://${id}/`],
      }),
    });
    assert.equal(h.extId, extId, 'extension id derived from the manifest key matches the loaded extension');
  });

  after(async () => {
    await h?.close();
    await app.stop();
    await server.stop();
    rmSync(dir, { recursive: true, force: true });
  });

  test('host connects and the extension says hello', async () => {
    const hostHello = await app.waitFor((m) => m.type === 'host_hello', 'host_hello');
    assert.ok(hostHello.browserPid > 0);
    const hello = await app.waitFor((m) => m.type === 'hello', 'hello');
    assert.equal(hello.protocol, 1);
    assert.equal(hello.standalone, null);
    const ui = await inSW(h, () => (globalThis as any).__ekagrachit.uiState());
    assert.equal((ui as { bridge: string }).bridge, 'app_connected');
  });

  test('the toolbar button asks the app to open its menu (no extension UI)', async () => {
    const tabsBefore = (await allTabs(h)).length;
    await inSW(h, () => (globalThis as any).__ekagrachit.onActionClicked());
    await app.waitFor((m) => m.type === 'show_menu', 'show_menu');
    assert.equal((await allTabs(h)).length, tabsBefore, 'no page or popup opened in Chrome');
  });

  test('app-initiated session: extension opens the focus window and reports it', async () => {
    app.sync({ sid: SID, target: DOC_A, remainingMs: 25 * 60_000, phase: 'preparing' });
    const ready = await app.waitFor((m) => m.type === 'window_ready' && m.sid === SID, 'window_ready');
    assert.ok(ready.windowId > 0 && ready.tabId > 0);
    assert.ok(ready.bounds.width > 0 && ready.bounds.height > 0);
    const s = await session(h);
    assert.equal(s?.owner, 'native');
    assert.equal(s?.windowId, ready.windowId);
    app.sync({ sid: SID, target: DOC_A, remainingMs: 25 * 60_000 - 500, phase: 'active' });
  });

  test('violations are reported to the app', async () => {
    const page = await focusPage(h);
    await page.click('#new-tab-jira');
    await app.waitFor((m) => m.type === 'violation' && m.kind === 'tab_closed', 'violation');
    assert.equal(server.hits('acme.atlassian.net'), 0);
  });

  test('stale (out-of-order) sync messages are ignored', async () => {
    app.sync(null, 1); // older seq than what was already applied
    await sleep(700);
    assert.equal((await session(h))?.sid, SID, 'session not ended by a stale message');
  });

  test('app "focus" command is honoured for the current sid only', async () => {
    app.send({ type: 'focus', sid: 'ffffffffffffffffffff' });
    app.send({ type: 'focus', sid: SID });
    await sleep(300);
    assert.ok(await session(h));
  });

  test('app disconnect: browser enforcement continues (degraded), then resumes on reconnect', async () => {
    await app.down();
    await waitFor(() => inSW(h, () => (globalThis as any).__ekagrachit.bridge.status as string), (s) => s === 'app_unavailable', 8000, 'host reports app gone');
    // Still enforcing:
    const before = (await allTabs(h)).length;
    await inSW(h, (url) => chrome.tabs.create({ url }).then(() => undefined), JIRA);
    await waitFor(() => allTabs(h), (t) => t.length === before, 5000, 'tab closed while degraded');
    const badge = await inSW(h, () => chrome.action.getBadgeText({}));
    assert.equal(badge, '!');
    // The app restarts (new epoch). The host reconnects within ~1.5 s and the
    // app re-syncs the same session from its persisted state.
    app.received = [];
    app.epoch = 'epoch-2';
    app.seq = 0;
    app.autoAck = false;
    await app.start();
    await app.waitFor((m) => m.type === 'hello', 'hello after reconnect');
    app.send({ type: 'hello_ack', protocol: 1, appVersion: 'fake', epoch: app.epoch });
    app.sync({ sid: SID, target: DOC_A, remainingMs: 20 * 60_000, phase: 'degraded' });
    await app.waitFor((m) => m.type === 'window_ready' && m.sid === SID, 'window re-reported (no new window)');
    assert.equal((await session(h))?.sid, SID);
    app.autoAck = true;
  });

  test('app ends the session: restrictions lifted, focus window closed, ack sent', async () => {
    const s = (await session(h))!;
    app.sync(null);
    await app.waitFor((m) => m.type === 'session_closed' && m.sid === SID, 'session_closed');
    assert.equal(await session(h), null);
    assert.equal((await inSW(h, () => chrome.declarativeNetRequest.getSessionRules())).length, 0);
    await waitFor(() => inSW(h, (id) => chrome.windows.get(id).then(() => true, () => false), s.windowId!), (x) => !x, 5000, 'window closed');
  });

  test('UI start is routed to the app, which stays authoritative', async () => {
    const pending = inSW(h, (t) => (globalThis as any).__ekagrachit.requestStart(t, 25), DOC_A);
    const req = await app.waitFor((m) => m.type === 'start_request', 'start_request');
    assert.equal(req.durationMinutes, 25);
    app.send({ type: 'start_result', cid: req.cid, ok: false, error: 'Grant Accessibility permission first.' });
    const r = (await pending) as { ok: boolean; error?: string };
    assert.equal(r.ok, false);
    assert.match(r.error!, /Accessibility/);
    assert.equal(await session(h), null, 'nothing started without the app');
  });

  test('regression: a start issued right after (re)connecting waits for the handshake', async () => {
    await app.down();
    await waitFor(() => inSW(h, () => (globalThis as any).__ekagrachit.bridge.status as string), (s) => s !== 'app_connected', 8000, 'app gone');
    app.received = [];
    app.ackDelayMs = 700;
    await app.start();
    await waitFor(() => inSW(h, () => (globalThis as any).__ekagrachit.bridge.status as string), (s) => s === 'app_connected', 8000, 'host reconnected');
    const pending = inSW(h, (t) => (globalThis as any).__ekagrachit.requestStart(t, 25), DOC_A);
    const req = await app.waitFor((m) => m.type === 'start_request', 'start_request');
    const helloIdx = app.received.findIndex((m) => m.type === 'hello');
    assert.ok(helloIdx >= 0 && helloIdx < app.received.indexOf(req), 'hello precedes the request on the wire');
    app.send({ type: 'start_result', cid: req.cid, ok: false, error: 'no' });
    assert.equal(((await pending) as { ok: boolean }).ok, false);
    app.ackDelayMs = 0;
  });

  test('ending from the browser is reported to the app and never resurrected', async () => {
    const sid2 = 'feedfacecafebeef0002';
    app.sync({ sid: sid2, target: DOC_A, remainingMs: 10 * 60_000, phase: 'active' });
    await app.waitFor((m) => m.type === 'window_ready' && m.sid === sid2, 'window_ready 2');
    await inSW(h, (sid) => (globalThis as any).__ekagrachit.requestEnd(sid), sid2);
    await app.waitFor((m) => m.type === 'end_request' && m.sid === sid2, 'end_request');
    // Simulate an app that does not answer: the extension ends locally after 3 s.
    await waitFor(() => session(h), (s) => s === null, 8000, 'ended locally');
    app.received = [];
    app.sync({ sid: sid2, target: DOC_A, remainingMs: 9 * 60_000, phase: 'active' });
    await app.waitFor((m) => m.type === 'session_closed' && m.sid === sid2, 'tombstone reply');
    assert.equal(await session(h), null);
  });
});
