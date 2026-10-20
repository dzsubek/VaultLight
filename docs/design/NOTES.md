# VaultLight — Design notes

Screens 1–16 of VaultLight (panel, menu-bar menu, Settings, About and error states), each in light and dark mode. PNG at 2× (2080×1320 px, design size 1040×660 pt).

**File naming:** files were renamed from the Claude Design export (`screen-NN-<id>[-state]-<appearance>.png`) to `NN-<slug>-<light|dark>.png`; the index in `README.md` maps each file back to its design option ID (e.g. `2e`) in *VaultLight Screens.dc.html*.

These notes describe intended behavior.

## Visual direction

- **Source:** Product Specification v2, sections 4–5 (panel placement and dismissal, ranking order, result-row fields, navigation and keyboard actions).
- **Material:** one translucent sheet, 680 pt wide, 18 pt corner radius, hairline edge and a soft long shadow. 60 pt search field with 22 pt type, 50 pt rows, 38 pt footer.
- **Accent:** a quiet teal, used only for the caret, the selected-row fill and the ↵ hint on that row. Organization tags get a faint tint of it. Everything else is neutral.
- **Type and data:** system font (SF Pro on a Mac). Monograms use a muted hue derived from the item name, so an item keeps the same color everywhere.

---

## Screen 1 — Search, unlocked, empty query (`1a`)
`01-search-empty-light.png` · `01-search-empty-dark.png`

- **Open:** ⌘⇧Space shows the panel on the screen with the pointer, centered in the upper third. The previous app stays frontmost, so a copy can be pasted straight away. The search field is focused and the previous query is cleared.
- **Recent:** with no query, the list shows items copied this session, newest first. Usage is kept in memory only, so after a lock or restart it shows Favorites instead. The top row is preselected.
- **Close:** Esc, a click outside the panel, or ⌘⇧Space again. ⌘, closes the panel and opens Settings.
- **Focus order:** focus never leaves the search field. ↑/↓ move the selection and the list scrolls to keep it visible. ↵ and the ⌘ shortcuts act on the selected row. Tab does nothing.
- **VoiceOver:** the field reads “Search vault”. Each row reads name, username, host, folder and “has one-time code”.

## Screen 2 — Search with results, “git”, second row selected (`1b`)
`02-search-results-light.png` · `02-search-results-dark.png`

- **Selection reset:** any change to the result list moves the selection back to the top row. ↑/↓ then move it; in this screen the user has pressed ↓ once.
- **Ranking:** exact name, then name prefix (GitHub … Gitpod), word prefix, host (Forgejo, matched on git.home.arpa), then fuzzy (Digitec). Items copied this session rank higher. Case and diacritics are ignored. The matched text is bold, in the name or the host.
- **Shortcuts:** all act on the selected row. ⌘P also copies the password. ↵, ⌘P, ⌘T and ⌘O close the panel; ⌘U keeps it open. ⌘T is dimmed when the row has no TOTP; pressing it anyway shows “No one-time code for this item” in the footer.
- **Pointer:** a click selects a row. A double-click copies the password, same as ↵.
- **Tags:** folders use a neutral pill. The organization item (GitLab, Northwind Labs) gets a teal-tinted pill with a small square mark.

## Screen 3 — Username copied (`2a`)
`03-username-copied-light.png` · `03-username-copied-dark.png`

- **Stays open:** ⌘U copies the username and keeps the panel open, so the next step is usually ↵ for the password.
- **Confirmation:** the footer status changes to “Username copied” for 2 s, then goes back to the sync status. Shortcuts stay visible.
- **Clipboard:** written current-host-only and marked concealed, but not cleared on a timer (spec 6.1).

## Screen 4 — Password copied, plus menu-bar countdown (`2b`)
`04-password-copied-light.png` · `04-password-copied-dark.png`

- **Brief state:** after ↵ the row's hint turns into a check and the footer shows “Password copied” with “Clears in 45s”. The panel fades out after about 400 ms and focus returns to the previous app.
- **Countdown:** the menu-bar icon shows the seconds left until the clipboard clears, counting from 45 s down to 1 s; then the label disappears and the icon returns to its resting state. The timeout follows Settings (45 s by default). In dark mode the capsule uses the system menu-bar highlight, not the accent.
- **Clear rules:** the clipboard is cleared only if it still holds this value. If the user copies something else, the countdown stops and the label goes away. Copying another secret restarts it.
- **⌘T:** copying a code uses the same state, with “Code copied”.

**Menu-bar indicator (2×, 1040×52 pt):** `04-password-copied-menubar-light.png` · `04-password-copied-menubar-dark.png`

## Screen 5 — No results (`2c`)
`05-no-results-light.png` · `05-no-results-dark.png`

- **Echo:** the query is repeated in the message so a typo is easy to spot. The panel keeps the height of an empty list instead of shrinking down to the field.
- **Shortcuts:** all action hints are dimmed; ↵ does nothing. Deleting characters brings results back with the top row selected.
- **Scope:** v1 searches logins only, so the hint says what is searched.

