# Privacy

Ekagrachit runs entirely on your Mac. It has no account, no server, no
analytics and no telemetry, and it makes no network requests of its own.

## What it stores, where, and for how long

| Data | Where | Kept until |
|---|---|---|
| The current session: target URL (or, for an app window, the app and the window's title), deadline, focus window/tab ids, links you reached for | `chrome.storage.local` (extension) and `~/Library/Application Support/Ekagrachit/session.json` (app) | The session ends |
| "Saved for later" links from your last session | `chrome.storage.local` | You press **Clear**, or 7 days |
| Settings (duration, overlay style, Shortcut names, sound) | macOS user defaults | You change them / uninstall |

No browsing history is recorded. Pages you visit outside a focus session are
never seen or stored.

## What it reads

- **The URL of the focus tab and of tabs opened during a session**, to decide
  whether a navigation stays on your chosen document. Nothing is read from
  page contents. The focus tab's *title* (your document's name) is shown in
  Ekagrachit's own UI.
- **The active tab's URL when you open the menu**, to offer it as the target.
- **Window positions and sizes** (from macOS and Chrome), to keep the overlay
  around your focus window.
- **The titles of open app windows, when you open the menu or press ⌃⌥⌘F**,
  read through the Accessibility permission, so the window list says
  "Q3 plan.docx — Microsoft Word" rather than just "Microsoft Word". Titles are
  shown in the menu, and the focus window's title is kept in the session file
  so the window can be found again if its app restarts. They never leave your
  Mac and are not kept after the session.
- Window *contents* are never read. Ekagrachit does not use screen recording.

## Permissions and why

| Component | Permission | Purpose |
|---|---|---|
| App | Accessibility | Bring the focus window back to the front when you switch away; list open windows by title. |
| Extension | `tabs`, `webNavigation` | Identify the focus window/tab and check top-level navigations. |
| Extension | `declarativeNetRequest` | Block off-target page loads *before* they happen. No host permissions are requested. |
| Extension | `nativeMessaging` | Talk to the Ekagrachit app on your Mac. |
| Extension | `storage`, `alarms` | Survive browser restarts; end the session on time. |

The app and the extension talk over a Unix socket in a folder only your macOS
user can access; nothing listens on the network.

## Removing everything

Quit Ekagrachit, delete it from Applications, remove the extension in
`chrome://extensions`, and delete `~/Library/Application Support/Ekagrachit`.
`scripts/uninstall.sh` does all of this except removing the extension.
