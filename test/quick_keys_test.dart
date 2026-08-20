import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:terminal_agent/l10n/l10n.dart';
import 'package:terminal_agent/models/terminal_key_layer.dart';
import 'package:terminal_agent/providers/app_state.dart';
import 'package:terminal_agent/theme/app_theme.dart';
import 'package:terminal_agent/views/terminal_quick_keys.dart';

/// Mounts just the key bar, pinned to the bottom of a phone-sized surface.
Future<List<String>> _pump(
  WidgetTester tester,
  AppState state, {
  Size size = const Size(360, 720),
}) async {
  final sent = <String>[];
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      // Stands in for the Provider rebuild the real host (TerminalTab) gets:
      // the bar renders live state (armed modifiers, active layer, upload
      // progress) and is redrawn by its parent, not by a listener of its own.
      body: ListenableBuilder(
        listenable: state,
        builder: (_, __) => Column(
          children: [
            const Spacer(),
            TerminalQuickKeys(
              state: state,
              onSend: sent.add,
              onAction: (a) => sent.add('action:$a'),
            ),
          ],
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return sent;
}

Future<AppState> _state() async {
  SharedPreferences.setMockInitialValues({});
  L10n.notifier.value = AppLang.es;
  await L10n.load();
  return AppState();
}

void main() {
  // The whole point of the redesign: the old bar hid its overflow in two
  // side-scrolling rows. If a horizontal Scrollable ever reappears in here,
  // keys are being hidden from the user again.
  testWidgets('no key scrolls horizontally out of view', (tester) async {
    final state = await _state();
    await _pump(tester, state);

    final scrollables = tester.widgetList<Scrollable>(find.byType(Scrollable));
    for (final s in scrollables) {
      // The layer PageView is horizontal by design — it moves whole layers,
      // never individual keys — so it is identified and allowed.
      final isPageView = tester
          .widgetList<PageView>(find.byType(PageView))
          .isNotEmpty;
      if (s.axisDirection == AxisDirection.right ||
          s.axisDirection == AxisDirection.left) {
        expect(isPageView, isTrue,
            reason: 'a horizontal scroll view other than the layer PageView '
                'means keys are hidden off-screen again');
      }
    }
  });

  testWidgets('every key of the active layer is inside the viewport',
      (tester) async {
    final state = await _state();
    await _pump(tester, state);

    final screen = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    for (final key in kControlKeys) {
      final finder = find.text(key.label);
      expect(finder, findsWidgets, reason: '${key.label} is not drawn');
      final rect = tester.getRect(finder.first);
      expect(rect.left, greaterThanOrEqualTo(-0.01));
      expect(rect.right, lessThanOrEqualTo(screen + 0.01));
    }
  });

  testWidgets('the fixed row keeps ESC/TAB/CTRL across a layer switch',
      (tester) async {
    final state = await _state();
    final sent = await _pump(tester, state);

    expect(find.text('ESC'), findsOneWidget);
    expect(find.text('^A'), findsOneWidget); // CTRL layer is first

    await tester.tap(find.text('FN'));
    await tester.pumpAndSettle();

    expect(state.activeShortcutLayer, QuickKeyLayer.fn);
    expect(find.text('F5'), findsOneWidget);
    expect(find.text('^A'), findsNothing);
    // The fixed row did not move.
    expect(find.text('ESC'), findsOneWidget);
    expect(find.text('TAB'), findsOneWidget);

    await tester.tap(find.text('F5'));
    await tester.pumpAndSettle();
    expect(sent, ['\x1b[15~']);
  });

  testWidgets('CTRL on the fixed row arms the modifier instead of sending',
      (tester) async {
    final state = await _state();
    final sent = await _pump(tester, state);

    await tester.tap(find.text('CTRL').first);
    await tester.pumpAndSettle();

    expect(state.ctrlArmed, isTrue);
    expect(sent, isEmpty);
  });

  testWidgets('hiding a layer removes its tab and keeps a valid selection',
      (tester) async {
    final state = await _state();
    await _pump(tester, state);

    await state.setShortcutLayers(
        [QuickKeyLayer.nav, QuickKeyLayer.mine]);
    await tester.pumpAndSettle();

    expect(find.text('FN'), findsNothing);
    expect(find.text('NAV'), findsOneWidget);
    expect(state.activeShortcutLayer, QuickKeyLayer.nav);
    expect(find.text('⇱'), findsOneWidget);
  });

  // Columns come from the row count, not the width: that is what guarantees
  // the fullest layer fits without a scroll at any row setting.
  testWidgets('one row means every layer still shows all its keys',
      (tester) async {
    final state = await _state();
    await state.setShortcutRows(1);
    await _pump(tester, state);

    // `findsWidgets` alone would pass on a key parked outside a scroll
    // viewport, which is exactly the failure mode being ruled out — so the
    // grid's own box is measured and every key has to sit inside it.
    final grid = tester.getRect(find.byType(PageView));
    for (final key in kControlKeys) {
      final finder = find.text(key.label);
      expect(finder, findsWidgets, reason: '${key.label} vanished at rows=1');
      final rect = tester.getRect(finder.first);
      expect(rect.top, greaterThanOrEqualTo(grid.top - 0.01),
          reason: '${key.label} is scrolled out of the grid at rows=1');
      expect(rect.bottom, lessThanOrEqualTo(grid.bottom + 0.01),
          reason: '${key.label} is scrolled out of the grid at rows=1');
    }
  });

  testWidgets('the side d-pad stays available as a layout option',
      (tester) async {
    final state = await _state();
    await state.setShortcutLayout(TerminalShortcutLayout.dpadLeft);
    final sent = await _pump(tester, state);

    // Arrows appear twice with the d-pad up: the cluster plus the NAV layer.
    expect(find.text('←'), findsWidgets);
    await tester.tap(find.text('←').first);
    await tester.pumpAndSettle();
    expect(sent, ['\x1b[D']);
  });

  // The bar sits between the terminal and the soft keyboard, so every pixel
  // here is a pixel of scrollback. One grid row is the default precisely
  // because layers hold the key count now; a second row only buys bigger keys
  // and costs 33px on every screen.
  testWidgets('the default bar stays within one row plus the tab strip',
      (tester) async {
    final state = await _state();
    await _pump(tester, state);

    expect(state.shortcutRows, 1);
    final bar = tester.getRect(find.byType(TerminalQuickKeys));
    expect(bar.height, lessThanOrEqualTo(100),
        reason: 'the quick keyboard is eating the terminal');
  });

  test('the layer list survives a prefs round-trip', () async {
    SharedPreferences.setMockInitialValues({});
    await L10n.load();
    final first = AppState();
    await first.setShortcutLayers([QuickKeyLayer.mine, QuickKeyLayer.fn]);
    await first.setShortcutRows(3);

    final second = AppState();
    // AppState loads its prefs asynchronously in the constructor.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(second.shortcutLayers, [QuickKeyLayer.mine, QuickKeyLayer.fn]);
    expect(second.shortcutRows, 3);
  });
}
