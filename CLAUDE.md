# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

"KALA" (package name `terminal_agent`) is a Flutter app that combines an SSH connection manager, a multi-session terminal emulator (SSH), a remote file explorer (SFTP), and a code editor into a single mobile-first IDE-like tool. Configured platforms are **Android** and **Linux** only.

## Commands

Two dependencies are vendored under `third_party/` and wired through `dependency_overrides` in `pubspec.yaml`: the patched `xterm`, and `dartssh2` — whose patch fixes an upstream bug where a channel's receive window is never replenished once exhausted, deadlocking any transfer over ~6 MB through a tunnel. Re-apply both patches if either package is upgraded.

The Flutter SDK is vendored inside this repo at `sdk/flutter` (a full flutter/flutter checkout used as the project's Dart/Flutter SDK — it is not part of the app's own source and generally doesn't need to be touched). If `flutter` is not on `PATH`, use `sdk/flutter/bin/flutter`.

- Install dependencies: `flutter pub get`
- Run the app (Linux desktop): `flutter run -d linux`
- Run the app (Android): `flutter run -d <android-device-id>`
- Static analysis / lints: `flutter analyze`
- Run all tests: `flutter test`
- Run a single test file: `flutter test test/widget_test.dart`
- Build Linux release: `flutter build linux`
- Build Android APK: `flutter build apk`

Note: `test/widget_test.dart` is still the default Flutter counter-app template and does not match `MyApp` (no counter UI exists), so `flutter test` currently fails. Replace or rewrite this test before relying on it.

## Architecture

### State management

All app state is centralized in a single `ChangeNotifier`, `AppState` (`lib/providers/app_state.dart`), provided at the root via `provider` in `lib/main.dart`. Views read it with `Provider.of<AppState>(context)`. There is no other state management layer — new features should extend `AppState` rather than introducing local widget state for anything that needs to survive tab switches.

### Multi-session terminal model

- `AppState` holds a list of `TerminalSession` objects (`_sessions`), each with its own `xterm.Terminal`, `ConnectionStatus` (`disconnected | connecting | remote`), and a `dartssh2.SSHClient`/`SSHSession` (remote shell).
- Only one session is "active" at a time (`_activeSessionIndex`). Most getters (`terminal`, `connectionStatus`, `currentPath`, `files`, etc.) are convenience delegates to `activeSession`.
- Connecting to a saved profile (`connectToSSH`) creates a *new* session and connects it via `_connectSessionToSSH`, then switches the active tab to the terminal.
- `disconnect` / session loss tears down the session's SSH connection and marks it as disconnected.

### Connection profiles

`ConnectionProfile` (`lib/models/connection_profile.dart`) is a plain JSON-serializable model (host/port/username/password/etc.). Profiles are persisted as a JSON string list under the `ssh_profiles` key via `shared_preferences` (`_loadProfiles`/`saveProfile`/`deleteProfile` in `AppState`). Passwords are stored in plaintext in shared preferences — there is no keychain/secure-storage integration.

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

### Source control (git panel)

Git is driven by `GitService` (`lib/services/git_service.dart`), built on demand by `AppState.createGitService()` for the *active* session: `GitService.remote` runs commands on an SSH exec channel, `GitService.local` through `Process.run`. A fresh instance per call is deliberate, so a panel that outlives a reconnect picks up the new client instead of a dead channel.

- Every command is built from an argument **list** and each argument is single-quoted for the remote shell (`_q`), so commit messages and paths can contain quotes, `$` or newlines. Nothing is interpolated into a command string.
- Commands run with `GIT_TERMINAL_PROMPT=0`, empty-answer askpass helpers and `ssh -o BatchMode=yes`: a push needing a passphrase fails with a message instead of hanging the channel until the timeout (25 s local ops, 90 s network ops).
- `git status --porcelain=v1 -z -b` is parsed by `GitRepoInfo.parse` (`lib/models/git_status.dart`), which keeps the index and worktree columns separate — that split is what the staged/unstaged groups are. `-z` is what makes paths with spaces and renames safe. Unit tests: `test/git_status_test.dart`; `test/git_service_test.dart` drives the local runner against a throwaway repo.
- UI: `lib/views/git_panel_sheet.dart` (the panel, opened from the terminal toolbar), `git_diff_sheet.dart` (colored unified diff) and `git_project_tree.dart` (the lazy file tree). Tapping a changed file shows its diff; long-pressing sends it to the explorer/editor.

### UI structure

`lib/views/home_view.dart` is the app shell. It holds ten screens, indexed by `AppState.activeTabIndex`: 0 connections, 1 terminal, 2 explorer, 3 editor, 4 server, 5 settings, 6 personalization, 7 about, 8 notifications, 9 tunnels. `AppScreen` (`lib/views/shell/app_screen.dart`) is their stable identity; it also carries `git`, which has no tab index.

The key screens:

1. `connections_tab.dart` — manage/edit SSH `ConnectionProfile`s, and connect to a profile.
2. `terminal_tab.dart` — the active session's `xterm.TerminalView`, a session-switcher bar (tap to switch, double-tap to rename, `x` to close), and a "smart keyboard" row of quick-input buttons that call `state.sendTerminalInput(...)`.
3. `explorer_tab.dart` — file browser for the active session's remote `currentPath`.
4. `editor_tab.dart` — wraps `re_editor`'s `CodeEditor`/`CodeLineEditingController`, syncing edits back to `AppState.updateFileContent`.

Switching happens programmatically via `AppState.setActiveTabIndex` (e.g. opening a file jumps to tab 3). Inside `AppState` those jumps go through the private `_setTab`, never a raw `_activeTabIndex =`, so pane focus stays in sync.

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
