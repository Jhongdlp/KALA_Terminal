# KALA

> A mobile-first terminal, SSH client, file explorer and code editor — all in one Flutter app for Android and Linux.

[Leer en español](README.es.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.44-02569B?logo=flutter)](https://flutter.dev)
[![Platforms](https://img.shields.io/badge/platforms-Android%20%7C%20Linux-green)]()
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

KALA turns your phone into a real development machine. It combines a multi-session terminal emulator, an SSH connection manager, a remote file explorer and a syntax-highlighting code editor behind a single dark, IDE-style interface.

## ✨ Features

- **SSH connection manager** — save connection profiles (host, port, user, password or private key). Secrets are stored in the Android Keystore / libsecret via secure storage, never in plain text.
- **Multi-session terminals** — run several SSH sessions side by side, switch between them with one tap, rename and close them like browser tabs.
- **Image pasting in the terminal** — paste images directly from clipboard or keyboards like Gboard. It automatically uploads them via SFTP as `pasted_image_timestamp.png` in the active directory, types the filename in the terminal prompt, and refreshes the explorer.
- **Remote file explorer** — browse the remote filesystem over SFTP. Open, navigate and edit files.
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

`targetSdk` is intentionally pinned to **28** in `android/app/build.gradle.kts` for legacy shared storage compatibility.

## 🏗 Architecture overview

```
lib/
├── main.dart              # App entry, root Provider
├── providers/
│   └── app_state.dart     # Single ChangeNotifier holding ALL app state
├── models/                # ConnectionProfile, session/file models
├── services/
│   ├── secure_store.dart      # Keystore/libsecret-backed secure storage
│   └── background_service.dart
├── theme/                 # Dark IDE theme + editor highlight themes
├── views/                 # One file per tab (terminal, explorer, editor…)
└── widgets/
```

Key design decisions:

- **Single source of truth**: all state lives in `AppState` (`ChangeNotifier` + `provider`). New stateful features should extend `AppState`, not add local widget state that dies on tab switches.
- **Sessions**: `AppState` holds a list of `TerminalSession`s, each owning its own `xterm.Terminal` plus an SSH client (`dartssh2`). Only one session is active at a time.
- **SFTP Integration**: file listing, navigation and editing are performed remotely over SFTP.

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
| [Cascadia Code](https://github.com/microsoft/cascadia-code) (`assets/fonts/`) | SIL OFL 1.1 | Terminal/editor font |

These components are distributed alongside the app under their own licenses.
