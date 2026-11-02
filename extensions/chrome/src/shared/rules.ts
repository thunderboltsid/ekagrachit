/**
 * Builds the declarativeNetRequest *session* rules that implement proactive
 * (pre-navigation) blocking during a focus session. Pure function; the
 * background worker installs the result with updateSessionRules.
 *
 *  - Rule OTHER_TABS: block every top-level (main_frame) load in tabs that did
 *    not exist when the session started, except the focus tab. New tabs and
 *    windows therefore never load content; the guard then closes them. Tabs
 *    that existed before the session are excluded so the user's existing
 *    browsing state is never modified.
 *  - Rule FOCUS_BLOCK + allow rules: in the focus tab, block every top-level
 *    load that does not match the target resource (or its auth flow).
 *
 * Only main_frame is filtered: sub-resources, XHR/fetch, websockets and
 * iframes (Docs relies on many of these) are never touched.
 */
import { type FocusPolicy, allowPatterns, authPatterns } from './identity.ts';

export const RULE_OTHER_TABS = 1;
export const RULE_FOCUS_BLOCK = 2;
export const RULE_ALLOW_BASE = 100;
export const MAX_RULE_ID = 199;

/** Minimal structural type compatible with chrome.declarativeNetRequest.Rule. */
export interface DnrRule {
  id: number;
  priority: number;
  action: { type: 'block' | 'allow' };
  condition: {
    resourceTypes: ['main_frame'];
    tabIds?: number[];
    excludedTabIds?: number[];
    regexFilter?: string;
    isUrlFilterCaseSensitive?: boolean;
  };
}

export interface RuleInput {
  policy: FocusPolicy;
  focusTabId: number;
  preexistingTabIds: number[];
  /** When false (landing grace period), the focus tab is not yet restricted. */
  armed: boolean;
}

export function buildRules(input: RuleInput): DnrRule[] {
  const excluded = Array.from(new Set([input.focusTabId, ...input.preexistingTabIds])).filter((id) => id >= 0);
  const rules: DnrRule[] = [
    {
      id: RULE_OTHER_TABS,
      priority: 1,
      action: { type: 'block' },
      condition: { resourceTypes: ['main_frame'], excludedTabIds: excluded },
    },
  ];
  if (!input.armed) return rules;

  rules.push({
    id: RULE_FOCUS_BLOCK,
    priority: 1,
    action: { type: 'block' },
    condition: { resourceTypes: ['main_frame'], tabIds: [input.focusTabId] },
  });

  const patterns = [
    ...allowPatterns(input.policy.primary),
    ...input.policy.aliases.flatMap((a) => allowPatterns(a)),
    ...authPatterns(input.policy.primary),
  ];
  let id = RULE_ALLOW_BASE;
  for (const p of patterns) {
    if (id > MAX_RULE_ID) break; // aliases are capped well below this; defensive
    rules.push({
      id: id++,
      priority: 2,
      action: { type: 'allow' },
      condition: {
        resourceTypes: ['main_frame'],
        tabIds: [input.focusTabId],
        regexFilter: p.regex,
        isUrlFilterCaseSensitive: p.caseSensitive,
      },
    });
  }
  return rules;
}

/** All rule ids this extension may own, for idempotent removal. */
export function allRuleIds(): number[] {
  const ids = [RULE_OTHER_TABS, RULE_FOCUS_BLOCK];
  for (let i = RULE_ALLOW_BASE; i <= MAX_RULE_ID; i++) ids.push(i);
  return ids;
}
