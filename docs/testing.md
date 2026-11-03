# Testing

## Automated (run in CI on every push)
| Suite | Where | What it covers |
|---|---|---|
| `extensions/chrome/tests/unit` (node:test) | Linux | Test C identity policy (Docs IDs, edit modes, fragments, other docs, Docs home, Jira/GitHub/Slack, malicious URLs: look-alike hosts, userinfo, path tricks, schemes); DNR regexes agree with the matcher; DNR rule shape (main_frame only, tab-scoped); Test F malformed/stale messages; reconciliation; deadlines. |
| `tests/e2e/isolation.test.ts` (Playwright, real Chromium) | Linux, headed under Xvfb | Test A: dedicated popup, document interactive, Doc B / Jira same-tab blocked *before any request* and reverted, SPA escape reverted, `_blank` links, `window.open`, new tab, new window closed without loading, focus snap-back, closed window reopened, "Open in Chrome" re-homed, worker suspension, expiry restores everything. Test E: pre-existing tabs untouched, `beforeunload` respected on close. Test D: double start, idempotent end, invalid targets, browser restart recovery, expired-session cleanup. |
| `tests/e2e/native-bridge.test.ts` | Linux | Chromium + extension ↔ **real Swift `ekagrachit-host`** ↔ scripted app: handshake, app-started session, violation reports, stale `sync` ignored, foreign-sid `focus` ignored, app crash → browser-only degraded enforcement → app restart re-sync, app-ended session, UI start routed to app, browser-ended session tombstoned. |
| `apps/macos/Tests` (XCTest, 60 tests) | Linux + macOS | State machine (every transition, timeouts, stale sids, idempotent end, restore/adopt, sleep past deadline), deadlines (sleep, clock set back/forward, reboot), overlay geometry (multi-display, edges, fractional), window matching & focus assessment, framing, protocol parsing (malformed/unexpected), persistence, Unix socket server (peer check, malformed frames, oversized frames), real host binary relay both ways. |
| macOS job: build + smoke | macos-26 (arm64) | Compiles the app, builds an arm64 ad-hoc signed bundle, launches it and drives handshake → adoption → end through the bundled host (`scripts/ci-macos-smoke.mjs`). |
| `tests/macos/desktop.test.ts` (13 tests) | macos-26, real WindowServer | Real app + Chromium + extension + host. Accessibility is granted through the TCC database (SIP is off on the runner). Observed with `ekagrachit-probe` (window list, synthetic clicks/keys) and **screenshot pixels**: <ul><li>only the focus window is uncovered, and there's no flicker over 2 s</li><li>app switch reversed (~140 ms)</li><li>Dock/desktop clicks absorbed</li><li>real Cmd+T/Cmd+N</li><li>other browser window</li><li>move/resize into the Dock area</li><li>minimise</li><li>full screen across Spaces</li><li>Mission Control</li><li>Stage Manager</li><li>emergency shortcut (Escape / short press / hold)</li><li>SIGKILL leaves no windows, and relaunch resumes</li><li>1-minute expiry</li></ul> Screenshots are uploaded as the `desktop-e2e-screenshots` artifact. |

Keyboard accelerators (Cmd+T, Cmd+N, Cmd+W) cannot be pressed through automation
(they are browser-UI commands); tests use the equivalent `chrome.tabs/windows`
calls, which produce the same events the guards handle.

## Running the desktop suite locally (macOS)
```bash
scripts/build-app.sh
(cd apps/macos && swift build -c release --product ekagrachit-probe)
cd extensions/chrome && npx playwright install chromium
HEADED=1 npm run test:macos
```
Grant Accessibility to your terminal (the probe posts synthetic input), or the
input-driven tests fail. The suite takes over the screen for about 2 minutes.

## What automation does not cover
See the end of [limitations.md](limitations.md): multiple displays, real sleep/wake,
a real Google account, branded Chrome.
