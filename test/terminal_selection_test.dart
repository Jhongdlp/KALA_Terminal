import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_agent/widgets/terminal_selection.dart';
import 'package:xterm/xterm.dart';

/// Copying text out of the terminal is the one thing that has to keep working
/// while the soft keyboard is up — which is exactly when the terminal is a
/// handful of lines tall and when everything else is moving under it.
///
/// Two failure modes are pinned down here:
///
///  * the selection being **lost**: showing the keyboard used to yank the
///    viewport to the bottom of the buffer, taking a selection made in the
///    scrollback off screen with it, and
///  * the handles being **unreachable**: they hang below their line and to the
///    left of the first column, so in a short viewport (or on a selection that
///    starts at column 0) the [Stack] clipped away most of the touch target.
void main() {
  late Terminal terminal;
  late TerminalController controller;
  late ScrollController scrollController;
  final viewKey = GlobalKey<TerminalViewState>();

  Future<void> pump(WidgetTester tester, {required Size size}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: TerminalSelectionArea(
                terminal: terminal,
                controller: controller,
                terminalViewKey: viewKey,
                scrollController: scrollController,
                onSendInput: (_) {},
                child: TerminalView(
                  terminal,
                  key: viewKey,
                  controller: controller,
                  scrollController: scrollController,
                  autofocus: true,
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  textStyle: const TerminalStyle(fontSize: 12),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    terminal = Terminal(maxLines: 500);
    controller = TerminalController();
    scrollController = ScrollController();
  });

  tearDown(() {
    controller.dispose();
    scrollController.dispose();
  });

  /// Selects the whole of buffer line [y], the way `system:select` does.
  void selectLine(int y) {
    final buffer = terminal.buffer;
    controller.setSelection(
      buffer.createAnchor(0, y),
      buffer.createAnchor(8, y),
    );
  }

  Rect rectOf(WidgetTester tester, String key) =>
      tester.getRect(find.byKey(ValueKey(key)));

  group('the keyboard never takes the selection away', () {
    setUp(() {
      for (var i = 0; i < 200; i++) {
        terminal.write('line $i\r\n');
      }
    });

    testWidgets('showing it leaves a scrolled-up viewport where it was',
        (tester) async {
      await pump(tester, size: const Size(360, 400));
      scrollController.jumpTo(0);
      await tester.pump();

      _showKeyboard(tester.view);
      await tester.pumpAndSettle();

      expect(scrollController.position.pixels, 0,
          reason: 'reading the scrollback survives the keyboard');
    });

    testWidgets('a selection made in the scrollback survives it',
        (tester) async {
      await pump(tester, size: const Size(360, 400));
      scrollController.jumpTo(0);
      await tester.pump();
      selectLine(4);
      await tester.pump();

      _showKeyboard(tester.view);
      await tester.pumpAndSettle();

      expect(controller.selection, isNotNull);
      expect(scrollController.position.pixels, 0);
      expect(find.text('COPIAR'), findsOneWidget);
    });

    testWidgets('a viewport already at the bottom still chases the prompt',
        (tester) async {
      await pump(tester, size: const Size(360, 400));
      final bottom = scrollController.position.maxScrollExtent;
      expect(scrollController.position.pixels, bottom);

      _showKeyboard(tester.view);
      await tester.pumpAndSettle();

      expect(scrollController.position.pixels, bottom);
    });
  });

  group('handles stay inside the viewport', () {
    setUp(() {
      for (var i = 0; i < 60; i++) {
        terminal.write('line $i\r\n');
      }
    });

    testWidgets('a selection in the first column keeps both touch targets',
        (tester) async {
      const size = Size(360, 400);
      await pump(tester, size: size);
      selectLine(terminal.buffer.lines.length - 2);
      await tester.pump();

      final area = tester.getRect(find.byType(TerminalSelectionArea));
      for (final key in const [
        'selection-handle-start',
        'selection-handle-end',
      ]) {
        final handle = rectOf(tester, key);
        expect(area.contains(handle.topLeft), isTrue,
            reason: '$key starts outside the terminal and is clipped away');
        expect(area.contains(handle.bottomRight - const Offset(1, 1)), isTrue,
            reason: '$key runs past the terminal and is clipped away');
      }
    });

    testWidgets('a terminal squeezed by the keyboard keeps them too',
        (tester) async {
      // Roughly what is left of a phone terminal with the keyboard, the quick
      // keys and the toolbar on screen.
      const size = Size(360, 120);
      await pump(tester, size: size);
      selectLine(terminal.buffer.lines.length - 2);
      await tester.pump();

      final area = tester.getRect(find.byType(TerminalSelectionArea));
      final start = rectOf(tester, 'selection-handle-start');
      expect(area.contains(start.topLeft), isTrue);
      expect(area.contains(start.bottomRight - const Offset(1, 1)), isTrue,
          reason: 'the handle must flip above its line rather than hang off '
              'the bottom edge');

      // And the bar that copies is reachable, not clipped with them.
      final bar = tester.getRect(find.text('COPIAR'));
      expect(area.contains(bar.center), isTrue);
    });
  });
}

/// Raises the soft keyboard the way the framework reports it: a bottom view
/// inset, which is what `KeyboardVisibilty` watches.
void _showKeyboard(TestFlutterView view) {
  view.viewInsets = FakeViewPadding(bottom: 300 * view.devicePixelRatio);
}
