import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_agent/widgets/joystick_recognizer.dart';
import 'package:xterm/xterm.dart';

/// The terminal has to host four touch gestures on the same pixels: a tap
/// (focus), a swipe (scroll), a long press (select) and the joystick drag
/// (arrow keys). They resolve against each other in the gesture arena, and the
/// failure mode is silent — one recogniser starts winning and another simply
/// stops working. These tests pin down who wins for each gesture shape.
///
/// The tree mirrors `TerminalTab`: the joystick's [RawGestureDetector] wraps
/// the [TerminalView], which brings its own tap / long-press / scroll
/// recognisers.
void main() {
  late Terminal terminal;
  late TerminalController controller;
  late ScrollController scrollController;
  late List<String> joystick;
  late List<String> output;

  Future<void> pumpTerminal(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: RawGestureDetector(
              behavior: HitTestBehavior.translucent,
              gestures: <Type, GestureRecognizerFactory>{
                JoystickGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                        JoystickGestureRecognizer>(
                  () => JoystickGestureRecognizer(
                    onJoystickStart: (_) => joystick.add('start'),
                    onJoystickMove: (_) => joystick.add('move'),
                    onJoystickEnd: () => joystick.add('end'),
                    isSelectionActive: () => controller.selection != null,
                  ),
                  (JoystickGestureRecognizer instance) {},
                ),
              },
              child: TerminalView(
                terminal,
                controller: controller,
                scrollController: scrollController,
                autofocus: false,
                textStyle: const TerminalStyle(fontSize: 12),
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
    joystick = <String>[];
    output = <String>[];
    terminal.onOutput = output.add;
  });

  tearDown(() {
    controller.dispose();
    scrollController.dispose();
  });

  group('normal buffer', () {
    setUp(() {
      for (var i = 0; i < 120; i++) {
        terminal.write('line $i\r\n');
      }
    });

    testWidgets('a plain swipe scrolls the scrollback, not the joystick',
        (tester) async {
      await pumpTerminal(tester);
      final bottom = scrollController.position.pixels;
      expect(bottom, greaterThan(0),
          reason: '120 lines should produce scrollback');

      final gesture =
          await tester.startGesture(const Offset(200, 200), kind: touch);
      // A finger that starts moving right away is a scroll, however slowly it
      // covers the distance.
      for (var i = 0; i < 12; i++) {
        await gesture.moveBy(const Offset(0, 10));
        await tester.pump(const Duration(milliseconds: 30));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(joystick, isEmpty);
      expect(scrollController.position.pixels, lessThan(bottom));
    });

    testWidgets('hold still, then drag, arms the joystick', (tester) async {
      await pumpTerminal(tester);
      final bottom = scrollController.position.pixels;

      final gesture =
          await tester.startGesture(const Offset(200, 200), kind: touch);
      await tester.pump(const Duration(milliseconds: 260));
      for (var i = 0; i < 20; i++) {
        await gesture.moveBy(const Offset(0, -4));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(joystick.first, 'start');
      expect(joystick.last, 'end');
      expect(scrollController.position.pixels, bottom,
          reason: 'the joystick owns the drag, so nothing scrolled');
    });

    testWidgets('a long press selects text and never arms the joystick',
        (tester) async {
      await pumpTerminal(tester);

      final gesture =
          await tester.startGesture(const Offset(60, 200), kind: touch);
      // Hold past the joystick's window with the small drift a real finger has.
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.moveBy(const Offset(1, 1));
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(joystick, isEmpty);
      expect(controller.selection, isNotNull);
    });

    testWidgets('the joystick stands down while a selection is on screen',
        (tester) async {
      await pumpTerminal(tester);
      final buffer = terminal.buffer;
      controller.setSelection(
        buffer.createAnchor(0, buffer.lines.length - 3),
        buffer.createAnchor(4, buffer.lines.length - 3),
      );
      await tester.pump();

      final gesture =
          await tester.startGesture(const Offset(200, 200), kind: touch);
      await tester.pump(const Duration(milliseconds: 260));
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(joystick, isEmpty);
    });
  });

  group('alternate buffer', () {
    setUp(() {
      // Alt screen + SGR mouse reporting, the way tmux with `mouse on` and
      // most TUI agents set themselves up.
      terminal.write('\x1b[?1049h\x1b[?1000h\x1b[?1006h');
      output.clear();
    });

    testWidgets('a swipe reports wheel events instead of arrow keys',
        (tester) async {
      await pumpTerminal(tester);
      expect(terminal.isUsingAltBuffer, isTrue);

      final gesture =
          await tester.startGesture(const Offset(200, 200), kind: touch);
      for (var i = 0; i < 12; i++) {
        await gesture.moveBy(const Offset(0, 10));
        await tester.pump(const Duration(milliseconds: 30));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(joystick, isEmpty);
      // SGR wheel-up is button 64: `CSI < 64 ; col ; row M`. Anything else
      // (notably 68, which is Shift+wheel) is ignored by tmux.
      expect(output.where((e) => e.startsWith('\x1b[<64;')), isNotEmpty);
      expect(output.where((e) => !e.startsWith('\x1b[<64;')), isEmpty);
      expect(output.any((e) => e == '\x1b[A' || e == '\x1bOA'), isFalse,
          reason: 'the app reports wheel events, so no arrow-key fallback');
    });

    testWidgets('a long press still selects instead of scrolling',
        (tester) async {
      await pumpTerminal(tester);
      terminal.write('hello world');
      await tester.pump();

      final gesture =
          await tester.startGesture(const Offset(60, 60), kind: touch);
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.moveBy(const Offset(1, 1));
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(controller.selection, isNotNull);
      expect(output, isEmpty, reason: 'selecting must not scroll the remote');
    });
  });
}

const touch = PointerDeviceKind.touch;
