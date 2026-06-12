# Contributing to KALA

Thank you for your interest in contributing! KALA is a young project and every kind of contribution helps: bug reports, feature ideas, documentation, translations, and of course code.

*¿Prefieres escribir en español? Ningún problema — los issues y PRs en español son bienvenidos.*

## Ways to contribute

- **Report bugs** using the [bug report template](../../issues/new/choose). Include your device, Android/Linux version, and steps to reproduce.
- **Propose features** through a feature request issue *before* writing code, so we can discuss the approach.
- **Improve docs** — READMEs, code comments, this file.
- **Translate** — the UI is currently Spanish-only; help with i18n is very welcome.
- **Write tests** — the project currently has no real test suite (see Roadmap), so tests are one of the most valuable contributions.

## Development setup

1. Fork and clone the repo:

   ```bash
   git clone https://github.com/<your-user>/TerminalAI.git
   cd TerminalAI
   ```

2. Use Flutter 3.44+ / Dart 3.12+. The repo vendors a full Flutter SDK at `sdk/flutter` — if you don't have a matching Flutter on your `PATH`, just use it directly:

   ```bash
   sdk/flutter/bin/flutter pub get
   sdk/flutter/bin/flutter run -d linux
   ```

3. Before opening a PR, make sure the analyzer is clean:

   ```bash
   flutter analyze
   ```

> **Note:** `flutter test` currently fails because `test/widget_test.dart` is still the default Flutter template. Don't worry about it unless your PR adds tests (please do!).

## Project conventions

These come from the existing codebase — please follow them so the project stays coherent. A longer architecture walkthrough lives in [CLAUDE.md](CLAUDE.md).

### State management

- All app state lives in a single `ChangeNotifier`: `AppState` (`lib/providers/app_state.dart`), provided at the root with `provider`.
- **Do not** introduce other state-management layers (bloc, riverpod, getx…). Extend `AppState` for anything that must survive tab switches.

### Local/remote duality

File and editor features must work both locally (`dart:io`) and remotely (SFTP via `dartssh2`), branching on `session.connectionStatus == ConnectionStatus.remote` and normalizing into the shared models. Look at `_loadFilesForSession`, `openFile` and `saveCurrentFile` for the pattern.

### UI & styling

- Hand-rolled flat dark theme with hardcoded constants: background `0xFF0D0D0D`, surface `0xFF1E1E1E`, borders `0xFF333333`, muted text `0xFF9CA3AF`, primary azure `0xFF007AFF`, 4 px border radii, small uppercase letter-spaced labels. Match these instead of default Material styling.
- UI copy is currently in **Spanish**.

### Android specifics

- `targetSdk` is pinned to **28** on purpose — API 29+ blocks exec() from app data directories and kills the proot/Alpine local terminal. Don't raise it.
- The local Android terminal is a real Alpine userland bootstrapped by `DistroService` (`lib/services/distro_service.dart`); the binaries/rootfs live in `assets/distro/`.

### Secrets

Passwords and private keys go through `SecureStore` (`lib/services/secure_store.dart`), never into plain `shared_preferences`. Only non-secret profile metadata may live in shared preferences.

## Pull request workflow

1. Create a topic branch from `main`: `git checkout -b feat/my-feature`.
2. Keep PRs focused — one feature or fix per PR.
3. Use clear commit messages, ideally [Conventional Commits](https://www.conventionalcommits.org/) style (`feat:`, `fix:`, `docs:`, `refactor:`…) — that's what the existing history uses.
4. Run `flutter analyze` and make sure it's clean.
5. If your change affects the UI, attach a screenshot or screen recording to the PR.
6. Fill in the PR template and link the related issue (`Fixes #123`).

A maintainer will review your PR. Reviews may take some time — this is a spare-time project — but every PR will get a response.

## Code of Conduct

By participating you agree to follow our [Code of Conduct](CODE_OF_CONDUCT.md).

## Security issues

Please **do not** open public issues for vulnerabilities. Follow [SECURITY.md](SECURITY.md) instead.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
