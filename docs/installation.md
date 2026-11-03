# Installation

Requirements: macOS 26 Tahoe or later on Apple Silicon, Google Chrome 120+.

## Option A — download (recommended)
1. Download `Ekagrachit-<version>.dmg` from the
   [latest release](https://github.com/thunderboltsid/ekagrachit/releases/latest)
   and drag **Ekagrachit** onto **Applications**.
2. Open Ekagrachit. macOS 26 blocks apps that aren't notarized the first time:
   click **Done**, then go to System Settings → Privacy & Security, scroll to
   *"Ekagrachit" was blocked…* and click **Open Anyway**, then confirm.
3. The setup window appears:
   - **Chrome extension:** click *Open Chrome Extensions*, turn on
     **Developer mode** (top right), click *Show Extension Folder*, and drag
     the **Chrome Extension** folder onto the Extensions page.
   - **Accessibility:** click *Open System Settings* and switch Ekagrachit on.
4. Both steps turn green. Click ◎ in the menu bar to start your first session.

The app registers itself with Chrome (and Chromium, Brave, Edge, Vivaldi if
installed) every time it starts, so moving or updating it needs no extra
steps. When an update ships a newer extension, the app copies it into the same
folder and the extension reloads itself while idle.

To verify a download, compare `shasum -a 256 Ekagrachit-*.dmg` with
`SHA256SUMS` on the release page.

## Option B — build from source
Needs Xcode 26+ and Node.js 22.18+.

```bash
git clone https://github.com/thunderboltsid/ekagrachit
cd ekagrachit
scripts/install.sh
```

`install.sh` builds the extension into `extensions/chrome/dist`, builds and
ad-hoc signs `Ekagrachit.app`, copies it to `~/Applications`, and writes the
Native Messaging host manifest
`~/Library/Application Support/Google/Chrome/NativeMessagingHosts/io.github.thunderboltsid.ekagrachit.json`
(also for Chrome Beta/Canary, Chromium and Brave if installed). Options:
`--dest DIR`, `--app PATH` (use a prebuilt app), `--extension-id ID`
(if your extension ID differs), `--skip-extension-build`.

Then:
1. Chrome → `chrome://extensions` → enable **Developer mode** → **Load unpacked**
   → choose `extensions/chrome/dist`. The ID shown must be
   `dpbpdbflelamfpmehknioljngeaagaeb` (it is fixed by the public key in
   `manifest.json`; `install.sh` prints the ID it registered).
2. `open ~/Applications/Ekagrachit.app` — a ◎ icon appears in the menu bar.
3. Grant **Accessibility** (System Settings → Privacy & Security → Accessibility → enable Ekagrachit).
4. The menu shows "Chrome extension connected" and "Accessibility granted". Paste a URL, pick a duration, **Start Focus**.

## Option C — CI artifacts (unsigned)
Each CI run on `macos-15` uploads `ekagrachit-macos-unsigned` containing
`Ekagrachit-macOS-unsigned.zip`, `ekagrachit-chrome-extension.zip`, and the
scripts. Unzip both, then:

```bash
xattr -dr com.apple.quarantine Ekagrachit.app
./install.sh --app ./Ekagrachit.app --skip-extension-build
```
and load the unzipped `dist` folder as an unpacked extension. The app is
ad-hoc signed (not notarized); Gatekeeper requires the quarantine removal above
or right-click → Open the first time.

## Optional: Do Not Disturb
macOS offers no API for apps to switch Focus modes. In the Shortcuts app create
"Ekagrachit Focus On" (action *Set Focus* → Do Not Disturb → On) and
"Ekagrachit Focus Off" (→ Off), then enter the names in Ekagrachit → Settings.

## Uninstall
```bash
scripts/uninstall.sh
```
and remove the extension in `chrome://extensions`.

## Troubleshooting
Run `scripts/doctor.sh` first.

| Symptom | Fix |
|---|---|
| Menu says "Chrome extension not connected" | Is Chrome running with the extension enabled? Re-run `install.sh`, then reload the extension (↻). Clicking the extension's toolbar button opens Ekagrachit's menu when they are connected, and an explanation page when they are not. |
| Extension popup: "Native host not installed" | Open (or quit and reopen) Ekagrachit: it registers itself with Chrome at every launch. Then reload the extension (↻ in `chrome://extensions`). If you loaded the extension from somewhere other than the folder the app shows, its ID differs: remove it and load the app's folder. |
| Extension popup: "Mac app not running" | Open Ekagrachit.app. |
| "Accessibility not granted" even after enabling it | Ad-hoc builds change identity on rebuild: remove Ekagrachit from the Accessibility list, add it again, relaunch the app. |
| Session never becomes active / "focus window could not be set up" | Chrome must be the browser with the extension; check that the popup appeared. Multiple Chrome profiles with the extension: disable it in the others. |
| Need to get out right now | ⌃⌥⌘E → hold. Or Force Quit Ekagrachit (⌥⌘⎋): overlays vanish with the process; restrictions in Chrome lift at the deadline, or reopen Ekagrachit (it resumes the session) and press ⌃⌥⌘E → hold. |
| Chrome shows "This page has been blocked by an extension" | Expected for an instant before Ekagrachit restores the target. If it persists, the target redirects somewhere unexpected; end the session and start it with the final URL. |
