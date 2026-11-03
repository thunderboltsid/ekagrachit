/**
 * Test A (Google Docs isolation) and Test E (preservation) against real Chromium.
 * Keyboard accelerators such as Cmd+T / Cmd+N are browser-UI commands that
 * automation cannot press; they are exercised through the equivalent extension
 * API calls (chrome.tabs.create / chrome.windows.create), which produce the
 * same tab/window events the guard reacts to.
 */
import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import {
  DOC_A, DOC_B, JIRA, SLACK, type Harness, TestServer,
  allTabs, focusPage, inSW, launch, session, sleep, startSession, tabUrl, waitFor,
} from './harness.ts';

describe('Test A: Google Docs isolation (browser-only mode)', () => {
  const server = new TestServer();
  let h: Harness;
  let preexistingTabId: number;

  before(async () => {
    await server.start();
    h = await launch({ server });
    // A pre-existing user tab that must survive untouched.
    const page = await h.ctx.newPage();
    await page.goto('https://news.example/front');
    preexistingTabId = (await allTabs(h)).find((t) => t.url.includes('news.example'))!.id;
  });
  after(async () => {
    await h.close();
    await server.stop();
  });

  test('opens the target in a dedicated popup window', async () => {
    const s = await startSession(h, DOC_A, 25);
    const win = await inSW(h, (id) => chrome.windows.get(id, { populate: true }), s.windowId!);
    assert.equal(win.type, 'popup');
    assert.equal(win.tabs!.length, 1);
    await waitFor(() => tabUrl(h, s.tabId!), (u) => u === DOC_A, 8000, 'doc A loaded');
    assert.equal(s.armed, true, 'Google Docs targets are enforced immediately');
  });

  test('the document stays interactive', async () => {
    const page = await focusPage(h);
    await page.fill('#editor', 'reviewing the design');
    assert.equal(await page.inputValue('#editor'), 'reviewing the design');
    await page.click('#anchor'); // in-document fragment navigation is fine
    await sleep(300);
    assert.match(page.url(), /DOC_A_1234567890\/edit#section-2$/);
    await page.evaluate(() => history.pushState({}, '', '/document/d/DOC_A_1234567890/edit?tab=t.1'));
    await sleep(400);
    assert.match(page.url(), /edit\?tab=t\.1$/);
    // Clear the beforeunload handler installed by typing, for the following tests.
    await page.evaluate(() => { window.onbeforeunload = null; });
  });

  test('navigating to Google Doc B is blocked before loading and reverted', async () => {
    const s = (await session(h))!;
    const page = await focusPage(h);
    const before = server.hits('docs.google.com', '/document/d/DOC_B');
    await page.click('#same-tab-doc-b').catch(() => undefined);
    await waitFor(() => tabUrl(h, s.tabId!), (u) => !!u && u.includes('DOC_A'), 8000, 'reverted to doc A');
    assert.equal(server.hits('docs.google.com', '/document/d/DOC_B'), before, 'Doc B was never fetched');
  });

  test('following a same-tab link to Jira is blocked and reverted', async () => {
    const s = (await session(h))!;
    const page = await focusPage(h);
    await page.click('#same-tab-jira').catch(() => undefined);
    await waitFor(() => tabUrl(h, s.tabId!), (u) => !!u && u.includes('DOC_A'), 8000, 'reverted to doc A');
    assert.equal(server.hits('acme.atlassian.net'), 0, 'Jira was never fetched');
  });

  test('SPA history change to another document is reverted', async () => {
    const s = (await session(h))!;
    const page = await focusPage(h);
    await page.evaluate(() => history.pushState({}, '', '/document/d/DOC_B_0987654321/edit'));
    await waitFor(() => tabUrl(h, s.tabId!), (u) => !!u && u.includes('DOC_A'), 8000, 'reverted to doc A');
  });

  test('external link opening a new tab is closed without loading', async () => {
    const page = await focusPage(h);
    const countBefore = (await allTabs(h)).length;
    await page.click('#new-tab-jira');
    await sleep(800);
    await waitFor(() => allTabs(h), (t) => t.length === countBefore, 5000, 'new tab closed');
    assert.equal(server.hits('acme.atlassian.net'), 0, 'Jira was never fetched');
  });

  test('a new tab (Cmd+T + typing a URL) is closed and never loads', async () => {
    const countBefore = (await allTabs(h)).length;
    await inSW(h, (url) => chrome.tabs.create({ url }).then(() => undefined), SLACK);
    await waitFor(() => allTabs(h), (t) => t.length === countBefore, 5000, 'tab closed');
    assert.equal(server.hits('app.slack.com'), 0, 'Slack was never fetched');
  });

  test('window.open from the document is closed', async () => {
    const page = await focusPage(h);
    const countBefore = (await allTabs(h)).length;
    await page.evaluate((u) => { setTimeout(() => window.open(u, '_blank', 'popup'), 0); }, JIRA);
    await sleep(500);
    await waitFor(() => allTabs(h), (t) => t.length === countBefore, 5000, 'popup closed');
    assert.equal(server.hits('acme.atlassian.net'), 0);
  });

  test('enforcement survives service-worker suspension', async () => {
    const page = await focusPage(h);
    const countBefore = (await allTabs(h)).length;
    const cdp = await h.ctx.newCDPSession(page);
    await cdp.send('ServiceWorker.enable');
    await cdp.send('ServiceWorker.stopAllWorkers');
    await cdp.detach();
    await sleep(500);
    // Nothing is running in the extension now. The tab-creation event must wake
    // the worker, which reloads the session from storage and closes the tab.
    await page.click('#new-tab-jira');
    await sleep(1500);
    await waitFor(() => allTabs(h), (t) => t.length === countBefore, 8000, 'new tab closed after worker restart');
    assert.equal(server.hits('acme.atlassian.net'), 0);
    assert.ok(await session(h));
  });

  test('a new browser window (Cmd+N) is closed', async () => {
    const before = await inSW(h, () => chrome.windows.getAll().then((w) => w.length));
    await inSW(h, (url) => chrome.windows.create({ url }).then(() => undefined), SLACK);
    await waitFor(() => inSW(h, () => chrome.windows.getAll().then((w) => w.length)), (n) => n === before, 5000, 'window closed');
    assert.equal(server.hits('app.slack.com'), 0);
  });

  // Headless Chromium has no real window focus; run with HEADED=1 under a display (xvfb-run in CI).
  test('focusing another existing window snaps back to the focus window', { skip: process.env.HEADED !== '1' && 'needs HEADED=1' }, async () => {
    const s = (await session(h))!;
    const other = await inSW(h, (id) => chrome.tabs.get(id).then((t) => t.windowId), preexistingTabId);
    const before = await inSW(h, () => (globalThis as any).__ekagrachit.lastRefocus as number);
    await inSW(h, (id) => chrome.windows.update(id, { focused: true }).then(() => undefined), other);
    // The guard must observe the focus change and issue a refocus of the popup.
    await waitFor(() => inSW(h, () => (globalThis as any).__ekagrachit.lastRefocus as number), (t) => t > before, 5000, 'guard refocused');
    await waitFor(
      () => inSW(h, () => chrome.windows.getLastFocused().then((w) => w.id)),
      (id) => id === s.windowId,
      5000,
      'focus window is the last focused window',
    );
  });

  test('closing the focus window reopens it', async () => {
    const s = (await session(h))!;
    await inSW(h, (id) => chrome.windows.remove(id), s.windowId!);
    const s2 = await waitFor(() => session(h), (x) => !!x && x.windowId !== null && x.windowId !== s.windowId, 8000, 'recreated');
    const win = await inSW(h, (id) => chrome.windows.get(id), s2!.windowId!);
    assert.equal(win.type, 'popup');
    await waitFor(() => tabUrl(h, s2!.tabId!), (u) => !!u && u.includes('DOC_A'), 8000, 'doc A reloaded');
  });

  test('moving the focus tab into a normal window ("Open in Chrome") re-homes it in a popup', async () => {
    const s = (await session(h))!;
    await inSW(h, (tabId) => chrome.windows.create({ tabId, type: 'normal' }).then(() => undefined), s.tabId!);
    const s2 = await waitFor(() => session(h), (x) => !!x && x.windowId !== s.windowId && x.tabId === s.tabId, 8000, 're-homed');
    const win = await inSW(h, (id) => chrome.windows.get(id, { populate: true }), s2!.windowId!);
    assert.equal(win.type, 'popup');
    assert.equal(win.tabs![0]!.id, s.tabId);
  });

  test('every blocked link is saved for later (same-tab, new tab, typed URL)', async () => {
    const parked = await inSW(h, async () => ((await chrome.storage.local.get('session')).session as { parked?: string[] }).parked ?? []);
    for (const u of [DOC_B, JIRA, SLACK]) assert.ok(parked.includes(u), `${u} parked; got ${JSON.stringify(parked)}`);
    assert.ok(!parked.some((u) => u.includes('DOC_A')), 'the focus document itself is never parked');
  });

  test('Test E: at expiry restrictions lift, only the focus window closes, existing tabs are intact', async () => {
    const s = (await session(h))!;
    await inSW(h, () => (globalThis as any).__ekagrachit.debugSetRemaining(300));
    await waitFor(() => session(h), (x) => x === null, 8000, 'session ended');
    await waitFor(
      () => inSW(h, (id) => chrome.windows.get(id).then(() => true, () => false), s.windowId!),
      (exists) => !exists,
      5000,
      'focus window closed',
    );
    assert.equal(await tabUrl(h, preexistingTabId), 'https://news.example/front', 'pre-existing tab untouched');
    // The "Saved for later" page opens with what the user reached for.
    const later = await waitFor(async () => h.ctx.pages().find((p) => p.url().endsWith('/later.html')) ?? null, (p) => p !== null, 5000, 'later page');
    await later!.waitForSelector('#items li');
    const hosts = await later!.$$eval('#items .host', (els) => els.map((e) => e.textContent));
    assert.ok(hosts.includes('acme.atlassian.net') && hosts.includes('app.slack.com'), `later page lists the links: ${hosts}`);
    if (process.env.EK_SHOTS) await later!.screenshot({ path: `${process.env.EK_SHOTS}/later.png` });
    const rules = await inSW(h, () => chrome.declarativeNetRequest.getSessionRules());
    assert.equal(rules.length, 0, 'all blocking rules removed');
    // Normal browsing works again.
    const tab = await inSW(h, (url) => chrome.tabs.create({ url }).then((t) => t.id!), SLACK);
    await waitFor(() => tabUrl(h, tab), (u) => u === SLACK, 5000, 'slack loads after session');
    assert.ok(server.hits('app.slack.com') > 0);
  });
});

describe('Test E: closing the focus window respects beforeunload', () => {
  const server = new TestServer();
  let h: Harness;
  before(async () => {
    await server.start();
    h = await launch({ server });
  });
  after(async () => {
    await h.close();
    await server.stop();
  });

  test('unsaved edits keep the window open and prompt the user', async () => {
    const s = await startSession(h, DOC_A, 25);
    const page = await focusPage(h);
    await page.fill('#editor', 'unsaved text');
    let dialogType: string | null = null;
    page.on('dialog', (d) => {
      dialogType = d.type();
      void d.dismiss(); // the user chooses "Stay"
    });
    await inSW(h, () => (globalThis as any).__ekagrachit.debugSetRemaining(100));
    await waitFor(() => session(h), (x) => x === null, 8000, 'session ended');
    await waitFor(async () => dialogType, (d) => d === 'beforeunload', 5000, 'beforeunload dialog');
    const stillOpen = await inSW(h, (id) => chrome.windows.get(id).then(() => true, () => false), s.windowId!);
    assert.equal(stillOpen, true, 'window kept open so no work is lost');
    assert.equal(await page.inputValue('#editor'), 'unsaved text');
  });
});

describe('Test D (browser): restart recovery and repeated requests', () => {
  const server = new TestServer();
  before(async () => {
    await server.start();
  });
  after(async () => {
    await server.stop();
  });

  test('a second start is rejected while a session is active; repeated ends are idempotent', async () => {
    const h = await launch({ server });
    try {
      const s = await startSession(h, DOC_A, 25);
      const second = await inSW(h, (t) => (globalThis as any).__ekagrachit.requestStart(t, 25), DOC_B);
      assert.equal((second as { ok: boolean }).ok, false);
      await inSW(h, (sid) => Promise.all([
        (globalThis as any).__ekagrachit.requestEnd(sid),
        (globalThis as any).__ekagrachit.requestEnd(sid),
        (globalThis as any).__ekagrachit.requestEnd(sid),
      ]).then(() => undefined), s.sid);
      assert.equal(await session(h), null);
      assert.equal((await inSW(h, () => chrome.declarativeNetRequest.getSessionRules())).length, 0);
    } finally {
      await h.close();
    }
  });

  test('invalid targets are rejected without side effects', async () => {
    const h = await launch({ server });
    try {
      for (const t of ['javascript:alert(1)', 'chrome://settings', 'https://u:p@x.example/', '']) {
        const r = await inSW(h, (x) => (globalThis as any).__ekagrachit.requestStart(x, 25), t);
        assert.equal((r as { ok: boolean }).ok, false, t);
      }
      const r = await inSW(h, (x) => (globalThis as any).__ekagrachit.requestStart(x, 0), DOC_A);
      assert.equal((r as { ok: boolean }).ok, false, 'zero duration');
      assert.equal(await session(h), null);
    } finally {
      await h.close();
    }
  });

  test('a session survives a browser restart and the focus window is restored', async () => {
    const h = await launch({ server });
    await startSession(h, DOC_A, 25);
    await h.close(true);
    const h2 = await launch({ server, userDataDir: h.userDataDir });
    try {
      // Window ids from the previous browser run are invalid; wait for a live popup.
      await waitFor(
        () => inSW(h2, async () => {
          const s = (await chrome.storage.local.get('session')).session as { windowId: number | null } | undefined;
          if (!s?.windowId) return null;
          const w = await chrome.windows.get(s.windowId, { populate: true }).catch(() => null);
          return w ? `${w.type}:${w.tabs?.[0]?.pendingUrl || w.tabs?.[0]?.url}` : null;
        }),
        (t) => !!t && t.startsWith('popup:') && t.includes('DOC_A'),
        15000,
        'popup window with the target restored',
      );
      const rules = await inSW(h2, () => chrome.declarativeNetRequest.getSessionRules());
      assert.ok(rules.length >= 3, 'enforcement rules re-installed');
    } finally {
      await h2.close();
    }
  });

  test('an expired session is cleaned up on startup', async () => {
    const h = await launch({ server });
    await startSession(h, DOC_A, 25);
    await inSW(h, async () => {
      const s = (await chrome.storage.local.get('session')).session as { endsAt: number };
      s.endsAt = Date.now() - 1000;
      await chrome.storage.local.set({ session: s });
    });
    await h.close(true);
    const h2 = await launch({ server, userDataDir: h.userDataDir });
    try {
      await waitFor(() => session(h2), (x) => x === null, 8000, 'expired session removed');
      assert.equal((await inSW(h2, () => chrome.declarativeNetRequest.getSessionRules())).length, 0);
    } finally {
      await h2.close();
    }
  });
});
