/**
 * FocusController: the extension's single owner of session state.
 *
 * Every mutation runs inside one serial queue (`this.serial`), so Chrome events
 * that race (window removed while the session is ending, tab created while the
 * window is being recreated, a sync arriving mid-start, ...) are applied one at
 * a time against a consistent record. The record is persisted to
 * chrome.storage.local after each change so a service-worker restart or a
 * browser restart resumes the same session.
 *
 * Enforcement layers (see docs/architecture.md):
 *   1. Proactive: declarativeNetRequest session rules block disallowed
 *      top-level loads before any content is fetched (shared/rules.ts).
 *   2. Reactive: webNavigation/tabs/windows listeners detect anything that
 *      bypasses DNR (SPA history changes, bfcache, window focus, new tabs,
 *      closed or moved focus tab) and reverse it.
 */
import {
  type FocusPolicy,
  type Identity,
  acceptsLandingAliases,
  describe,
  evaluate,
  identityOf,
  parseTarget,
} from '../shared/identity.ts';
import { type Bounds, type DesiredSession, type Inbound, type Outbound, type ViolationKind, type WindowState, PROTOCOL_VERSION, isNewerSync, newId } from '../shared/protocol.ts';
import { allRuleIds, buildRules } from '../shared/rules.ts';
import {
  MAX_ALIASES,
  type Owner,
  type SessionRecord,
  clampDurationMinutes,
  isExpired,
  reconcile,
  remainingMs,
  tooManyRestores,
} from '../shared/session.ts';
import { type BridgeStatus, NativeBridge } from './bridge.ts';

const KEY_SESSION = 'session';
const KEY_ENDED = 'endedSids';
const KEY_RUN = 'browserRunId'; // chrome.storage.session: survives SW restarts, not browser restarts
const ALARM_EXPIRY = 'ekagrachit-expiry';
const ALARM_TICK = 'ekagrachit-tick';
const LANDING_SETTLE_MS = 3_000;
const LANDING_MAX_MS = 20_000;
const STARTUP_SETTLE_MS = 4_000;
const REFOCUS_THROTTLE_MS = 120;

export interface UiState {
  session: null | {
    sid: string;
    owner: Owner;
    title: string;
    target: string;
    endsAt: number;
    armed: boolean;
  };
  bridge: BridgeStatus;
  bridgeError: string | null;
  lastError: string | null;
}

type Timer = ReturnType<typeof setTimeout>;

export class FocusController {
  readonly bridge: NativeBridge;
  private rec: SessionRecord | null = null;
  private runId = '';
  private queue: Promise<unknown> = Promise.resolve();
  private readonly ready: Promise<void>;
  private settling = false;
  private restoreTimes: number[] = [];
  private recreateTimes: number[] = [];
  lastRefocus = 0;
  private refocusTimer: Timer | null = null;
  private rehomingTabId: number | null = null;
  private controlWindowId: number | null = null;
  private armTimer: Timer | null = null;
  private expiryTimer: Timer | null = null;
  private lastSync: { epoch: string; seq: number } | null = null;
  private pendingStarts = new Map<string, (r: { ok: boolean; error?: string }) => void>();
  lastError: string | null = null;

  constructor() {
    this.bridge = new NativeBridge(
      (msg) => void this.serial(() => this.onNative(msg)),
      (status) => void this.serial(() => this.onBridgeStatus(status)),
    );
    this.ready = this.serial(() => this.init());
  }

  /** Run `fn` after every previously queued operation. Errors are logged, never rethrown into the queue. */
  serial<T>(fn: () => Promise<T> | T): Promise<T> {
    // init() is the first queued operation, so everything else runs after it.
    const run = this.queue.then(fn);
    this.queue = run.catch((e) => {
      console.error('[ekagrachit]', e);
    });
    return run;
  }

  // ---------------------------------------------------------------- lifecycle

