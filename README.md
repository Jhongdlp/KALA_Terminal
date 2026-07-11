# KALA

> A mobile-first terminal, SSH client, file explorer and code editor — all in one Flutter app for Android and Linux.

[Leer en español](README.es.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.44-02569B?logo=flutter)](https://flutter.dev)
[![Platforms](https://img.shields.io/badge/platforms-Android%20%7C%20Linux-green)]()
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

KALA turns your phone into a real development machine. It combines a multi-session terminal emulator, an SSH connection manager, a local/remote file explorer and a syntax-highlighting code editor behind a single dark, IDE-style interface.

## ✨ Features

- **Real Linux terminal on Android** — not a fake shell. KALA bundles [proot](https://proot-me.github.io/) and an [Alpine Linux](https://alpinelinux.org/) mini rootfs, so the local terminal is a full userland with `apk` package management. Install `git`, `python`, `nodejs`… directly on your phone, no root required.
- **Multi-session terminals** — run several local and SSH sessions side by side, switch between them with one tap, rename and close them like browser tabs.
- **Image pasting in the terminal** — paste images directly from clipboard or keyboards like Gboard. It automatically saves/uploads them (via SFTP for remote sessions) as `pasted_image_timestamp.png` in the active directory, types the filename in the terminal prompt, and refreshes the explorer.
- **SSH connection manager** — save connection profiles (host, port, user, password or private key). Secrets are stored in the Android Keystore / libsecret via secure storage, never in plain text.
- **Dual local/remote file explorer** — browse the local filesystem or the remote one over SFTP with the same UI. Open, navigate and edit files wherever they live.
- **Code editor** — powered by [re_editor](https://pub.dev/packages/re_editor) with syntax highlighting, dirty-state tracking, and transparent save-back over SFTP for remote files.
- **Unified Cloud-Console Server Dashboard** — monitor system resources (CPU, RAM, Disk, services) and fully manage Docker containers, images, volumes, networks, compose, and system configurations.
- **Native Office and external document viewer** — open Word, Excel, PowerPoint, EPUB, ZIP, and APK files natively using the system's apps. Remote files are downloaded to temporary files and cleaned up automatically.
- **Built-in viewers** — render Markdown and PDF files without leaving the app.
- **Smart keyboard** — a quick-input row above the terminal with Ctrl+C, arrows, tab and common commands, designed for touch screens.
- **IDE-style dark theme** — flat dark UI with Cascadia Code as the terminal font.

## 📱 Platforms

| Platform | Status |
|----------|--------|
| Android  | ✅ Supported (the main target) |
| Linux    | ✅ Supported (desktop) |
| iOS / Windows / macOS | ❌ Not configured |

## 🚀 Getting started

### Prerequisites

- [Flutter](https://docs.flutter.dev/get-started/install) 3.44+ (Dart 3.12+).
  This repo vendors a full Flutter SDK at `sdk/flutter`; if you don't have Flutter on your `PATH`, use `sdk/flutter/bin/flutter` instead of `flutter` in the commands below.
- For Android builds: Android SDK + an Android device or emulator.
- For Linux builds: the standard [Flutter Linux desktop dependencies](https://docs.flutter.dev/platform-integration/linux/setup) (`clang`, `cmake`, `ninja-build`, `libgtk-3-dev`, …).

### Build and run

```bash
git clone https://github.com/Jhongdlp/TerminalAI.git
cd TerminalAI

flutter pub get

# Run on Linux desktop
flutter run -d linux

# Run on Android
flutter run -d <android-device-id>

# Release builds
flutter build apk          # Android
flutter build linux        # Linux
```

### A note on Android `targetSdk`

`targetSdk` is intentionally pinned to **28** in `android/app/build.gradle.kts`. From API 29 onward Android blocks executing binaries from the app's data directory, which breaks the bundled proot/Alpine terminal. Please don't raise it without reading the comment in that file first.

## 🏗 Architecture overview

```
lib/
├── main.dart              # App entry, root Provider
├── providers/
│   └── app_state.dart     # Single ChangeNotifier holding ALL app state
├── models/                # ConnectionProfile, session/file models
├── services/
│   ├── distro_service.dart    # proot + Alpine rootfs install & bootstrap
│   ├── secure_store.dart      # Keystore/libsecret-backed secret storage
│   └── background_service.dart
├── theme/                 # Dark IDE theme + editor highlight themes
├── views/                 # One file per tab (terminal, explorer, editor…)
└── widgets/
```

Key design decisions:

- **Single source of truth**: all state lives in `AppState` (`ChangeNotifier` + `provider`). New stateful features should extend `AppState`, not add local widget state that dies on tab switches.
- **Sessions**: `AppState` holds a list of `TerminalSession`s, each owning its own `xterm.Terminal` plus either a local PTY (`flutter_pty`) or an SSH client (`dartssh2`). Only one session is active at a time.
- **Local/remote duality**: file listing, navigation and editing branch on the session's `ConnectionStatus` — `dart:io` locally, SFTP remotely — and normalize into the same models. New file/editor features must follow this dual-path pattern.

See [CLAUDE.md](CLAUDE.md) for a deeper architecture walkthrough.

## 🗺 Roadmap

- [ ] Distro selector (Alpine / Ubuntu / Debian) — see `docs/selector-de-distros.md`
- [ ] Port forwarding / SSH tunnels
- [ ] Editor: search & replace, multi-file tabs
- [ ] Translations (the UI is currently Spanish)
- [ ] Real test suite (the current `widget_test.dart` is still the Flutter template)

Have an idea? [Open a feature request](../../issues/new/choose).

## 🤝 Contributing

Contributions are very welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, coding conventions and how to set up your environment, and our [Code of Conduct](CODE_OF_CONDUCT.md).

Found a security issue? Please follow [SECURITY.md](SECURITY.md) instead of opening a public issue.

## 📄 License

This project is licensed under the [MIT License](LICENSE).

### Bundled third-party components

| Component | License | Use |
|-----------|---------|-----|
| [proot](https://github.com/proot-me/proot) (prebuilt binary in `assets/distro/`) | GPL-2.0 | User-space chroot for the Android terminal |
| [Alpine Linux mini rootfs](https://alpinelinux.org/) (`assets/distro/`) | Various (MIT/GPL per package) | Local Linux userland |
| [Cascadia Code](https://github.com/microsoft/cascadia-code) (`assets/fonts/`) | SIL OFL 1.1 | Terminal/editor font |

These components are distributed alongside the app under their own licenses.
