import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isNewerSync, parseInbound } from '../../src/shared/protocol.ts';
import { clampDurationMinutes, isExpired, reconcile, tooManyRestores, type SessionRecord } from '../../src/shared/session.ts';

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
