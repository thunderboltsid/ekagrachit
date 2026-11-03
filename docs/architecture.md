# Ekagrachit architecture

> One resource. One focus window. One duration. Everything else disappears.

## Components

![Component diagram: the Chrome extension (NativeBridge, FocusController, identity policy and DNR rules) talks over Chrome Native Messaging to ekagrachit-host, which relays over a same-user Unix socket to Ekagrachit.app (BridgeServer, FocusSessionCoordinator, SessionStateMachine, OverlayManager and WindowTracker). The extension opens and guards the dedicated Chrome popup; the app covers everything else on screen.](images/diagrams/components.svg)

| Concern | Owner |
|---|---|
| Session lifecycle, deadline, persistence | App (`SessionStateMachine`) |
| Creating the focus window, URL enforcement, tab/window guards | Extension |
| Desktop isolation (overlays), keeping the focus window frontmost | App |
| Browser-only fallback when the app is absent/disconnected | Extension |

## Key decisions

### Dedicated popup via `chrome.windows.create({type: "popup"})`
Verified in Chromium (spike + E2E): creates a separate window in the *existing*
profile (cookies, Google login), with no tab strip and a read-only location
strip. The extension, not a command-line launch, creates it, so there is no
remote-debugging port and no second browser instance. Chrome `--app` mode was
not used: it requires launching Chrome from the command line and offers no
enforcement hooks the extension doesn't already have.

### Native Messaging directionality
Only the extension can open a native messaging channel. It therefore keeps one
**persistent** `connectNative` port open. Chrome spawns `ekagrachit-host`, which
connects to the app's socket (retrying every 1.5 s) and tells the extension
whether the app is reachable (`host_status`). A persistent port also keeps the
MV3 service worker alive (Chrome ≥ 105), keeping enforcement latency low.
No localhost TCP server exists anywhere.

### State sync, not event streams
The app pushes the *desired* session (`sync {epoch, seq, session|null}`); the
extension reconciles its local state to it (pure `reconcile()`). Lost,
duplicated or reordered messages are healed by the next sync (the app also
re-syncs every 10 s). `epoch` (per app launch) + `seq` reject stale messages;
every session-scoped message carries `sid` and is ignored if it doesn't match.
Sessions ended from the browser are tombstoned so a later sync can't revive them.
See [protocol.md](protocol.md).

Starting a session, end to end:

![Sequence diagram: You start a focus session in the app; the app enters preparing and sends sync(preparing) via the host; the extension creates the popup and installs DNR rules, then reports window_ready; the app locates the native window, shows overlays and sends sync(active). Later, a link to Jira is blocked by DNR before any request and the extension reports a violation, which the pill shows as "Saved for later".](images/diagrams/session-start.svg)

### Two-layer browser enforcement
1. **Proactive (before any request is made)** – `declarativeNetRequest`
   *session* rules, `main_frame` only:
   - focus tab: block everything, then higher-priority `allow` rules (RE2
     regexes) for the target identity and its sign-in flow;
   - every tab created during the session (`excludedTabIds` = focus tab +
     all tabs that existed at start): block all top-level loads.
   Sub-resources, XHR, websockets and iframes are never filtered, so Docs keeps
   working. Pre-existing tabs are never touched.
2. **Reactive (detect and reverse)** – `webNavigation`, `tabs`, `windows`
   listeners: SPA `pushState`/fragment changes and bfcache restores (which never
   hit DNR) are checked against the identity policy and reverted; tabs/windows
   created during the session are closed; focus moving to another Chrome window
   is snapped back; a closed focus window is recreated; a focus tab moved out of
   the popup ("Open in Chrome") is moved back into a new popup without reload.

