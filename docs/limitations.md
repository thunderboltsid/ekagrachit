# Enforcement matrix and known limitations

Ekagrachit is a user-controlled focus tool, **not a security boundary**. It
makes ordinary context switching hard and slow; a determined user (or any
process running as the user) can always get out — by design, there is an
emergency exit.

Legend: **Prevented** = the action never shows unrelated content.
**Reversed** = it happens, is detected and undone (typically < 150 ms; the
desktop outside the focus window stays covered throughout). **Possible** = not
stopped.

## Browser (verified in Chromium by automated tests unless noted)
| Attempt | Result | Mechanism |
|---|---|---|
| Link / typed / scripted navigation of the focus tab to another doc or site | **Prevented** (request blocked before it is sent), then the target is reloaded; the link is saved for later | DNR main-frame rules |
| Link with `target=_blank`, `window.open`, Cmd+T, Cmd+N, reopen-closed-tab, settings/history pages | Network load **prevented**; tab/window **closed** (a new-tab page may flash inside Chrome) | DNR `excludedTabIds` + `tabs.onCreated` |
| SPA `pushState` / bfcache Back to another resource | **Reversed** | `webNavigation` + identity policy |
| Focusing another existing Chrome window | **Reversed** | `windows.onFocusChanged` (needs a real display: verified headed under Xvfb) |
| Closing the focus window (Cmd+W) | **Reversed** (window reopened at the last allowed URL) | `windows.onRemoved` |
| "Open in Chrome" (moving the tab out of the popup) | **Reversed** without reload | `tabs.onAttached` + `windows.create({tabId})` |
| Back/Forward within the doc | allowed (same resource) | |
| Docs features that open new tabs (some downloads, "Open in new tab", add-on authorisation pop-ups) | blocked during a session | consequence of the new-tab rule |
| Incognito window (Cmd+Shift+N) | **Reversed natively** by the app (not visible to the extension unless "Allow in Incognito" is enabled, in which case it is also closed) | macOS focus loop |
| DevTools (Cmd+Opt+I) | docked: inside the focus window; undocked: **reversed natively** | |
| Cmd+Q in Chrome | **Possible** — Chrome quits (after its own "hold ⌘Q" warning if enabled). The app goes to *degraded*, covers the screen and ends the session after 120 s if Chrome does not come back. | |
| Disabling/removing the extension in chrome://extensions | **Possible** (requires reaching that page, which is blocked during a session) | |

## Desktop (macOS) — verified on a macOS 26 runner by `tests/macos/desktop.test.ts`
Real Ekagrachit.app + real Chromium (Chrome for Testing) + extension + host,
observed through the window server and checked with screenshot pixels.

