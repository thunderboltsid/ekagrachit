import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  type FocusPolicy,
  type Identity,
  allowPatterns,
  authPatterns,
  describe,
  patternRegExp,
  evaluate,
  parseTarget,
  sameResource,
} from '../../src/shared/identity.ts';

function id(url: string): Identity {
  const r = parseTarget(url);
  assert.ok(r.ok, `expected ${url} to parse`);
  return r.identity;
}
const policy = (url: string): FocusPolicy => ({ primary: id(url), aliases: [] });

const DOC_A = 'https://docs.google.com/document/d/1AbC_dEf-123/edit';

test('Test C: Google Doc identity (same document variants are allowed)', () => {
  const p = policy(DOC_A);
  for (const ok of [
    DOC_A,
    'https://docs.google.com/document/d/1AbC_dEf-123/edit#heading=h.abc',
    'https://docs.google.com/document/d/1AbC_dEf-123/edit?tab=t.0',
    'https://docs.google.com/document/d/1AbC_dEf-123/edit?usp=sharing&tab=t.0#bookmark=id.x',
    'https://docs.google.com/document/d/1AbC_dEf-123',
    'https://docs.google.com/document/d/1AbC_dEf-123/',
    'https://docs.google.com/document/d/1AbC_dEf-123/view',
    'https://docs.google.com/document/d/1AbC_dEf-123/preview',
    'https://docs.google.com/document/d/1AbC_dEf-123/comment',
    'https://docs.google.com/document/u/1/d/1AbC_dEf-123/edit',
    'https://docs.google.com/a/example.com/document/d/1AbC_dEf-123/edit',
    'https://DOCS.GOOGLE.COM/document/d/1AbC_dEf-123/edit',
    'https://docs.google.com./document/d/1AbC_dEf-123/edit',
    'https://drive.google.com/file/d/1AbC_dEf-123/view',
    'https://drive.google.com/open?id=1AbC_dEf-123',
  ]) {
    assert.equal(evaluate(p, ok), 'allow', ok);
  }
});

test('Test C: other documents, Docs home and unrelated sites are denied', () => {
  const p = policy(DOC_A);
  for (const bad of [
    'https://docs.google.com/document/d/DEF/edit',
    'https://docs.google.com/document/d/1AbC_dEf-1234/edit', // prefix extension
    'https://docs.google.com/document/d/1abc_def-123/edit', // IDs are case-sensitive
    'https://docs.google.com/document/u/0/',
    'https://docs.google.com/',
    'https://drive.google.com/drive/my-drive',
    'https://example.atlassian.net/browse/ABC-1',
    'https://github.com/org/repo/pull/1',
    'https://slack.com/',
    'http://docs.google.com/document/d/1AbC_dEf-123/edit', // downgrade
    'https://docs.google.com:8443/document/d/1AbC_dEf-123/edit',
    'https://docs.google.com.evil.example/document/d/1AbC_dEf-123/edit',
    'https://evil.example/docs.google.com/document/d/1AbC_dEf-123/edit',
    'https://docs.google.com@evil.example/document/d/1AbC_dEf-123/edit',
    'https://user:pw@docs.google.com/document/d/1AbC_dEf-123/edit',
    'https://docs.google.com/document/d/1AbC_dEf-123%2F../DEF/edit',
    'https://docs.google.com/document/d/e/1AbC_dEf-123/pub', // published id namespace is distinct
    'javascript:alert(1)',
    'data:text/html,hi',
    'file:///etc/passwd',
    'chrome://settings',
    'not a url',
  ]) {
    assert.equal(evaluate(p, bad), 'deny', bad);
  }
});

test('Google auth flow is permitted but is not the resource', () => {
  const p = policy(DOC_A);
  assert.equal(evaluate(p, 'https://accounts.google.com/ServiceLogin?continue=x'), 'auth');
  assert.equal(evaluate(p, 'https://accounts.youtube.com/accounts/SetSID?ssdc=1'), 'auth');
  assert.equal(evaluate(p, 'https://accounts.youtube.com/watch'), 'deny');
  assert.equal(evaluate(p, 'https://myaccount.google.com/'), 'deny');
  assert.equal(evaluate(p, 'about:blank'), 'neutral');
});

