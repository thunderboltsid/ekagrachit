# Ekagrachit (एकाग्रचित्त)

**One resource. One focus window. One duration. Everything else disappears.**

Ekagrachit is a macOS deep-focus tool for people whose distractions are
*productive* apps. You give it one document — a Google Doc, a GitHub PR, a Jira
issue, any page — and a duration. It opens that resource in a dedicated Chrome
window (your real profile, already signed in), obscures everything else on
every display, and keeps you on that one resource until the time is up.

It is not a website blocklist. Jira isn't "bad"; it's just not what you chose
to work on for the next 45 minutes.

```
 ┌───────────── menu bar app (Swift) ─────────────┐
 │ session state machine · overlays · focus loop   │──┐ unix socket (same user only)
 └─────────────────────────────────────────────────┘  │
                                         ekagrachit-host (native messaging relay)
 ┌──────────── Chrome extension (MV3) ────────────┐   │ stdio
 │ dedicated popup · URL identity · DNR rules      │──┘
 └─────────────────────────────────────────────────┘
```

## What happens during a session
- The target opens in a **Chrome popup window**: no tab strip, your cookies and logins.
- Every other window, the Dock, the desktop and the menu bar are covered by a
  **frosted (or solid) overlay** on every display and Space. The focus window
  stays sharp and fully interactive.
- Navigating the focus window to a different document or site is **blocked before
  the request is sent** and the target is restored. New tabs/windows never load
  and are closed. Closing the focus window reopens it.
- Cmd+Tab, the Dock, other Chrome windows, other Spaces: the hole around the
  focus window closes instantly and the focus window is brought back.
- A small pill shows the remaining time. At the end everything is restored and
  only the focus window closes (Chrome asks if there are unsaved changes).
- **Emergency exit**: ⌃⌥⌘E (or "End…" on the pill) → hold the button for 2.5 s.

What is prevented vs. merely reversed vs. still possible is spelled out in
[docs/limitations.md](docs/limitations.md).

## Install (macOS 26 Tahoe+, Apple Silicon, Google Chrome, Xcode 26+, Node 22.18+)
```bash
git clone https://github.com/thunderboltsid/ekagrachit && cd ekagrachit
scripts/install.sh
```
Then load the extension: `chrome://extensions` → Developer mode → **Load unpacked** →
`extensions/chrome/dist`. Open `~/Applications/Ekagrachit.app` and grant
**Accessibility** when prompted. Details and the prebuilt-artifact path:
[docs/installation.md](docs/installation.md).

### Permissions
| Component | Permission | Why |
|---|---|---|
| App | Accessibility | Raise the exact Chrome focus window when you switch away (macOS 14+ restricts app activation otherwise). |
| App | — (no Screen Recording, no Input Monitoring) | Blur is composited by the window server; only window bounds are read; the emergency shortcut is a Carbon hot key. |
| Extension | `tabs`, `webNavigation` | Know which tab/window is the focus window and check top-level URLs. |
| Extension | `declarativeNetRequest` | Block disallowed top-level loads before they happen (no host permissions). |
| Extension | `nativeMessaging`, `storage`, `alarms` | Talk to the app; survive service-worker restarts; expire on time. |

Privacy: everything is local. No accounts, telemetry, analytics or network
calls. Document contents are never read. Only the current session (target URL,
deadline) is persisted, and deleted when the session ends.

## Use without the Mac app
The extension works alone (browser-only mode): click its toolbar icon, enter a
URL and duration. Browser restrictions apply; the desktop is not obscured.
During a session the controls open with ⌃⇧E (`MacCtrl+Shift+E`).

## Repository
```
apps/macos/            Swift package
  Sources/EkagrachitCore/   pure logic: state machine, deadlines, protocol, IPC, geometry (macOS + Linux)
  Sources/EkagrachitHost/   ekagrachit-host (Chrome Native Messaging host)
  Sources/EkagrachitApp/    menu bar app (AppKit/SwiftUI)
  Tests/                    XCTest (60 tests incl. real socket + host relay)
extensions/chrome/     MV3 extension (TypeScript, esbuild)
  src/shared/               identity policy, DNR rules, protocol, reconciliation (pure)
  src/background/           service worker: controller + native bridge
  tests/unit, tests/e2e     node:test + Playwright in real Chromium
scripts/               build-app, install, uninstall, doctor
docs/                  architecture, protocol, limitations, installation, development, testing
```

## Build & test
```bash
cd extensions/chrome && npm ci && npm run typecheck && npm test && npm run build
HEADED=1 xvfb-run -a npm run test:e2e   # Linux; on macOS: HEADED=1 npm run test:e2e
cd apps/macos && swift test             # core tests (macOS or Linux)
scripts/build-app.sh                    # macOS: apps/macos/build/Ekagrachit.app
```
See [docs/development.md](docs/development.md) and [docs/testing.md](docs/testing.md).

## License
MIT — see [LICENSE](LICENSE).
