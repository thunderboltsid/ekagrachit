/**
 * Extension-side session record and the pure reconciliation function that maps
 * the app's authoritative `sync` onto local actions.
 */
import { type FocusPolicy, evaluate } from './identity.ts';
import type { DesiredSession } from './protocol.ts';

export type Owner = 'extension' | 'native';

export interface SessionRecord {
  sid: string;
  owner: Owner;
  target: string;
  policy: FocusPolicy;
  startedAt: number;
  /** Wall-clock deadline (ms since epoch). */
  endsAt: number;
  windowId: number | null;
  tabId: number | null;
  /** False during the landing grace period (exact-page targets only). */
  armed: boolean;
  /** Wall-clock time after which the session is armed even without a matching commit. */
  armDeadline: number;
  lastAllowedUrl: string;
  /** Links the user reached for during the session ("saved for later"). Optional for older records. */
  parked?: string[];
  /** The focus tab's title (the document's name), for display only. */
  title?: string;
  /** Tabs that existed when enforcement started; never touched by the guard. */
  preexistingTabIds: number[];
  /** Identifies the browser run in which windowId/tabId are valid. */
  browserRunId: string;
}

export const MAX_ALIASES = 4;
export const NATIVE_DEADLINE_GRACE_MS = 3_000;
export const MAX_SESSION_MS = 8 * 3600_000;
export const MIN_SESSION_MS = 60_000;

export type ReconcileAction =
  | { kind: 'none' }
  | { kind: 'start'; desired: DesiredSession }
  | { kind: 'replace'; desired: DesiredSession }
  | { kind: 'adopt'; desired: DesiredSession }
  | { kind: 'end' }
  | { kind: 'reject_ended'; sid: string };

/**
 * @param local      current local session, if any
 * @param desired    session the app wants (null = none)
 * @param endedSids  sids the user ended locally (tombstones); never resurrected
 */
export function reconcile(local: SessionRecord | null, desired: DesiredSession | null, endedSids: readonly string[]): ReconcileAction {
  if (desired === null) {
    // The app owns native sessions; a standalone (extension-owned) session that
    // the app did not adopt keeps running on its own deadline.
    if (local !== null && local.owner === 'native') return { kind: 'end' };
    return { kind: 'none' };
  }
  if (endedSids.includes(desired.sid)) return { kind: 'reject_ended', sid: desired.sid };
  if (local === null) return { kind: 'start', desired };
  if (local.sid !== desired.sid) return { kind: 'replace', desired };
  return { kind: 'adopt', desired };
}

/** Remaining ms, never negative. */
export function remainingMs(rec: Pick<SessionRecord, 'endsAt'>, now: number): number {
  return Math.max(0, rec.endsAt - now);
}

export function isExpired(rec: Pick<SessionRecord, 'endsAt' | 'owner'>, now: number): boolean {
  const grace = rec.owner === 'native' ? NATIVE_DEADLINE_GRACE_MS : 0;
  return now >= rec.endsAt + grace;
}

export function clampDurationMinutes(minutes: number): number | null {
  if (!Number.isFinite(minutes)) return null;
  const ms = Math.round(minutes) * 60_000;
  if (ms < MIN_SESSION_MS || ms > MAX_SESSION_MS) return null;
  return Math.round(minutes);
}

/** Restore-loop breaker: true if too many restores happened recently. */
export function tooManyRestores(timestamps: readonly number[], now: number, windowMs = 30_000, max = 8): boolean {
  return timestamps.filter((t) => now - t < windowMs).length >= max;
}

export const MAX_PARKED = 50;

/**
 * Adds a blocked link to the "saved for later" list. Only http(s) URLs that are
 * not the focus resource or its sign-in flow are kept; duplicates (ignoring the
 * fragment) are dropped. Returns the host to show, or null if nothing was added.
 */
export function parkUrl(list: string[], rawUrl: string, policy: FocusPolicy, max = MAX_PARKED): string | null {
  let url: URL;
  try {
    url = unwrapRedirect(new URL(rawUrl));
  } catch {
    return null;
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return null;
  if (url.username || url.password) return null;
  const verdict = evaluate(policy, url.href);
  if (verdict === 'allow' || verdict === 'auth') return null;
  url.hash = '';
  const key = url.href;
  if (list.some((u) => u.split('#')[0] === key)) return null;
  if (list.length >= max) return null;
  list.push(key);
  return url.hostname;
}

/** "Design review - Google Docs" -> "Design review". */
export function cleanTitle(raw: string): string {
  return raw.replace(/\s+[-–—]\s+(Google (Docs|Sheets|Slides|Forms|Drawings|Drive)|Jira|GitHub)$/i, '').trim().slice(0, 120);
}

/**
 * Google Docs/Sheets/Slides route external links through
 * https://www.google.com/url?q=<target>; keep the real destination.
 */
export function unwrapRedirect(url: URL): URL {
  const host = url.hostname.replace(/^www\./, '');
  if ((host === 'google.com' || /^google\.[a-z.]+$/.test(host)) && url.pathname === '/url') {
    const target = url.searchParams.get('q') ?? url.searchParams.get('url');
    if (target) {
      try {
        const t = new URL(target);
        if (t.protocol === 'https:' || t.protocol === 'http:') return t;
      } catch {
        /* not a URL: keep the wrapper */
      }
    }
  }
  return url;
}