test('other Google editors are recognised by document id', () => {
  const sheet = policy('https://docs.google.com/spreadsheets/d/SHEET1/edit#gid=0');
  assert.equal(evaluate(sheet, 'https://docs.google.com/spreadsheets/d/SHEET1/edit?gid=5#gid=5'), 'allow');
  assert.equal(evaluate(sheet, 'https://docs.google.com/spreadsheets/d/SHEET2/edit'), 'deny');
  const pub = policy('https://docs.google.com/document/d/e/2PACX-pub/pub');
  assert.equal(evaluate(pub, 'https://docs.google.com/document/d/e/2PACX-pub/pub?embedded=true'), 'allow');
  assert.equal(evaluate(pub, 'https://docs.google.com/document/d/2PACX-pub/edit'), 'deny');
});

test('GitHub PR identity covers its tabs but not the rest of github.com', () => {
  const p = policy('https://github.com/Org/Repo/pull/42');
  for (const ok of [
    'https://github.com/org/repo/pull/42/files',
    'https://github.com/Org/Repo/pull/42/commits?w=1',
    'https://github.com/org/repo/pull/42#discussion_r1',
    'https://github.com/org/repo/issues/42', // GitHub redirects issues/N <-> pull/N
  ]) assert.equal(evaluate(p, ok), 'allow', ok);
  for (const bad of [
    'https://github.com/org/repo/pull/421',
    'https://github.com/org/repo/pull/4',
    'https://github.com/org/repo',
    'https://github.com/org/other/pull/42',
    'https://github.com/org/repo/discussions/42',
    'https://github.com/notifications',
    'https://gist.github.com/org/repo/pull/42',
  ]) assert.equal(evaluate(p, bad), 'deny', bad);
  assert.equal(evaluate(p, 'https://github.com/login?return_to=x'), 'auth');
  assert.equal(evaluate(p, 'https://github.com/loginx'), 'deny');
});

test('Jira issue identity', () => {
  const p = policy('https://acme.atlassian.net/browse/PROJ-12');
  assert.equal(evaluate(p, 'https://acme.atlassian.net/browse/PROJ-12?focusedCommentId=1'), 'allow');
  assert.equal(evaluate(p, 'https://acme.atlassian.net/browse/PROJ-123'), 'deny');
  assert.equal(evaluate(p, 'https://other.atlassian.net/browse/PROJ-12'), 'deny');
  assert.equal(evaluate(p, 'https://acme.atlassian.net/jira/your-work'), 'deny');
  assert.equal(evaluate(p, 'https://id.atlassian.com/login'), 'auth');
});

test('generic pages: exact page with defined normalisation', () => {
  const p = policy('https://example.com/a/b?x=1&y=2#top');
  for (const ok of [
    'https://example.com/a/b?x=1&y=2',
    'https://example.com/a/b/?y=2&x=1', // trailing slash, param order
    'https://example.com/a/b?x=1&y=2&utm_source=news&fbclid=1', // tracking params
    'https://EXAMPLE.com:443/a/b?x=1&y=2#other',
  ]) assert.equal(evaluate(p, ok), 'allow', ok);
  for (const bad of [
    'https://example.com/a/b?x=1',
    'https://example.com/a/b?x=1&y=3',
    'https://example.com/a/c?x=1&y=2',
    'https://example.com/A/b?x=1&y=2', // paths are case-sensitive
    'https://example.com/a/b/c?x=1&y=2',
    'https://www.example.com/a/b?x=1&y=2',
    'https://example.com:8443/a/b?x=1&y=2',
    'http://example.com/a/b?x=1&y=2',
    'https://example.com/a/%62?x=1&y=2', // percent-encoding variants are distinct (conservative)
  ]) assert.equal(evaluate(p, bad), 'deny', bad);
});

test('http targets may be upgraded to https, never the reverse', () => {
  const p = policy('http://intranet.local/wiki/page');
  assert.equal(evaluate(p, 'https://intranet.local/wiki/page'), 'allow');
  assert.equal(evaluate(p, 'http://intranet.local/wiki/page'), 'allow');
});

test('parseTarget validation', () => {
  assert.equal(parseTarget('').ok, false);
  assert.equal(parseTarget('ftp://x.example/').ok, false);
  assert.equal(parseTarget('javascript:alert(1)').ok, false);
  assert.equal(parseTarget('https://u:p@example.com').ok, false);
  const bare = parseTarget('example.com/x');
  assert.ok(bare.ok && bare.url === 'https://example.com/x');
});

