import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'strings_en.dart';

/// Languages the UI ships with. Spanish is the source language: every `tr()`
/// key *is* the Spanish text, so `AppLang.es` needs no dictionary and can never
/// show a missing translation.
enum AppLang {
  es('es', 'Español'),
  en('en', 'English');

  const AppLang(this.code, this.label);

  /// ISO-639-1 code, also what gets persisted.
  final String code;

  /// Name shown in the language picker, always in its own language.
  final String label;

  static AppLang fromCode(String? code) =>
      AppLang.values.firstWhere((l) => l.code == code, orElse: () => AppLang.es);
}

/// Runtime language switch.
///
/// Deliberately *not* part of [AppState]: `tr()` is called from services and
/// models that have no `BuildContext` and no provider, so the active language
/// has to be reachable as global state. [notifier] exists only so the widget
/// tree can be remounted when it changes (see `main.dart`).
class L10n {
  L10n._();

  static const _prefsKey = 'app_language';

  /// Listen to this to rebuild UI after a language change.
  static final ValueNotifier<AppLang> notifier = ValueNotifier(AppLang.es);

  static AppLang get lang => notifier.value;

  /// Reads the stored language. Call before `runApp` so the first frame is
  /// already in the right language.
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    notifier.value = AppLang.fromCode(prefs.getString(_prefsKey));
  }

  static Future<void> setLang(AppLang lang) async {
    if (notifier.value == lang) return;
    notifier.value = lang;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, lang.code);
  }
}

/// Translates [source] (Spanish, the source language) into the active language.
///
/// The Spanish text doubles as the lookup key, so an untranslated string falls
/// back to Spanish instead of showing a raw identifier.
///
/// [args] fills positional `{0}`, `{1}`… placeholders — use them instead of
/// string interpolation, otherwise the interpolated value ends up baked into
/// the key and the lookup never matches:
///
/// ```dart
/// Text(tr('Conectado a {0}', [host]))
/// ```
String tr(String source, [List<Object?>? args]) {
  var out = source;
  if (L10n.lang != AppLang.es) {
    final table = _tables[L10n.lang];
    final hit = table?[source];
    if (hit != null) {
      out = hit;
    } else {
      assert(() {
        if (!_reported.contains(source)) {
          _reported.add(source);
          debugPrint('[l10n] falta traducción (${L10n.lang.code}): $source');
        }
        return true;
      }());
    }
  }
  if (args != null) {
    for (var i = 0; i < args.length; i++) {
      out = out.replaceAll('{$i}', '${args[i]}');
    }
  }
  return out;
}

const Map<AppLang, Map<String, String>> _tables = {AppLang.en: enStrings};

/// Debug-only, so the same missing key isn't logged on every rebuild.
final Set<String> _reported = {};
