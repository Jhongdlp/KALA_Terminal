# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

"Kammel" (package name `terminal_agent`) is a Flutter app that combines an SSH connection manager, a multi-session terminal emulator (SSH), a remote file explorer (SFTP), and a code editor into a single mobile-first IDE-like tool. Configured platforms are **Android** and **Linux** only.

## Commands

Two dependencies are vendored under `third_party/` and wired through `dependency_overrides` in `pubspec.yaml`: the patched `xterm`, and `dartssh2` — whose patch fixes an upstream bug where a channel's receive window is never replenished once exhausted, deadlocking any transfer over ~6 MB through a tunnel. Re-apply both patches if either package is upgraded.

The `xterm` patches worth knowing about, beyond Gboard inline image paste: `TerminalMouseButton` reports wheel buttons as `64 + 0…3`, not upstream's `64 + 4…7` (which sets bit 2 — the Shift modifier — so every wheel event reached the remote as Shift+Wheel, and tmux leaves `S-WheelUpPane` unbound, i.e. scrolling a tmux session did nothing); `TerminalScrollGestureHandler` was rewritten around the gesture arena (see Terminal touch gestures); and touch taps are no longer forwarded to the application as mouse clicks, only real mouse taps are. `_onKeyboardShow` no longer jumps the viewport to the bottom unconditionally (see Selecting and copying text).

