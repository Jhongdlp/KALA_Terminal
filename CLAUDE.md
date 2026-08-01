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

### UI structure

`lib/views/home_view.dart` is the app shell: a `Scaffold` with an `IndexedStack` driven by `AppState.activeTabIndex` and a `BottomNavigationBar` with four tabs:

1. `connections_tab.dart` — manage/edit SSH `ConnectionProfile`s, and connect to a profile.
2. `terminal_tab.dart` — renders the active session's `xterm.TerminalView`, a horizontal session-switcher bar (tap to switch, double-tap to rename, `x` to close), and a custom "smart keyboard" row of quick-input buttons (Ctrl+C, arrows, common commands) that call `state.sendTerminalInput(...)`.
3. `explorer_tab.dart` — file browser for the active session's remote `currentPath`, dispatching to `changeDirectory`/`navigateUp`/`openFile`.
4. `editor_tab.dart` — wraps `re_editor`'s `CodeEditor`/`CodeLineEditingController`, syncing edits back to `AppState.updateFileContent` and showing a dirty-state dot.

Switching to the editor or files tab happens programmatically via `AppState.setActiveTabIndex`/`_activeTabIndex` mutations (e.g., opening a file jumps to tab 3).

### Localization (ES/EN)

Spanish is the source language and the lookup key: every user-facing string is written in Spanish inside `tr('…')` (`lib/l10n/l10n.dart`), and `lib/l10n/strings_en.dart` maps that exact Spanish text to English. A key with no entry falls back to the Spanish text, so a partial translation is always safe.

- `tr()` reads a global (`L10n.notifier`), not an `InheritedWidget`, because it is called from `AppState` and from `services/` where there is no `BuildContext`. Consequently a language change has nothing to notify: `main.dart` rebuilds `MaterialApp` under a `ValueKey(lang)`, remounting the tree so every `tr()` call re-runs. Sessions live in `AppState`, so nothing is lost.
- `tr()` is not a `const` expression — a widget holding one cannot be `const`.
- Interpolation must go through positional placeholders, never `$x`, or the value gets baked into the key: `tr('Túnel activo: {0}', [spec])`.
- The language is persisted under the `app_language` prefs key and picked in Ajustes → Idioma. `L10n.load()` runs before `runApp` so the first frame is already correct.
- Persisted text (terminal shortcut labels) is stored in Spanish and translated at draw time via `tr(shortcut.label)`; a user-renamed label just falls through untranslated.
- `python3 scripts/i18n_check.py` lists `tr()` keys with no English entry (`--stubs` prints pasteable lines). `test/l10n_test.dart` checks fallback, placeholder substitution, and that no translation drops a placeholder.
- Out of scope so far: messages the app writes *into* the terminal (`\r\n`-terminated), shell commands, and JSON/prefs keys — all deliberately left untranslated.

### Styling conventions

The UI uses a hand-rolled dark "flat IDE" theme: hardcoded hex colors (`Color(0xFF0D0D0D)` background, `Color(0xFF1E1E1E)` surface, `Color(0xFF333333)` borders, `Color(0xFF9CA3AF)` muted text, primary azure `Color(0xFF007AFF)`), small uppercase letter-spaced labels, and 4px border radii. Match these constants rather than using default Material styling when adding UI. UI copy is authored in Spanish and wrapped in `tr()` — see Localization above.