test('aliases from landing redirects extend the policy exactly', () => {
  const p: FocusPolicy = { primary: id('https://example.com/start'), aliases: [id('https://www.example.com/start/')] };
  assert.equal(evaluate(p, 'https://www.example.com/start'), 'allow');
  assert.equal(evaluate(p, 'https://www.example.com/other'), 'deny');
});

// DNR regexes must never be stricter than the matcher for legitimate URLs,
// and must reject the obvious escapes (they may be looser for queries).
test('DNR allow regexes agree with the matcher', () => {
  const cases: [string, string[], string[]][] = [
    [
      DOC_A,
      [
        DOC_A,
        'https://docs.google.com/document/d/1AbC_dEf-123/edit?tab=t.0#heading=h.x',
        'https://docs.google.com/document/u/2/d/1AbC_dEf-123/edit',
        'https://docs.google.com/document/d/1AbC_dEf-123',
        'https://drive.google.com/open?id=1AbC_dEf-123',
        'https://drive.google.com/file/d/1AbC_dEf-123/view',
      ],
      [
        'https://docs.google.com/document/d/DEF/edit',
        'https://docs.google.com/document/d/1AbC_dEf-1234/edit',
        'https://docs.google.com/',
        'https://jira.example.com/',
        'https://docs.google.com.evil.example/document/d/1AbC_dEf-123/edit',
      ],
    ],
    [
      'https://github.com/org/repo/pull/42',
      ['https://github.com/org/repo/pull/42/files', 'https://github.com/Org/Repo/issues/42'],
      ['https://github.com/org/repo/pull/421', 'https://github.com/org/repo', 'https://github.com/'],
    ],
    [
      'https://example.com/a/b?x=1',
      ['https://example.com/a/b?x=1', 'https://example.com/a/b/?x=1#f'],
      ['https://example.com/a/bc', 'https://example.com/a', 'https://example.com/a/b/c', 'https://example.com.evil/a/b'],
    ],
    [
      'https://example.com/',
      ['https://example.com/'],
      ['https://example.com/x', 'https://example.community/'],
    ],
  ];
  // Documented looseness: DNR cannot normalise queries, so a different query on
  // the same page passes DNR and is reverted by the event-driven guard instead.
  const page = id('https://example.com/');
  assert.ok(allowPatterns(page).some((p) => patternRegExp(p).test('https://example.com/?q=1')));
  assert.ok(!sameResource(page, 'https://example.com/?q=1'));
  for (const [target, allowed, denied] of cases) {
    const ident = id(target);
    const res = allowPatterns(ident).map((p) => patternRegExp(p));
    const hit = (u: string) => res.some((r) => r.test(new URL(u).href));
    for (const u of allowed) {
      assert.ok(sameResource(ident, u), `matcher should allow ${u}`);
      assert.ok(hit(u), `DNR regex should allow ${u}`);
    }
    for (const u of denied) assert.ok(!hit(u), `DNR regex should block ${u}`);
  }
  const auth = authPatterns(id(DOC_A)).map((p) => patternRegExp(p));
  assert.ok(auth.some((r) => r.test('https://accounts.google.com/v3/signin/identifier?x')));
  assert.ok(!auth.some((r) => r.test('https://accounts.google.com.evil/')));
});