  private async init(): Promise<void> {
    const stored = (await chrome.storage.session.get(KEY_RUN))[KEY_RUN];
    let newBrowserRun = false;
    if (typeof stored === 'string') {
      this.runId = stored;
    } else {
      this.runId = newId();
      newBrowserRun = true;
      await chrome.storage.session.set({ [KEY_RUN]: this.runId });
    }
    const rec = (await chrome.storage.local.get(KEY_SESSION))[KEY_SESSION] as SessionRecord | undefined;
    this.rec = rec ?? null;
    this.bridge.connect();

    if (!this.rec) {
      // No session: make sure no stale rules survive (e.g. after a crash mid-end).
      await this.clearRules();
      await this.updateBadge();
      return;
    }
    if (isExpired(this.rec, Date.now())) {
      await this.end('expired');
      return;
    }
    if (this.rec.browserRunId !== this.runId || newBrowserRun) {
      // Browser restarted: window/tab ids are meaningless now. Let session
      // restore settle so restored tabs count as pre-existing, then re-establish.
      this.settling = true;
      setTimeout(() => void this.serial(() => this.recoverAfterRestart()), STARTUP_SETTLE_MS);
    } else {
      await this.applyRules();
      if (this.rec.windowId !== null && !(await this.windowExists(this.rec.windowId))) {
        await this.recreateFocusWindow('focus_window_recreated');
      }
    }
    this.scheduleTimers();
    await this.updateBadge();
  }

  private async recoverAfterRestart(): Promise<void> {
    this.settling = false;
    const rec = this.rec;
    if (!rec) return;
    if (isExpired(rec, Date.now())) {
      await this.end('expired');
      return;
    }
    rec.browserRunId = this.runId;
    rec.preexistingTabIds = (await chrome.tabs.query({})).map((t) => t.id).filter((id): id is number => id !== undefined);
    // Adopt a restored popup showing the target, if Chrome restored one.
    const popups = await chrome.windows.getAll({ populate: true, windowTypes: ['popup'] });
    const match = popups.find((w) => w.tabs?.length === 1 && w.tabs[0]?.url && evaluate(rec.policy, w.tabs[0].url) === 'allow');
    if (match?.id !== undefined && match.tabs?.[0]?.id !== undefined) {
      rec.windowId = match.id;
      rec.tabId = match.tabs[0].id;
      rec.preexistingTabIds = rec.preexistingTabIds.filter((id) => id !== rec.tabId);
      await this.save();
      await this.applyRules();
      await this.reportWindow();
    } else {
      rec.windowId = null;
      rec.tabId = null;
      await this.recreateFocusWindow('focus_window_recreated');
    }
    this.scheduleTimers();
  }

  // ---------------------------------------------------------------- public API (UI)

  async uiState(): Promise<UiState> {
    await this.ready;
    const r = this.rec;
    return {
      session: r
        ? { sid: r.sid, owner: r.owner, title: describe(r.policy.primary), target: r.target, endsAt: r.endsAt, armed: r.armed }
        : null,
      bridge: this.bridge.status,
      bridgeError: this.bridge.lastError,
      lastError: this.lastError,
    };
  }

  /** Start requested from the extension UI. Routed to the app when it is connected. */
  async requestStart(target: string, minutes: number): Promise<{ ok: boolean; error?: string }> {
    await this.ready;
    const parsed = parseTarget(target);
    if (!parsed.ok) return { ok: false, error: parsed.error };
    const duration = clampDurationMinutes(minutes);
    if (duration === null) return { ok: false, error: 'Duration must be between 1 and 480 minutes.' };
    if (this.rec) return { ok: false, error: 'A focus session is already active.' };

    if (this.bridge.appConnected) {
      const cid = newId();
      const result = new Promise<{ ok: boolean; error?: string }>((resolve) => {
        this.pendingStarts.set(cid, resolve);
        setTimeout(() => {
          if (this.pendingStarts.delete(cid)) resolve({ ok: false, error: 'Ekagrachit app did not respond.' });
        }, 15_000);
      });
      this.bridge.send({ v: 1, type: 'start_request', cid, target: parsed.url, durationMinutes: duration });
      return result;
    }
    return this.serial(async () => {
      if (this.rec) return { ok: false, error: 'A focus session is already active.' };
      return this.establish(newId(), 'extension', parsed.url, parsed.identity, Date.now() + duration * 60_000);
    });
  }

