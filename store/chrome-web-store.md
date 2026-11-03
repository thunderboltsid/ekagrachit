# Chrome Web Store submission kit

Upload `ekagrachit-chrome-web-store-<version>.zip` from the GitHub release
(identical to the sideload build, minus the `key` field the Store rejects).

**After the first upload** the Store assigns a permanent extension ID. Add it to
`NativeHostRegistration.allowedExtensionIDs`
(`apps/macos/Sources/EkagrachitCore/NativeHostRegistration.swift`) and ship an
app update, so the app accepts connections from the Store build as well as from
sideloaded copies.

## Listing

**Name:** Ekagrachit — one-pointed focus

**Summary (132 chars max):**
A deep-focus tool for people whose distractions are productive apps. One page, one window, nothing else until time's up.

**Category:** Productivity → Tools

**Description:**

> The problem isn't social media. It's the Jira ticket your design doc links
> to, the PR that ticket mentions, the Slack thread that pings while you read
> it. Twenty minutes later the review you sat down for is still unfinished.
>
> Ekagrachit (एकाग्रचित्त, "one-pointed attention") gives you a temporary,
> strictly scoped workspace:
>
> • Choose one resource and a duration: a Google Doc, Sheet or Slides deck, a
>   GitHub or GitLab pull request, a Jira or Linear issue, a Notion or
>   Confluence page, a Figma file, a Miro board, an Overleaf project, a Colab
>   notebook, Word, Excel or PowerPoint for the web, or any page.
> • It opens in a dedicated window, signed in as usual. Editing, comments and
>   everything else in the document keep working.
> • Links to anything else simply don't load. New tabs and windows close.
>   Every link you reached for is saved and shown when the session ends.
> • With the free Ekagrachit Mac app, the rest of your screen is covered too —
>   other apps, the Dock, other Spaces — and switching away brings you right back.
>   The Mac app can also focus any app window: Word, Pages, VS Code, Xcode,
>   iTerm2 and the rest.
> • Ending early takes a deliberate hold, never an accidental click.
>
> Everything stays on your device: no account, no tracking, no network requests.

## Privacy practices (dashboard answers)

- **Single purpose:** Restrict browsing to one user-chosen page or document
  for a user-chosen duration.
- **Data collected:** None is transmitted. Website content: not collected.
  Web history: not collected (URLs of navigations are checked locally during a
  session only; links the user tried to open are stored locally until cleared).
- **Remote code:** No.

## Permission justifications

| Permission | Justification |
|---|---|
| `tabs` | Identify the dedicated focus window/tab, close tabs opened during a session, and offer the active tab as the focus target. |
| `webNavigation` | Detect navigations in the focus tab that do not reach the network (single-page-app history changes, back/forward cache) and revert them. |
| `declarativeNetRequest` | Block top-level loads of other pages during a session before any request is made. Only `main_frame` requests in tabs touched by the session are affected; no host permissions are requested. |
| `nativeMessaging` | Coordinate with the optional Ekagrachit macOS app, which covers the rest of the screen. |
| `storage` | Persist the active session across browser restarts and keep "Saved for later" links. |
| `alarms` | End the session at its deadline even if the service worker was suspended. |

## Store assets

- Icon 128×128: `extensions/chrome/assets/icons/128.png`
- Screenshots (1280×800): `docs/images/*.png` are real captures from the macOS CI run (`desktop-e2e-screenshots` artifact); pad/crop to 1280×800.
