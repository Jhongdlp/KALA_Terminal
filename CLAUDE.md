# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

"KALA" (package name `terminal_agent`) is a Flutter app that combines an SSH connection manager, a multi-session terminal emulator (SSH), a remote file explorer (SFTP), and a code editor into a single mobile-first IDE-like tool. Configured platforms are **Android** and **Linux** only.

## Commands

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

### Styling conventions

The UI uses a hand-rolled dark "flat IDE" theme: hardcoded hex colors (`Color(0xFF0D0D0D)` background, `Color(0xFF1E1E1E)` surface, `Color(0xFF333333)` borders, `Color(0xFF9CA3AF)` muted text, primary azure `Color(0xFF007AFF)`), small uppercase letter-spaced labels, and 4px border radii. Match these constants rather than using default Material styling when adding UI. UI copy/strings are in Spanish.
