/// What changed in each release, shipped **inside the build**.
///
/// The app used to say nothing about what an update brought. The GitHub
/// release body was shown once, before installing, in whatever language the
/// release was written in — and then never again. Someone three versions
/// behind got only the newest body, and nobody could look up what changed
/// after the fact.
///
/// Keeping the changelog in the app fixes both halves at once:
///
/// - **It is translated like every other string.** The text below is written in
///   Spanish (the source language) and drawn through `tr()`, so it follows the
///   user's language with no extra machinery. A missing translation falls back
///   to Spanish, exactly like the rest of the UI.
/// - **It can be shown at the right moment** — after the update landed, not
///   before — and it can show *every* version the user skipped, not just the
///   newest. See `lib/views/whats_new_sheet.dart`.
///
/// The pre-install dialog still shows the GitHub body, because a build cannot
/// carry the notes of a version that did not exist when it shipped. That body
/// is generated **in English** from this same table by
/// `scripts/changelog_notes.py`, so the two never drift apart and a user in any
/// language gets at worst English there and their own language once installed.
///
/// `scripts/i18n_check.py` reports these strings as unused: it only sees
/// literal `tr('…')` calls and these go through `tr(change.text)`. They are
/// not unused — `test/changelog_test.dart` fails if any of them loses a
/// translation.
library;

import '../l10n/l10n.dart';

/// The kind of change, which is also how entries are grouped in the sheet.
///
/// Deliberately only three. A user reading a phone screen wants "what can I do
/// now / what got better / what stopped breaking"; finer categories (docs,
/// chore, refactor) are release-engineering vocabulary and belong in the git
/// log, not in front of the user.
enum ChangeKind { added, improved, fixed }

extension ChangeKindLabel on ChangeKind {
  String get label => switch (this) {
        ChangeKind.added => tr('NUEVO'),
        ChangeKind.improved => tr('MEJOR'),
        ChangeKind.fixed => tr('ARREGLADO'),
      };

  /// Stable key used by the release-note generator, so renaming a label can't
  /// change the generated markdown.
  String get key => switch (this) {
        ChangeKind.added => 'added',
        ChangeKind.improved => 'improved',
        ChangeKind.fixed => 'fixed',
      };
}

class ChangeEntry {
  final ChangeKind kind;

  /// Spanish source text, drawn as `tr(text)`.
  final String text;

  const ChangeEntry(this.kind, this.text);
}

class ReleaseNote {
  /// Dotted version, matching the `version:` name in `pubspec.yaml` and the
  /// release tag without its leading `v`.
  final String version;

  /// ISO date (`YYYY-MM-DD`) the release was tagged.
  final String date;

  final List<ChangeEntry> changes;

  const ReleaseNote({
    required this.version,
    required this.date,
    required this.changes,
  });
}

