import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  type FocusPolicy,
  type Identity,
  allowPatterns,
  authPatterns,
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
  assert.ok(allowPatterns(page).some((p) => new RegExp(p.regex).test('https://example.com/?q=1')));
  assert.ok(!sameResource(page, 'https://example.com/?q=1'));
  for (const [target, allowed, denied] of cases) {
    const ident = id(target);
    const res = allowPatterns(ident).map((p) => new RegExp(p.regex, p.caseSensitive ? '' : 'i'));
    const hit = (u: string) => res.some((r) => r.test(new URL(u).href));
    for (const u of allowed) {
      assert.ok(sameResource(ident, u), `matcher should allow ${u}`);
      assert.ok(hit(u), `DNR regex should allow ${u}`);
    }
    for (const u of denied) assert.ok(!hit(u), `DNR regex should block ${u}`);
  }
  const auth = authPatterns(id(DOC_A)).map((p) => new RegExp(p.regex, 'i'));
  assert.ok(auth.some((r) => r.test('https://accounts.google.com/v3/signin/identifier?x')));
  assert.ok(!auth.some((r) => r.test('https://accounts.google.com.evil/')));
});
