import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isNewerSync, parseInbound } from '../../src/shared/protocol.ts';
import { cleanTitle, clampDurationMinutes, isExpired, parkUrl, reconcile, tooManyRestores, type SessionRecord } from '../../src/shared/session.ts';
import { parseTarget } from '../../src/shared/identity.ts';

const SID = 'abcdef0123456789';

test('Test F: malformed and unexpected native messages are rejected', () => {
  for (const bad of [
    null, 1, 'x', [], {}, { type: 'nope' },
    { type: 'sync' },
    { type: 'sync', epoch: 'e', seq: -1, session: null },
    { type: 'sync', epoch: 'e', seq: 1.5, session: null },
    { type: 'sync', epoch: 'e', seq: 1, session: { sid: 'short', target: 'https://x', remainingMs: 1, phase: 'active' } },
    { type: 'sync', epoch: 'e', seq: 1, session: { sid: SID, target: 'https://x', remainingMs: -5, phase: 'active' } },
    { type: 'sync', epoch: 'e', seq: 1, session: { sid: SID, target: 'https://x', remainingMs: 1e12, phase: 'active' } },
    { type: 'sync', epoch: 'e', seq: 1, session: { sid: SID, target: 'https://x', remainingMs: 5, phase: 'hacked' } },
    { type: 'sync', epoch: 'e', seq: 1, session: { sid: SID, target: 42, remainingMs: 5, phase: 'active' } },
    { type: 'focus', sid: '../../etc' },
    { type: 'host_status', appConnected: 'yes' },
    { type: 'start_result', cid: 'c', ok: 'true' },
  ]) {
    assert.equal(parseInbound(bad), null, JSON.stringify(bad));
  }
});

test('valid messages parse', () => {
  assert.deepEqual(parseInbound({ type: 'sync', epoch: 'e1', seq: 3, session: { sid: SID, target: 'https://x', remainingMs: 1000, phase: 'active', extra: 1 } }), {
    type: 'sync', epoch: 'e1', seq: 3, session: { sid: SID, target: 'https://x', remainingMs: 1000, phase: 'active' },
  });
  assert.deepEqual(parseInbound({ type: 'host_status', appConnected: true, hostVersion: '0.1.0' }), { type: 'host_status', appConnected: true, hostVersion: '0.1.0' });
});

test('v1 additions: reload and active tab requests', () => {
  assert.deepEqual(parseInbound({ type: 'reload' }), { type: 'reload' });
  assert.deepEqual(parseInbound({ type: 'active_tab_request', cid: 'c1' }), { type: 'active_tab_request', cid: 'c1' });
  assert.equal(parseInbound({ type: 'active_tab_request' }), null);
});

test('Test F: stale sync messages are ignored; a new app epoch resets ordering', () => {
  assert.ok(isNewerSync(null, { epoch: 'a', seq: 0 }));
  assert.ok(isNewerSync({ epoch: 'a', seq: 4 }, { epoch: 'a', seq: 5 }));
  assert.ok(!isNewerSync({ epoch: 'a', seq: 5 }, { epoch: 'a', seq: 5 }));
  assert.ok(!isNewerSync({ epoch: 'a', seq: 5 }, { epoch: 'a', seq: 2 }));
  assert.ok(isNewerSync({ epoch: 'a', seq: 5 }, { epoch: 'b', seq: 0 }));
});

function rec(over: Partial<SessionRecord> = {}): SessionRecord {
  return {
    sid: SID, owner: 'native', target: 'https://x', policy: { primary: { kind: 'page', allowHttp: false, host: 'x', port: '', path: '/', query: '' }, aliases: [] },
    startedAt: 0, endsAt: 1000, windowId: 1, tabId: 2, armed: true, armDeadline: 0, lastAllowedUrl: 'https://x', preexistingTabIds: [], browserRunId: 'r', ...over,
  };
}
const desired = (sid = SID) => ({ sid, target: 'https://x', remainingMs: 1000, phase: 'active' as const });

