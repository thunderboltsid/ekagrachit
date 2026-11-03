# Notes for coding agents

- Read `docs/architecture.md` first. The app's `SessionStateMachine` (pure,
  `apps/macos/Sources/EkagrachitCore`) is the single source of truth for session
  state; the extension reconciles to the app's `sync`. Don't add session state
  elsewhere.
- Keep OS-independent logic in `EkagrachitCore` / `extensions/chrome/src/shared`
  so it stays testable on Linux.
- Protocol changes: update `docs/protocol.md`, both `Protocol.swift` and
  `shared/protocol.ts`, and the parser tests on both sides.
- Checks before committing:
  - `cd extensions/chrome && npm run typecheck && npm test && HEADED=1 xvfb-run -a npm run test:e2e`
  - `cd apps/macos && swift build && swift test`
- The AppKit app only compiles on macOS; rely on the `macos` CI job and never
  claim desktop behaviour was verified without a real Mac (see docs/testing.md).
- Shell scripts: guard every `rm` path with `${VAR:?}`.
- No telemetry, no network calls, no reading document contents, no private APIs.
  The single exception is the update check (`Updater.swift`): HTTPS to this
  repository's GitHub releases, no identifiers, off with one setting.
