/**
 * NativeBridge: persistent Chrome Native Messaging port to ekagrachit-host.
 *
 * Directionality: only the extension can open the channel (connectNative), so
 * the extension keeps one long-lived port open at all times. The host relays
 * it to Ekagrachit.app over a same-user Unix socket and reports whether the
 * app is reachable with `host_status`. An open native port also keeps the MV3
 * service worker alive (Chrome >= 105), which keeps enforcement latency low.
 */
import { NATIVE_HOST_NAME, type Inbound, type Outbound, parseInbound } from '../shared/protocol.ts';

export type BridgeStatus =
  | 'connecting'
  | 'host_missing' // native host manifest not installed / not allowed
  | 'host_disconnected' // host exited or crashed; retrying
  | 'app_unavailable' // host running, app not running
  | 'app_connected'; // end-to-end channel available

export class NativeBridge {
  status: BridgeStatus = 'connecting';
  lastError: string | null = null;
  private port: chrome.runtime.Port | null = null;
  private retryMs = 1_000;
  private retryTimer: ReturnType<typeof setTimeout> | null = null;

  private readonly onMessage: (msg: Inbound) => void;
  private readonly onStatus: (status: BridgeStatus) => void;

  constructor(onMessage: (msg: Inbound) => void, onStatus: (status: BridgeStatus) => void) {
    this.onMessage = onMessage;
    this.onStatus = onStatus;
  }

  get appConnected(): boolean {
    return this.status === 'app_connected';
  }

  connect(): void {
    if (this.port) return;
    if (this.retryTimer) {
      clearTimeout(this.retryTimer);
      this.retryTimer = null;
    }
    let port: chrome.runtime.Port;
    try {
      port = chrome.runtime.connectNative(NATIVE_HOST_NAME);
    } catch (e) {
      this.handleDisconnect(String(e));
      return;
    }
    this.port = port;
    port.onMessage.addListener((raw: unknown) => {
      const msg = parseInbound(raw);
      if (!msg) return; // malformed or unknown: ignore
      if (msg.type === 'host_status') {
        this.retryMs = 1_000;
        this.setStatus(msg.appConnected ? 'app_connected' : 'app_unavailable');
      }
      this.onMessage(msg);
    });
    port.onDisconnect.addListener(() => {
      if (this.port !== port) return;
      this.port = null;
      this.handleDisconnect(chrome.runtime.lastError?.message ?? 'disconnected');
    });
  }

  send(msg: Outbound): boolean {
    if (!this.port || !this.appConnected) return false;
    try {
      this.port.postMessage(msg);
      return true;
    } catch (e) {
      this.lastError = String(e);
      return false;
    }
  }

  private handleDisconnect(reason: string): void {
    this.lastError = reason;
    const missing = /not found|forbidden|not allowed|Invalid native messaging host/i.test(reason);
    this.setStatus(missing ? 'host_missing' : 'host_disconnected');
    // Back off; a missing host is retried slowly (also by the periodic alarm).
    const delay = missing ? 60_000 : this.retryMs;
    this.retryMs = Math.min(this.retryMs * 2, 30_000);
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null;
      this.connect();
    }, delay);
  }

  private setStatus(s: BridgeStatus): void {
    if (this.status === s) return;
    this.status = s;
    this.onStatus(s);
  }
}
