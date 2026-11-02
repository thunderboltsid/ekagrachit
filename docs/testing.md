# Testing

## Automated (run in CI on every push)
| Suite | Where | What it covers |
|---|---|---|
| `extensions/chrome/tests/unit` (node:test) | Linux | Test C identity policy (Docs IDs, edit modes, fragments, other docs, Docs home, Jira/GitHub/Slack, malicious URLs: look-alike hosts, userinfo, path tricks, schemes); DNR regexes agree with the matcher; DNR rule shape (main_frame only, tab-scoped); Test F malformed/stale messages; reconciliation; deadlines. |
| `tests/e2e/isolation.test.ts` (Playwright, real Chromium) | Linux, headed under Xvfb | Test A: dedicated popup, document interactive, Doc B / Jira same-tab blocked *before any request* and reverted, SPA escape reverted, `_blank` links, `window.open`, new tab, new window closed without loading, focus snap-back, closed window reopened, "Open in Chrome" re-homed, worker suspension, expiry restores everything. Test E: pre-existing tabs untouched, `beforeunload` respected on close. Test D: double start, idempotent end, invalid targets, browser restart recovery, expired-session cleanup. |
| `tests/e2e/native-bridge.test.ts` | Linux | Chromium + extension ↔ **real Swift `ekagrachit-host`** ↔ scripted app: handshake, app-started session, violation reports, stale `sync` ignored, foreign-sid `focus` ignored, app crash → browser-only degraded enforcement → app restart re-sync, app-ended session, UI start routed to app, browser-ended session tombstoned. |
| `apps/macos/Tests` (XCTest, 57 tests) | Linux + macOS | State machine (every transition, timeouts, stale sids, idempotent end, restore/adopt, sleep past deadline), deadlines (sleep, clock set back/forward, reboot), overlay geometry (multi-display, edges, fractional), window matching & focus assessment, framing, protocol parsing (malformed/unexpected), persistence, Unix socket server (peer check, malformed frames, oversized frames), real host binary relay both ways. |
| macOS job | macos-15 | Compiles the AppKit app, builds a universal ad-hoc signed bundle, lint Info.plist, host smoke test. |

Keyboard accelerators (Cmd+T, Cmd+N, Cmd+W) cannot be pressed through automation
(they are browser-UI commands); tests use the equivalent `chrome.tabs/windows`
calls, which produce the same events the guards handle.

## Manual verification on a Mac (required for desktop isolation)
CI compiles the app but cannot exercise window-server behaviour. Before
calling a build good, run through this on a real Mac (ideally with two displays):

1. Start a 15-minute session on a Google Doc you can edit. Popup opens, signed in.
   Type, comment, use the context menu, open the Docs "Share" dialog. ✔ usable.
2. Everything else is frosted on every display; menu bar and Dock covered; pill shows time.
3. Click the desktop / Dock area → nothing activates; focus stays on the doc.
4. Cmd+Tab to Slack / Terminal → bounced back; no other window visible outside the doc's rectangle.
5. Cmd+T, Cmd+N, Cmd+Shift+N, Cmd+W, Cmd+M, Cmd+H in the popup → all reversed.
6. Click a link to another doc / Jira in the doc → never loads.
7. Ctrl+→ to another Space → covered, returns. Mission Control → pick another window → returns.
8. Make the popup full screen → still works; second display still covered.
9. Drag/resize the popup → hole follows within ~100 ms.
10. Unplug/plug an external display → overlays re-layout.
11. Close the lid for > remaining time, open → session over, desktop normal.
12. ⌃⌥⌘E → panel; click "Hold to end" briefly → nothing; hold 2.5 s → session ends, popup closes (with Chrome's prompt if you have unsaved text in a form).
13. Quit Chrome during a session → full cover with "Reopening focus window…"; reopen Chrome → session resumes; or wait 2 min → session ends.
14. `kill` Ekagrachit during a session → overlays vanish; relaunch → session resumes.
15. Revoke Accessibility → new start refused with instructions; running session shows "Limited".
16. Original Chrome windows/tabs unchanged after the session.

Record results (and macOS version / display setup) in the PR.
