import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:terminal_agent/l10n/l10n.dart';
import 'package:terminal_agent/main.dart';
import 'package:terminal_agent/providers/app_state.dart';
import 'package:terminal_agent/services/tunnel_manager.dart';
import 'package:terminal_agent/theme/app_theme.dart';

/// The checked radio must sit on the same row as the given language label.
void _expectCheckedRadioOn(WidgetTester tester, String label) {
  final checked = find.byIcon(Icons.radio_button_checked);
  expect(checked, findsOneWidget);
  expect(
    tester.getCenter(checked).dy,
    moreOrLessEquals(tester.getCenter(find.text(label)).dy, epsilon: 2),
  );
}

Future<AppState> _pumpApp(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  L10n.notifier.value = AppLang.es;
  await L10n.load();
  final state = AppState();

  // An explicit surface rather than the 800x600 default: these tests look for
  // controls partway down a settings list, and a ListView only builds what fits
  // its viewport. Narrow enough to stay on the compact layout (< 900), tall
  // enough that the desktop window title bar can't push a control out of range.
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(800, 1400);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: state),
        ChangeNotifierProvider<TunnelManager>.value(value: state.tunnels),
      ],
      child: const MyApp(),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

void main() {
  // A language change has to remount the tree: `tr()` reads a global, so a
  // widget that depends on no InheritedWidget (a const panel, a plain Text)
  // would otherwise never rebuild and would keep the old language.
  testWidgets('the language picker follows the language it just set',
      (tester) async {
    final state = await _pumpApp(tester);
    addTearDown(() => L10n.notifier.value = AppLang.es);

    state.setActiveTabIndex(5); // Ajustes
    await tester.pumpAndSettle();
    _expectCheckedRadioOn(tester, 'Español');

    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();

    expect(L10n.lang, AppLang.en);
    expect(find.text('SETTINGS'), findsWidgets);
    _expectCheckedRadioOn(tester, 'English');

    await tester.tap(find.text('Español'));
    await tester.pumpAndSettle();

    expect(L10n.lang, AppLang.es);
    expect(find.text('AJUSTES'), findsWidgets);
    _expectCheckedRadioOn(tester, 'Español');
  });

  testWidgets('the shortcut layout dropdown shows the layout it just set',
      (tester) async {
    final state = await _pumpApp(tester);

    state.setActiveTabIndex(6); // Personalizar
    await tester.pumpAndSettle();

    final dropdown = find.byType(DropdownButton<TerminalShortcutLayout>);
    expect(dropdown, findsOneWidget);
    expect(
      tester.widget<DropdownButton<TerminalShortcutLayout>>(dropdown).value,
      TerminalShortcutLayout.classic,
    );

    // Same path the dropdown's onChanged takes; the panel has to follow it.
    await state.setShortcutLayout(TerminalShortcutLayout.dpadLeft);
    await tester.pumpAndSettle();

    expect(
      tester.widget<DropdownButton<TerminalShortcutLayout>>(dropdown).value,
      TerminalShortcutLayout.dpadLeft,
    );
  });
}
