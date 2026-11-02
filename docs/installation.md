# Installation

Requirements: macOS 13 Ventura or later, Google Chrome 120+.

## Option A — build from source (recommended)
Needs Xcode 15.3+ (or the Command Line Tools with Swift 5.10+) and Node.js 22.18+.

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

## Option B — CI artifacts (unsigned)
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
| Menu says "Chrome extension not connected" | Is Chrome running with the extension enabled? Re-run `install.sh`, then reload the extension (↻). The extension popup shows the bridge state. |
| Extension popup: "Native host not installed" | Host manifest missing or extension ID mismatch: compare the ID in `chrome://extensions` with `allowed_origins` printed by `doctor.sh`; re-run `install.sh --extension-id <id>`. |
| Extension popup: "Mac app not running" | Open Ekagrachit.app. |
| "Accessibility not granted" even after enabling it | Ad-hoc builds change identity on rebuild: remove Ekagrachit from the Accessibility list, add it again, relaunch the app. |
| Session never becomes active / "focus window could not be set up" | Chrome must be the browser with the extension; check that the popup appeared. Multiple Chrome profiles with the extension: disable it in the others. |
| Need to get out right now | ⌃⌥⌘E → hold. Or Force Quit Ekagrachit (⌥⌘⎋): overlays vanish with the process; restrictions in Chrome lift at the deadline or via the extension popup (⌃⇧E → hold). |
| Chrome shows "This page has been blocked by an extension" | Expected for an instant before Ekagrachit restores the target. If it persists, the target redirects somewhere unexpected; end the session and start it with the final URL. |