### URL identity
`shared/identity.ts` (pure, unit tested) maps a URL to an identity:
Google Docs/Sheets/Slides/Forms/Drawings/Drive files by document ID (any
`/edit`, `/view`, `?tab=`, `#heading`, `/u/N/`, `/a/domain/` variant), GitHub
PR/issue by owner/repo/number (PR sub-tabs allowed), Jira issue by key, a
registry of web apps by their stable resource id (Notion page, Figma file,
Linear issue, Confluence page, GitLab MR/issue on any host, Bitbucket PR, Miro
board, Overleaf project, Colab notebook, Microsoft 365 `sourcedoc`), and
everything else as an exact page (scheme family, host, port, path modulo
trailing slash, query as an order-insensitive multiset minus tracking params,
fragment ignored). No domain wildcards. Credentials in URLs are rejected.
Exact-page targets get a short landing grace period (≤20 s, settles 3 s after
the last commit) during which redirects become exact aliases.

### Desktop isolation: four panels, not a cutout
Per display, up to four borderless non-activating `NSPanel`s surround the focus
window's rectangle (`OverlayGeometry.coverRects`). There is no overlay window
where the focus window is, so hit-testing is trivially correct. Panels use
`NSVisualEffectView(.behindWindow)` (the window server blurs what is behind; no
screen capture, no Screen Recording permission) or a solid fill. Level:
`statusBar + 1` — above apps, floating panels, the Dock and the menu bar; below
pop-up menus (Chrome context menus still work) and system security UI.
`collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`
makes them follow every Space, including a full-screen focus window's Space.

