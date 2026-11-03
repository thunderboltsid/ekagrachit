# Bridge protocol v1

Transport on both hops: 32-bit little-endian (native) length prefix + UTF-8 JSON
object, max 1 MiB per message.

![Transport: Chrome extension ⇄ ekagrachit-host over Native Messaging (stdio, u32 length + UTF-8 JSON) ⇄ Ekagrachit.app over a same-user Unix socket with the same framing.](images/diagrams/transport.svg)

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
| `show_menu` | — | The extension's toolbar button was clicked: the app opens its menu (which offers the active tab). The extension has no start or end UI of its own. |
| `start_request` | `cid`, `target`, `durationMinutes` | Automation only (the worker's test hook): start a session through the app. Answered by `start_result`. |
| `end_request` | `sid` | Automation only: end a session through the app. |
| `window_ready` | `sid`, `windowId`, `tabId`, `bounds{left,top,width,height}`, `state` | Focus window exists and is enforced. Re-sent after recreation, re-homing, reconnect. |
| `window_bounds` | `sid`, `windowId`, `bounds`, `state` | Focus window moved/resized. |
| `window_lost` | `sid` | Focus window closed; being recreated. |
| `violation` | `sid`, `kind`, `host?` | An escape attempt was blocked/reverted (prompts an immediate native focus check). `host` is set when the link was saved for later. |
| `active_tab` | `cid`, `url` | Answer to `active_tab_request`: the active tab's http(s) URL, or `""`. |
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
| `reload` | — | The app bundles a different extension build (already copied to the extension folder); an idle extension reloads itself. Sent at most once per extension version per app run. |
| `active_tab_request` | `cid` | Prefill the start form with the active tab. |

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