  /** Deliberate early end from the extension UI (hold-to-confirm happens in the UI). */
  async requestEnd(sid: string): Promise<void> {
    await this.ready;
    await this.serial(async () => {
      const rec = this.rec;
      if (!rec || rec.sid !== sid) return;
      if (rec.owner === 'native' && this.bridge.appConnected) {
        this.bridge.send({ v: 1, type: 'end_request', sid });
        // The app answers with sync(null). If it doesn't, end locally anyway.
        setTimeout(() => void this.serial(async () => {
          if (this.rec?.sid === sid) await this.end('user_ended');
        }), 3_000);
        return;
      }
      await this.end('user_ended');
    });
  }

  /** Opens the extension's own control window (allowed during a session). */
  async openControls(): Promise<void> {
    await this.serial(async () => {
      if (this.controlWindowId !== null && (await this.windowExists(this.controlWindowId))) {
        await chrome.windows.update(this.controlWindowId, { focused: true });
        return;
      }
      const w = await chrome.windows.create({ url: chrome.runtime.getURL('popup.html?window=1'), type: 'popup', width: 380, height: 460, focused: true });
      this.controlWindowId = w?.id ?? null;
    });
  }

  /** Test support: shorten the running session. Only reachable from inside this worker. */
  async debugSetRemaining(ms: number): Promise<void> {
    await this.serial(async () => {
      if (!this.rec) return;
      this.rec.endsAt = Date.now() + ms;
      await this.save();
      this.scheduleTimers();
    });
  }

  // ---------------------------------------------------------------- establish / end

  private async establish(sid: string, owner: Owner, target: string, primary: Identity, endsAt: number): Promise<{ ok: boolean; error?: string }> {
    const policy: FocusPolicy = { primary, aliases: [] };
    const preexisting = (await chrome.tabs.query({})).map((t) => t.id).filter((id): id is number => id !== undefined);
    const now = Date.now();
    const rec: SessionRecord = {
      sid,
      owner,
      target,
      policy,
      startedAt: now,
      endsAt,
      windowId: null,
      tabId: null,
      armed: !acceptsLandingAliases(primary),
      armDeadline: now + LANDING_MAX_MS,
      lastAllowedUrl: target,
      preexistingTabIds: preexisting,
      browserRunId: this.runId,
    };
    this.rec = rec;
    this.lastError = null;
    await this.save();
    try {
      await this.createFocusWindow();
    } catch (e) {
      this.lastError = `Could not open the focus window: ${String(e)}`;
      this.send({ v: 1, type: 'error', sid, code: 'window_create_failed', message: String(e) });
      await this.end('start_failed');
      return { ok: false, error: this.lastError };
    }
    this.scheduleTimers();
    await this.updateBadge();
    return { ok: true };
  }

  /** Idempotent. Lifts every restriction first, then closes only our window. */
  private async end(reason: string): Promise<void> {
    const rec = this.rec;
    this.clearTimers();
    this.rec = null;
    await chrome.storage.local.remove(KEY_SESSION);
    await this.clearRules();
    await this.updateBadge();
    if (!rec) return;
    if (reason === 'user_ended') await this.addTombstone(rec.sid);
    if (rec.windowId !== null) {
      // windows.remove goes through the normal window-close path, which runs
      // beforeunload: if the page has unsaved state Chrome asks the user and
      // the window stays open. Do not await: the promise only settles after
      // the user answers such a dialog.
      chrome.windows.remove(rec.windowId).catch(() => undefined);
    }
    this.send({ v: 1, type: 'session_closed', sid: rec.sid, reason });
  }

