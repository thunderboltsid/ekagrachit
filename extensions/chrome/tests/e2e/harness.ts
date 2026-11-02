/**
 * E2E harness: real Chromium + the built extension + a local HTTPS server that
 * impersonates docs.google.com, Jira, Slack etc. via --host-resolver-rules.
 * No real third-party site is contacted.
 */
import { type BrowserContext, type Page, type Worker, chromium } from 'playwright';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, readFileSync } from 'node:fs';
import { createServer, type Server } from 'node:https';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { AddressInfo } from 'node:net';

export const EXT_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'dist');
export const DOC_A = 'https://docs.google.com/document/d/DOC_A_1234567890/edit';
export const DOC_B = 'https://docs.google.com/document/d/DOC_B_0987654321/edit';
export const JIRA = 'https://acme.atlassian.net/browse/PROJ-1';
export const SLACK = 'https://app.slack.com/client/T000/C000';

export interface Served {
  host: string;
  path: string;
}

export class TestServer {
  server!: Server;
  port = 0;
  readonly requests: Served[] = [];
  private dir = mkdtempSync(join(tmpdir(), 'ekagrachit-tls-'));

  async start(): Promise<void> {
    const key = join(this.dir, 'key.pem');
    const cert = join(this.dir, 'cert.pem');
    execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', key, '-out', cert, '-days', '1', '-subj', '/CN=ekagrachit-test'], { stdio: 'ignore' });
    this.server = createServer({ key: readFileSync(key), cert: readFileSync(cert) }, (req, res) => {
      const host = (req.headers.host ?? '').split(':')[0]!;
      const path = req.url ?? '/';
      this.requests.push({ host, path });
      res.setHeader('content-type', 'text/html; charset=utf-8');
      res.setHeader('cache-control', 'no-store');
      if (path.startsWith('/favicon')) {
        res.statusCode = 404;
        res.end();
        return;
      }
      if (host === 'docs.google.com' && path.startsWith('/document/d/')) {
        const id = path.split('/')[3];
        res.end(`<!doctype html><title>Doc ${id}</title>
<h1 id="h">Document ${id}</h1>
<textarea id="editor" aria-label="editor"></textarea>
<a id="same-tab-doc-b" href="${DOC_B}">Doc B (same tab)</a>
<a id="same-tab-jira" href="${JIRA}">Jira (same tab)</a>
<a id="new-tab-jira" href="${JIRA}" target="_blank">Jira (new tab)</a>
<a id="anchor" href="#section-2">Section 2</a>
<script>
  document.getElementById('editor').addEventListener('input', () => {
    window.onbeforeunload = (e) => { e.preventDefault(); e.returnValue = ''; };
  });
</script>`);
        return;
      }
      res.end(`<!doctype html><title>${host}${path}</title><h1>${host}${path}</h1>`);
    });
    await new Promise<void>((r) => this.server.listen(0, '127.0.0.1', r));
    this.port = (this.server.address() as AddressInfo).port;
  }

  hits(host: string, pathPrefix = '/'): number {
    return this.requests.filter((r) => r.host === host && r.path.startsWith(pathPrefix)).length;
  }

  async stop(): Promise<void> {
    await new Promise<void>((r) => this.server.close(() => r()));
    rmSync(this.dir, { recursive: true, force: true });
  }
}

export interface Harness {
  ctx: BrowserContext;
  sw: Worker;
  extId: string;
  userDataDir: string;
  server: TestServer;
  close(keepProfile?: boolean): Promise<void>;
}

export async function launch(opts: { server: TestServer; userDataDir?: string; nativeHostManifest?: (extId: string) => object; extId?: string }): Promise<Harness> {
  const userDataDir = opts.userDataDir ?? mkdtempSync(join(tmpdir(), 'ekagrachit-profile-'));
  if (opts.nativeHostManifest && opts.extId) {
    mkdirSync(join(userDataDir, 'NativeMessagingHosts'), { recursive: true });
    writeFileSync(join(userDataDir, 'NativeMessagingHosts', 'io.github.thunderboltsid.ekagrachit.json'), JSON.stringify(opts.nativeHostManifest(opts.extId)));
  }
  const ctx = await chromium.launchPersistentContext(userDataDir, {
    channel: 'chromium',
    headless: process.env.HEADED !== '1',
    ignoreHTTPSErrors: true,
    args: [
      `--disable-extensions-except=${EXT_DIR}`,
      `--load-extension=${EXT_DIR}`,
      `--host-resolver-rules=MAP * 127.0.0.1:${opts.server.port}`,
      '--ignore-certificate-errors',
      '--no-proxy-server',
    ],
  });
  let sw = ctx.serviceWorkers()[0];
  if (!sw) sw = await ctx.waitForEvent('serviceworker');
  const extId = sw.url().split('/')[2]!;
  return {
    ctx,
    sw,
    extId,
    userDataDir,
    server: opts.server,
    async close(keepProfile = false) {
      await ctx.close();
      if (!keepProfile) rmSync(userDataDir, { recursive: true, force: true });
    },
  };
}

/** Evaluate inside the service worker with access to the controller. */
export async function inSW<T, A = undefined>(h: Harness, fn: (arg: A) => Promise<T> | T, arg?: A): Promise<T> {
  // Re-resolve the worker: it may have been restarted.
  const workers = h.ctx.serviceWorkers().filter((w) => w.url().includes(h.extId));
  const sw = workers[workers.length - 1] ?? (await h.ctx.waitForEvent('serviceworker'));
  h.sw = sw;
  return sw.evaluate(fn as never, arg as never) as Promise<T>;
}

export interface SessionView {
  sid: string;
  windowId: number | null;
  tabId: number | null;
  armed: boolean;
  endsAt: number;
  owner: string;
}

export async function session(h: Harness): Promise<SessionView | null> {
  return inSW(h, async () => {
    const v = (await chrome.storage.local.get('session')).session as SessionView | undefined;
    return v ?? null;
  });
}

export async function startSession(h: Harness, target: string, minutes = 25): Promise<SessionView> {
  const r = await inSW(h, (a) => (globalThis as any).__ekagrachit.requestStart(a.target, a.minutes), { target, minutes });
  if (!(r as { ok: boolean }).ok) throw new Error(`start failed: ${JSON.stringify(r)}`);
  const s = await waitFor(() => session(h), (s) => s !== null && s.windowId !== null && s.tabId !== null);
  return s!;
}

export async function tabUrl(h: Harness, tabId: number): Promise<string | null> {
  return inSW(h, (id) => chrome.tabs.get(id).then((t) => t.url ?? t.pendingUrl ?? null, () => null), tabId);
}

export async function allTabs(h: Harness): Promise<{ id: number; windowId: number; url: string }[]> {
  return inSW(h, () => chrome.tabs.query({}).then((ts) => ts.map((t) => ({ id: t.id!, windowId: t.windowId, url: t.url || t.pendingUrl || '' }))));
}

export async function focusPage(h: Harness): Promise<Page> {
  return waitFor(
    async () => h.ctx.pages().find((p) => p.url().includes('DOC_A')) ?? null,
    (p) => p !== null,
  ) as Promise<Page>;
}

export async function waitFor<T>(fn: () => Promise<T>, ok: (v: T) => boolean, timeoutMs = 8000, label = 'condition'): Promise<T> {
  const start = Date.now();
  let last: T;
  for (;;) {
    last = await fn();
    if (ok(last)) return last;
    if (Date.now() - start > timeoutMs) throw new Error(`timed out waiting for ${label}; last=${JSON.stringify(last)}`);
    await new Promise((r) => setTimeout(r, 100));
  }
}

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