## Screen 6 — Locked, stored session available, with the system Touch ID sheet (`2d`)
`06-locked-touchid-light.png` · `06-locked-touchid-dark.png`

- **Sequence:** the panel opens at once in the locked state. The Keychain read starts immediately and macOS shows its sheet; VaultLight only sets the reason text.
- **Fallback:** “Use Password…” asks for the Mac login password (user-presence check), or the user can confirm on a paired Apple Watch.
- **After:** on success the panel switches to Search in place, with the field focused. On Cancel it stays locked, and ↵ shows the sheet again.
- **Session rejected:** if the stored session no longer works, the Keychain item is deleted and the panel moves to the master password state (Screen 7).

## Screen 7 — Locked, master password required (`2e`)
- State 1, entering: `07-locked-master-password-light.png` · `07-locked-master-password-dark.png`
- State 2, wrong password: `07-locked-wrong-password-light.png` · `07-locked-wrong-password-dark.png`

- **One field:** the search field becomes a secure field in place, so the panel doesn't jump. ↵ or Unlock runs the unlock; the button shows a spinner while bw works.
- **Reason:** the footer says why the password is needed: after a restart, the stored session expired, or the session was rejected.
- **Wrong password:** the field clears and keeps focus, the divider turns red and the panel gives one short horizontal shake. No attempt counter.
- **Memory:** the password is passed through an environment variable and dropped right after unlock.

## Screen 8 — Footer states (`2f`)
`08-footer-states-light.png` · `08-footer-states-dark.png`

- **Synced:** time since the last successful sync, with a gray dot. Updates while the panel is open.
- **Offline:** amber dot. Search and copy keep working against the cached vault; sync retries on the normal interval.
- **Sync error:** red dot plus “Try again”, which can be clicked. Covers timeouts and CLI errors that aren't network-related.
- **Priority:** copy confirmations (Screens 3 and 4) temporarily replace any of these.

## Screen 9 — Setup problem, bw not installed (`2g`)
`09-bw-missing-light.png` · `09-bw-missing-dark.png`

- **Copy:** the Copy button or ⌘C puts the command on the clipboard; the button label changes to “Copied” for 2 s.
- **Recheck:** VaultLight checks the pinned paths again each time the panel opens. No polling.
- **Too old:** the same layout covers an outdated bw, with the command `brew upgrade bitwarden-cli`.
- **Settings:** ⌘, opens Settings at the bw path field for a custom location.

---

## Onboarding (spec 3.2)

Onboarding uses the same panel and hotkey; there is no separate window. The header shows “Set up VaultLight” and a three-step indicator: **Server → Sign in → Unlock**.

## Screen 10 — Server (`3a`)
- State 1, default (Bitwarden US): `10-onboarding-server-light.png` · `10-onboarding-server-dark.png`
- State 2, self-hosted with URL field: `10-onboarding-server-selfhosted-light.png` · `10-onboarding-server-selfhosted-dark.png`

Options: **Bitwarden US** (vault.bitwarden.com, default), **Bitwarden EU** (vault.bitwarden.eu), **Self-hosted** (Vaultwarden or a Bitwarden server you run).

- **When:** shown whenever `bw status` reports unauthenticated.
- **Keyboard:** ↑/↓ move between servers, ↵ continues. Choosing Self-hosted reveals the URL field and focuses it.
- **Continue:** runs `bw config server <url>`. If a self-hosted URL doesn’t respond, “Can’t reach this server” appears under the field and the panel stays on this step.
- **Later:** the server can be changed in Settings; doing so signs you out.

## Screen 11 — Sign in (`3b`)
- State 1, email and master password: `11-onboarding-signin-email-light.png` · `11-onboarding-signin-email-dark.png`
- State 2, two-step code: `11-onboarding-signin-2fa-light.png` · `11-onboarding-signin-2fa-dark.png`
- State 3, API key (client_id / client_secret): `11-onboarding-signin-apikey-light.png` · `11-onboarding-signin-apikey-dark.png`

- **Method:** ⌘1 / ⌘2 switch between “Email and password” and “API key”. Tab moves between fields here, unlike in search.
- **Two-step:** shown only when bw asks for a code. Digits move to the next box automatically, pasting fills all six, and the sixth digit submits. “Send a code by email” runs the login again using the email method.
- **Errors:** for wrong credentials or a wrong code, the message appears in red under the fields; the secret field clears and keeps focus, with the same shake as Screen 7.
- **Next:** email sign-in reuses the master password to unlock and goes straight to the finishing state (Screen 12, state 2). API-key sign-in goes to the master password step (Screen 12, state 1).
- **Secrets:** passed to bw as environment variables and dropped after the call. client_id and client_secret are not stored.

## Screen 12 — Unlock and finish (`3c`)
- State 1, master password after an API-key sign-in: `12-onboarding-unlock-light.png` · `12-onboarding-unlock-dark.png`
- State 2, finishing: `12-onboarding-finishing-light.png` · `12-onboarding-finishing-dark.png`