  private async createFocusWindow(): Promise<void> {
    const rec = this.mustRec();
    const bounds = await this.preferredBounds();
    const win = await chrome.windows.create({ url: rec.lastAllowedUrl, type: 'popup', focused: true, ...bounds });
    const tabId = win?.tabs?.[0]?.id;
    if (!win || win.id === undefined || tabId === undefined) throw new Error('window has no tab');
    rec.windowId = win.id;
    rec.tabId = tabId;
    rec.preexistingTabIds = rec.preexistingTabIds.filter((id) => id !== tabId);
    await this.save();
    await this.applyRules();
    await this.reportWindow();
  }

  private async recreateFocusWindow(kind: ViolationKind): Promise<void> {
    const rec = this.rec;
    if (!rec) return;
    const now = Date.now();
    this.recreateTimes = this.recreateTimes.filter((t) => now - t < 60_000);
    if (this.recreateTimes.length >= 5) {
      // Something keeps closing the window (or Chrome refuses to open it).
      // Don't spin: wait, then try again while the session lasts.
      setTimeout(() => void this.serial(async () => {
        if (this.rec?.sid === rec.sid && this.rec.windowId === null) await this.recreateFocusWindow(kind);
      }), 5_000);
      return;
    }
    this.recreateTimes.push(now);
    rec.windowId = null;
    rec.tabId = null;
    await this.save();
    this.send({ v: 1, type: 'window_lost', sid: rec.sid });
    try {
      await this.createFocusWindow();
      this.violation(kind);
    } catch (e) {
      this.lastError = `Could not reopen the focus window: ${String(e)}`;
    }
  }

  // ---------------------------------------------------------------- native messages

  private async onBridgeStatus(status: BridgeStatus): Promise<void> {
    if (status === 'app_connected') {
      const rec = this.rec;
      this.send({
        v: 1,
        type: 'hello',
        protocol: PROTOCOL_VERSION,
        extVersion: chrome.runtime.getManifest().version,
        extensionId: chrome.runtime.id,
        standalone: rec && rec.owner === 'extension' ? { sid: rec.sid, target: rec.target, remainingMs: remainingMs(rec, Date.now()) } : null,
      });
    } else {
      this.lastSync = null;
    }
    await this.updateBadge();
  }

  private async onNative(msg: Inbound): Promise<void> {
    switch (msg.type) {
      case 'host_status':
        return;
      case 'hello_ack':
        if (msg.protocol !== PROTOCOL_VERSION) {
          this.lastError = `Protocol mismatch: app speaks v${msg.protocol}, extension v${PROTOCOL_VERSION}. Update both components.`;
        }
        return;
      case 'error':
        this.lastError = `App: ${msg.message || msg.code}`;
        return;
      case 'start_result': {
        const resolve = this.pendingStarts.get(msg.cid);
        if (resolve) {
          this.pendingStarts.delete(msg.cid);
          resolve(msg.error === undefined ? { ok: msg.ok } : { ok: msg.ok, error: msg.error });
        }
        return;
      }
      case 'focus':
        if (this.rec?.sid === msg.sid) await this.refocus(true);
        return;
      case 'sync':
        if (!isNewerSync(this.lastSync, msg)) return; // stale or duplicate
        this.lastSync = { epoch: msg.epoch, seq: msg.seq };
        await this.applySync(msg.session);
        return;
    }
  }

