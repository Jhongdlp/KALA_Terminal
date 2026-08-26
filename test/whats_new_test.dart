import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:terminal_agent/l10n/l10n.dart';
import 'package:terminal_agent/views/release_notes_view.dart';

/// The GitHub release body used to reach the user as a wall of literal `##`,
/// `-` and `**`. What matters is that the markers are gone and the words are
/// not — an unrecognised construct must still show its text.
Future<void> _pump(WidgetTester tester, String markdown) async {
  // L10n.load() reads SharedPreferences; without the mock the channel has no
  // handler and the await never completes.
  SharedPreferences.setMockInitialValues({});
  L10n.notifier.value = AppLang.es;
  await L10n.load();
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: ReleaseNotesView(markdown)),
    ),
  ));
}

/// Every string the widget actually renders, spans included.
List<String> _rendered(WidgetTester tester) {
  final out = <String>[];
  for (final w in tester.widgetList<RichText>(find.byType(RichText))) {
    out.add(w.text.toPlainText());
  }
  return out;
}

void main() {
  testWidgets('headings lose their hashes and keep their words',
      (tester) async {
    await _pump(tester, '## Added\n- Something new');
    final text = _rendered(tester).join('\n');
    expect(text, contains('ADDED'));
    expect(text, isNot(contains('##')));
  });

  testWidgets('bullets lose their dash and keep their text', (tester) async {
    await _pump(tester, '- First thing\n* Second thing\n+ Third thing');
    final text = _rendered(tester).join('\n');
    for (final item in ['First thing', 'Second thing', 'Third thing']) {
      expect(text, contains(item));
    }
    expect(text, isNot(contains('- First')));
    expect(text, isNot(contains('* Second')));
  });

  testWidgets('bold and code markers are consumed, not printed',
      (tester) async {
    await _pump(tester, '- A **bold** word and `some code`');
    final text = _rendered(tester).join('\n');
    expect(text, contains('bold'));
    expect(text, contains('some code'));
    expect(text, isNot(contains('**')));
    expect(text, isNot(contains('`')));
  });

  testWidgets('bold really is bold, not merely stripped', (tester) async {
    await _pump(tester, '- A **bold** word');
    final spans = <InlineSpan>[];
    tester
        .widget<RichText>(find.byType(RichText).last)
        .text
        .visitChildren((s) {
      spans.add(s);
      return true;
    });
    final bold = spans.whereType<TextSpan>().where(
        (s) => s.text == 'bold' && s.style?.fontWeight == FontWeight.w700);
    expect(bold, isNotEmpty);
  });

  testWidgets('an unrecognised construct still shows its words',
      (tester) async {
    // A table, a quote, a link — none of them are handled, and all of them
    // must still be readable rather than dropped.
    await _pump(tester, '> quoted line\n[a link](https://example.com)');
    final text = _rendered(tester).join('\n');
    expect(text, contains('quoted line'));
    expect(text, contains('a link'));
  });

  testWidgets('an empty body renders nothing rather than crashing',
      (tester) async {
    await _pump(tester, '');
    expect(_rendered(tester), isEmpty);
  });

  testWidgets('a real GitHub body survives end to end', (tester) async {
    await _pump(tester, '''
## Added
- **Agents dashboard**: one screen showing what every session is doing.
- Jump hosts (`ProxyJump`).

## Fixed
- Keyboard bugs.

_Released 2026-08-26._
''');
    final text = _rendered(tester).join('\n');
    expect(text, contains('ADDED'));
    expect(text, contains('FIXED'));
    expect(text, contains('Agents dashboard'));
    expect(text, contains('ProxyJump'));
    expect(text, contains('Keyboard bugs.'));
    expect(text, isNot(contains('#')));
    expect(text, isNot(contains('**')));
  });
}