// ---------------------------------------------------------------------------
// Web apps recognised by resource id. For each: URLs of the same resource
// (matcher AND DNR allow regex accept), and near misses (both reject).
// ---------------------------------------------------------------------------
const SERVICE_CASES: { name: string; target: string; same: string[]; other: string[]; label: string }[] = [
  {
    name: 'Notion',
    target: 'https://www.notion.so/acme/Design-Review-0123456789abcdef0123456789abcdef',
    same: [
      'https://www.notion.so/acme/Design-Review-0123456789abcdef0123456789abcdef?pvs=4',
      'https://notion.so/acme/Renamed-Title-0123456789abcdef0123456789abcdef',
      'https://www.notion.so/0123456789abcdef0123456789abcdef#block',
      'https://www.notion.so/01234567-89ab-cdef-0123-456789abcdef',
    ],
    other: [
      'https://www.notion.so/acme/Other-fedcba9876543210fedcba9876543210',
      'https://www.notion.so/acme',
      'https://www.notion.so.evil.example/0123456789abcdef0123456789abcdef',
    ],
    label: 'Notion page',
  },
  {
    name: 'Notion site',
    target: 'https://acme.notion.site/Handbook-0123456789abcdef0123456789abcdef',
    same: ['https://acme.notion.site/0123456789abcdef0123456789abcdef'],
    other: ['https://other.notion.site/Handbook-0123456789abcdef0123456789abcdef'],
    label: 'Notion page',
  },
  {
    name: 'Figma',
    target: 'https://www.figma.com/design/AbCdEfGhIjKl123/Checkout?node-id=1-2',
    same: [
      'https://www.figma.com/design/AbCdEfGhIjKl123/Checkout?node-id=4-7&t=x',
      'https://figma.com/file/AbCdEfGhIjKl123/Checkout',
      'https://www.figma.com/proto/AbCdEfGhIjKl123/Checkout',
    ],
    other: ['https://www.figma.com/design/ZzCdEfGhIjKl123/Other', 'https://www.figma.com/files/recent', 'https://www.figma.com/design/abcdefghijkl123/x'],
    label: 'Figma file',
  },
  {
    name: 'Linear',
    target: 'https://linear.app/acme/issue/ENG-123/fix-login',
    same: ['https://linear.app/acme/issue/ENG-123', 'https://linear.app/acme/issue/ENG-123/renamed#comment-1'],
    other: ['https://linear.app/acme/issue/ENG-1234', 'https://linear.app/acme/team/ENG/active', 'https://linear.app/other/issue/ENG-123'],
    label: 'ENG-123',
  },
  {
    name: 'Confluence',
    target: 'https://acme.atlassian.net/wiki/spaces/ENG/pages/123456/Runbook',
    same: [
      'https://acme.atlassian.net/wiki/spaces/ENG/pages/123456/Runbook+v2',
      'https://acme.atlassian.net/wiki/spaces/ENG/pages/123456',
      'https://acme.atlassian.net/wiki/pages/viewpage.action?pageId=123456',
    ],
    other: ['https://acme.atlassian.net/wiki/spaces/ENG/pages/1234567/Other', 'https://acme.atlassian.net/wiki/home', 'https://evil.atlassian.net/wiki/spaces/ENG/pages/123456'],
    label: 'Confluence page',
  },
  {
    name: 'GitLab',
    target: 'https://gitlab.com/acme/platform/api/-/merge_requests/42',
    same: ['https://gitlab.com/acme/platform/api/-/merge_requests/42/diffs', 'https://gitlab.com/Acme/Platform/API/-/merge_requests/42#note_1'],
    other: ['https://gitlab.com/acme/platform/api/-/merge_requests/421', 'https://gitlab.com/acme/platform/api/-/issues/42', 'https://gitlab.com/acme/platform/api'],
    label: 'acme/platform/api !42',
  },
  {
    name: 'Self-hosted GitLab',
    target: 'https://git.example.com/team/repo/-/issues/7',
    same: ['https://git.example.com/team/repo/-/issues/7?x=1'],
    other: ['https://gitlab.com/team/repo/-/issues/7', 'https://git.example.com/team/repo/-/issues/8'],
    label: 'team/repo #7',
  },
  {
    name: 'Bitbucket',
    target: 'https://bitbucket.org/acme/api/pull-requests/9',
    same: ['https://bitbucket.org/acme/api/pull-requests/9/diff', 'https://bitbucket.org/acme/api/pull-requests/9/overview'],
    other: ['https://bitbucket.org/acme/api/pull-requests/90', 'https://bitbucket.org/acme/api/src/main'],
    label: 'acme/api #9',
  },
  {
    name: 'Miro',
    target: 'https://miro.com/app/board/uXjVN1a2b3c=/',
    same: ['https://miro.com/app/board/uXjVN1a2b3c=/?moveToWidget=345', 'https://miro.com/app/board/uXjVN1a2b3c='],
    other: ['https://miro.com/app/board/uXjVOther=/', 'https://miro.com/app/dashboard/'],
    label: 'Miro board',
  },
  {
    name: 'Overleaf',
    target: 'https://www.overleaf.com/project/64a1b2c3d4e5f60718293a4b',
    same: ['https://www.overleaf.com/project/64a1b2c3d4e5f60718293a4b/detacher', 'https://overleaf.com/project/64a1b2c3d4e5f60718293a4b'],
    other: ['https://www.overleaf.com/project', 'https://www.overleaf.com/project/64a1b2c3d4e5f60718293a4c'],
    label: 'Overleaf project',
  },
  {
    name: 'Colab',
    target: 'https://colab.research.google.com/drive/1aBcD_eF-gHiJ',
    same: ['https://colab.research.google.com/drive/1aBcD_eF-gHiJ#scrollTo=xyz'],
    other: ['https://colab.research.google.com/drive/1aBcD_eF-gHiJK', 'https://colab.research.google.com/'],
    label: 'Colab notebook',
  },
  {
    name: 'SharePoint / Office for the web',
    target: 'https://acme.sharepoint.com/:w:/r/sites/eng/_layouts/15/Doc.aspx?sourcedoc=%7B1A2B3C4D-0000-1111-2222-333344445555%7D&file=Plan.docx&action=default',
    same: [
      'https://acme.sharepoint.com/sites/eng/_layouts/15/Doc.aspx?sourcedoc={1a2b3c4d-0000-1111-2222-333344445555}&action=edit',
      'https://acme.sharepoint.com/sites/eng/_layouts/15/Doc.aspx?sourcedoc=%7B1A2B3C4D-0000-1111-2222-333344445555%7D&file=Plan.docx&mobileredirect=true',
    ],
    other: [
      'https://acme.sharepoint.com/sites/eng/_layouts/15/Doc.aspx?sourcedoc=%7B9A2B3C4D-0000-1111-2222-333344445555%7D',
      'https://acme.sharepoint.com/sites/eng',
      'https://other.sharepoint.com/sites/eng/_layouts/15/Doc.aspx?sourcedoc=%7B1A2B3C4D-0000-1111-2222-333344445555%7D',
    ],
    label: 'Microsoft 365 document',
  },
];