  private async applySync(desired: DesiredSession | null): Promise<void> {
    const ended = await this.tombstones();
    const action = reconcile(this.rec, desired, ended);
    switch (action.kind) {
      case 'none':
        return;
      case 'end':
        await this.end('app_ended');
        return;
      case 'reject_ended':
        this.send({ v: 1, type: 'session_closed', sid: action.sid, reason: 'user_ended' });
        return;
      case 'replace':
        await this.end('replaced');
        await this.startFromNative(action.desired);
        return;
      case 'start':
        await this.startFromNative(action.desired);
        return;
      case 'adopt': {
        const rec = this.mustRec();
        rec.owner = 'native';
        rec.endsAt = Date.now() + action.desired.remainingMs;
        await this.save();
        this.scheduleTimers();
        if (rec.windowId !== null && (await this.windowExists(rec.windowId))) {
          await this.reportWindow();
        } else if (!this.settling) {
          await this.recreateFocusWindow('focus_window_recreated');
        }
        await this.updateBadge();
        return;
      }
    }
  }

  private async startFromNative(desired: DesiredSession): Promise<void> {
    const parsed = parseTarget(desired.target);
    if (!parsed.ok) {
      this.send({ v: 1, type: 'error', sid: desired.sid, code: 'invalid_target', message: parsed.error });
      this.send({ v: 1, type: 'session_closed', sid: desired.sid, reason: 'invalid_target' });
      return;
    }
    await this.establish(desired.sid, 'native', parsed.url, parsed.identity, Date.now() + desired.remainingMs);
  }

  // ---------------------------------------------------------------- enforcement: navigation

  async onNavigationCommitted(tabId: number, frameId: number, url: string): Promise<void> {
    const rec = this.rec;
    if (!rec || tabId !== rec.tabId || frameId !== 0) return;
    const verdict = evaluate(rec.policy, url);
    if (!rec.armed) {
      // Landing grace: follow redirects of an exact-page target and learn them.
      if (verdict === 'allow') {
        rec.lastAllowedUrl = url;
        if (url === rec.target || evaluate({ primary: rec.policy.primary, aliases: [] }, url) === 'allow') {
          await this.arm();
          return;
        }
      } else if (verdict === 'deny' && /^https?:/.test(url) && rec.policy.aliases.length < MAX_ALIASES) {
        rec.policy.aliases.push(identityOf(new URL(url)));
        rec.lastAllowedUrl = url;
      }
      rec.armDeadline = Math.min(rec.startedAt + LANDING_MAX_MS, Date.now() + LANDING_SETTLE_MS);
      await this.save();
      this.scheduleArm();
      return;
    }
    await this.checkUrl(url, 'navigation_reverted');
  }

  /** SPA (pushState) and fragment navigations never hit DNR; check them here. */
  async onSameDocumentNavigation(tabId: number, frameId: number, url: string): Promise<void> {
    const rec = this.rec;
    if (!rec || !rec.armed || tabId !== rec.tabId || frameId !== 0) return;
    await this.checkUrl(url, 'navigation_reverted');
  }

  async onNavigationError(tabId: number, frameId: number, error: string): Promise<void> {
    const rec = this.rec;
    if (!rec || tabId !== rec.tabId || frameId !== 0) return;
    if (!/ERR_BLOCKED_BY_CLIENT/.test(error)) return;
    // DNR blocked a disallowed load before any content was fetched; the tab now
    // shows Chrome's "blocked" page. Put the target back.
    await this.restore('navigation_blocked');
  }

  private async checkUrl(url: string, kind: ViolationKind): Promise<void> {
    const rec = this.mustRec();
    const verdict = evaluate(rec.policy, url);
    if (verdict === 'allow') {
      if (rec.lastAllowedUrl !== url) {
        rec.lastAllowedUrl = url;
        await this.save();
      }
      return;
    }
    if (verdict === 'auth' || verdict === 'neutral') return;
    await this.restore(kind);
  }

  private async restore(kind: ViolationKind): Promise<void> {
    const rec = this.mustRec();
    if (rec.tabId === null) return;
    const now = Date.now();
    this.restoreTimes = this.restoreTimes.filter((t) => now - t < 30_000);
    if (tooManyRestores(this.restoreTimes, now)) {
      this.lastError = 'The focus page keeps navigating away; stopped reverting to avoid a loop.';
      return;
    }
    this.restoreTimes.push(now);
    await chrome.tabs.update(rec.tabId, { url: rec.lastAllowedUrl }).catch(() => undefined);
    this.violation(kind);
  }

