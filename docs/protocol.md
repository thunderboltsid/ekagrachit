# Bridge protocol v1

Transport on both hops: 32-bit little-endian (native) length prefix + UTF-8 JSON
object, max 1 MiB per message.

```
extension ⇄ (Chrome Native Messaging, stdio) ⇄ ekagrachit-host ⇄ (Unix socket) ⇄ Ekagrachit.app
```

All messages carry `"v": 1` and a `"type"`. Unknown types and malformed fields
are dropped by the receiver (`parseInbound` in TS, `AppInbound.parse` in Swift).
Session ids (`sid`) are 8–64 chars of `[A-Za-z0-9_-]`.

## Host → extension
| type | fields | meaning |
|---|---|---|
| `host_status` | `appConnected: bool`, `hostVersion` | App socket reachable or not. Sent on change. |

## Host → app
| `host_hello` | `browserPid`, `hostVersion` | Sent on connect. `browserPid` = the host's parent (the browser), used to find its windows. |

## Extension → app
| type | fields | meaning |
|---|---|---|
| `hello` | `protocol`, `extVersion`, `extensionId`, `standalone: {sid,target,remainingMs}|null` | Sent when `host_status.appConnected` becomes true. A running browser-only session is offered for adoption. |
| `start_request` | `cid`, `target`, `durationMinutes` | Start pressed in the extension UI while the app is connected. Answered by `start_result`. |
| `end_request` | `sid` | User held "end" in the extension UI. |
| `window_ready` | `sid`, `windowId`, `tabId`, `bounds{left,top,width,height}`, `state` | Focus window exists and is enforced. Re-sent after recreation, re-homing, reconnect. |
| `window_bounds` | `sid`, `windowId`, `bounds`, `state` | Focus window moved/resized. |
| `window_lost` | `sid` | Focus window closed; being recreated. |
| `violation` | `sid`, `kind` | An escape attempt was blocked/reverted (prompts an immediate native focus check). |
| `session_closed` | `sid`, `reason` | Extension ended its side (ack of a `sync(null)`, user ended in browser, invalid target, or tombstoned sid). |
| `error` | `sid?`, `code`, `message` | e.g. `window_create_failed`, `invalid_target`. |

## App → extension
| type | fields | meaning |
|---|---|---|
| `hello_ack` | `protocol`, `appVersion`, `epoch` | `epoch` is random per app launch. |
| `sync` | `epoch`, `seq`, `session: {sid,target,remainingMs,phase}|null` | **Authoritative desired state.** Accepted if `epoch` is new or `seq` increased. Sent on every state change, on connect and every 10 s. |
| `focus` | `sid` | Bring the focus window forward (unminimise). |
| `start_result` | `cid`, `ok`, `error?` | Answer to `start_request`. |
| `error` | `code`, `message` | e.g. `protocol_mismatch`. |

## Reconciliation (extension)
| local | desired | action |
|---|---|---|
| none | null | nothing |
| native-owned | null | end: lift rules, close focus window, `session_closed` |
| extension-owned | null | keep (app chose not to adopt; it has its own deadline) |
| any | sid in tombstones | reply `session_closed` (never resurrect a user-ended session) |
| none | S | create focus window for S, `window_ready` |
| sid A | S (≠A) | end A, start S |
| sid S | S | adopt: owner=native, refresh deadline, re-report window (recreate if gone) |

## Startup sequences
- **App start from menu**: app `sync(S, preparing)` → ext creates popup → `window_ready` → app locates native window, shows overlays → `sync(S, active)`.
- **App restart**: app restores persisted S → on `hello` sends `sync(S)` → ext adopts existing window → `window_ready`.
- **Browser-only session, app launched later**: ext `hello{standalone: S}` → app adopts S → `sync(S)` → same as above.