for (const c of SERVICE_CASES) {
  test(`${c.name}: same resource across URL variants, nothing else`, () => {
    const ident = id(c.target);
    assert.equal(ident.kind, 'service', `${c.target} should be recognised`);
    assert.equal(describe(ident), c.label);
    const res = allowPatterns(ident).map((p) => patternRegExp(p));
    const hit = (u: string) => res.some((r) => r.test(new URL(u).href));
    for (const u of [c.target, ...c.same]) {
      assert.ok(sameResource(ident, u), `matcher should allow ${u}`);
      assert.ok(hit(u), `DNR regex should allow ${u}`);
    }
    for (const u of c.other) {
      assert.ok(!sameResource(ident, u), `matcher should deny ${u}`);
      assert.ok(!hit(u) || !sameResource(ident, u), `guard must deny ${u}`);
    }
  });
}

test('web app sign-in pages are auth, not the resource', () => {
  const cases: [string, string, string][] = [
    ['https://www.figma.com/design/AbCdEfGhIjKl123/x', 'https://www.figma.com/login?cont=x', 'https://www.figma.com/files'],
    ['https://linear.app/acme/issue/ENG-1', 'https://linear.app/login', 'https://linear.app/acme/inbox'],
    ['https://acme.atlassian.net/wiki/spaces/E/pages/1/x', 'https://id.atlassian.com/login?continue=x', 'https://acme.atlassian.net/jira'],
    ['https://gitlab.com/a/b/-/issues/1', 'https://gitlab.com/users/sign_in', 'https://gitlab.com/explore'],
    ['https://acme.sharepoint.com/x/Doc.aspx?sourcedoc=%7B1A2B3C4D-0000-1111-2222-333344445555%7D', 'https://login.microsoftonline.com/common/oauth2', 'https://www.office.com/'],
    ['https://www.notion.so/0123456789abcdef0123456789abcdef', 'https://accounts.google.com/o/oauth2/auth', 'https://www.notion.so/acme'],
  ];
  for (const [target, auth, deny] of cases) {
    const p = policy(target);
    assert.equal(evaluate(p, auth), 'auth', auth);
    assert.ok(authPatterns(p.primary).some((r) => patternRegExp(r).test(auth)), `auth regex ${auth}`);
    assert.equal(evaluate(p, deny), 'deny', deny);
  }
});

test('web app lookalikes stay exact pages', () => {
  for (const u of ['http://linear.app/acme/issue/ENG-1', 'https://linear.app:8443/acme/issue/ENG-1', 'https://figma.com.evil.example/design/AbCdEfGhIjKl123/x']) {
    assert.equal(id(u).kind, 'page', u);
  }
});