The Flutter SDK is vendored inside this repo at `sdk/flutter` (a full flutter/flutter checkout used as the project's Dart/Flutter SDK — it is not part of the app's own source and generally doesn't need to be touched). If `flutter` is not on `PATH`, use `sdk/flutter/bin/flutter`.

- Install dependencies: `flutter pub get`
- Run the app (Linux desktop): `flutter run -d linux`
- Run the app (Android): `flutter run -d <android-device-id>`
- Static analysis / lints: `flutter analyze`
- Run all tests: `flutter test`
- Run a single test file: `flutter test test/l10n_test.dart`
- Build Linux release: `flutter build linux`
- Build Android APK: `flutter build apk`

Note: one pre-existing failure in `test/git_service_test.dart` ("push without a remote fails with git's own message") is a wording assertion against git's output that newer git versions no longer match — it is not a regression in the app.

## Architecture

### State management

All app state is centralized in a single `ChangeNotifier`, `AppState` (`lib/providers/app_state.dart`), provided at the root via `provider` in `lib/main.dart`. Views read it with `Provider.of<AppState>(context)`. There is no other state management layer — new features should extend `AppState` rather than introducing local widget state for anything that needs to survive tab switches.

### Multi-session terminal model

- `AppState` holds a list of `TerminalSession` objects (`_sessions`), each with its own `xterm.Terminal`, `ConnectionStatus` (`disconnected | connecting | remote`), and a `dartssh2.SSHClient`/`SSHSession` (remote shell).
- Only one session is "active" at a time (`_activeSessionIndex`). Most getters (`terminal`, `connectionStatus`, `currentPath`, `files`, etc.) are convenience delegates to `activeSession`.
- Connecting to a saved profile (`connectToSSH`) creates a *new* session and connects it via `_connectSessionToSSH`, then switches the active tab to the terminal.
- `disconnect` / session loss tears down the session's SSH connection and marks it as disconnected.

### Terminal touch gestures

Four touch gestures share the same pixels, and they are resolved by the **gesture arena**, not by ordering `if`s. The failure mode is silent: one recogniser starts winning and another simply stops working, so `test/terminal_gestures_test.dart` pins down who wins for each gesture shape. Run it after touching anything below.

| Gesture | Winner | Effect |
| --- | --- | --- |
| tap | xterm `TapGestureRecognizer` | focus / soft keyboard, or dismiss a selection |
| swipe | the buffer's scroll recogniser | normal buffer: local scrollback. Alt buffer: wheel events to the app (+ fling) |
| still hold ≥`padHoldMs` (200 default), then drag | `JoystickGestureRecognizer` | the touch pad: the direction's slot, repeated with a speed ramp |
| …then stop inside the deadzone for `padRadialMs` | the same pointer, already won | the pad's radial: eight slots, picked on release |
| still hold ≥500ms | xterm `LongPressGestureRecognizer` | select word, then `TerminalSelectionArea`'s handles |
| two fingers | `_PinchFontZoom` (a `Listener`, outside the arena) | font size |

`JoystickGestureRecognizer` (`lib/widgets/joystick_recognizer.dart`) is the one that can starve the others, so it never claims the arena up front: it rejects itself on any movement past `stillSlop` before the hold qualifies (that's a swipe), on a second finger (that's a pinch), on pointer-up without a drag (that's a tap), and at `armWindowEnd` — deliberately just under `kLongPressTimeout`, so a resting finger that drifts can no longer steal a selection. `stillSlop + dragThreshold` is kept **under `kTouchSlop`**: the scrollable that hosts the terminal is deeper in the tree, so its drag recogniser sees every move event first and would win any event that crosses both thresholds at once.

### Selecting and copying text

Copying is the one thing on that table with **no second entrance**, so it gets defended twice.

`TerminalSelectionArea` (`lib/widgets/terminal_selection.dart`) is the Android-style layer over xterm's bare word selection: two draggable handles plus the COPIAR / PEGAR / TODO bar. Its geometry is written for a terminal that is *short* — with the soft keyboard, the toolbar and the quick keys on screen a phone has a handful of lines left — because the `Stack` it draws in **clips**, and a handle painted past an edge is visible and untappable:

- A handle whose 50px box would hang below the last row **flips above its line** (square corner at the bottom, the way Android's own handles do); the box is clamped into the viewport on both axes, so a selection starting at column 0 still has a target to grab.
- The action bar tries above the first line, then below the end handle, then centred — and is finally clamped, because in three lines of viewport none of the three fit and an unpressable COPIAR is the worst of the options.

The other half is not losing the selection in the first place. `_onKeyboardShow` (vendored `terminal_view.dart`) used to jump the viewport to the bottom of the buffer unconditionally; since the tap that begins a long press is also the tap that raises the keyboard, selecting anything in the scrollback yanked the view out from under it. It now chases the prompt **only if the viewport was already at the bottom** (asked *before* the frame that applies the new insets, while `maxScrollExtent` still describes the old layout) and never while a selection is on screen. Typing still snaps back — `_onInsert` scrolls to the bottom on the first keystroke. `test/terminal_selection_test.dart` pins both halves.

`system:select` is the entrance that no gesture can take away: it selects the word under the finger that armed the pad (so it belongs on a radial slot — hold, lean, release, and the handles are up), or, fired from the ACCIONES layer where there is nothing to point at, the last non-empty line. Migration `settings_shortcuts_migrated_v8` adds it to setups that already exist, since the problem it solves is not one only fresh installs have.

### The touch pad

The pad is the hold-and-drag gesture with a UI and a keymap. It exists because the two things a phone terminal needs most — walking the shell history and reaching Esc/Tab/^C — are otherwise a trip to the soft keyboard, and because its predecessor was *invisible*: nothing happened until the finger had already crossed a 60px deadzone, which is indistinguishable from the scroll refusing to work.

Three modes, and the escalation between them is the whole design (`TouchPadMode`, `lib/widgets/terminal_touch_pad.dart`):

1. **Armed** — `onHoldQualified` fires *before* the arena is won, so a ring is drawn under the finger the moment a nudge would arm the pad. This is the affordance the gesture never had; it is also why the callback is paired with `onHoldCancelled`, which takes the ring back when the sequence turns out to be a swipe, a tap or a long press.
2. **Repeat** — past the deadzone, the direction's slot is sent on a ramp (300ms → 30ms). A slot bound to a `system:` action fires **once** instead: repeating it would reopen a sheet three times a second.
3. **Radial** — the armed pad, held inside the deadzone for `terminalPadRadialMs`, blooms into the eight slots; the finger leans towards one and **release** fires it, the centre cancels. Once open it owns the gesture — a pull no longer starts a repeat, or waiting for the menu would be punished.

The radial deliberately escalates from the *armed pad* rather than from a longer hold: at 500ms xterm's long press wins the arena and starts a text selection, and anything claiming the pointer past that point would have to take word selection away. The nudge that arms the pad is already ours, so the dwell that follows competes with nothing.

`PadDirection` and the slot map live in `lib/models/touch_pad.dart` and are covered by `test/touch_pad_test.dart`. Two geometries, on purpose: the drag resolves on the **dominant axis** (a sloppy upward swipe is still "up"), the radial on **eight equal 45° sectors**. Slots hold `TerminalShortcut`s — the same vocabulary as the quick keyboard, so anything that can sit on a key can sit on the pad — persisted as one blob under `settings_pad_slots`, with raw bytes stored in their escaped form (`padEscape`) so preferences stay readable text. Everything else about the pad is a setting under `settings_pad_*` (Personalizar → Pad táctil): on/off, hold time, deadzone, radial on/off and its delay. They are settings because the gesture shares its pixels with the scroll and the long press, and where one hand draws the line between them is not where another does.

Alt-buffer scrolling (tmux, and any TUI agent running under it) lives in the vendored `TerminalScrollGestureHandler`. Upstream wrapped the terminal in a second `Scrollable` that swallowed the drag before xterm's own recognisers saw it; it now runs a plain `VerticalDragGestureRecognizer` that competes fairly, so a long press still selects instead of scrolling. Its fling is gated on `terminal.mouseMode.reportScroll` — without mouse reporting `_sendScrollEvent` falls back to arrow keys, and a fling would dump a hundred of them into whatever holds the prompt.

**A swipe inside a full-screen app is a guess**, and the whole of `_sendScrollEvent` is about narrowing it. If the application reports the wheel, it gets a wheel event and there is nothing to decide. If it doesn't, the fallback types `↑`/`↓` — which is a scroll in `less` and *history navigation* in a TUI agent's input box, where it silently replaces what the user was writing. Three things gate it:

- **`Terminal.mouseMode` is derived from a set, not from the last escape sequence.** DEC modes 9 / 1000 / 1002 / 1003 are independent switches and programs disable defensively (`CSI ? 1003 l` after asking for 1000). Upstream mapped every "off" onto `MouseMode.none`, so one such line silenced wheel reporting for good and every later swipe went out as arrow keys. `setMouseMode` now takes `enabled:` and picks the most specific mode still on. This is the bug behind "scrolling misbehaves in *other* agents" — the ones that touch mouse modes at all.
- **DEC mode 1007** (`altBufferMouseScrollMode`) is honoured and now defaults to **on**, matching modern terminals: an application that says it does its own scrolling is obeyed.
- **`AppState.terminalAltScrollKeys`** (Ajustes → Terminal, default on) is the user's own switch, for the agents that declare nothing at all.

`test/terminal_mouse_modes_test.dart` covers the mode algebra and what each combination actually puts on the wire.

### Soft keyboard, dictation and the IME

The terminal has no text field of its own, so xterm attaches the IME to `CustomTextEdit` (`third_party/xterm/lib/src/ui/custom_text_edit.dart`): a hidden buffer holding the four-space sentinel `'  |  '`, whose middle is whatever the keyboard has typed. On each `updateEditingValue` the typed region is diffed against `_pendingSent` — the mirror of what has already been forwarded — and the difference goes to the shell as backspaces plus a tail.

The diff is what makes keyboard-side edits work at all: swipe typing replacing a word, autocorrect, and Gboard's fix-the-last-word all arrive as a *rewrite* of text already sent, never as an append.

**Do not wipe the buffer after forwarding.** Upstream called `setEditingState` after every committed character; on Android that restarts the input connection, which ends any running voice-typing session (dictation kept cutting out mid-sentence) and leaves the keyboard with no context to predict from. The mirror is cleared on Enter (`performAction`), on an injected key (`reset()`, from `TerminalTab._sendTerminalKey`), when the connection opens or closes, and past `_maxPendingLength`. `test/terminal_ime_test.dart` pins this down, including that ordinary typing still yields exactly the right bytes.

Even so, the raw path can only ever offer the keyboard one command line of context. For dictation proper there is `TerminalComposeBar` (`lib/views/terminal_compose_bar.dart`), toggled from the terminal toolbar: a real `TextField` where the words stay put until sent, so the suggestion strip, continuous dictation and autocorrect behave normally. It sends through `AppState.insertPromptText` (a paste, so a TUI agent sees one insert rather than a burst of keystrokes) plus an optional `\r`.

### Connection profiles

`ConnectionProfile` (`lib/models/connection_profile.dart`) is a plain JSON-serializable model (host/port/username/etc.). Profile *metadata* is persisted as a JSON string list under the `ssh_profiles` key via `shared_preferences` (`_loadProfiles`/`saveProfile`/`deleteProfile` in `AppState`), written through `toJsonPublic()`.

**Secrets do not go there.** Passwords and private keys live in `SecureStore` (`lib/services/secure_store.dart`) — Keystore-backed `EncryptedSharedPreferences` on Android, libsecret on Linux — keyed by profile id. `_loadProfiles` migrates any legacy profile that still carries its secret inline and rewrites prefs without it. The profile form says so under the password field; users deciding whether to type a production password into a phone app deserve to know where it lands.

Three things *about* profiles live in their own small prefs entries rather than on the profile, because they change from the list far more often than the profile does and rewriting `ssh_profiles` means a secure-storage round trip per profile: `connection_groups` (the `ConnectionGroup` folders), `profile_favorites`, and `profile_last_used` (stamped by `_noteProfileConnected` on every successful connect, which is what feeds "Recientes").

`SshConfigImport` (`lib/services/ssh_config_import.dart`) reads `Host` blocks out of an OpenSSH client config so a laptop's thirty hosts don't have to be retyped into a phone form. It is deliberately partial — `Host`/`HostName`/`User`/`Port`/`IdentityFile`/`ProxyJump` only — and **drops** any block carrying `ProxyCommand`, `Match` or `Include` rather than importing it half-configured: a profile that silently connects somewhere else is worse than one that was never created. Wildcard blocks (`Host *`) are defaults, not machines, and are skipped.

`ProxyJump` is honoured only in the shape the app can reproduce faithfully: **one alias with a block in the same file**. A jump spec naming a host directly (`user@bastion:22`) or chaining hops with commas drops the entry, because the rest of that machine's route would be a guess. `_resolveJumps` then propagates drops to a fixed point — a host whose bastion was dropped is unreachable too — and `toProfiles` pulls a needed bastion in even when the user didn't tick it, since importing a machine without its jump host produces a profile that can never connect.

`ConnectionProfile.colorHex` + `isProduction` are the profile's **signal color**, resolved through `profileTint` (`lib/widgets/profile_tint.dart`) and painted by every surface that says which machine a session belongs to: the connections row and the sessions sheet (a 3px stripe on the leading edge), the terminal (a `ProfileTintBand` above the toolbar — *outside* it, so fullscreen keeps it), the toolbar's status glyph (its shape already carries connection status, so its color is free to carry identity), the desktop title bar's bottom border and dot, and the command palette's server/session rows. A production profile with no color of its own falls back to `AppColors.danger`; marking a machine as production and getting no visible difference would make the switch a lie. This is the one hue allowed into a monochrome palette, and it is drawn as a stripe or a dot, **never a fill** — it has to be visible at a glance without competing with the content. Rows put the stripe in a `Stack`, not in the `Row`, so a tinted row keeps exactly the alignment of an untinted one. `test/profile_color_test.dart` covers the fallbacks and the legacy (untinted) profile.

`testProfile` opens a throwaway client and closes it — the "Probar conexión" button in the form. It deliberately creates no session and stamps nothing: a test is not a connection.

### Jump hosts (ProxyJump)

`ConnectionProfile.jumpProfileId` points at **another profile**, not at a copied host/user/key: the bastion is a machine the user already has a profile for, with its own credentials and its own pinned host key, and inlining that into every profile behind it means editing ten profiles the day it moves.

`JumpChain` (`lib/models/jump_chain.dart`) is the whole policy, and it is **pure** — no I/O, no `AppState` — which is what lets the form refuse a bad chain before saving it and the connection path refuse one before opening a socket, with the same code. `resolve` returns the hops in **dial order** (first entry = dialled from the device) and throws `JumpChainError` for the four ways a chain breaks: a hop that no longer exists, a cycle (the visited set is seeded with the target, so a self-jump is a cycle and not a one-hop chain), more than `maxHops` (5), or a hop pointing at the local terminal profile. `candidatesFor` is the other half: the picker only ever offers legal hops, so an unusable chain cannot be saved in the first place.

`AppState.openClient` dials the chain and returns the target client, so **every** consumer — sessions, `testProfile`, the server console, the git panel — gets jump support without knowing about it. Three things hold that together:

- Each hop is a full `_authenticateClient` over the previous hop's `forwardLocal` channel (dartssh2's `SSHForwardChannel` *is* an `SSHSocket`), so every machine in the chain is authenticated and **host-key-pinned under its own host:port**.
- `_bindHopsTo` ties the hops' lifetime to the returned client: closing it, the server closing it, or a hop dying under it tears the whole chain down in reverse order. Callers keep the one-client contract they always had.
- A hop failure is wrapped in `JumpHopError`, which `describeError` and `ConnectionError._kindOf` unwrap **by type, before any text matching** — a hop's rejected password must still route to "Editar perfil" while the message names the machine that actually refused. A `JumpChainError` gets its own `ConnectionErrorKind.jump`.

Deleting a bastion is not a local edit: `deleteProfile` unlinks every profile that jumped through it and returns their ids so the undo (`relinkJumpHost`) can put the chain back, and the confirmation names them before they're gone. `testProfile`'s timeout grows with the chain (20s + 15s per hop) so a good two-hop chain over a slow link isn't failed and blamed on the target.

### Connection failures

Every failed connect is classified once into `ConnectionError` (`lib/models/connection_error.dart`) and parked on `TerminalSession.lastError`. The *wording* comes from `describeError` (`lib/services/friendly_error.dart`); what `ConnectionError` adds is **routing** — `suggestsEditingProfile` / `suggestsKnownHosts` decide whether the failure sheet's primary button opens the profile, opens Ajustes → Servidores conocidos, or just retries. "Reintentar" is the right button for a timeout and the wrong one for a rejected password.

The terminal still gets a line (translated, followed by the raw exception so the scrollback keeps it for a bug report), but the actionable surface is the reconnect banner: it names the cause and links to the sheet.

### Port forwarding (tunnels)

Tunnels are configured per profile (`ConnectionProfile.tunnels`, a list of `SshTunnel` — see `lib/models/ssh_tunnel.dart`) and run by `TunnelManager` (`lib/services/tunnel_manager.dart`), a separate `ChangeNotifier` owned by `AppState` and provided alongside it in `main.dart` so live byte counters don't rebuild the whole app.

- All three OpenSSH kinds are supported: `-L` (local), `-D` (SOCKS5, implemented by dartssh2's `forwardDynamic`) and `-R` (remote).
- Tunnels are tied to their session: started in `_connectSessionToSSH` via `syncOnConnect`, stopped on connection loss (`onSessionLost`, which keeps `TunnelRuntime.desired` so a reconnect restores exactly what was up) and released in `_cleanupSession` (`removeSession`).
- `saveProfile` calls `syncConfig` on live sessions, so adding/editing a tunnel applies without reconnecting.
- Legacy `PortForward`/`forwards` JSON is migrated into `tunnels` on load, and `toMap` still mirrors local tunnels into `forwards` so a downgrade doesn't lose them.
- Listening sockets bind to loopback unless `SshTunnel.exposeToLan` is set; ports below 1024 are rejected up front (Android can't bind them).
- `SshTunnel.idleTimeoutMinutes` closes a tunnel after N minutes with **zero open connections** — it narrows the window in which another app on the phone can reach the local port, and never cuts a session in use (the countdown is armed/cancelled from `_onConnectionCountChanged`). Not offered for SOCKS, whose connections dartssh2 doesn't report.
- UI: `lib/views/tunnels_tab.dart` (tab index 9, reachable from the drawer), a badge + sheet in the terminal toolbar, and the shared editor `lib/views/tunnel_editor_sheet.dart` used by both the profile form and the console.

### Host key verification

`openClient` passes `onVerifyHostkeyBlob` (a handler added by the vendored dartssh2 patch — upstream only exposes an MD5 digest, too weak to pin on). `AppState._verifyHostKey` implements trust-on-first-use against `KnownHosts` (`lib/services/known_hosts.dart`, persisted under the `known_hosts` prefs key): a matching key connects silently, an unknown one is confirmed once and pinned, and a *changed* one blocks by default. The dialog lives in `lib/views/host_key_dialog.dart` and is reached from `AppState` through the `hostKeyConfirm` hook wired in `main.dart` via `navigatorKey` — when no UI is available the key is refused, never silently trusted. Pinned entries can be audited/forgotten from Ajustes → "Servidores conocidos". Fingerprints are OpenSSH-format `SHA256:<base64>`, verified to match `ssh-keygen -lf`.

### File explorer & editor — SFTP integration

All file listing, navigation, and editing are performed remotely over SFTP:

- File listing (`_loadFilesForSession`) uses `session.sshClient!.sftp().listdir(...)`, normalizing entries into `FileSystemEntityInfo`.
- Directory navigation (`navigateUp`, `changeDirectory`) handles POSIX-style path manipulation on the SFTP client.
- The code editor (`openFile`/`saveCurrentFile`) reads/writes via SFTP (`sftp().open(...)`). The editing SSH client (`_editingSshClient`) is captured at open time so editing keeps working even if the user switches the active session/tab afterward.

### Explorer navigation

The path is a **breadcrumb of tappable segments** (`_buildBreadcrumb`), not the `Text` it used to be: climbing out of `/var/www/html/app/config` cost four presses of "subir un nivel" when the path was pure information. The row still scrolls reversed, so the deepest end stays visible.

Sorting (`AppState.fileSortKey` / `fileSortAscending`, persisted) and pinned folders (`explorer_bookmarks`) share one sheet behind the path bar's sort icon — both answer "show me this directory differently", and neither earns a permanent control in a 42px bar that already holds seven. Directories are pinned above files in every sort mode, and `sortFiles` falls back to the name on ties so the order can't shuffle between rebuilds. Pinned folders are also indexed by the command palette.

Deletion over SFTP has no trash and no undo, so its confirmation **names what will go** (up to eight, then "… y N más"). A count alone asks the user to trust something they can no longer see, because the selection bar covers the list.

### Source control (git panel)

Git is driven by `GitService` (`lib/services/git_service.dart`), built on demand by `AppState.createGitService()` for the *active* session: `GitService.remote` runs commands on an SSH exec channel, `GitService.local` through `Process.run`. A fresh instance per call is deliberate, so a panel that outlives a reconnect picks up the new client instead of a dead channel.

- Every command is built from an argument **list** and each argument is single-quoted for the remote shell (`_q`), so commit messages and paths can contain quotes, `$` or newlines. Nothing is interpolated into a command string.
- Commands run with `GIT_TERMINAL_PROMPT=0`, empty-answer askpass helpers and `ssh -o BatchMode=yes`: a push needing a passphrase fails with a message instead of hanging the channel until the timeout (25 s local ops, 90 s network ops).
- `git status --porcelain=v1 -z -b` is parsed by `GitRepoInfo.parse` (`lib/models/git_status.dart`), which keeps the index and worktree columns separate — that split is what the staged/unstaged groups are. `-z` is what makes paths with spaces and renames safe. Unit tests: `test/git_status_test.dart`; `test/git_service_test.dart` drives the local runner against a throwaway repo.
- UI: `lib/views/git_panel_sheet.dart` (the panel, opened from the terminal toolbar), `git_diff_sheet.dart` (colored unified diff) and `git_project_tree.dart` (the lazy file tree). Tapping a changed file shows its diff; long-pressing sends it to the explorer/editor.

### UI structure

`lib/views/home_view.dart` is the app shell. It holds eleven screens, indexed by `AppState.activeTabIndex`: 0 connections, 1 terminal, 2 explorer, 3 editor, 4 server, 5 settings, 6 personalization, 7 about, 8 notifications, 9 tunnels, 10 agents. `AppScreen` (`lib/views/shell/app_screen.dart`) is their stable identity; it also carries `git`, which has no tab index.

The key screens:

1. `connections_tab.dart` — manage/edit SSH `ConnectionProfile`s, and connect to a profile. It stays a flat list until there are `_organiseThreshold` (5) profiles, and only then grows a search field, a "Recientes" panel and a "Favoritos" one; groups appear as soon as the user makes one. Collapsed groups are *not* persisted — a folder that stays shut across restarts is how a profile gets lost.
2. `terminal_tab.dart` — the active session's `xterm.TerminalView`, a session-switcher bar (tap to switch, double-tap to rename, `x` to close), and the quick keyboard (see below).
3. `explorer_tab.dart` — file browser for the active session's remote `currentPath`.
4. `editor_tab.dart` — wraps `re_editor`'s `CodeEditor`/`CodeLineEditingController`, syncing edits back to `AppState.updateFileContent`.

Switching happens programmatically via `AppState.setActiveTabIndex` (e.g. opening a file jumps to tab 3). Inside `AppState` those jumps go through the private `_setTab`, never a raw `_activeTabIndex =`, so pane focus stays in sync.

### Quick keyboard (layers)

`lib/views/terminal_quick_keys.dart` draws the extra-keys bar over the terminal. Its one hard rule: **nothing scrolls horizontally**. The bar it replaced hid its overflow in two side-scrolling rows — no affordance said there was more, and the drag competed with the terminal's own gestures — so any horizontal `Scrollable` reappearing in here is a regression, and `test/quick_keys_test.dart` asserts it stays out.

Three tiers, top to bottom:

1. **The fixed row** — `ESC TAB CTRL ^C` plus the arrows, or `ESC TAB CTRL SHIFT ^C ^D` when the arrows live elsewhere (`kFixedKeysInline` / `kFixedKeys` in `lib/models/terminal_key_layer.dart`). It never changes, so muscle memory survives a layer switch, and `^C` is never one tap away behind one.
2. **The layer grid** — one page of a `PageView`, swipeable, equal-width cells.
3. **The tab strip** — always visible, plus a gear that always opens `ShortcutManagerSheet`. Tabs rather than a dot indicator or a modal "next layer" key: only tabs show *where you are and what else exists*.

**Columns are derived from the row count, not from the width** (`_columns`). With `AppState.shortcutRows` fixed by the user (1–3, **default 1**), `ceil(keys / rows)` is the narrowest grid that still shows every key of the fullest layer — which is what makes "no horizontal scroll" a guarantee rather than a hope. One row is the default because the layers hold the key count now: at 28px keys the bar is 96px against the old scrolling bar's 73px, and the 23px difference is exactly the tab strip. A second row only buys bigger keys (25px → 54px cells on a 360px screen) for 33px of scrollback, so it is a setting, not the default; `test/quick_keys_test.dart` pins the default height. The built-in layers always get the columns they need; `QuickKeyLayer.mine` is the one the user can grow without limit, so it may widen the grid up to `_kMineColumnCap` (8) and then scrolls *vertically* instead of shrinking every other layer with it. The grid box height is the same for every layer, so switching one never resizes the PTY.

Layers are `QuickKeyLayer` — `control`, `nav`, `fn` are code-defined constants; `actions` is the enabled `system:` shortcuts and `mine` is everything else the user owns (`AppState.actionShortcuts` / `myShortcuts`). Which layers are visible and in what order is persisted **by id** under `settings_shortcut_layers`, so reordering the enum can't scramble a setup. `system:settings` is deliberately filtered out of `actions`: the gear on the strip already covers it.

NAV carries the editing keys as **glyphs** (`⇱ ⇲ ⇞ ⇟ ⌦ ⇤`), not words — at one row a cell is ~25–40px and "RE PÁG" would be shrunk to an unreadable 7px by `_label`'s `FittedBox`. The four arrows are a separate block (`kArrowKeys`) folded into NAV *only* in the `classic` layout, where nothing else draws them; otherwise NAV would spend four cells on duplicates and shrink the rest for nothing.

`TerminalShortcutLayout` still chooses where the arrows go (Personalizar → "Flechas del teclado rápido"): `inline` (the default for fresh installs), `classic` (arrows only on NAV), or the side `dpadLeft`/`dpadRight` cluster. New values must be **appended** — the enum index is what's persisted.

`_KeyButton` sizes its own content: labels go through `FittedBox` so a long one shrinks instead of overflowing, and an icon key shows icon+label side by side when the cell is wide (the ACCIONES layer, ~85px cells), falls back to stacked, then to label-only, then to icon-only. Migration `settings_shortcuts_migrated_v5` drops the `^A/^E/^K/^L` copies from the user's own list now that the CTRL layer ships them — only entries still byte-identical to the old default, never a renamed one.

### Commands, keyboard shortcuts and the palette

`lib/views/shell/app_commands.dart` is one registry behind three surfaces: the physical key bindings (`appShortcutBindings`, wired into a `CallbackShortcuts` around the whole shell in `HomeView.build`), the command palette (`lib/views/command_palette.dart`), and the reference sheet (`lib/views/shortcuts_help_sheet.dart`). One list, so a keymap, a menu and a help page cannot disagree.

**Which keys are usable is not a style choice.** App shortcuts sit above the focused widget, so the terminal sees every key first and anything it claims never arrives. Two independent claimants:

- `CtrlInputHandler` folds Ctrl+letter into a control code. It returns null the moment Shift is held — which is exactly what makes `Ctrl+Shift+letter` safe, and why binding plain Ctrl+letter would break the shell.
- The **keytab** (`third_party/xterm/.../keytab_default.dart`) claims whole keys with *any* modifier: `Tab`, the arrows, Home/End, PgUp/PgDn and **F1–F12** (`key F1 -AnyMod : "\EOP"`). Ctrl+Tab and F1 were the first bindings written here and both silently did nothing.

So: Ctrl+Shift+letter, plus punctuation (`Ctrl+Shift+.` / `Ctrl+Shift+,` cycle sessions, `Ctrl+,` opens Ajustes) and `Alt+1…9` for direct session jumps. `test/ux_features_test.dart` asserts no binding lands on a claimed key, that every Ctrl+letter carries Shift, and that no two commands share a combination.

The palette also indexes saved servers, open sessions and pinned folders — "conectar a prod" and "abrir el panel de git" are the same kind of intention.

### Discoverability: onboarding and the gesture reference

The app's best features are gestures with no visible affordance (hold-and-drag joystick, pinch zoom, swipeable key layers, long-press dock, double-tap rename). Two surfaces exist so they are findable:

- `lib/views/onboarding_sheet.dart` — three cards on first run, guarded by `onboarding_seen_v1`, which `markOnboardingSeen` writes *before* showing so the language remount can't repeat it. Replayable from Ajustes → Ayuda. **Widget tests must seed that pref** (`SharedPreferences.setMockInitialValues({'onboarding_seen_v1': true})`) or the sheet covers whatever they were reaching for.
- `lib/views/shortcuts_help_sheet.dart` — the permanent reference: gesture tables plus the keyboard section generated from the command registry.

Both the gesture tables and the command labels are translated *dynamically* (`tr(gesture.action)`), so `scripts/i18n_check.py` reports their keys as unused. They are not — see the note at the top of `strings_en.dart` before deleting anything it flags.

### Terminal scrollback: search, history and export

- **Search** (`lib/services/terminal_search.dart`): matches are cell-accurate — `BufferLine.getText()` drops empty cells and would shift every column after a gap, so `lineText` pads blanks and keeps `string index == column`. That is what lets a hit be highlighted by setting the normal selection (`createAnchorFromOffset`), rather than inventing a second highlight mechanism. Smart case (an uppercase letter narrows), capped at `maxMatches`, and the search bar starts at the *last* hit because the interesting occurrence of an error is the most recent one.
- **Command history** (`AppState._recordCommand`): reuses the Enter boundary already being watched for agent identification (`_noteInputEvidence`). Skipped while the alt buffer is up — inside a TUI those keystrokes are chat messages, not shell history. Persisted under `command_history` and switchable off in Ajustes → Terminal (turning it off deletes what was collected).
- **Export**: "copiar toda la salida" / "guardar salida en archivo" from the terminal's `más` menu.

The toolbar itself is width-aware: under 520px it keeps the session switcher, search, quick keys and `más`, and the rest moves into that sheet with *words* instead of glyphs.

### Agent notifications

The point of the feature is a phone that buzzes when a TUI agent stops and needs the user; the whole difficulty is *not* buzzing at anything else. `NotificationPrefs` (`lib/models/notification_prefs.dart`) holds the settings, `NotificationService` posts through the Android channel, and the detector lives in `AppState` (`_evaluateAgentActivity` / `_maybeFireIdleAlert`) over the classifiers in `lib/services/agent_screen.dart` (`AgentScreen`, pure and covered by `test/agent_screen_test.dart`).

Three guards stand between "the screen changed and went quiet" and a notification, and each one exists because of a specific false alarm:

- **A shell prompt is nobody waiting.** `AgentScreen.looksLikeShellPrompt` reads the last two meaningful lines (two, because tmux parks its status bar under the prompt) and bails at the first box-drawing or agent-chrome line, since inside an agent's input frame the shell is nowhere near the bottom. `>` is deliberately *not* a prompt sigil — Aider's own input line uses it. Matching also **clears the session's sticky agent identity**: the agent exited, so the next prompt redraw must not be announced under its name.
- **`NotificationPrefs.requireAgent`** (on by default, Ajustes → Notificaciones → Sensibilidad) drops question/done alerts for a session where no agent was detected. The bell (BEL / OSC 9 / 777) is an explicit request for attention and is never gated by it.
- **`TerminalSession.redrawGraceUntil`** — the reason the bug was reported as "it notifies me for leaving the terminal". Backgrounding the app hides the soft keyboard, which resizes the PTY, which makes the remote repaint: to the signature machinery that is brand-new content that then goes silent, i.e. exactly the shape of a finished task. For `_redrawGrace` (3s) after a PTY resize or a lifecycle change, a changed signature is adopted as the new baseline *without* opening an idle period.

Every decision, sent or dropped, is appended to `alertLog` with its reason and shown in the notifications screen — a misfire is meant to be diagnosed from the phone, not guessed at.

### The agents dashboard

Four terminals running four agents are four identical black rectangles of monospaced text, and finding the one that stopped to ask a question means visiting each tab and reading it. `AgentsTab` (tab index 10, `lib/views/agents_tab.dart`) answers "which of them needs me, and what for" on one screen.

**It detects nothing new.** The watch loop above already classifies every session's screen on each output batch in order to decide whether to buzz the phone, and then threw the answer away. The whole feature is that decision *kept*:

- `AgentScreen.read` returns one `ScreenReading` and is the single place the classifiers' overlap is resolved. The order is load-bearing and it is the order the notification path always applied: busy → **shellPrompt → question** → quiet. Prompts (starship, pure, oh-my-zsh) open with `❯`, which `looksLikeQuestion` reads as a selection menu, so asking about questions first is exactly the bug that announced "espera tu respuesta" at an empty prompt.
- `_maybeFireIdleAlert` now reads the screen once, pushes the resulting `AgentState` to the monitor, and **then** runs the notification policy unchanged. It deliberately re-asks `looksBusy`/`looksLikeQuestion` rather than deriving from the reading: `read`'s precedence is right for a dashboard that must pick exactly one state, but the alert has always been allowed to call a busy screen a question when `suppressWhileBusy` is off. That path runs once per idle period, not on the 300ms one, so asking twice is free.
- States that are useless as notifications are perfectly good on a dashboard. "It's at a shell prompt" and "no agent was detected" are `drop()`s in the alert path and real, useful cards here.

`AgentMonitor` (`lib/services/agent_monitor.dart`) is a **separate `ChangeNotifier`**, owned by `AppState` and provided alongside it in `main.dart` — same split, and the same reason, as `TunnelManager`'s byte counters. The watch loop re-reads a session's screen several times a second; notifying through `AppState` there would rebuild the whole app at that rate. The second half of that guarantee is `note()`, which **compares before it notifies**: `AgentActivity` is immutable and compared by value, so a busy agent writing constantly stays in one state and costs nothing. `since` is only reset on a real transition, or "esperando 4 min" would read zero forever. Dropping the agent badge is an explicit `clearAgent` flag (the `clearGroupId`/`clearJump` idiom) because "null means leave it alone" is what lets a connection handler avoid wiping the question still on screen — and the agent exiting at a prompt has to take its name with it.

`_watchEnabled` is `agentAlertsEnabled || agentDashboardEnabled` (`settings_agent_dashboard`, default on, in Ajustes → Notificaciones): two features now read the same signal, so turning alerts off must not freeze the dashboard on whatever each session happened to be doing.

`AppState.sendToSession` is the first path in the app that types into a session the user is **not looking at**, so: it skips `sendTerminalInput` (whose sticky CTRL would turn a "y" tapped on another screen into a `^Y`), routes free text through `Terminal.paste` and control sequences raw (wrapped in paste markers, an Esc is just text), still feeds `_noteInputEvidence`, and returns false rather than swallowing a keystroke the user believes they sent. The card puts the screen snippet **above** the buttons, and a profile with `isProduction` confirms first.

Sections are ordered by `AgentState.urgency` (declaration order, `waiting` first) and sessions keep tab order inside one: cards reshuffling under the finger is how the wrong machine gets tapped. `AgentWaitingBadge` (`lib/widgets/agent_waiting_badge.dart`) puts the count on the drawer entry, the rail and the compact strip's MENÚ slot — each subscribing to the monitor on its own so the badge rebuilds and not the shell around it. Knowing without opening is arguably worth more than the screen.

Registering a new tab-backed screen touches seven places, and **two of them fail silently**: `DesktopShell.fullCanvas` (omit it and `_bodyIndex` falls to `-1`, showing the workspace instead) and `MenuDrawer` (the compact strip has five slots, so the drawer is the only way to reach anything past index 3). `test/agent_monitor_test.dart` and `test/agents_tab_test.dart` cover the rest.

Out of scope on purpose: sessions the app is not attached to. A profile with `useTmux` can have an agent running in a detached session, but finding it needs periodic `tmux ls` over an exec channel — network and battery for something the dashboard never promised.

### Release notes and the changelog

Two different moments, and the app used to serve only the first badly.

**Before installing**, the update dialog shows the GitHub release body. It is markdown, and it used to be dumped verbatim into an 11px muted monospace box — so a good release note reached the user as a wall of literal `##`, `-` and `**`. `ReleaseNotesView` (`lib/views/release_notes_view.dart`) handles the four constructs a release note actually uses (headings, bullets, `**bold**`, `` `code` ``) and lets everything else fall through as plain text, which is the correct failure: an unhandled construct still shows its words.

**After installing** is the moment that did not exist. `lib/models/changelog.dart` ships the changelog *inside the build*, so it can be shown when the user actually has the version, in **their language** (the entries are Spanish source text drawn through `tr(change.text)`, like the gesture tables), and for **every version they skipped** rather than only the newest. `maybeShowWhatsNew` runs once per launch after onboarding; `showChangelog` (Acerca de → NOVEDADES) is the permanent way back.

The two halves are kept from drifting by generating one from the other: `scripts/changelog_notes.py` renders the GitHub body **in English** from the same table, translating through `strings_en.dart`, and `scripts/release.sh` refuses to publish a version with no changelog entry. That is also the answer to "what language are the notes in": English on GitHub by construction, the user's own language once installed.

Three details worth keeping:

- `kChangelog`'s **top entry is the version being prepared**, and `changelogUpTo` filters out anything newer than the running build — so writing next release's notes early can never announce a feature the user does not have.
- `changelogSince(null, …)` is empty on purpose: a fresh install gets onboarding, not a changelog, and stacking both would bury the first.
- The seen-version pref is `whats_new_seen_version`, deliberately **without** the `settings_` prefix so `BackupService` leaves it alone — restoring a backup onto a new phone must not swallow the notes for a version that phone never ran.

`test/changelog_test.dart` enforces the ordering rules **and the translations**: these strings are invisible to `scripts/i18n_check.py`, so without that test they would quietly rot back to Spanish.

### Agent launchers

Typing `claude --dangerously-skip-permissions` on a phone keyboard is a thing nobody does twice, so the flags a user always wants live in the launcher rather than in their fingers. `system:agents` (the terminal's AGENTES key, and any pad slot bound to it) opens a grid of **real brand marks** — `assets/agents/*.png`, the same LobeHub artwork the Android notification badges use, keyed by the same ids as `AppState._agentMarkers`. One vocabulary across detection, notification badge and launcher.

`AgentLauncher` (`lib/models/agent_launcher.dart`) stores the command **verbatim** and sends it verbatim, so anything the user's shell accepts works — `cd repo && claude`, `npx opencode`, a wrapper script. It goes out through `insertPromptText` (a bracketed paste, so a TUI sees one insertion) with the Enter sent separately and only when `autoRun` is set.

Two deliberate refusals: the **defaults ship no flags at all** (a launcher that silently added `--dangerously-skip-permissions` would be making a security decision for the user — the editor offers it, with the consequence written out in words), and the command field is **free text** rather than a picker, because the app does not know next year's CLI and a new agent has to be addable without a release. `AgentMark` draws the marks **untinted**, the only images in the app that escape the palette: they are brand logos, and recolouring them is what would stop them being recognisable at a glance.

Editable in Personalizar → Agentes (`lib/views/agent_launchers_panel.dart`). Migration `settings_shortcuts_migrated_v7` adds the key to existing setups, not just fresh ones. A shipped default whose *command* turns out to be wrong is corrected on load the same way (Antigravity's binary is `agy`, not `antigravity`) — but only while the stored command is still byte-identical to the old default, since a line the user edited is theirs, wrong or not. `test/agent_launcher_test.dart`.

### Backup and restore

`lib/services/backup_service.dart` writes one JSON file with every `settings_*` key plus an explicit allow-list (`ssh_profiles`, `connection_groups`, `profile_favorites`, `profile_last_used`, `prompt_snippets`, `explorer_bookmarks`, `known_hosts`, `app_language`).

- `_deviceLocalKeys` is excluded in both directions: window geometry and pane splits belong to the screen they were set on, and restoring `settings_app_lock_enabled` onto a device with no enrolled biometric turns a restore into a lockout.
- Restores **merge** (a key in the file replaces the current one; anything else is kept) and the allow-list is enforced on the way *in* too, so a crafted file can't write arbitrary prefs.
- Secrets are opt-in and produce a plaintext file holding every credential the user owns — the toggle says so in words.
- Afterwards the caller must call `AppState.reloadFromDisk()`; live sessions are deliberately untouched.

### Session restore

`open_sessions` holds `{profileId, name}` per open tab, rewritten on create/close/rename. On launch `_restoreSessions` recreates them **disconnected**, with the reconnect banner ready — reconnecting by itself would open SSH connections and burn mobile data nobody asked to spend. `createNewSession(connect: false)` is what makes that possible. Switchable in Ajustes → Terminal.

### Accessibility

- `lib/widgets/tap_target.dart`: `TapTarget` grows the *hit area* around a control without changing how it looks, and `IconTapTarget` is the labelled icon button to prefer over a hand-rolled `GestureDetector(child: Icon(...))` — those left most of the chrome both untappable and silent under TalkBack. The minimum is width-class aware (48dp touch, 32dp pointer).
- Text scaling: Flutter already honours the system setting, so what the app adds is its own multiplier (`AppState.textScale`, Personalizar → "Tamaño del texto") and a **clamp on the product** in `main.dart`'s `_TextScaleGate`. The clamp is load-bearing: the shell is built from fixed heights (46px toolbar, 42px path bar, 30px panel titles) whose labels stop fitting past `maxEffectiveTextScale`. The gate lives in `MaterialApp.builder` because a `MediaQuery` inside `HomeView` would leave dialogs and sheets — their own routes — unscaled.
- Long button labels: `InvertedButton`/`GhostButton` wrap their `Text` in `Flexible` with ellipsis. An `expand: true` button is as wide as its parent and its label has no say in that; without it a long label overflows on a narrow phone.

### Explorer action dock

The explorer's file actions (upload, new folder/file, select all, copy, paste) live in a narrow tab stuck to a screen edge — `_buildSideDock` in `explorer_tab.dart`, wrapped in `EdgeDock` (`lib/widgets/edge_dock.dart`). A long press picks the dock up; the drag chooses a vertical position and a side, and it snaps back against whichever edge the finger is nearer. It is never left floating mid-screen: parked over the list it would cover a file row with nothing to say which one.

Position goes through `Alignment(-1|1, y)`, not raw offsets — an alignment is resolved against the child's own measured size, so the dock can't end up half off-screen however tall it grows when opened, and `EdgeDock` never needs to know its height. `AnimatedAlign` runs at `Duration.zero` while the finger is down (a tween lags the drag) and eases only on release, so the snap reads as a snap. The side is passed back into the builder because the rounded corners and the chevron both have to face away from the edge.

Resting place persists under `settings_explorer_dock_left` / `settings_explorer_dock_y`. `test/edge_dock_test.dart` covers the snap, the side switch, the on-screen clamp, and that a plain tap still reaches the panel's own buttons.

### Responsive shell (compact vs desktop)

The shell picks a layout from its **own width**, never from `Platform.isLinux` — a narrow Linux window gets the touch layout and a wide Android tablet gets the desktop one. `lib/theme/breakpoints.dart` publishes a `Layout` inherited widget (`compact` < 900 ≤ `medium` < 1400 ≤ `expanded`) from a `LayoutBuilder` in `HomeView`. It carries only the width *class*, so it notifies once per breakpoint crossing rather than once per pixel of a drag. Inside a screen body prefer `constraints.widthClass` (the `BoxWidthClass` extension): a 300px explorer pane on a 1920px display is compact.

- **Compact** — the historical layout: a 54px top nav strip over an `IndexedStack`, plus the `MenuDrawer` end drawer.
- **Desktop** — `shell/desktop_shell.dart`: a 56px `NavRail` beside either `shell/workspace.dart` (explorer/git │ editor over terminal, split by `widgets/split_pane.dart`) or one full-canvas screen. Split fractions and pane visibility live in `AppState` (`settings_split_*`, `settings_*_pane_open`).

`activeTabIndex` keeps its meaning in both; the desktop shell only *derives* from it, so every existing `setActiveTabIndex` call site works unchanged — "go to the editor" simply becomes "focus the editor pane" when the editor is already on screen. `AppState.focusedPaneTab` tracks which pane owns focus, and the rail shows two tiers: *on screen* (muted) and *focused* (accent).

**The load-bearing invariant:** `_HomeViewState` holds a `GlobalKey` per screen and every mount goes through `mount(screen)`. Moving a keyed subtree between the two shells **within a single build** re-parents its Element instead of rebuilding it, so a live `TerminalTab` keeps its FocusNode, controllers and scroll position across a resize. Therefore:

- The two shells must swap with a bare `if/else`. An `AnimatedSwitcher` or crossfade mounts both at once and destroys the terminal on every resize.
- A screen must never be mounted twice — the desktop `IndexedStack` holds only non-paneable screens, and hidden panes go in the workspace's `Offstage` bucket.
- `_screenKeys` must stay an **instance** field. As a static it would turn the language remount (see Localization) into a re-parent, and `tr()` inside tabs would keep the old language.

`test/layout_breakpoint_test.dart` pins all of this down with an `identical()` assertion on the `TerminalTab` State across a crossing.

Two more desktop notes: PTY resizes are debounced 150ms per session (`AppState._scheduleResize`) — without it a splitter drag floods the SSH channel with `window-change` and TUIs redraw continuously. And bottom sheets go through `showAdaptiveSheet` (`lib/widgets/adaptive_sheet.dart`), which stays a bottom sheet under 900px and becomes a centred constrained dialog above it.

### Desktop window chrome

The app draws its own 32px title bar (`shell/window_title_bar.dart`), mounted in `MaterialApp.builder` so it sits above the navigator and stays over dialogs. It shows the active session (`user@host`) with a connection dot, drags via `windowManager.startDragging()`, double-clicks to maximize and right-clicks to the WM menu.

- `linux/runner/my_application.cc` always attaches a `GtkHeaderBar`, even outside GNOME. That is deliberate: it decides *how* `window_manager` hides the bar. With a header bar present it hides only that widget and the window stays `decorated`, keeping the native resize borders; without one it falls back to `gtk_window_set_decorated(FALSE)`, which strips the resize edges too.
- `main.dart` applies `TitleBarStyle.hidden` inside `waitUntilReadyToShow`, so the GTK bar is gone before the window is first shown instead of flashing.
- Because the bar is above the navigator there is **no `Overlay`** there: it uses `Semantics`, not `Tooltip`, and needs its own `Material` ancestor or `Text` falls back to the yellow-underlined debug style.
- `lib/services/window_geometry.dart` persists size/position/maximized under `window_*` prefs keys, debounced 400ms. The minimum window size (420×560) is deliberately *below* the 900px breakpoint so the touch layout stays reachable.

### Localization (ES/EN)

Spanish is the source language and the lookup key: every user-facing string is written in Spanish inside `tr('…')` (`lib/l10n/l10n.dart`), and `lib/l10n/strings_en.dart` maps that exact Spanish text to English. A key with no entry falls back to the Spanish text, so a partial translation is always safe.

- `tr()` reads a global (`L10n.notifier`), not an `InheritedWidget`, because it is called from `AppState` and from `services/` where there is no `BuildContext`. Consequently a language change has nothing to notify: the tree has to be remounted so every `tr()` call re-runs. That happens in `_LockGate` (`main.dart`), which listens to `L10n.notifier` and wraps the app content in a `KeyedSubtree(key: ValueKey(lang))`. Sessions live in `AppState`, so nothing is lost — but anything a mount kicks off (the release check in `HomeView.initState`) has to be guarded against running again.
- The remount must stay **below** the navigator. Keying `MaterialApp` itself does *not* work: `navigatorKey` is a `GlobalKey`, so the existing `Navigator` is re-parented into the new app rather than rebuilt, and only elements with an `InheritedWidget` dependency end up rebuilding — a `const` panel or a plain `Text(tr(…))` keeps the previous language. `test/settings_switches_test.dart` pins this down.
- `tr()` is not a `const` expression — a widget holding one cannot be `const`.
- Interpolation must go through positional placeholders, never `$x`, or the value gets baked into the key: `tr('Túnel activo: {0}', [spec])`.
- The language is persisted under the `app_language` prefs key and picked in Ajustes → Idioma. `L10n.load()` runs before `runApp` so the first frame is already correct.
- Persisted text (terminal shortcut labels) is stored in Spanish and translated at draw time via `tr(shortcut.label)`; a user-renamed label just falls through untranslated.
- `python3 scripts/i18n_check.py` lists `tr()` keys with no English entry (`--stubs` prints pasteable lines). `test/l10n_test.dart` checks fallback, placeholder substitution, and that no translation drops a placeholder.
- Out of scope so far: messages the app writes *into* the terminal (`\r\n`-terminated), shell commands, and JSON/prefs keys — all deliberately left untranslated.

### Styling conventions

The UI uses a hand-rolled dark "flat IDE" theme: hardcoded hex colors (`Color(0xFF0D0D0D)` background, `Color(0xFF1E1E1E)` surface, `Color(0xFF333333)` borders, `Color(0xFF9CA3AF)` muted text, primary azure `Color(0xFF007AFF)`), small uppercase letter-spaced labels, and 4px border radii. Match these constants rather than using default Material styling when adding UI. UI copy is authored in Spanish and wrapped in `tr()` — see Localization above.
