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

  test('every generated regex is supported by Chrome', async () => {
    const patterns = TARGETS.flatMap((t) => {
      const r = parseTarget(t);
      assert.ok(r.ok && r.identity.kind === 'service', t);
      return [...allowPatterns(r.identity), ...authPatterns(r.identity)];
    });
    const results = await inSW(h, (ps) => Promise.all(ps.map((p) =>
      chrome.declarativeNetRequest.isRegexSupported({ regex: p.regex, isCaseSensitive: p.caseSensitive })
        .then((r) => ({ regex: p.regex, ok: r.isSupported, reason: r.reason ?? '' })))), patterns);
    for (const r of results) assert.ok(r.ok, `${r.regex}: ${r.reason}`);
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