/// Every release, **newest first**.
///
/// The top entry is the version being prepared: `scripts/release.sh` refuses to
/// publish a version that has no entry here, which is the forcing function that
/// keeps this file from rotting. Entries newer than the running build are
/// filtered out at display time, so a prepared-but-unreleased entry is never
/// shown as if it had shipped.
const List<ReleaseNote> kChangelog = [
  ReleaseNote(
    version: '2.10.1',
    date: '2026-08-27',
    changes: [
      ChangeEntry(ChangeKind.fixed,
          'El scroll dejaba de funcionar en agentes que activan y desactivan el ratón (Antigravity y otros): deslizar mandaba flechas al prompt y te reescribía lo que estabas tecleando. Arreglado.'),
      ChangeEntry(ChangeKind.fixed,
          'El lanzador de Antigravity usaba un comando que no existe; ahora abre «agy».'),
      ChangeEntry(ChangeKind.improved,
          'Mantén pulsado en la terminal y el menú radial del pad se abre solo, sin el gesto oculto de antes.'),
      ChangeEntry(ChangeKind.improved,
          'La capa ACCIONES del teclado rápido va primero y es la que aparece al abrir la barra.'),
      ChangeEntry(ChangeKind.added,
          'Nuevo ajuste para desactivar el scroll con flechas en apps de pantalla completa (Ajustes → Terminal).'),
    ],
  ),
  ReleaseNote(
    version: '2.10.0',
    date: '2026-08-26',
    changes: [
      ChangeEntry(ChangeKind.added,
          'Tablero de agentes: una pantalla con lo que está haciendo cada sesión y cuál se detuvo a preguntarte algo.'),
      ChangeEntry(ChangeKind.added,
          'Responde al agente desde el propio tablero, sin entrar en la sesión. Las máquinas de producción piden confirmación.'),
      ChangeEntry(ChangeKind.added,
          'Color por máquina: marca un perfil con un color (y opcionalmente como producción) y se distingue en toda la app.'),
      ChangeEntry(ChangeKind.added,
          'Servidores de salto (ProxyJump): llega a máquinas que solo responden desde dentro, encadenando por un bastión.'),
      ChangeEntry(ChangeKind.added,
          'Importa servidores desde tu ~/.ssh/config, incluidos sus saltos.'),
      ChangeEntry(ChangeKind.added,
          'Lanzadores de agente: abre Claude, Codex o el que quieras con un toque, cada uno con su comando y sus banderas.'),
      ChangeEntry(ChangeKind.added,
          'Esta pantalla de novedades, con el historial de versiones y en tu idioma.'),
    ],
  ),
  ReleaseNote(
    version: '2.9.0',
    date: '2026-08-25',
    changes: [
      ChangeEntry(ChangeKind.added, 'La app habla chino simplificado.'),
      ChangeEntry(ChangeKind.improved,
          'Traducciones que faltaban en varias pantallas.'),
    ],
  ),
  ReleaseNote(
    version: '2.8.1',
    date: '2026-08-21',
    changes: [
      ChangeEntry(ChangeKind.improved, 'La terminal va más fina.'),
      ChangeEntry(ChangeKind.fixed,
          'Fallos del teclado y del dock lateral del explorador.'),
    ],
  ),
  ReleaseNote(
    version: '2.8.0',
    date: '2026-08-19',
    changes: [
      ChangeEntry(ChangeKind.added,
          'Busca dentro de la salida de la terminal.'),
      ChangeEntry(ChangeKind.added,
          'Atajos de teclado físico y paleta de comandos.'),
      ChangeEntry(ChangeKind.added,
          'Grupos para organizar las conexiones cuando son muchas.'),
      ChangeEntry(ChangeKind.added,
          'Copia de seguridad y restauración de tus ajustes y perfiles.'),
    ],
  ),
  ReleaseNote(
    version: '2.7.0',
    date: '2026-08-17',
    changes: [
      ChangeEntry(ChangeKind.added,
          'Joystick de flechas: mantén pulsado y arrastra para moverte por el historial.'),
      ChangeEntry(ChangeKind.added,
          'Barra de dictado, para hablarle al agente en vez de escribir.'),
      ChangeEntry(ChangeKind.added, 'Variables en los prompts guardados.'),
    ],
  ),
  ReleaseNote(
    version: '2.6.0',
    date: '2026-08-07',
    changes: [
      ChangeEntry(ChangeKind.added,
          'Interfaz de escritorio: paneles redimensionables y barra de título propia.'),
      ChangeEntry(ChangeKind.added,
          'Panel de Git: estado, diff y commits sin salir de la app.'),
    ],
  ),
];

/// Comparison used everywhere versions are ordered. True when [a] is strictly
/// newer than [b]; non-numeric parts count as 0, matching `UpdateService`.
bool isVersionNewer(String a, String b) {
  final pa = a.split('.');
  final pb = b.split('.');
  final len = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < len; i++) {
    final na = i < pa.length ? (int.tryParse(pa[i]) ?? 0) : 0;
    final nb = i < pb.length ? (int.tryParse(pb[i]) ?? 0) : 0;
    if (na != nb) return na > nb;
  }
  return false;
}

/// Releases the user has actually got — everything at or below [current].
///
/// The filter is what makes it safe to write next release's entry before it
/// ships: a prepared version is never announced as if it were installed.
List<ReleaseNote> changelogUpTo(String current) =>
    kChangelog.where((r) => !isVersionNewer(r.version, current)).toList();

/// What to show after an update: every release newer than [seen], capped at
/// [current].
///
/// Empty when [seen] is already up to date, and empty when [seen] is null —
/// a fresh install has no "what changed", it has onboarding.
List<ReleaseNote> changelogSince(String? seen, String current) {
  if (seen == null) return const [];
  return changelogUpTo(current)
      .where((r) => isVersionNewer(r.version, seen))
      .toList();
}
