# VaultLight

Native macOS menu-bar app: a Spotlight-style panel that searches a Bitwarden vault through the official `bw` CLI and copies credentials. Unofficial, not affiliated with Bitwarden.

- **Designs:** `docs/design/*.png` — match them for layout, spacing and copy. `docs/design/README.md` indexes them; `docs/design/NOTES.md` has per-screen behavior notes.
- **Screenshots:** `docs/screenshots/` holds the built app under each design's file name, for comparison with `docs/design/`.

## Commands

| Task | Command |
| --- | --- |
| First-time setup | `make bootstrap` |
| Regenerate Xcode project | `make gen` (after adding/removing files under `App/`) |
| Core unit tests (fast) | `make test-core` |
| Build the app (unsigned) | `make build` |
| Everything CI runs | `make check` |
| Sync String Catalogs | `make strings` (after changing UI copy; `make check` fails while a catalog is stale) |
| Format | `make format` |
| Lint | `make lint` |

`make check` must exit 0 before a change is committed.

## Layout

- `Packages/VaultLightCore/` — ALL logic: CLI wrapper, models, search index, ranking, session policy, clipboard policy, settings model. Pure Swift package, tested with `swift test`. No AppKit in here except behind protocols.
- `App/` — thin AppKit/SwiftUI layer: NSPanel, hotkey, menu bar, views, view models that call Core.
- `Tests/Fixtures/bw-fake/` — fake `bw` CLI + fixture vault. Tests MUST use this, never the real `bw`.
- `project.yml` — XcodeGen spec. `VaultLight.xcodeproj` is generated and gitignored.

## Non-negotiable rules (security)

IMPORTANT: breaking one of these is a failed change, regardless of tests.

1. Start processes only through the Core CLI wrapper, with `posix_spawn` of the pinned executable path + an argv array (not Foundation `Process`, which decomposes non-ASCII arguments and environment values). Never `/bin/sh -c`, never `posix_spawnp`/`PATH` lookup, never string-built commands.
2. Secrets (master password, session key, API key) go to `bw` via environment variables only (`--passwordenv`, `BW_SESSION`, `BW_CLIENTID`/`BW_CLIENTSECRET`). Never in arguments.
3. Child environment is minimal: `HOME`, `PATH`, `BITWARDENCLI_APPDATA_DIR`, plus the one secret the call needs.
4. Never log secrets, item names, usernames or search queries. Use `Logger` with `privacy: .private` for every dynamic value.
5. Never write secrets or vault content to disk (no caches, no debug dumps, no test snapshots containing them).
6. The search index type has NO password, TOTP seed, notes or custom-field properties.
7. Clipboard writes use `.currentHostOnly` + `org.nspasteboard.ConcealedType` + `org.nspasteboard.TransientType`; clearing checks `changeCount` first.

## Working rules

- Never run the real `bw` binary or touch the user's real Bitwarden data or Keychain items. Keychain code under test uses the service name `com.vaultlight.test` and a protocol so unit tests use an in-memory fake.
- Never edit `*.xcodeproj` / `*.pbxproj` by hand — edit `project.yml` and run `make gen`.
- Never edit signing settings, entitlements' team IDs, or `Configs/Local.xcconfig`.
- Swift 6 language mode with strict concurrency. Prefer `actor`s and `async`/`await` over locks and GCD.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`).
- Write the failing test first for Core behavior; then implement.
- Don't add third-party dependencies without explaining why in the commit message.
- Commit at the end of each green step with a conventional message (`feat(core): …`, `test(index): …`). Never commit with `make check` red.

## When compacting

Always preserve: the current task, the list of files changed in it, failing test names, and any open questions.