  private async arm(): Promise<void> {
    const rec = this.mustRec();
    if (rec.armed) return;
    rec.armed = true;
    if (this.armTimer) clearTimeout(this.armTimer);
    this.armTimer = null;
    await this.save();
    await this.applyRules();
    // Re-validate the current URL now that the policy is final.
    if (rec.tabId !== null) {
      const tab = await chrome.tabs.get(rec.tabId).catch(() => null);
      if (tab?.url) await this.checkUrl(tab.url, 'navigation_reverted');
    }
    await this.updateBadge();
  }

  // ---------------------------------------------------------------- enforcement: tabs & windows

  async onTabCreated(tab: chrome.tabs.Tab): Promise<void> {
    const rec = this.rec;
    if (!rec || this.settling || tab.id === undefined) return;
    if (tab.id === rec.tabId || rec.preexistingTabIds.includes(tab.id)) return;
    if (tab.windowId === this.controlWindowId) return;
    const url = tab.pendingUrl ?? tab.url ?? '';
    if (url.startsWith(chrome.runtime.getURL(''))) return; // our own UI
    // A tab created during the session (Cmd+T, Cmd+N, target=_blank, window.open,
    // reopen-closed-tab...). DNR has already blocked its network load; close it.
    await this.closeTab(tab.id);
    this.violation('tab_closed');
    this.lastRefocus = 0; // closing may move focus elsewhere: refocus now and re-check after the throttle
    await this.refocus(false);
    await this.refocus(false);
  }

  async onWindowFocusChanged(windowId: number): Promise<void> {
    const rec = this.rec;
    if (!rec || this.settling || rec.windowId === null) return;
    if (windowId === chrome.windows.WINDOW_ID_NONE) return; // another app took focus: the macOS app handles that
    if (windowId === rec.windowId || windowId === this.controlWindowId) return;
    this.violation('window_refocused');
    await this.refocus(false);
  }

  async onWindowRemoved(windowId: number): Promise<void> {
    if (windowId === this.controlWindowId) this.controlWindowId = null;
    const rec = this.rec;
    if (!rec || windowId !== rec.windowId) return;
    if (this.rehomingTabId !== null) return; // the tab was moved out; onAttached re-homes it
    await this.recreateFocusWindow('focus_window_recreated');
  }

  async onTabRemoved(tabId: number, isWindowClosing: boolean): Promise<void> {
    const rec = this.rec;
    if (!rec || tabId !== rec.tabId || isWindowClosing) return;
    await this.recreateFocusWindow('focus_window_recreated');
  }

  /** Synchronous flag set from the raw listener, before queueing (ordering matters). */
  noteTabDetached(tabId: number): void {
    if (this.rec && tabId === this.rec.tabId) this.rehomingTabId = tabId;
  }

  async onTabAttached(tabId: number, newWindowId: number): Promise<void> {
    const rec = this.rec;
    if (!rec || tabId !== rec.tabId) return;
    if (newWindowId === rec.windowId) {
      this.rehomingTabId = null;
      return;
    }
    // e.g. "Open in Chrome" moved the focus tab into a normal window. Move it
    // back into a fresh popup, preserving the page (no reload).
    try {
      const bounds = await this.preferredBounds();
      const win = await chrome.windows.create({ tabId, type: 'popup', focused: true, ...bounds });
      if (win?.id !== undefined) {
        rec.windowId = win.id;
        await this.save();
        await this.reportWindow();
        this.violation('tab_rehomed');
      }
    } catch {
      await this.recreateFocusWindow('focus_window_recreated');
    } finally {
      this.rehomingTabId = null;
    }
  }