**Focus loop** (10 Hz, plus immediate checks on app activation, Space change,
display change, wake and extension `violation` reports): `CGWindowList` gives
the focus window's bounds/on-screen state and the windows *above* it.
`FocusPolicy.assess` (pure, tested) decides:
- `focused` → hole open;
- `lost` (another app active, or another layer-0 window over it that isn't a
  Chrome child surface inside its frame) → **close the hole immediately**,
  then raise the focus window (Accessibility: `AXRaise` + `AXFrontmost`; plus the
  extension's `windows.update({focused})`);
- `offscreen` (minimised, hidden, other Space) → full cover + raise;
- `exempt` (SecurityAgent, permission prompts, System Settings, loginwindow…)
  → overlays step aside until it's gone;
- `ownUI` (Ekagrachit's confirmation panel) → keep overlays, don't fight.

The native window is identified as: owner pid = the browser pid reported by the
host (its parent process) AND bounds = `chrome.windows` bounds (±4 pt) AND
layer 0, newest window number; fallback after 1.5 s: a window that did not exist
before the session with the same size.

### Time
`Deadline` stores a wall-clock deadline, a monotonic deadline from a clock that
**includes sleep** (Darwin `CLOCK_MONOTONIC`, Linux `CLOCK_BOOTTIME`) and the
boot ID. Remaining = `min(wall, monotonic)` within the same boot, wall-only
after a reboot. Consequences: sleep counts as elapsed time; setting the clock
back or suspending a process can never extend a session; setting it forward can
end it early (safe direction). The extension receives `remainingMs` (no clock
comparison across processes) and keeps its own alarm at the deadline (+3 s) so
a dead app can never leave the browser locked.

### Performance: never wait on another app
The app's main thread draws the overlays, runs the 10 Hz focus check and
answers the menu, so it must never block on another process.
- **Accessibility calls are capped at 0.3 s** (`AXUIElementSetMessagingTimeout`
  on the system-wide element and on every app element). The system default,
  about 6 s per call, let one busy or hung app freeze Ekagrachit.
- **Raising runs off the main thread** (`AXRaiser`: a serial queue; requests
  that arrive while one is in flight are dropped, since it already does the
  job). The window's AX element is cached between raises instead of listing
  the app's windows and reading every frame each time.
- **Browsers are never asked for window titles.** Querying Chrome through
  Accessibility makes it build accessibility data for the page, which is
  expensive for documents like Google Docs. Titles are read only for apps
  that can be targets, and when re-finding a native window, only for that
  app.
- The focus check itself uses only window-server queries
  (`CGWindowListCopyWindowInfo` for one window and the windows above it), no
  Accessibility.
- Regression test: `tests/macos/desktop.test.ts` freezes the focused app with
  `SIGSTOP`, switches away repeatedly, and requires Ekagrachit to answer its
  own Accessibility queries within a second each time.

## Session state machine (app)

![State diagram: idle → preparing (start, restore, adopt) → active (window located and overlays shown). active ⇄ degraded (extension disconnected or focus window missing / window re-verified). preparing, active and degraded → ending (timeout, failure, expiry, user end, extension ended, or 120 s degraded). ending → idle (ack, disconnect or 4 s).](images/diagrams/state-machine.svg)

`active` requires: valid URL, extension connected, popup created, tab
verified, native window located, overlays shown, same sid acknowledged.
`degraded` (extension disconnected or focus window missing) keeps overlays and
browser rules; it returns to `active` once the window is re-verified, or ends
after 120 s rather than trapping the user. Every end path removes overlays first.
`ending` only waits (≤4 s) for the extension to close its window; repeated end
requests are no-ops. Fully specified and tested in
`apps/macos/Sources/EkagrachitCore/SessionStateMachine.swift`.

## Failure behaviour

| Failure | Behaviour |
|---|---|
| Extension service worker suspended | Session in `chrome.storage.local`; DNR session rules persist; first event wakes the worker (E2E-tested). |
| Chrome restarts | Rules re-installed; after a 4 s settle (so restored tabs count as pre-existing) a restored popup is adopted or the window recreated (E2E-tested). |
| Chrome quits | App: focus window gone → `degraded`, full cover, HUD explains; ends after 120 s; emergency exit always available. |
| Native host / app disconnect | Extension keeps enforcing browser rules until its deadline, badge `!`; reconnect + re-sync resumes (E2E-tested). |
| App crashes / is killed | Overlays are windows of the app process and vanish with it — nothing orphaned. Persisted session is resumed on relaunch if still valid; otherwise cleared. |
| App restarts | `restore` → `preparing(recovering)`; extension re-reports its existing window; 30 s timeout then clean up. |
| Focus window closed | Extension recreates it (rate-limited); app re-locates it. |
| Accessibility revoked mid-session | Session continues; raise falls back to app activation + extension focus; HUD shows "Limited". New sessions require the permission. |
| Stale/foreign messages | Dropped by validation, sid matching and epoch/seq ordering (unit + E2E tested). |
| Display connected/disconnected | Overlay layout recomputed on `didChangeScreenParameters`. |
| Sleep/wake | Deadline uses sleep-inclusive clocks; wake triggers an immediate tick. |

## Implementation status

All items below are verified by automated tests in CI. Linux covers the extension, Chromium and the Swift core; the macOS 26 runner covers the real app, the window server and screenshots.

| Item | Verified by |
|---|---|
| Spike 1: MV3 popup in the existing profile | Chromium E2E (Linux + macOS) |
| Spike 2: navigation isolation (prevent vs. reverse) | `isolation.test.ts` |
| Spike 3: overlay with one interactive external window | `desktop.test.ts` (pixels + window server) |
| Spike 4: native messaging, host manifest, key-pinned extension ID | `native-bridge.test.ts`, `desktop.test.ts` |
| M1 browser-only prototype | `isolation.test.ts` |
| M2 native shell: state machine, timer, permissions, safe exit | XCTest + `desktop.test.ts` (emergency exit) |
| M3 desktop overlays: tracking, Dock, full screen, Stage Manager, restore | `desktop.test.ts` (multi-display: geometry unit tests only) |
| M4 integration: sync, acks, timeouts, stale ids, reconnection, window identification | `native-bridge.test.ts`, `desktop.test.ts`, smoke test |
| M5 hardening: restarts, disconnects, races | all suites. A hello/request race and a Dock-coverage bug were found and fixed this way |
| M6 packaging | CI artifact `ekagrachit-macos-unsigned` |

Outside what this repository can do on its own: Developer ID signing and notarization. These need an Apple Developer account; until then builds are ad-hoc signed.
