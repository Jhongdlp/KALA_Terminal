import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/core.dart';
import 'package:xterm/xterm.dart';

/// The four mouse tracking modes (DEC 9, 1000/1001, 1002, 1003) are
/// **independent switches**, and a TUI that turns one off while keeping
/// another on is ordinary: an agent that follows the pointer only while
/// something is open sends `CSI ? 1003 l` and expects to keep the wheel.
///
/// xterm.dart collapsed every "off" into [MouseMode.none], so from that moment
/// the terminal believed the application wanted no mouse at all — and a swipe,
/// finding the wheel unreported, fell back to typing arrow keys into whatever
/// held the prompt. In an agent's input box that is history navigation: the
/// text being written is replaced by an old message.
void main() {
  late Terminal terminal;
  late List<String> output;

  setUp(() {
    terminal = Terminal(maxLines: 200);
    output = <String>[];
    terminal.onOutput = output.add;
  });

  group('tracking modes are independent', () {
    test('turning off motion keeps wheel reporting', () {
      terminal.write('\x1b[?1049h\x1b[?1000h\x1b[?1006h');
      expect(terminal.mouseMode.reportScroll, isTrue);

      // The application stops asking for motion. It never asked for it in the
      // first place — programs disable defensively — and 1000 is still on.
      terminal.write('\x1b[?1003l');
      expect(terminal.mouseMode.reportScroll, isTrue,
          reason: 'disabling 1003 must not silence 1000');
    });

    test('the most specific mode still on wins', () {
      terminal.write('\x1b[?1000h\x1b[?1002h\x1b[?1003h');
      expect(terminal.mouseMode, MouseMode.upDownScrollMove);

      terminal.write('\x1b[?1003l');
      expect(terminal.mouseMode, MouseMode.upDownScrollDrag);

      terminal.write('\x1b[?1002l');
      expect(terminal.mouseMode, MouseMode.upDownScroll);

      terminal.write('\x1b[?1000l');
      expect(terminal.mouseMode, MouseMode.none);
    });

    test('a clean teardown really does turn everything off', () {
      terminal.write('\x1b[?1000h\x1b[?1002h\x1b[?1006h');
      terminal.write('\x1b[?1000l\x1b[?1002l');
      expect(terminal.mouseMode, MouseMode.none);
      expect(terminal.mouseMode.reportScroll, isFalse);
    });

    test('click-only tracking is its own switch', () {
      terminal.write('\x1b[?9h');
      expect(terminal.mouseMode, MouseMode.clickOnly);
      terminal.write('\x1b[?1000h');
      expect(terminal.mouseMode, MouseMode.upDownScroll);
      // Dropping the wheel mode leaves the click mode the app also asked for.
      terminal.write('\x1b[?1000l');
      expect(terminal.mouseMode, MouseMode.clickOnly);
    });
  });

  group('alternate scroll (DEC 1007)', () {
    test('is on by default, the way modern terminals ship it', () {
      expect(terminal.altBufferMouseScrollMode, isTrue);
    });

    test('an application can opt out of the arrow-key translation', () {
      terminal.write('\x1b[?1007l');
      expect(terminal.altBufferMouseScrollMode, isFalse);
      terminal.write('\x1b[?1007h');
      expect(terminal.altBufferMouseScrollMode, isTrue);
    });
  });

  group('what a swipe actually sends', () {
    late ScrollController scrollController;

    Future<void> pump(WidgetTester tester, {bool simulateScroll = true}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 400,
              child: TerminalView(
                terminal,
                scrollController: scrollController,
                autofocus: false,
                simulateScroll: simulateScroll,
                textStyle: const TerminalStyle(fontSize: 12),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> swipe(WidgetTester tester) async {
      final gesture = await tester.startGesture(const Offset(200, 200),
          kind: PointerDeviceKind.touch);
      for (var i = 0; i < 12; i++) {
        await gesture.moveBy(const Offset(0, 10));
        await tester.pump(const Duration(milliseconds: 30));
      }
      await gesture.up();
      await tester.pumpAndSettle();
    }

    setUp(() {
      scrollController = ScrollController();
    });

    tearDown(() => scrollController.dispose());

    testWidgets('an app that dropped 1003 still gets wheel events, not arrows',
        (tester) async {
      terminal.write('\x1b[?1049h\x1b[?1000h\x1b[?1006h\x1b[?1003l');
      await pump(tester);
      output.clear();

      await swipe(tester);

      expect(output.where((e) => e.startsWith('\x1b[<64;')), isNotEmpty);
      expect(output.any((e) => e == '\x1b[A' || e == '\x1bOA'), isFalse,
          reason: 'arrow keys here land in the agent prompt, not in a pager');
    });

    testWidgets('an app with no mouse at all still gets the pager fallback',
        (tester) async {
      terminal.write('\x1b[?1049h');
      await pump(tester);
      output.clear();

      await swipe(tester);

      expect(output.any((e) => e == '\x1b[A' || e == '\x1bOA'), isTrue,
          reason: 'less and man are only scrollable by thumb because of this');
    });

    testWidgets('DEC 1007 off silences the fallback', (tester) async {
      terminal.write('\x1b[?1049h\x1b[?1007l');
      await pump(tester);
      output.clear();

      await swipe(tester);

      expect(output, isEmpty);
    });

    testWidgets('the user switch silences it too', (tester) async {
      terminal.write('\x1b[?1049h');
      await pump(tester, simulateScroll: false);
      output.clear();

      await swipe(tester);

      expect(output, isEmpty);
    });
  });
}