  async onTabReplaced(addedTabId: number, removedTabId: number): Promise<void> {
    const rec = this.rec;
    if (!rec || removedTabId !== rec.tabId) return;
    rec.tabId = addedTabId;
    await this.save();
    await this.applyRules();
    await this.reportWindow();
  }

  async onWindowBoundsChanged(win: chrome.windows.Window): Promise<void> {
    const rec = this.rec;
    if (!rec || win.id !== rec.windowId) return;
    const b = boundsOf(win);
    if (b) this.send({ v: 1, type: 'window_bounds', sid: rec.sid, windowId: rec.windowId, bounds: b, state: (win.state ?? 'normal') as WindowState });
  }

  private async refocus(fromNative: boolean): Promise<void> {
    const rec = this.rec;
    if (!rec || rec.windowId === null) return;
    const now = Date.now();
    const wait = this.lastRefocus + REFOCUS_THROTTLE_MS - now;
    if (!fromNative && wait > 0) {
      // Throttled, but never dropped: focus often falls back to another window
      // right after we close one, so re-check once the throttle window passes.
      if (!this.refocusTimer) {
        this.refocusTimer = setTimeout(() => {
          this.refocusTimer = null;
          void this.serial(async () => {
            const sessionWin = this.rec?.windowId;
            if (sessionWin == null) return;
            const focused = await chrome.windows.getLastFocused().catch(() => null);
            if (focused?.id !== sessionWin || !focused.focused) await this.refocus(true);
          });
        }, wait);
      }
      return;
    }
    this.lastRefocus = now;
    const win = await chrome.windows.get(rec.windowId).catch(() => null);
    if (!win) return;
    const update: chrome.windows.UpdateInfo = { focused: true };
    if (win.state === 'minimized') update.state = 'normal';
    await chrome.windows.update(rec.windowId, update).catch(() => undefined);
  }

  private async closeTab(tabId: number): Promise<void> {
    for (let attempt = 0; attempt < 4; attempt++) {
      try {
        await chrome.tabs.remove(tabId);
        return;
      } catch (e) {
        if (/No tab with id/i.test(String(e))) return;
        // "Tabs cannot be edited right now (user may be dragging a tab)."
        await new Promise((r) => setTimeout(r, 100 * (attempt + 1)));
      }
    }
  }

  // ---------------------------------------------------------------- timers

  async onAlarm(name: string): Promise<void> {
    if (name === ALARM_EXPIRY || name === ALARM_TICK) {
      await this.checkExpiry();
      await this.updateBadge();
    }
    if (name === ALARM_TICK && this.bridge.status !== 'app_connected') this.bridge.connect();
  }

  private async checkExpiry(): Promise<void> {
    if (this.rec && isExpired(this.rec, Date.now())) await this.end('expired');
  }

  private scheduleTimers(): void {
    const rec = this.rec;
    this.clearTimers();
    if (!rec) return;
    const at = rec.endsAt + (rec.owner === 'native' ? 3_000 : 0);
    // setTimeout is precise while the worker is alive; the alarm covers worker
    // suspension and system sleep (alarms fire on wake if overdue).
    this.expiryTimer = setTimeout(() => void this.serial(() => this.checkExpiry()), Math.max(0, at - Date.now()) + 50);
    void chrome.alarms.create(ALARM_EXPIRY, { when: at });
    void chrome.alarms.create(ALARM_TICK, { periodInMinutes: 0.5 });
    this.scheduleArm();
  }

  private scheduleArm(): void {
    const rec = this.rec;
    if (!rec || rec.armed) return;
    if (this.armTimer) clearTimeout(this.armTimer);
    this.armTimer = setTimeout(() => void this.serial(async () => {
      if (this.rec && !this.rec.armed && Date.now() >= this.rec.armDeadline - 20) await this.arm();
    }), Math.max(0, rec.armDeadline - Date.now()));
  }

  private clearTimers(): void {
    if (this.expiryTimer) clearTimeout(this.expiryTimer);
    if (this.armTimer) clearTimeout(this.armTimer);
    this.expiryTimer = null;
    this.armTimer = null;
    void chrome.alarms.clear(ALARM_EXPIRY);
    void chrome.alarms.clear(ALARM_TICK);
  }

