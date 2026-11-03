/**
 * Ekagrachit bridge protocol, version 1.
 *
 * Transport: Chrome Native Messaging (extension <-> ekagrachit-host, stdio,
 * 32-bit native-endian length prefix + UTF-8 JSON), relayed by the host over a
 * same-user Unix domain socket to Ekagrachit.app with the same framing.
 *
 * The macOS app is authoritative. It pushes the *desired* session state with
 * `sync` (full state, not deltas), so any lost or duplicated message is healed
 * by the next sync. Every session-scoped message carries the session id `sid`;
 * receivers drop messages whose sid does not match their current session.
 *
 * Documented in docs/protocol.md. Mirrored in apps/macos/Sources/EkagrachitCore/Protocol.swift.
 */

export const PROTOCOL_VERSION = 1;
export const NATIVE_HOST_NAME = 'io.github.thunderboltsid.ekagrachit';

export interface Bounds {
  left: number;
  top: number;
  width: number;
  height: number;
}

export type WindowState = 'normal' | 'minimized' | 'maximized' | 'fullscreen' | 'locked-fullscreen';

/** Desired session pushed by the app. */
export interface DesiredSession {
  sid: string;
  target: string;
  /** Milliseconds remaining at the time the app sent the message. Clock-skew free. */
  remainingMs: number;
  phase: 'preparing' | 'active' | 'degraded';
}

// ----- app/host -> extension ------------------------------------------------

export type Inbound =
  | { type: 'host_status'; appConnected: boolean; hostVersion: string }
  | { type: 'hello_ack'; protocol: number; appVersion: string; epoch: string }
  | { type: 'sync'; epoch: string; seq: number; session: DesiredSession | null }
  | { type: 'focus'; sid: string }
  | { type: 'start_result'; cid: string; ok: boolean; error?: string }
  | { type: 'error'; code: string; message: string }
  | { type: 'reload' }
  | { type: 'active_tab_request'; cid: string };

// ----- extension -> app -----------------------------------------------------

export interface StandaloneSessionInfo {
  sid: string;
  target: string;
  remainingMs: number;
}

export type Outbound =
  | { v: 1; type: 'hello'; protocol: number; extVersion: string; extensionId: string; standalone: StandaloneSessionInfo | null }
  | { v: 1; type: 'start_request'; cid: string; target: string; durationMinutes: number }
  | { v: 1; type: 'end_request'; sid: string }
  | { v: 1; type: 'window_ready'; sid: string; windowId: number; tabId: number; bounds: Bounds; state: WindowState }
  | { v: 1; type: 'window_bounds'; sid: string; windowId: number; bounds: Bounds; state: WindowState }
  | { v: 1; type: 'window_lost'; sid: string }
  | { v: 1; type: 'violation'; sid: string; kind: ViolationKind; host?: string }
  | { v: 1; type: 'active_tab'; cid: string; url: string }
  | { v: 1; type: 'show_menu' }
  | { v: 1; type: 'session_closed'; sid: string; reason: string }
  | { v: 1; type: 'error'; sid?: string; code: string; message: string };

export type ViolationKind =
  | 'navigation_blocked'
  | 'navigation_reverted'
  | 'tab_closed'
  | 'window_refocused'
  | 'focus_window_recreated'
  | 'tab_rehomed';

const MAX_SID = 64;
const SID_RE = /^[A-Za-z0-9_-]{8,64}$/;

/**
 * Validate an inbound message. Returns null for anything malformed or unknown;
 * callers must ignore nulls. Never throws.
 */
export function parseInbound(raw: unknown): Inbound | null {
  if (!isObject(raw)) return null;
  const type = raw.type;
  switch (type) {
    case 'host_status':
      if (typeof raw.appConnected !== 'boolean') return null;
      return { type, appConnected: raw.appConnected, hostVersion: str(raw.hostVersion, 32) ?? 'unknown' };
    case 'hello_ack': {
      const protocol = raw.protocol;
      const epoch = str(raw.epoch, MAX_SID);
      if (typeof protocol !== 'number' || !Number.isInteger(protocol) || epoch === null) return null;
      return { type, protocol, appVersion: str(raw.appVersion, 32) ?? 'unknown', epoch };
    }
    case 'sync': {
      const epoch = str(raw.epoch, MAX_SID);
      const seq = raw.seq;
      if (epoch === null || typeof seq !== 'number' || !Number.isSafeInteger(seq) || seq < 0) return null;
      if (raw.session === null) return { type, epoch, seq, session: null };
      const s = raw.session;
      if (!isObject(s)) return null;
      const sid = sidOf(s.sid);
      const target = str(s.target, 4096);
      const remainingMs = s.remainingMs;
      const phase = s.phase;
      if (sid === null || target === null) return null;
      if (typeof remainingMs !== 'number' || !Number.isFinite(remainingMs) || remainingMs < 0 || remainingMs > 24 * 3600_000) return null;
      if (phase !== 'preparing' && phase !== 'active' && phase !== 'degraded') return null;
      return { type, epoch, seq, session: { sid, target, remainingMs, phase } };
    }
    case 'focus': {
      const sid = sidOf(raw.sid);
      return sid === null ? null : { type, sid };
    }
    case 'start_result': {
      const cid = str(raw.cid, MAX_SID);
      if (cid === null || typeof raw.ok !== 'boolean') return null;
      const error = str(raw.error, 512);
      return error === null ? { type, cid, ok: raw.ok } : { type, cid, ok: raw.ok, error };
    }
    case 'error': {
      const code = str(raw.code, 64);
      if (code === null) return null;
      return { type, code, message: str(raw.message, 512) ?? '' };
    }
    case 'reload':
      return { type };
    case 'active_tab_request': {
      const cid = str(raw.cid, MAX_SID);
      return cid === null ? null : { type, cid };
    }
    default:
      return null;
  }
}

export function isValidSid(s: unknown): s is string {
  return typeof s === 'string' && SID_RE.test(s);
}

function sidOf(v: unknown): string | null {
  return isValidSid(v) ? v : null;
}

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function str(v: unknown, max: number): string | null {
  return typeof v === 'string' && v.length <= max ? v : null;
}

/** Ordering guard for `sync`: accept a new epoch, otherwise only increasing seq. */
export function isNewerSync(last: { epoch: string; seq: number } | null, next: { epoch: string; seq: number }): boolean {
  if (last === null || last.epoch !== next.epoch) return true;
  return next.seq > last.seq;
}

export function newId(): string {
  const bytes = new Uint8Array(12);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}