test('Test D: reconciliation of desired vs local session', () => {
  assert.deepEqual(reconcile(null, null, []), { kind: 'none' });
  assert.deepEqual(reconcile(rec(), null, []), { kind: 'end' });
  assert.deepEqual(reconcile(rec({ owner: 'extension' }), null, []), { kind: 'none' });
  assert.equal(reconcile(null, desired(), []).kind, 'start');
  assert.equal(reconcile(rec(), desired(), []).kind, 'adopt');
  assert.equal(reconcile(rec(), desired('zzzzzzzzzzzzzzzz'), []).kind, 'replace');
  assert.deepEqual(reconcile(null, desired(), [SID]), { kind: 'reject_ended', sid: SID });
});

test('deadlines and limits', () => {
  assert.ok(!isExpired({ endsAt: 1000, owner: 'extension' }, 999));
  assert.ok(isExpired({ endsAt: 1000, owner: 'extension' }, 1000));
  assert.ok(!isExpired({ endsAt: 1000, owner: 'native' }, 2000)); // native grace: app ends it first
  assert.ok(isExpired({ endsAt: 1000, owner: 'native' }, 4000));
  assert.equal(clampDurationMinutes(25), 25);
  assert.equal(clampDurationMinutes(0), null);
  assert.equal(clampDurationMinutes(481), null);
  assert.equal(clampDurationMinutes(Number.NaN), null);
  assert.ok(tooManyRestores([1, 2, 3, 4, 5, 6, 7, 8], 10));
  assert.ok(!tooManyRestores([1, 2, 3], 10));
});

test('saved for later: only real, new, off-target links are parked', () => {
  const t = parseTarget('https://docs.google.com/document/d/DOC_A/edit');
  if (!t.ok) throw new Error();
  const policy = { primary: t.identity, aliases: [] };
  const list: string[] = [];
  assert.equal(parkUrl(list, 'https://acme.atlassian.net/browse/X-1#c', policy), 'acme.atlassian.net');
  assert.equal(parkUrl(list, 'https://acme.atlassian.net/browse/X-1', policy), null, 'duplicate ignoring fragment');
  assert.equal(parkUrl(list, 'https://docs.google.com/document/d/DOC_A/edit#h', policy), null, 'the focus document itself');
  assert.equal(parkUrl(list, 'https://accounts.google.com/x', policy), null, 'sign-in flow');
  assert.equal(parkUrl(list, 'chrome://newtab/', policy), null);
  assert.equal(parkUrl(list, 'about:blank', policy), null);
  assert.equal(parkUrl(list, 'https://u:p@evil.example/', policy), null);
  assert.equal(parkUrl(list, 'not a url', policy), null);
  assert.equal(parkUrl(list, 'https://docs.google.com/document/d/DOC_B/edit', policy), 'docs.google.com');
  assert.deepEqual(list, ['https://acme.atlassian.net/browse/X-1', 'https://docs.google.com/document/d/DOC_B/edit']);
  const full = Array.from({ length: 3 }, (_, i) => `https://x.example/${i}`);
  assert.equal(parkUrl(full, 'https://y.example/', policy, 3), null, 'capped');
});

test('document titles are shown without the product suffix', () => {
  assert.equal(cleanTitle('Design review - Google Docs'), 'Design review');
  assert.equal(cleanTitle('Q3 plan – Google Sheets'), 'Q3 plan');
  assert.equal(cleanTitle('Fix race in bridge · Pull Request #12 · org/repo'), 'Fix race in bridge · Pull Request #12 · org/repo');
});

test('saved for later unwraps Google Docs link redirects', () => {
  const t = parseTarget('https://docs.google.com/document/d/DOC_A/edit');
  if (!t.ok) throw new Error();
  const policy = { primary: t.identity, aliases: [] };
  const list: string[] = [];
  assert.equal(parkUrl(list, 'https://www.google.com/url?q=https://acme.atlassian.net/browse/X-9&sa=D&source=editors&ust=1', policy), 'acme.atlassian.net');
  assert.deepEqual(list, ['https://acme.atlassian.net/browse/X-9']);
  assert.equal(parkUrl(list, 'https://www.google.com/url?q=javascript:alert(1)', policy), 'www.google.com', 'non-http targets are not unwrapped');
});
