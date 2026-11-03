/**
 * Web apps recognised by resource id, against real Chromium: every generated
 * declarativeNetRequest regex is accepted by Chrome's RE2 (isRegexSupported),
 * and a Figma session lets the file's own views load while another file is
 * blocked before any request reaches the server.
 */
import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { allowPatterns, authPatterns, parseTarget } from '../../src/shared/identity.ts';
import { type Harness, TestServer, inSW, launch, sleep, startSession, tabUrl, waitFor } from './harness.ts';

const TARGETS = [
  'https://www.notion.so/acme/Design-Review-0123456789abcdef0123456789abcdef',
  'https://acme.notion.site/Handbook-0123456789abcdef0123456789abcdef',
  'https://www.figma.com/design/AbCdEfGhIjKl123/Checkout',
  'https://linear.app/acme/issue/ENG-123/fix-login',
  'https://acme.atlassian.net/wiki/spaces/ENG/pages/123456/Runbook',
  'https://gitlab.com/acme/platform/api/-/merge_requests/42',
  'https://bitbucket.org/acme/api/pull-requests/9',
  'https://miro.com/app/board/uXjVN1a2b3c=/',
  'https://www.overleaf.com/project/64a1b2c3d4e5f60718293a4b',
  'https://colab.research.google.com/drive/1aBcD_eF-gHiJ',
  'https://acme.sharepoint.com/sites/eng/_layouts/15/Doc.aspx?sourcedoc=%7B1A2B3C4D-0000-1111-2222-333344445555%7D',
];
 // Real-length ids and long URLs: our stand-ins once used short ids, which hid
// Chrome's 2 KB compiled-regex limit (real Google Docs failed to start).
const LONG_TARGETS = [
  'https://docs.google.com/document/d/1CBz8qV_mD6rbDmTsMuosTOQGRXGhN3d8UrcULUI6Vkw/edit?tab=t.0',
  'https://docs.google.com/spreadsheets/u/1/d/1CBz8qV_mD6rbDmTsMuosTOQGRXGhN3d8UrcULUI6Vkw/edit#gid=0',
  'https://docs.google.com/document/d/e/2PACX-1vQ8xYz-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789AbCdEfGhIjKlMnOpQrStUvWxYz012345/pub',
  'https://drive.google.com/file/d/1CBz8qV_mD6rbDmTsMuosTOQGRXGhN3d8UrcULUI6Vkw/view',
  'https://github.com/a-very-long-organisation-name/an-even-longer-repository-name-for-testing/pull/123456',
  'https://acme-corporation-engineering.atlassian.net/browse/PLATFORMTEAM-123456',
  `https://example.com/${'section/'.repeat(30)}page?${'q=1&'.repeat(20)}x=2`,
  'https://www.notion.so/acme/A-very-long-page-title-that-goes-on-and-on-and-on-0123456789abcdef0123456789abcdef',
  'https://gitlab.example.com/group/subgroup/another-subgroup/very-long-project-name/-/merge_requests/123456',
];
const DOC44 = 'https://docs.google.com/document/d/1CBz8qV_mD6rbDmTsMuosTOQGRXGhN3d8UrcULUI6Vkw/edit';
const FIGMA = 'https://www.figma.com/design/AbCdEfGhIjKl123/Checkout';
const FIGMA_OTHER = 'https://www.figma.com/design/ZzZzZzZzZzZz999/Other';

describe('Web apps by resource id (real Chromium)', () => {
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

  test('without the Mac app, the toolbar button explains where Ekagrachit lives', async () => {
    await inSW(h, () => (globalThis as any).__ekagrachit.onActionClicked());
    const page = await waitFor(async () => h.ctx.pages().find((p) => p.url().endsWith('/app.html')) ?? null, (p) => p !== null, 6000, 'app.html');
    assert.match(await page!.textContent('h2') ?? '', /menu bar/);
    await page!.close();
  });

  test('every generated regex is supported by Chrome, with real-length ids and long URLs', async () => {
    const patterns = [...TARGETS, ...LONG_TARGETS].flatMap((t) => {
      const r = parseTarget(t);
      assert.ok(r.ok, t);
      if (TARGETS.includes(t)) assert.equal(r.identity.kind, 'service', t);
      return [...allowPatterns(r.identity), ...authPatterns(r.identity)].filter((p) => p.regex !== undefined) as { regex: string; caseSensitive: boolean }[];
    });
    const results = await inSW(h, (ps) => Promise.all(ps.map((p) =>
      chrome.declarativeNetRequest.isRegexSupported({ regex: p.regex, isCaseSensitive: p.caseSensitive })
        .then((r) => ({ regex: p.regex, ok: r.isSupported, reason: r.reason ?? '' })))), patterns);
    for (const r of results) assert.ok(r.ok, `${r.regex}: ${r.reason}`);
  });

  test('a Google Doc with a real-length id starts, keeps its views, blocks another doc', async () => {
    const s = await startSession(h, DOC44);
    await waitFor(() => tabUrl(h, s.tabId!), (u) => u?.startsWith(DOC44) === true);
    const view = 'https://docs.google.com/document/u/1/d/1CBz8qV_mD6rbDmTsMuosTOQGRXGhN3d8UrcULUI6Vkw/edit?tab=t.0';
    await inSW(h, (a) => chrome.tabs.update(a.tab, { url: a.url }).then(() => undefined), { tab: s.tabId!, url: view });
    await waitFor(() => tabUrl(h, s.tabId!), (u) => u === view, 8000, 'other view of the same doc loads');
    const other = 'https://docs.google.com/document/d/1CBz8qV_mD6rbDmTsMuosTOQGRXGhN3d8UrcULUI6VkX/edit';
    await inSW(h, (a) => chrome.tabs.update(a.tab, { url: a.url }).then(() => undefined), { tab: s.tabId!, url: other });
    await sleep(1200);
    assert.equal(server.hits('docs.google.com', '/document/d/1CBz8qV_mD6rbDmTsMuosTOQGRXGhN3d8UrcULUI6VkX'), 0, 'other doc never fetched');
    await inSW(h, (x) => (globalThis as any).__ekagrachit.requestEnd(x), s.sid);
    await waitFor(async () => (await inSW(h, async () => (await chrome.storage.local.get('session')).session ?? null)), (v) => v === null, 8000, 'ended');
  });

  test('a Figma session allows the file\'s views and blocks another file', async () => {
    const s = await startSession(h, FIGMA);
    await waitFor(() => tabUrl(h, s.tabId!), (u) => u?.startsWith(FIGMA) === true);
    // Same file, another view: allowed.
    const proto = 'https://www.figma.com/proto/AbCdEfGhIjKl123/Checkout?node-id=1-2';
    await inSW(h, (a) => chrome.tabs.update(a.tab, { url: a.url }).then(() => undefined), { tab: s.tabId!, url: proto });
    await waitFor(() => tabUrl(h, s.tabId!), (u) => u === proto, 8000, 'proto view loads');
    assert.ok(server.hits('www.figma.com', '/proto/AbCdEfGhIjKl123') > 0);
    // Another file: never fetched, and the tab returns to the file.
    await inSW(h, (a) => chrome.tabs.update(a.tab, { url: a.url }).then(() => undefined), { tab: s.tabId!, url: FIGMA_OTHER });
    await sleep(1200);
    assert.equal(server.hits('www.figma.com', '/design/ZzZzZzZzZzZz999'), 0, 'other file was never fetched');
    const u = await tabUrl(h, s.tabId!);
    assert.ok(u?.includes('AbCdEfGhIjKl123'), `still on the focus file: ${u}`);
  });
});
