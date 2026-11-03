<p align="center"><img src="docs/images/icon-256.png" width="128" alt="Ekagrachit icon"></p>

<h1 align="center">Ekagrachit</h1>
<p align="center"><b>One document. One window. Nothing else.</b><br>
<a href="https://thunderboltsid.github.io/ekagrachit/">Website</a> ·
<a href="https://github.com/thunderboltsid/ekagrachit/releases/latest">Download</a> ·
<a href="docs/installation.md">Install guide</a> ·
<a href="PRIVACY.md">Privacy</a></p>

**A deep-focus tool for people whose distractions are productive apps.**

Ekagrachit (एकाग्रचित्त, *one-pointed attention*) runs on macOS with Google
Chrome. You give it the one thing you want to work on — a Google
Doc, a GitHub pull request, a Jira issue, any page — and a duration. It opens
that resource in its own window, signed in as usual, and keeps every other
tab, site and app out of reach until the time is up.

It is not a website blocker. Jira isn't "bad"; it just isn't what you chose
to work on for the next 45 minutes.

The name comes from the Bhagavad Gītā and Patañjali's Yoga Sūtras: *ekāgra*,
the one-pointed mind, "a lamp sheltered from the wind." [What the name means →](https://thunderboltsid.github.io/ekagrachit/#name)

![A focus session: the design doc is sharp and interactive; everything else on screen is covered; a small pill shows the time left](docs/images/focus-session.png)

## What happens during a session

- **Only your document.** It opens in a dedicated Chrome window with no tab
  strip. Editing, comments and the rest of the document keep working.
- **Off-target links never load.** Navigations to anything else are blocked
  before a request is made. New tabs and windows are closed.
- **Saved for later.** Every link you reach for is kept. The pill says
  *Saved for later: github.com*, and the full list appears when the session ends.
- **Everything else disappears.** Other apps, the Dock and the menu bar are
  covered on every display and Space. Cmd-Tab, Mission Control, Stage Manager
  and other Spaces all lead back to your document.
- **Deliberate exit.** ⌃⌥⌘E (or *End…* in the pill), then hold for 2.5 s.
- **Robust.** Survives sleep, browser and app restarts. Changing the clock
  can't extend a session. Pages with unsaved changes are never closed without
  asking.
- **Private.** Everything stays on your Mac: no account, no telemetry, no
  network requests. Document contents are never read.

| Start | Saved for later | End early |
|---|---|---|
| ![Menu with the current tab prefilled](docs/images/menu.png) | ![Links saved during the session](docs/images/saved-for-later.png) | ![Hold to end session](docs/images/end-early.png) |

## Install

Requires **macOS 26 Tahoe on Apple Silicon** and **Google Chrome**.

1. Download `Ekagrachit-<version>.dmg` from the
   [latest release](https://github.com/thunderboltsid/ekagrachit/releases/latest)
   and drag Ekagrachit to Applications.
2. Open it. The setup window walks you through the rest:
   - load the Chrome extension: turn on Developer mode in `chrome://extensions`,
     then drag in the folder Ekagrachit shows you;
   - allow Accessibility.

The first time you open the app, macOS asks you to confirm it (System
Settings → Privacy & Security → **Open Anyway**), because builds are not yet
notarized. Details and troubleshooting are in [docs/installation.md](docs/installation.md).

## Build from source

```bash
git clone https://github.com/thunderboltsid/ekagrachit && cd ekagrachit
scripts/install.sh          # builds the extension + app, installs to ~/Applications
```

| | |
|---|---|
| `extensions/chrome/` | MV3 extension (TypeScript): identity policy, blocking rules, session controller |
| `apps/macos/Sources/EkagrachitCore/` | Platform-independent Swift: state machine, deadlines, protocol, IPC, geometry |
| `apps/macos/Sources/EkagrachitApp/` | Menu bar app (SwiftUI + AppKit): overlays, focus loop, setup |
| `apps/macos/Sources/EkagrachitHost/` | Chrome Native Messaging host (stdio ↔ Unix socket relay) |
| `docs/` | Website and documentation ([architecture](docs/architecture.md), [protocol](docs/protocol.md), [limitations](docs/limitations.md), [testing](docs/testing.md), [development](docs/development.md)) |

Every push runs:
- extension unit tests and Chromium end-to-end tests;
- Swift tests on Linux and macOS;
- a desktop suite on a real macOS 26 runner. It drives the real app, Chrome
  and extension, and checks the results through the window server and
  screenshot pixels.

See [docs/testing.md](docs/testing.md).

Releases: run `scripts/set-version.sh X.Y.Z`, commit, and push tag `vX.Y.Z`.
CI builds, verifies and publishes the DMG and extension zips.

## License

MIT. See [LICENSE](LICENSE).
