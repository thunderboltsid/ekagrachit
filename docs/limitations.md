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
| Link / typed / scripted navigation of the focus tab to another doc or site | **Prevented** (request blocked before it is sent), then the target is reloaded | DNR main-frame rules |
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

## Desktop (macOS) — implemented, built in CI, **requires verification on a physical Mac**
| Attempt | Result |
|---|---|
| Clicking outside the focus window, the Dock, the desktop, the menu bar | **Prevented**: covered by overlay panels above Dock/menu-bar level; clicks are absorbed and refocus Chrome |
| Cmd+Tab to Slack/Terminal | The switcher still appears (system UI). Switching is **reversed**: the hole closes immediately on activation and the focus window is raised again. The other app's window is never visible outside the focus window's rectangle; inside it, at most one 100 ms poll interval |
| Another Chrome window brought to front | **Reversed** (same). Safety valve: if some window above the focus window cannot be dislodged for 2.5 s while Chrome is frontmost, the hole reopens instead of locking you out of your document |
| Switching Spaces (Ctrl+→, swipe) | Overlays are on every Space; the new Space is fully covered and the focus window is re-activated (macOS switches back to its Space) |
| Mission Control / App Exposé | **Possible to open** (it draws above all apps); choosing another window there is **reversed** |
| Spotlight / Launchpad | Spotlight's panel can open; launching an app is **reversed** |
| Notification banners | **Possible** unless Do Not Disturb is enabled (see below) |
| Minimising / hiding Chrome (Cmd+M / Cmd+H) | **Reversed** (unminimise/unhide) |
| Full-screen focus window | supported: overlays join its Space; other displays stay covered |
| Stage Manager | Untested. Overlays are not managed by Stage Manager; strips may be covered. |
| System dialogs (password prompts, permission requests, System Settings) | deliberately **not blocked**: overlays step aside while they are frontmost |
| Force Quit (Cmd+Opt+Esc), Activity Monitor kill | **Possible** by design. Overlays die with the process; nothing is left behind |

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
