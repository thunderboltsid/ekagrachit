# Development

## Layout and boundaries

![Module diagram: in the Swift package, EkagrachitApp (AppKit/SwiftUI shell) and EkagrachitHost (relay) depend on EkagrachitCore (no AppKit: state machine, deadlines, protocol, geometry, focus policy, IPC). In the extension, src/ui talks to src/background via runtime messages, which uses the pure src/shared. The protocol is mirrored between EkagrachitCore and src/shared and tested on both sides.](images/diagrams/modules.svg)

- `apps/macos/Sources/EkagrachitCore` — **no AppKit**. Everything that can be
  decided without the OS lives here and is unit-tested on macOS and Linux:
  `SessionStateMachine` (pure reducer: `(state, event, now) -> (state, effects)`),
  `Deadline`, `Protocol`, `Framing`, `Geometry`, `WindowMatching`/`FocusPolicy`,
  `SessionStore`, `UnixSocket`, `BridgeServer`.
- `apps/macos/Sources/EkagrachitApp` — the thin impure shell:
  `FocusSessionCoordinator` turns system/bridge input into events and executes
  effects; `OverlayManager`, `WindowTracker`, `ConfirmEndPanel`, `HotKey`, SwiftUI views.
- `apps/macos/Sources/EkagrachitHost` — stdio relay; contains no session logic.
- `extensions/chrome/src/shared` — pure TS (identity, rules, protocol, reconcile).
- `extensions/chrome/src/background` — `FocusController` (single serial queue
  for all state mutations) and `NativeBridge`.

Session state exists in exactly one authoritative place (the app's
`MachineState`); the extension mirrors the desired session and reconciles.

## Common tasks
```bash
# Extension
cd extensions/chrome
npm ci
npm run build          # -> dist/ (load unpacked)
npm run typecheck && npm test
HEADED=1 npm run test:e2e        # macOS / Linux desktop
HEADED=1 xvfb-run -a npm run test:e2e   # headless Linux box

# Native
cd apps/macos
swift build            # core + host (+ app on macOS)
swift test
swift run Ekagrachit   # run the app unbundled (Accessibility is granted to the terminal in that case)
../../scripts/build-app.sh   # bundle
```

Open `apps/macos/Package.swift` in Xcode to edit/debug the app.

## Iterating on the bridge locally
After `install.sh`, the host manifest points to the installed app's host. To
use a debug build instead, edit the manifest's `path` to
`apps/macos/.build/debug/ekagrachit-host` and reload the extension. Environment
overrides: `EKAGRACHIT_SOCKET` (socket path), `EKAGRACHIT_SUPPORT_DIR` (state dir).

## Conventions
- Swift 5 language mode, `@MainActor` for AppKit-facing types; bridge callbacks
  arrive on the main queue.
- TypeScript uses only erasable syntax (runs directly under Node's type stripping for tests).
- No runtime dependencies in the extension; dev dependencies: typescript, esbuild, playwright, @types.
- Every new escape path gets an E2E test (extension) or a `FocusPolicy`/state-machine test (native).

## Releases
Every push to `main` whose checks all pass is released; there is no manual
step.

```text
push to main → CI: extension · Swift on Linux · macOS app + desktop E2E
             → publish (release.yml, called by CI)
                 next tag   = latest vX.Y.Z + patch   (trailer "Release: minor" / "Release: major" bumps more)
                 build      = scripts/set-version.sh <tag> → scripts/package-release.sh
                 verify     = DMG mounts, app signature, bundled extension, version matches the tag
                 publish    = tag on the tested commit + GitHub release (DMG, extension zips, SHA256SUMS)
                 notes      = commit subjects since the previous tag (scripts/release/notes.sh)
```

- **Versions live in tags.** Nothing is committed back (so a release can't
  trigger another); the build stamps the tag's version into the manifest,
  app bundle and host. The version in the source tree is only for local
  builds.
- **One at a time.** Releases share a concurrency group. If several pushes
  land quickly, the newest one is released and those still waiting are
  skipped; a commit that already has a version tag is never released twice.
- **Bigger bumps are explicit**: add a trailer line `Release: minor` (or
  `Release: major`) at the end of the commit message, next to
  `Co-Authored-By:`. Only a real trailer counts; mentioning the words in the
  message body does not (that once released 1.0.0 by accident).
- **Write commit subjects for people**: they are the release notes.
- **By hand, if ever needed:** pushing a `vX.Y.Z` tag releases it, and
  running the *Release* workflow with an existing tag rebuilds it and
  re-attaches its files.
- Try it locally: `scripts/release/next-version.sh` and
  `scripts/release/notes.sh "$(scripts/release/next-version.sh)"`.

## Diagrams
Diagrams are written in Mermaid (`docs/diagrams/*.mmd`) and committed as rendered
SVGs (`docs/images/diagrams/*.svg`), which the docs embed. After editing a
`.mmd` file, re-render with:
```bash
scripts/render-diagrams.sh   # pinned mermaid-cli; uses local Chrome/Chromium
```
