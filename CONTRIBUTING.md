# Contributing to KALA

Thank you for your interest in contributing! KALA is a young project and every kind of contribution helps: bug reports, feature ideas, documentation, translations, and of course code.

*¿Prefieres escribir en español? Ningún problema — los issues y PRs en español son bienvenidos.*

## Ways to contribute

- **Report bugs** using the [bug report template](../../issues/new/choose). Include your device, Android/Linux version, and steps to reproduce.
- **Propose features** through a feature request issue *before* writing code, so we can discuss the approach.
- **Improve docs** — READMEs, code comments, this file.
- **Translate** — the UI ships in Spanish, English and Simplified Chinese. Spanish is
  the source language: every `tr('…')` key *is* the Spanish text, and a new language is
  one `strings_<code>.dart` table plus an entry in `AppLang`. A partial table is safe —
  anything missing falls back to Spanish.
- **Write tests** — there is a suite under `test/` (run it with `flutter test`). Gaps are
  still plenty, and a test that pins down a gesture, a parser or a layout invariant is
  one of the most valuable things you can send.

## Development setup

1. Fork and clone the repo:

   ```bash
   git clone https://github.com/<your-user>/Kammel_ssh.git
   cd Kammel_ssh
   ```

2. Use **Flutter 3.44.4** (Dart 3.12+) — the version CI builds with:

   ```bash
   flutter pub get
   flutter run -d linux      # or -d <android-device-id>
   ```

   Two packages are vendored under `third_party/` and wired through
   `dependency_overrides`: a patched `xterm` and a patched `dartssh2`. `pub get`
   picks them up automatically — don't replace them with the upstream versions,
   the patches are load-bearing (see [CLAUDE.md](CLAUDE.md)).

3. Before opening a PR, run what CI runs:

   ```bash
   flutter analyze --no-fatal-infos
   flutter test
   ```

   Both must pass — CI runs them on every PR and the result is a required check
   on `main`. The analyzer still reports pre-existing *infos* (deprecated
   `withOpacity` calls); those are tracked separately and don't fail the build.

## Project conventions

These come from the existing codebase — please follow them so the project stays coherent. A longer architecture walkthrough lives in [CLAUDE.md](CLAUDE.md).

### State management

- All app state lives in a single `ChangeNotifier`: `AppState` (`lib/providers/app_state.dart`), provided at the root with `provider`.
- **Do not** introduce other state-management layers (bloc, riverpod, getx…). Extend `AppState` for anything that must survive tab switches.

### Local/remote duality

File and editor features must work both locally (`dart:io`) and remotely (SFTP via `dartssh2`), branching on `session.connectionStatus == ConnectionStatus.remote` and normalizing into the shared models. Look at `_loadFilesForSession`, `openFile` and `saveCurrentFile` for the pattern.

### UI & styling

- Hand-rolled flat dark theme with hardcoded constants: background `0xFF0D0D0D`, surface `0xFF1E1E1E`, borders `0xFF333333`, muted text `0xFF9CA3AF`, primary azure `0xFF007AFF`, 4 px border radii, small uppercase letter-spaced labels. Match these instead of default Material styling.
- UI copy is authored in **Spanish** and wrapped in `tr('…')` (`lib/l10n/l10n.dart`).
  The Spanish text *is* the lookup key, so never write a bare user-facing string —
  and note that `tr()` is not a `const` expression, so a widget holding one can't
  be `const`.

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
