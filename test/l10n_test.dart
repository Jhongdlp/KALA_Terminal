import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:terminal_agent/l10n/l10n.dart';
import 'package:terminal_agent/l10n/strings_en.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    L10n.notifier.value = AppLang.es;
  });

  group('tr', () {
    test('Spanish is the source language, so it never looks anything up', () {
      expect(tr('Conectar'), 'Conectar');
      expect(tr('No existe en ningún diccionario'),
          'No existe en ningún diccionario');
    });

    test('translates through the English table', () async {
      await L10n.setLang(AppLang.en);
      expect(tr('Conectar'), 'Connect');
      expect(tr('Cancelar'), 'Cancel');
    });

    test('an untranslated key falls back to the Spanish text', () async {
      await L10n.setLang(AppLang.en);
      expect(tr('Una cadena que nadie tradujo'), 'Una cadena que nadie tradujo');
    });

    test('fills positional placeholders in both languages', () async {
      expect(tr('{0} activos', [3]), '3 activos');
      await L10n.setLang(AppLang.en);
      expect(tr('{0} activos', [3]), '3 running');
      expect(tr('No se pudo abrir el túnel {0}: {1}', ['-L 80', 'boom']),
          'Could not open tunnel -L 80: boom');
    });

    test('placeholders are filled even when the key is untranslated', () async {
      await L10n.setLang(AppLang.en);
      expect(tr('Sin traducir {0}', ['x']), 'Sin traducir x');
    });
  });

  group('strings_en.dart', () {
    test('keeps every placeholder of the Spanish key', () {
      final placeholder = RegExp(r'\{\d+\}');
      final broken = <String>[];
      enStrings.forEach((es, en) {
        final a = placeholder.allMatches(es).map((m) => m[0]!).toSet();
        final b = placeholder.allMatches(en).map((m) => m[0]!).toSet();
        if (a.length != b.length || !a.containsAll(b)) broken.add(es);
      });
      expect(broken, isEmpty,
          reason: 'la traducción perdió o inventó un placeholder');
    });

    test('has no empty translations', () {
      expect(enStrings.entries.where((e) => e.value.trim().isEmpty).map((e) => e.key),
          isEmpty);
    });
  });

  test('AppLang round-trips through its stored code', () {
    for (final lang in AppLang.values) {
      expect(AppLang.fromCode(lang.code), lang);
    }
    expect(AppLang.fromCode(null), AppLang.es);
    expect(AppLang.fromCode('klingon'), AppLang.es);
  });
}
