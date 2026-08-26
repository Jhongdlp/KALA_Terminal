import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../models/changelog.dart';
import '../theme/app_theme.dart';
import '../widgets/adaptive_sheet.dart';
import '../widgets/swiss.dart';

/// Last app version whose changes the user has been shown.
///
/// Deliberately **not** prefixed `settings_`, so `BackupService` leaves it
/// alone: "have I already read this" belongs to the install, not to the
/// account. Restoring a backup onto a fresh phone should not swallow the
/// notes for a version that phone has never run.
const String kWhatsNewSeenKey = 'whats_new_seen_version';

/// Shows what changed since the user last opened the app, then records the
/// current version as seen.
///
/// Called once per launch from the shell. It stays quiet in the two cases that
/// matter:
///
/// - **Fresh install** — nothing is stored yet, so there is no "what changed";
///   there is onboarding, and stacking a changelog on top of it would bury it.
///   The current version is recorded silently so the *next* update does speak.
/// - **Nothing new** — the stored version is already the running one.
Future<void> maybeShowWhatsNew(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  final info = await PackageInfo.fromPlatform();
  final current = info.version;
  final seen = prefs.getString(kWhatsNewSeenKey);

  // Written *before* the sheet opens, for the same reason onboarding does it:
  // a language change remounts the tree, and a flag written afterwards would
  // let the sheet come back a second time.
  await prefs.setString(kWhatsNewSeenKey, current);

  final notes = changelogSince(seen, current);
  if (notes.isEmpty) return;
  if (!context.mounted) return;

  await _show(context, notes, justUpdated: true);
}

/// The full history, from Acerca de. Always available, so a user who dismissed
/// the sheet — or who wants to know what a version they skipped brought — can
/// still find out.
Future<void> showChangelog(BuildContext context) async {
  final info = await PackageInfo.fromPlatform();
  if (!context.mounted) return;
  await _show(context, changelogUpTo(info.version), justUpdated: false);
}

Future<void> _show(
  BuildContext context,
  List<ReleaseNote> notes, {
  required bool justUpdated,
}) {
  return showAdaptiveSheet(
    context,
    backgroundColor: AppColors.panel,
    isScrollControlled: true,
    maxWidth: 560,
    builder: (ctx) => _WhatsNewBody(notes: notes, justUpdated: justUpdated),
  );
}

class _WhatsNewBody extends StatelessWidget {
  final List<ReleaseNote> notes;
  final bool justUpdated;

  const _WhatsNewBody({required this.notes, required this.justUpdated});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        justUpdated ? tr('NOVEDADES') : tr('HISTORIAL'),
                        style: AppText.label(12,
                            color: AppColors.bone, spacing: 1.6),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        justUpdated
                            ? tr('Esto es lo que ha cambiado desde tu última versión.')
                            : tr('Todo lo que ha cambiado, versión a versión.'),
                        style: AppText.body(11, color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close, size: 18, color: AppColors.muted),
                  tooltip: tr('Cerrar'),
                ),
              ],
            ),
          ),
          const Hairline(),
          Flexible(
            child: notes.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(tr('Todavía no hay novedades que contar.'),
                        style: AppText.body(12, color: AppColors.muted)),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: notes.length,
                    separatorBuilder: (_, _) => const Hairline(),
                    itemBuilder: (_, i) => _ReleaseBlock(
                      note: notes[i],
                      // Only the newest block is opened by default: three
                      // skipped versions expanded at once is a wall of text
                      // nobody reads.
                      highlighted: i == 0,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ReleaseBlock extends StatelessWidget {
  final ReleaseNote note;
  final bool highlighted;

  const _ReleaseBlock({required this.note, required this.highlighted});

  @override
  Widget build(BuildContext context) {
    // Grouped by kind rather than listed flat: "what can I do now" and "what
    // stopped breaking" are different questions, and the order answers the
    // first one first.
    final byKind = <ChangeKind, List<ChangeEntry>>{};
    for (final change in note.changes) {
      byKind.putIfAbsent(change.kind, () => []).add(change);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                note.version,
                style: AppText.mono(15,
                    color: highlighted ? AppColors.accent : AppColors.bone,
                    weight: FontWeight.w700),
              ),
              const SizedBox(width: 8),
              Text(note.date,
                  style: AppText.mono(9, color: AppColors.faint, spacing: 0.6)),
            ],
          ),
          const SizedBox(height: 10),
          for (final kind in ChangeKind.values)
            if (byKind[kind] != null) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: MonoTag(kind.label, bordered: true),
              ),
              for (final change in byKind[kind]!)
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 0, 0, 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 5, right: 8),
                        child: Container(
                            width: 3, height: 3, color: AppColors.muted),
                      ),
                      Expanded(
                        child: Text(
                          tr(change.text),
                          style: AppText.body(12, color: AppColors.bone),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 6),
            ],
        ],
      ),
    );
  }
}
