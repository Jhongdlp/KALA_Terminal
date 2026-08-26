import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:terminal_agent/l10n/l10n.dart';
import 'package:terminal_agent/l10n/strings_en.dart';
import 'package:terminal_agent/l10n/strings_zh.dart';

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

  // Every table mirrors the Spanish key set, so the same invariants have to
  // hold for each one — a third language must not be able to regress quietly.
  const tables = <String, Map<String, String>>{
    'strings_en.dart': enStrings,
    'strings_zh.dart': zhStrings,
  };

  tables.forEach((name, table) {
    group(name, () {
      test('keeps every placeholder of the Spanish key', () {
        final placeholder = RegExp(r'\{\d+\}');
        final broken = <String>[];
        table.forEach((es, translated) {
          final a = placeholder.allMatches(es).map((m) => m[0]!).toSet();
          final b =
              placeholder.allMatches(translated).map((m) => m[0]!).toSet();
          if (a.length != b.length || !a.containsAll(b)) broken.add(es);
        });
        expect(broken, isEmpty,
            reason: 'la traducción perdió o inventó un placeholder');
      });

      test('has no empty translations', () {
        expect(
            table.entries
                .where((e) => e.value.trim().isEmpty)
                .map((e) => e.key),
            isEmpty);
      });

      test('covers exactly the same keys as every other table', () {
        for (final other in tables.entries) {
          expect(table.keys.toSet(), other.value.keys.toSet(),
              reason: '$name y ${other.key} no cubren las mismas claves');
        }
      });
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