| Attempt | Result |
|---|---|
| Clicking outside the focus window, the Dock, the desktop, the menu bar | **Prevented**: covered by overlay panels above Dock/menu-bar level; clicks are absorbed (tested with synthetic clicks) |
| Focus window moved/resized over the Dock area | The Dock strip stays covered (the uncovered area is clipped to the screen's visible frame); the hole follows moves (tested) |
| Another app's floating panel above the focus window | Its intersection with the focus window is covered (unit-tested logic) |
| Switching to another app (the outcome of Cmd+Tab) | **Reversed** in ~125–145 ms (measured); the hole closes first. The Cmd+Tab switcher itself still appears |
| Real Cmd+T / Cmd+N keystrokes in the focus window | Nothing is left open; focus window stays on top (tested with synthetic keystrokes) |
| Another browser window brought to front | **Reversed** (tested). Safety valve: a window that cannot be dislodged for 2.5 s while Chrome is frontmost reopens the hole instead of locking you out |
| Minimising the focus window | **Reversed** (tested). Cmd+H uses the same path (unhide + raise) |
| Full-screen focus window (its own Space); switching away from that Space | **Reversed** in ~125 ms; stays full screen (tested) |
| Mission Control | **Possible to open**; leaving it returns to the focus window (tested). Picking another window in it is the app-switch case |
| Stage Manager | Works: the hole follows the window Stage Manager repositions; strips stay covered (tested) |
| Emergency exit ⌃⌥⌘E | Escape cancels, a short press does nothing, a 2.5 s hold ends the session and removes every overlay (tested) |
| Ekagrachit killed mid-session | Overlays vanish with the process; browser rules continue; relaunch resumes the same session (tested) |
| Expiry | Overlays removed, focus window closed, desktop restored (tested) |
| Spotlight | Its panel can open; launching an app is the app-switch case |
| Notification banners | **Possible** unless Do Not Disturb is enabled (see below) |
| System dialogs (password prompts, permission requests, System Settings) | deliberately **not blocked**: overlays step aside while they are frontmost |
| Force Quit (Cmd+Opt+Esc), Activity Monitor kill | **Possible** by design. Nothing is left behind |
| Auto-hidden Dock revealed by moving the pointer to the screen edge | The revealed Dock can appear over the focus window's edge; clicking an app there is the app-switch case (reversed) |

## Native app windows (Word, Pages, VS Code, Cursor, Xcode, iTerm2, Warp, …)
The unit is **the window**. Whatever happens inside it is allowed: an editor's
file tabs, a terminal's tabs and splits, a document's sheets and dialogs. There
is no per-URL control inside an app the way there is for web pages.

| Attempt | Result |
|---|---|
| Switching to another app | **Reversed**, as for web sessions (tested with TextEdit) |
| A new window of the same app (⌘N, ⌘O, "New Tab" that opens a window) | Covered; the focus window is raised back on top (tested with TextEdit) |
| The app's own sheets, popovers, autocomplete and menus | Allowed while they stay inside the focus window's frame |
| A floating panel of the same app outside the window (an inspector, a palette) | Its part outside the window is covered; a panel *over* the window counts as "another window in front" after the 2.5 s safety valve reopens the hole |
| Closing the focus window | The session waits for the window to come back (found again by title, or the app's only window) and ends after the degraded timeout if it doesn't |
| Quitting / relaunching the app | Same as closing: the window is found again by its title when the app reopens it |
| Apps whose windows have no title (some games, Electron splash screens) | Work, but cannot be found again after a relaunch unless the app has a single window |
| Browsers as native targets | Not offered: web pages are focused through the extension, which gives link-level control |
| Starting via `ekagrachit://` | `focus?window=front`, `focus?app=<bundle id>`, `focus?url=…`. There is deliberately no URL to end a session |

Window titles are read through the Accessibility permission to label the
window list and to find the window again; see [PRIVACY.md](../PRIVACY.md).

### Not covered by automated tests
These need hardware or accounts CI does not have:
- **Two or more displays.** The runner has one display. The geometry is unit-tested for multi-display layouts.
- **Real sleep/wake.** Deadline semantics are unit-tested; on wake the app ticks immediately.
- **A real Google account and Google Docs.** Tests use a local stand-in served as `docs.google.com`.
- **Real web apps (Notion, Figma, Linear, Confluence, GitLab, Office for the web, …).** URL identity, the generated blocking rules (checked with Chrome's own `isRegexSupported`) and a stand-in Figma session are tested; their sign-in flows against the real services are not.
- **Third-party Mac apps (Office, iWork, IDEs, iTerm2, Warp).** The desktop tests use TextEdit and Terminal, which exercise the same window-server and Accessibility paths. Apps with unusual window structures (multiple layer-0 helper windows, custom full-screen modes) may behave differently.
- **Branded Google Chrome.** Tests use Chrome for Testing, which has the same extension APIs. Branded Chrome only differs in requiring "Load unpacked" by hand.

## Platform constraints
- **Focus / Do Not Disturb**: macOS has no public API for apps to toggle Focus.
  Ekagrachit runs user-chosen Shortcuts at start/end (Settings → Do Not Disturb).
  Create Shortcuts named e.g. "Ekagrachit Focus On" / "Off" with the *Set Focus*
  action.
- **Blur**: `NSVisualEffectView` blurs the windows behind in the window server;
  no screen capture or Screen Recording permission is used. On "Reduce
  transparency" systems it renders as a solid tint.
- **Cmd+Tab and Mission Control cannot be suppressed** without a keyboard event
  tap (Input Monitoring permission) or private APIs; both were rejected as
  disproportionate. Ekagrachit reverses their outcome instead.
- **Accessibility permission** is required to raise a specific window of another
  app reliably on macOS 14+ (cooperative activation). Ad-hoc signed builds
  change identity on every rebuild, so the grant may need to be renewed after
  updating a self-built app.
- **Unsaved work**: the focus window is closed with `chrome.windows.remove`,
  which runs `beforeunload` (verified: Chrome shows its dialog and the window
  stays open). Navigation reversion reloads the document; Google Docs autosaves
  continuously, but a page with unsaved local state could lose it if it
  navigates itself to a disallowed URL.
- **Multiple Chrome profiles**: use the extension in one profile. If several
  profiles connect, the most recent one drives the session.
- **Sign-in**: Google, GitHub and Atlassian sign-in pages are allowed inside the
  focus window. For other sites that need interactive SSO, sign in before
  starting the session.
- **Exact-page targets**: a different query string on the same path passes DNR
  and is reverted by the event guard (brief load). Percent-encoded variants of a
  path are treated as different pages (conservative).
