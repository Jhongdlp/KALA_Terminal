import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_agent/l10n/l10n.dart';
import 'package:terminal_agent/l10n/strings_en.dart';
import 'package:terminal_agent/l10n/strings_zh.dart';
import 'package:terminal_agent/models/changelog.dart';

/// The in-app changelog. Two things are pinned down here: the ordering rules
/// the "what's new" sheet depends on, and the translation obligation — these
/// strings go through `tr(change.text)`, so `scripts/i18n_check.py` cannot see
/// them and would happily let them rot back to Spanish.
void main() {
  group('table', () {
    test('is ordered newest first, with no repeats', () {
      for (var i = 1; i < kChangelog.length; i++) {
        expect(
          isVersionNewer(kChangelog[i - 1].version, kChangelog[i].version),
          isTrue,
          reason:
              '${kChangelog[i - 1].version} must be newer than ${kChangelog[i].version}',
        );
      }
    });

    test('every release is a dotted version, a real date and has changes', () {
      for (final release in kChangelog) {
        expect(RegExp(r'^\d+\.\d+\.\d+$').hasMatch(release.version), isTrue,
            reason: 'bad version: ${release.version}');
        expect(DateTime.tryParse(release.date), isNotNull,
            reason: 'bad date on ${release.version}: ${release.date}');
        expect(release.changes, isNotEmpty,
            reason: '${release.version} has no changes');
      }
    });
  });

  group('translations', () {
    // The point of shipping the changelog inside the app is that it follows
    // the user's language. An untranslated entry silently falls back to
    // Spanish, which is exactly the thing this feature exists to stop.
    final texts = <String>{
      for (final release in kChangelog)
        for (final change in release.changes) change.text,
    };

    test('every entry has an English translation', () {
      for (final text in texts) {
        expect(enStrings.containsKey(text), isTrue,
            reason: 'no English translation for: $text');
      }
    });

    test('every entry has a Chinese translation', () {
      for (final text in texts) {
        expect(zhStrings.containsKey(text), isTrue,
            reason: 'no Chinese translation for: $text');
      }
    });

    test('the kind labels are translated too', () {
      for (final kind in ChangeKind.values) {
        L10n.notifier.value = AppLang.es;
        final spanish = kind.label;
        expect(enStrings.containsKey(spanish), isTrue,
            reason: 'no English translation for kind label: $spanish');
        expect(zhStrings.containsKey(spanish), isTrue,
            reason: 'no Chinese translation for kind label: $spanish');
      }
    });
  });

  group('isVersionNewer', () {
    test('compares numerically, not as text', () {
      expect(isVersionNewer('2.10.0', '2.9.0'), isTrue);
      expect(isVersionNewer('2.9.0', '2.10.0'), isFalse);
      expect(isVersionNewer('2.9.0', '2.9.0'), isFalse);
      // Missing components count as zero, matching UpdateService.
      expect(isVersionNewer('2.9.1', '2.9'), isTrue);
      expect(isVersionNewer('2.9', '2.9.0'), isFalse);
    });
  });

  group('changelogUpTo', () {
    test('hides a version that has not shipped yet', () {
      // The top entry is written before the release; showing it as installed
      // would announce a feature the user does not have.
      final newest = kChangelog.first.version;
      expect(changelogUpTo(newest).first.version, newest);

      final older = kChangelog.length > 1 ? kChangelog[1].version : '0.0.1';
      final visible = changelogUpTo(older).map((r) => r.version);
      expect(visible, isNot(contains(newest)));
      expect(visible.first, older);
    });
  });

  group('changelogSince', () {
    test('a fresh install is told nothing — it gets onboarding instead', () {
      expect(changelogSince(null, kChangelog.first.version), isEmpty);
    });

    test('an up-to-date install is told nothing', () {
      final newest = kChangelog.first.version;
      expect(changelogSince(newest, newest), isEmpty);
    });

    test('skipping versions shows every one of them, not just the newest', () {
      if (kChangelog.length < 3) return;
      final current = kChangelog.first.version;
      final from = kChangelog[2].version;
      final shown = changelogSince(from, current).map((r) => r.version);
      expect(shown, [kChangelog[0].version, kChangelog[1].version]);
      // The version you were already on is not "new".
      expect(shown, isNot(contains(from)));
    });
  });
}
