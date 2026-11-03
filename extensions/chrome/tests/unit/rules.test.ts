import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseTarget } from '../../src/shared/identity.ts';
import { RULE_FOCUS_BLOCK, RULE_OTHER_TABS, allRuleIds, buildRules } from '../../src/shared/rules.ts';

const parsed = parseTarget('https://docs.google.com/document/d/ABC123/edit');
if (!parsed.ok) throw new Error('parse');
const policy = { primary: parsed.identity, aliases: [] };

test('only main_frame requests are ever filtered', () => {
  for (const r of buildRules({ policy, focusTabId: 7, preexistingTabIds: [1, 2], armed: true })) {
    assert.deepEqual(r.condition.resourceTypes, ['main_frame']);
  }
});

test('other-tabs rule excludes the focus tab and pre-existing tabs', () => {
  const rules = buildRules({ policy, focusTabId: 7, preexistingTabIds: [1, 2, 7, -1], armed: false });
  assert.equal(rules.length, 1);
  assert.equal(rules[0]!.id, RULE_OTHER_TABS);
  assert.deepEqual(rules[0]!.condition.excludedTabIds, [7, 1, 2]);
});

test('armed focus tab: block-all plus higher-priority allow rules scoped to the tab', () => {
  const rules = buildRules({ policy, focusTabId: 7, preexistingTabIds: [], armed: true });
  const block = rules.find((r) => r.id === RULE_FOCUS_BLOCK)!;
  assert.deepEqual(block.condition.tabIds, [7]);
  const allows = rules.filter((r) => r.action.type === 'allow');
  assert.ok(allows.length >= 3); // docs + drive + auth
  for (const a of allows) {
    assert.deepEqual(a.condition.tabIds, [7]);
    assert.ok(a.priority > block.priority);
    const f = a.condition.regexFilter ?? a.condition.urlFilter;
    assert.ok(f && f.length < 1024);
  }
  const ids = new Set(rules.map((r) => r.id));
  assert.equal(ids.size, rules.length);
  for (const r of rules) assert.ok(allRuleIds().includes(r.id));
});
