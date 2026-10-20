# Designs

Claude Design artboards for VaultLight (panel, menu-bar menu, Settings, About, error states), one PNG per screen state and appearance, at 2× (2080×1320 px; design size 1040×660 pt, panel 680 pt wide). `04-password-copied-menubar` is a menu-bar strip at 2080×104 px (1040×52 pt).

- **Naming:** `NN-<slug>-<light|dark>.png`. `NN` is the screen number; screens with several states have one slug per state.
- **Behavior notes:** [NOTES.md](NOTES.md) — visual direction, sizes, copy and interaction details per screen.
- **Screenshots:** UI milestones save screenshots of the real app to `docs/screenshots/` under the **same file name** as the design they reproduce, so the ui-reviewer subagent can pair them by name.

## Index

| File (`-light` / `-dark`) | Design ID | Shows | Spec | Milestone |
| --- | --- | --- | --- | --- |
| `01-search-empty` | 1a | Unlocked, empty query, recents | §4.2, §5.1 | M4 |
| `02-search-results` | 1b | Query "git", ranked results, 2nd row selected | §5.1–5.4 | M4 |
| `03-username-copied` | 2a | ⌘U, footer "Username copied", panel stays open | §5.4, §6.1 | M4 |
| `04-password-copied` | 2b | ↵, row check, footer "Clears in 45s" | §5.4, §6.2 | M5 |
| `04-password-copied-menubar` | 2b | Menu-bar icon with clipboard countdown | §6.2 | M5 |
| `05-no-results` | 2c | "No matches" with the query echoed | §7.4 | M4 |
| `06-locked-touchid` | 2d | Locked, stored session, system Touch ID sheet | §3.1, §3.4 | M6 |
| `07-locked-master-password` | 2e state 1 | Master password field | §3.1, §3.5 | M6 |
| `07-locked-wrong-password` | 2e state 2 | Wrong master password | §3.1 | M6 |
| `08-footer-states` | 2f | Footer: synced / offline / sync error | §7.3, §7.4 | M7 |
| `09-bw-missing` | 2g | `bw` not installed, install command | §3.1, §7.4 | M6 |
| `10-onboarding-server` | 3a state 1 | Server picker, Bitwarden US selected | §3.2 | M6 |
| `10-onboarding-server-selfhosted` | 3a state 2 | Self-hosted with URL field | §3.2 | M6 |
| `11-onboarding-signin-email` | 3b state 1 | Email and master password | §3.2 | M6 |
| `11-onboarding-signin-2fa` | 3b state 2 | Two-step code | §3.2 | M6 |
| `11-onboarding-signin-apikey` | 3b state 3 | API key (client_id / client_secret) | §3.2 | M6 |
| `12-onboarding-unlock` | 3c state 1 | Master password after API-key sign-in | §3.2 | M6 |
| `12-onboarding-finishing` | 3c state 2 | Finishing checklist | §3.2 | M6 |
| `13-menubar-menu-unlocked` | 4a state 1 | Menu-bar menu, unlocked | §8 | M6 |
| `13-menubar-menu-locked` | 4a state 2 | Menu-bar menu, locked (Sync/Lock dimmed) | §8 | M6 |
| `13-menubar-menu-shortcut-unavailable` | 4a state 3 | Hotkey registration failed, amber badge | §4.1, §8 | M6 |
| `14-settings-general` | 4b state 1 | Settings: General tab | §8 | M6 |
| `14-settings-security` | 4b state 2 | Settings: Security tab | §3.5, §8 | M6 |
| `14-settings-vault` | 4b state 3 | Settings: Vault tab | §7.1, §8 | M6 |
| `14-settings-shortcut-conflict` | 4b state 4 | General tab, shortcut can't be registered | §4.1 | M6 |
| `15-about` | 4c | About window with "not affiliated" disclaimer | §11.5 | M6 |
| `16-error-bw-too-old` | 4d state 1 | `bw` too old, upgrade command | §7.4 | M6 |
| `16-error-server-unreachable` | 4d state 2 | Self-hosted server can't be reached | §3.2 | M6 |
| `16-error-signin` | 4d state 3 | Wrong email or master password | §3.2 | M6 |
| `16-error-2fa-code` | 4d state 4 | Wrong two-step code | §3.2 | M6 |
| `16-error-footer` | 4d state 5 | Footer: no one-time code, copy failed, CLI timeout, code copied | §5.4, §7.4 | M6 |

## Not designed yet

No artboard exists for these; follow the spec and native macOS conventions, and list them as "no design" in the milestone's screenshot comparison instead of "missing screenshot".

- "Lock and Forget" confirmation dialog (Screen 13) — M6
- Unsafe `bw` binary refused (spec §7.1) — M6
- "Code sent" state after "Send a code by email" (Screen 11) — M6
- App icon (placeholder in `15-about`) — M8
- Busy footer: spinner and "Getting password…", "Loading folders…", "Syncing…", "Updating search…"; Touch ID screen "Opening your vault…" (screenshot `footer-busy`) — M7 follow-up