  // ---------------------------------------------------------------- helpers

  private mustRec(): SessionRecord {
    if (!this.rec) throw new Error('no session');
    return this.rec;
  }

  private async save(): Promise<void> {
    if (this.rec) await chrome.storage.local.set({ [KEY_SESSION]: this.rec });
  }

  private async applyRules(): Promise<void> {
    const rec = this.rec;
    if (!rec || rec.tabId === null) return;
    const addRules = buildRules({ policy: rec.policy, focusTabId: rec.tabId, preexistingTabIds: rec.preexistingTabIds, armed: rec.armed });
    await chrome.declarativeNetRequest.updateSessionRules({
      removeRuleIds: allRuleIds(),
      addRules: addRules as chrome.declarativeNetRequest.Rule[],
    });
  }

  private async clearRules(): Promise<void> {
    await chrome.declarativeNetRequest.updateSessionRules({ removeRuleIds: allRuleIds() }).catch(() => undefined);
  }

  private async reportWindow(): Promise<void> {
    const rec = this.rec;
    if (!rec || rec.windowId === null || rec.tabId === null) return;
    const win = await chrome.windows.get(rec.windowId).catch(() => null);
    const b = win ? boundsOf(win) : null;
    if (!win || !b) return;
    this.send({ v: 1, type: 'window_ready', sid: rec.sid, windowId: rec.windowId, tabId: rec.tabId, bounds: b, state: (win.state ?? 'normal') as WindowState });
  }

  private async windowExists(id: number): Promise<boolean> {
    return (await chrome.windows.get(id).catch(() => null)) !== null;
  }

  private async preferredBounds(): Promise<Partial<Bounds>> {
    // Match the user's current browser window so the focus window appears where they were working.
    const last = await chrome.windows.getLastFocused({ windowTypes: ['normal'] }).catch(() => null);
    if (last && last.state === 'normal') {
      const b = boundsOf(last);
      if (b) return b;
    }
    return { width: 1280, height: 900 };
  }

  private send(msg: Outbound): void {
    this.bridge.send(msg);
  }

  private violation(kind: ViolationKind): void {
    if (this.rec) this.send({ v: 1, type: 'violation', sid: this.rec.sid, kind });
  }

  private async tombstones(): Promise<string[]> {
    const v = (await chrome.storage.local.get(KEY_ENDED))[KEY_ENDED];
    return Array.isArray(v) ? v.filter((s): s is string => typeof s === 'string') : [];
  }

  private async addTombstone(sid: string): Promise<void> {
    const list = [sid, ...(await this.tombstones()).filter((s) => s !== sid)].slice(0, 16);
    await chrome.storage.local.set({ [KEY_ENDED]: list });
  }

  private async updateBadge(): Promise<void> {
    const rec = this.rec;
    if (!rec) {
      await chrome.action.setBadgeText({ text: '' });
      await chrome.action.setTitle({ title: 'Ekagrachit' });
      return;
    }
    const mins = Math.ceil(remainingMs(rec, Date.now()) / 60_000);
    const degraded = rec.owner === 'native' && !this.bridge.appConnected;
    await chrome.action.setBadgeBackgroundColor({ color: degraded ? '#b45309' : '#3f3f46' });
    await chrome.action.setBadgeText({ text: degraded ? '!' : `${mins}m` });
    await chrome.action.setTitle({
      title: degraded ? 'Ekagrachit: app disconnected — browser-only enforcement' : `Ekagrachit: ${mins} min remaining`,
    });
  }
}

function boundsOf(w: chrome.windows.Window): Bounds | null {
  if (w.left === undefined || w.top === undefined || w.width === undefined || w.height === undefined) return null;
  return { left: w.left, top: w.top, width: w.width, height: w.height };
}
