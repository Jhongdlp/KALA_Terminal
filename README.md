<div align="center">

<img src="public/icon/IconKAMMEL.png" width="120" alt="KAMMEL SSH">

# KAMMEL SSH

**An SSH client built for driving AI coding agents from your phone.**

Multi-session terminal · SFTP explorer · code editor · Docker & database console — in one Flutter app for Android and Linux.

[Leer en español](README.es.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.44-02569B?logo=flutter)](https://flutter.dev)
[![Platforms](https://img.shields.io/badge/platforms-Android%20%7C%20Linux-green)]()
[![Latest release](https://img.shields.io/github/v/release/Jhongdlp/Kammel_ssh?label=download)](https://github.com/Jhongdlp/Kammel_ssh/releases/latest)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

</div>

---

## What it is

`ssh` on a phone is usually a compromise: no keyboard, no notifications, and the session dies the moment you switch apps. KAMMEL SSH is built around the one workload where that hurts most — **running a TUI coding agent (Claude Code, Codex, Aider, Gemini CLI…) on a remote server** and babysitting it from your pocket.

So it keeps the shell alive in the background, **notifies you when the agent stops and needs an answer**, and gives you a touch keyboard, a file explorer, an editor and a git panel so you never have to type a path by hand.

It is also a perfectly ordinary, fast SSH client if you just want a shell.

## ✨ Features

### Terminal
- **Multi-session SSH** — several servers open at once, switch with one tap, rename and close them like browser tabs. Reconnect in place when a session drops.
- **tmux persistence** — opt in per profile and a dropped connection re-attaches to the still-running remote session instead of losing your work.
- **Stays alive in the background** — an Android foreground service keeps every shell running while you're in another app (the way Termux does).
- **Smart keyboard** — a configurable quick-key row (Ctrl, Esc, Tab, arrows, pipes, common commands) with three layouts: classic double row, or a D-pad pinned left/right. Every key is editable, reorderable, and you can add your own.
- **Real keyboard behaviour** — suggestions, autocorrect and voice dictation work in the terminal (upstream `xterm` hardcodes an "incognito" keyboard that disables all of it; we ship a patched copy).
- **Selection, copy, paste and link detection** — tap a URL in the output to open it in the browser.
- **Attach anything** — pick a file from the phone and its path is inserted at the prompt, ready for the agent to read.
- **Paste images straight into the prompt** — from the clipboard or Gboard. The image is uploaded over SFTP as `pasted_image_<timestamp>.png` in the current directory and the filename is typed for you.

### AI agent support (the reason this app exists)
- **Agent detection** — recognises Claude Code, Codex, Gemini CLI, Aider, OpenCode, Copilot CLI, Cursor, Qwen Code and Antigravity from the running command line and window title, including through wrappers like `npx`, `sudo` or `uvx`.
- **"Agent needs you" notifications** — when a backgrounded session goes idle after a burst of work, asks a question, or rings the terminal bell / emits `OSC 9`/`OSC 777`, you get a heads-up notification with a snippet of the screen and the agent's badge. Tap it to jump straight back to that session.
- **Per-alert intensity** — each alert kind maps to its own Android channel: heads-up, sound only, silent, or off. Mute individual sessions. Send test notifications from Settings.
- **Prompt snippets** — save recurring instructions and insert them with one tap instead of typing a paragraph on a phone keyboard.
- **Voice dictation** in the prompt composer.
- **Git panel** — see pending changes in the project, open a changed file, write a commit, or **delegate to the agent** ("commit everything with a sensible message and push") with a single tap.

### Connections
- **Profiles** — host, port, user, password or private key, saved and reusable.
- **Paste an SSH command** — drop in `ssh -p 2222 user@host -L 8080:localhost:80` and the profile fills itself in.
- **Device SSH key** — generate an ed25519 identity that lives in the phone's secure storage and never leaves it. Copy the public line into `~/.ssh/authorized_keys` and connect passwordless.
- **Secrets in the OS keystore** — passwords and private keys go to the Android Keystore / libsecret via `flutter_secure_storage`, not into plain preferences.
- **App lock** — optional biometric / device-credential unlock on launch and on resume.
- **Local port forwarding** — declare `-L` tunnels on a profile and they open automatically with the session.

### Files & editor
- **SFTP explorer** — browse, search, filter by type, show/hide dotfiles, multi-select, copy/move/paste, delete, and create.
- **Transfers both ways** — upload files from the phone, download selections to it, with progress and per-file error reporting.
- **Code editor** — `re_editor` with syntax highlighting, dirty-state tracking and save-back over SFTP. The editing connection is captured on open, so switching sessions doesn't break the file you're editing.
- **Built-in viewers** — Markdown (with zoom and preview toggle), PDF, images including SVG, and **video/audio playback** via `media_kit` with a playback bar.
- **External documents** — Word, Excel, PowerPoint, EPUB, ZIP and APK open in the system's own apps; the temp file is cleaned up afterwards.
- **Terminal ↔ explorer sync** — optionally keep the explorer following the shell's working directory, or open a terminal at any folder.

### Server console
- **Monitor** — CPU load, RAM, disk and system services at a glance.
- **Docker** — containers (start/stop/logs/stats), images, volumes, networks and compose stacks.
- **System** — resource and configuration overview, with an audit/analytics mode.
- **Databases** — attach PostgreSQL / MySQL profiles to a server (including instances running inside a container) and inspect them from the same console.

### App
- **Themes** — system / light / dark / true-black OLED, with an accent colour picker.
- **Terminal styling** — Dracula, Gruvbox, Nord or "follow the app theme", font size, and a choice of Cascadia Code, JetBrains Mono, Fira Code, Source Code Pro, Inconsolata or Anonymous Pro.
- **Icon density** and quick-key size controls, for small screens and big thumbs alike.
- **In-app updates** — checks GitHub Releases and installs the new APK for you.
- **Spanish UI** (English translation welcome — see the roadmap).

## 📦 Install

**Android:** grab the APK from the [latest release](https://github.com/Jhongdlp/Kammel_ssh/releases/latest). After that the app updates itself.

**Linux:** build from source (below).

## 📱 Platforms

| Platform | Status |
|----------|--------|
| Android  | ✅ Supported (the main target) |
| Linux    | ✅ Supported (desktop) |
| iOS / Windows / macOS | ❌ Not configured |

## 🚀 Getting started (from source)

### Prerequisites

- [Flutter](https://docs.flutter.dev/get-started/install) 3.44+ (Dart 3.12+).
  This repo vendors a full Flutter SDK at `sdk/flutter`; if you don't have Flutter on your `PATH`, use `sdk/flutter/bin/flutter` instead of `flutter` below.
- For Android builds: Android SDK + a device or emulator.
- For Linux builds: the standard [Flutter Linux desktop dependencies](https://docs.flutter.dev/platform-integration/linux/setup) (`clang`, `cmake`, `ninja-build`, `libgtk-3-dev`, …).

### Build and run

```bash
git clone https://github.com/Jhongdlp/Kammel_ssh.git
cd Kammel_ssh

flutter pub get

# Run on Linux desktop
flutter run -d linux

# Run on Android
flutter run -d <android-device-id>

# Release builds
flutter build apk          # Android
flutter build linux        # Linux
```

### First connection

1. **Connections** tab → **+** → fill in host/user, or paste a full `ssh …` command.
2. Optionally enable the **device key** (Settings → *Llave SSH del dispositivo*) and copy the public line into the server's `~/.ssh/authorized_keys`.
3. Tap the profile to connect. The terminal tab opens with the session.
4. Start your agent (`claude`, `codex`, `aider`, …). Leave the app — you'll get a notification when it needs you.

### Notes on the Android build

- `targetSdk` is intentionally pinned to **28** in `android/app/build.gradle.kts` for legacy shared-storage compatibility.
- `MainActivity` must stay a `FlutterFragmentActivity`; `local_auth` needs it for the app lock.
- The terminal uses a **vendored, patched copy of `xterm`** at `third_party/xterm`, wired in through `dependency_overrides`. Keyboard suggestions, dictation and inline image paste live there, not upstream.

## 🏗 Architecture overview

```
lib/
├── main.dart               # App entry, root Provider
├── providers/
│   └── app_state.dart      # Single ChangeNotifier holding ALL app state
├── models/                 # ConnectionProfile, SshTunnel, PromptSnippet,
│                           # TerminalShortcut, NotificationPrefs, DB profiles
├── services/
│   ├── secure_store.dart       # Keystore/libsecret-backed secrets
│   ├── device_key.dart         # On-device ed25519 SSH identity
│   ├── app_lock.dart           # Biometric / device-credential lock
│   ├── background_service.dart # Android foreground service (keeps shells alive)
│   ├── notification_service.dart # Agent-alert notification channels
│   ├── server_controller.dart  # Server console + Docker + DB state machine
│   └── update_service.dart     # In-app updates from GitHub Releases
├── theme/                  # Themes, terminal palettes, editor highlighting
├── views/                  # One file per tab/screen
└── widgets/
```

Key design decisions:

- **Single source of truth**: all state lives in `AppState` (`ChangeNotifier` + `provider`). New stateful features extend `AppState` rather than adding local widget state that dies on a tab switch.
- **Sessions**: `AppState` holds a list of `TerminalSession`s, each owning its own `xterm.Terminal` and `dartssh2` client. Only one is active at a time; most getters delegate to it.
- **Everything remote goes over SFTP**: listing, navigation, editing and transfers all use the session's SFTP client.
- **Agent detection is heuristic and local** — it reads the terminal's own output and typed commands. Nothing is sent anywhere.

See [CLAUDE.md](CLAUDE.md) for a deeper walkthrough.

## 🔒 Privacy

KAMMEL SSH talks to your servers and to the GitHub Releases API (update check). Nothing else. There is no telemetry, no account, and no backend — credentials never leave the device.

## 🗺 Roadmap

- [ ] Dynamic (`-D`, SOCKS5) and remote (`-R`) tunnels — the model exists, the UI covers `-L` today
- [ ] English (and further) translations of the UI
- [ ] Editor: search & replace, multi-file tabs
- [ ] Key-based auth improvements: passphrase-protected keys, agent forwarding
- [ ] A real test suite (`test/widget_test.dart` is still the Flutter template)

Have an idea? [Open an issue](https://github.com/Jhongdlp/Kammel_ssh/issues/new).

## 🤝 Contributing

Contributions are very welcome — read [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, coding conventions and environment setup.

Found a security issue? Please report it privately through [GitHub Security Advisories](https://github.com/Jhongdlp/Kammel_ssh/security/advisories/new) rather than a public issue.

## 📄 License

[MIT](LICENSE).

### Bundled third-party components

| Component | License | Use |
|-----------|---------|-----|
| [Cascadia Code](https://github.com/microsoft/cascadia-code) (`assets/fonts/`) | SIL OFL 1.1 | Terminal/editor font |
| [xterm.dart](https://github.com/TerminalStudio/xterm.dart) (`third_party/xterm/`, patched) | MIT | Terminal emulator |

These components are distributed alongside the app under their own licenses.