Finishing checklist: Signed in (Bitwarden US) · Vault unlocked · Session saved to the Keychain (Touch ID next time) · Building the search index (214 logins).

- **Unlock:** runs `bw unlock --passwordenv --raw`. The master password is dropped as soon as the session key comes back.
- **Store:** writing the Keychain item doesn’t prompt; Touch ID is first asked for on the next locked open (Screen 6).
- **Finishing:** rows tick off in order. When the index is built, the panel turns into Search (Screen 1) in place, showing Favorites because nothing has been copied yet.
- **Esc:** closing during setup keeps progress; the next open resumes at the same step, so server and sign-in are not repeated.

## Menu bar and windows

## Screen 13 — Menu-bar menu (`4a`)
- State 1, unlocked: `13-menubar-menu-unlocked-light.png` · `13-menubar-menu-unlocked-dark.png`
- State 2, locked: `13-menubar-menu-locked-light.png` · `13-menubar-menu-locked-dark.png`
- State 3, shortcut unavailable: `13-menubar-menu-shortcut-unavailable-light.png` · `13-menubar-menu-shortcut-unavailable-dark.png`

Menu: status line · Open VaultLight (⌘⇧Space) · Sync Now · Lock Now · Lock and Forget… · Settings… (⌘,) · About VaultLight · Quit VaultLight (⌘Q).

- **Open:** a click on the menu-bar icon opens the menu. The first line shows the vault state and can't be clicked.
- **Commands:** the list from spec 8, plus About VaultLight as the way into the About window. Sync Now and Lock Now are dimmed while the vault is locked.
- **Lock and Forget:** runs `bw lock` and deletes the Keychain item. Whether it asks for confirmation first is still open; the ellipsis assumes it does.
- **Shortcut unavailable:** if hotkey registration fails (spec 4.1), the icon gets an amber badge and the menu starts with “Choose Another Shortcut…”, which opens Settings in the conflict state (Screen 14, state 4).

## Screen 14 — Settings (`4b`)
- State 1, General: `14-settings-general-light.png` · `14-settings-general-dark.png`
- State 2, Security: `14-settings-security-light.png` · `14-settings-security-dark.png`
- State 3, Vault: `14-settings-vault-light.png` · `14-settings-vault-dark.png`
- State 4, General with shortcut conflict: `14-settings-shortcut-conflict-light.png` · `14-settings-shortcut-conflict-dark.png`

- **Window:** a standard Settings window. Opening it brings VaultLight to the front, so the menu bar shows its name. ⌘, from the panel or the menu opens it on the last tab used.
- **Tabs:** General has the shortcut, clipboard and launch-at-login settings. Security has session ages and auto-lock. Vault has the account, server, sync and bw path. All ten settings from spec 8 are included, with the spec's defaults.
- **Shortcut recorder:** click to record, Esc cancels, × resets to ⌘⇧Space. If the new shortcut can't be registered, the recorder stays in recording mode and shows the reason in red.
- **Changes:** apply immediately; there is no Save button. Changing Server or choosing Sign Out… asks for confirmation, then signs out and returns the panel to onboarding.
- **Custom bw path:** choosing Custom… under Location opens a file picker. The path is checked against spec 7.1 before it is used.

## Screen 15 — About (`4c`)
`15-about-light.png` · `15-about-dark.png`

- **Disclaimer:** required by spec 11.5. The same sentence goes in the README and the cask description.
- **Details:** shows the bw version and the server in use, which helps with bug reports. Source code and Licenses open in the browser.
- **Icon:** a placeholder until the icon concepts are done. It must not use Bitwarden's name or logo.

## Screen 16 — Errors (`4d`)
- State 1, bw too old: `16-error-bw-too-old-light.png` · `16-error-bw-too-old-dark.png`
- State 2, can't reach self-hosted server: `16-error-server-unreachable-light.png` · `16-error-server-unreachable-dark.png`
- State 3, sign-in error: `16-error-signin-light.png` · `16-error-signin-dark.png`
- State 4, two-step code error: `16-error-2fa-code-light.png` · `16-error-2fa-code-dark.png`
- State 5, footer errors (no one-time code, copy failed, CLI timeout, code copied): `16-error-footer-light.png` · `16-error-footer-dark.png`

- **bw too old:** same layout as Screen 9, with `brew upgrade bitwarden-cli`. The minimum version shown (2025.1.0) is a placeholder; spec 12 lists it as an open question.
- **Server unreachable:** the URL field turns red and keeps focus. Editing the URL clears the message; Continue tries again.
- **Sign-in error:** the master password clears and keeps focus; the email stays. The message doesn't say which of the two was wrong. The panel gives one short shake, as in Screen 7.
- **Two-step error:** all six boxes clear and focus moves to the first. The email-code link stays available.
- **Footer errors:** from spec 5.4 and 7.4. The panel stays open. Try again (or ↵) repeats the last action. A failed copy never changes the clipboard.

## Still open

- Lock and Forget confirmation (Screen 13)
- What the user sees when the bw binary is unsafe (spec 7.1)
- Email-code “sent” state for two-step login (Screen 11)
- App icon concepts
