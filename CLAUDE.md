# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

"KALA" (package name `terminal_agent`) is a Flutter app that combines an SSH connection manager, a multi-session terminal emulator (SSH), a remote file explorer (SFTP), and a code editor into a single mobile-first IDE-like tool. Configured platforms are **Android** and **Linux** only.

## Commands

Two dependencies are vendored under `third_party/` and wired through `dependency_overrides` in `pubspec.yaml`: the patched `xterm`, and `dartssh2` — whose patch fixes an upstream bug where a channel's receive window is never replenished once exhausted, deadlocking any transfer over ~6 MB through a tunnel. Re-apply both patches if either package is upgraded.

The `xterm` patches worth knowing about, beyond Gboard inline image paste: `TerminalMouseButton` reports wheel buttons as `64 + 0…3`, not upstream's `64 + 4…7` (which sets bit 2 — the Shift modifier — so every wheel event reached the remote as Shift+Wheel, and tmux leaves `S-WheelUpPane` unbound, i.e. scrolling a tmux session did nothing); `TerminalScrollGestureHandler` was rewritten around the gesture arena (see Terminal touch gestures); and touch taps are no longer forwarded to the application as mouse clicks, only real mouse taps are.

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
| still hold ≥200ms, then drag | `JoystickGestureRecognizer` | arrow keys, speed ramped by pull distance |
| still hold ≥500ms | xterm `LongPressGestureRecognizer` | select word, then `TerminalSelectionArea`'s handles |
| two fingers | `_PinchFontZoom` (a `Listener`, outside the arena) | font size |

`JoystickGestureRecognizer` (`lib/widgets/joystick_recognizer.dart`) is the one that can starve the others, so it never claims the arena up front: it rejects itself on any movement past `stillSlop` before the hold qualifies (that's a swipe), on a second finger (that's a pinch), on pointer-up without a drag (that's a tap), and at `armWindowEnd` — deliberately just under `kLongPressTimeout`, so a resting finger that drifts can no longer steal a selection. `stillSlop + dragThreshold` is kept **under `kTouchSlop`**: the scrollable that hosts the terminal is deeper in the tree, so its drag recogniser sees every move event first and would win any event that crosses both thresholds at once.

Alt-buffer scrolling (tmux, and any TUI agent running under it) lives in the vendored `TerminalScrollGestureHandler`. Upstream wrapped the terminal in a second `Scrollable` that swallowed the drag before xterm's own recognisers saw it; it now runs a plain `VerticalDragGestureRecognizer` that competes fairly, so a long press still selects instead of scrolling. Its fling is gated on `terminal.mouseMode.reportScroll` — without mouse reporting `_sendScrollEvent` falls back to arrow keys, and a fling would dump a hundred of them into whatever holds the prompt.

### Soft keyboard, dictation and the IME

The terminal has no text field of its own, so xterm attaches the IME to `CustomTextEdit` (`third_party/xterm/lib/src/ui/custom_text_edit.dart`): a hidden buffer holding the four-space sentinel `'  |  '`, whose middle is whatever the keyboard has typed. On each `updateEditingValue` the typed region is diffed against `_pendingSent` — the mirror of what has already been forwarded — and the difference goes to the shell as backspaces plus a tail.

The diff is what makes keyboard-side edits work at all: swipe typing replacing a word, autocorrect, and Gboard's fix-the-last-word all arrive as a *rewrite* of text already sent, never as an append.

**Do not wipe the buffer after forwarding.** Upstream called `setEditingState` after every committed character; on Android that restarts the input connection, which ends any running voice-typing session (dictation kept cutting out mid-sentence) and leaves the keyboard with no context to predict from. The mirror is cleared on Enter (`performAction`), on an injected key (`reset()`, from `TerminalTab._sendTerminalKey`), when the connection opens or closes, and past `_maxPendingLength`. `test/terminal_ime_test.dart` pins this down, including that ordinary typing still yields exactly the right bytes.

Even so, the raw path can only ever offer the keyboard one command line of context. For dictation proper there is `TerminalComposeBar` (`lib/views/terminal_compose_bar.dart`), toggled from the terminal toolbar: a real `TextField` where the words stay put until sent, so the suggestion strip, continuous dictation and autocorrect behave normally. It sends through `AppState.insertPromptText` (a paste, so a TUI agent sees one insert rather than a burst of keystrokes) plus an optional `\r`.

### Connection profiles

`ConnectionProfile` (`lib/models/connection_profile.dart`) is a plain JSON-serializable model (host/port/username/etc.). Profile *metadata* is persisted as a JSON string list under the `ssh_profiles` key via `shared_preferences` (`_loadProfiles`/`saveProfile`/`deleteProfile` in `AppState`), written through `toJsonPublic()`.

**Secrets do not go there.** Passwords and private keys live in `SecureStore` (`lib/services/secure_store.dart`) — Keystore-backed `EncryptedSharedPreferences` on Android, libsecret on Linux — keyed by profile id. `_loadProfiles` migrates any legacy profile that still carries its secret inline and rewrites prefs without it. The profile form says so under the password field; users deciding whether to type a production password into a phone app deserve to know where it lands.

Three things *about* profiles live in their own small prefs entries rather than on the profile, because they change from the list far more often than the profile does and rewriting `ssh_profiles` means a secure-storage round trip per profile: `connection_groups` (the `ConnectionGroup` folders), `profile_favorites`, and `profile_last_used` (stamped by `_noteProfileConnected` on every successful connect, which is what feeds "Recientes").

`SshConfigImport` (`lib/services/ssh_config_import.dart`) reads `Host` blocks out of an OpenSSH client config so a laptop's thirty hosts don't have to be retyped into a phone form. It is deliberately partial — `Host`/`HostName`/`User`/`Port`/`IdentityFile` only — and **drops** any block carrying `ProxyJump`, `ProxyCommand`, `Match` or `Include` rather than importing it half-configured: a profile that silently connects somewhere else is worse than one that was never created. Wildcard blocks (`Host *`) are defaults, not machines, and are skipped.

`testProfile` opens a throwaway client and closes it — the "Probar conexión" button in the form. It deliberately creates no session and stamps nothing: a test is not a connection.

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

`lib/views/home_view.dart` is the app shell. It holds ten screens, indexed by `AppState.activeTabIndex`: 0 connections, 1 terminal, 2 explorer, 3 editor, 4 server, 5 settings, 6 personalization, 7 about, 8 notifications, 9 tunnels. `AppScreen` (`lib/views/shell/app_screen.dart`) is their stable identity; it also carries `git`, which has no tab index.

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
