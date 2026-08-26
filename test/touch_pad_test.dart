import 'dart:ui' show Offset;

import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_agent/models/terminal_shortcut.dart';
import 'package:terminal_agent/models/touch_pad.dart';

/// The pad's pure half: which slot a drag points at, and what survives a trip
/// through preferences. The geometry is what the finger feels, so both of its
/// modes are pinned down here — four fat quadrants while dragging, eight equal
/// sectors once the radial is open.
void main() {
  group('padDirectionFor', () {
    test('nothing inside the deadzone', () {
      expect(
        padDirectionFor(const Offset(20, -20), deadzone: 60, corners: false),
        isNull,
      );
      expect(
        padDirectionFor(const Offset(0, 0), deadzone: 60, corners: true),
        isNull,
      );
    });

    test('the drag resolves to the dominant axis, however sloppy', () {
      // A "straight up" swipe with 30px of drift is still up.
      expect(
        padDirectionFor(const Offset(30, -80), deadzone: 60, corners: false),
        PadDirection.up,
      );
      expect(
        padDirectionFor(const Offset(-90, 20), deadzone: 60, corners: false),
        PadDirection.left,
      );
      expect(
        padDirectionFor(const Offset(10, 95), deadzone: 60, corners: false),
        PadDirection.down,
      );
    });

    test('a diagonal never reaches a corner while dragging', () {
      final picked =
          padDirectionFor(const Offset(70, -70), deadzone: 60, corners: false);
      expect(picked, anyOf(PadDirection.up, PadDirection.right));
      expect(picked?.isCorner, isFalse);
    });

    test('the radial splits the circle into eight equal sectors', () {
      const cases = <(Offset, PadDirection)>[
        (Offset(80, 0), PadDirection.right),
        (Offset(-80, 0), PadDirection.left),
        (Offset(0, -80), PadDirection.up),
        (Offset(0, 80), PadDirection.down),
        (Offset(60, -60), PadDirection.upRight),
        (Offset(-60, -60), PadDirection.upLeft),
        (Offset(60, 60), PadDirection.downRight),
        (Offset(-60, 60), PadDirection.downLeft),
      ];
      for (final (delta, expected) in cases) {
        expect(padDirectionFor(delta, deadzone: 34, corners: true), expected,
            reason: '$delta should pick $expected');
      }
    });
  });

  group('padEscape', () {
    test('control bytes come back as readable escapes', () {
      expect(padEscape('\x1b[A'), r'\x1b[A');
      expect(padEscape('\x03'), r'\x03');
      expect(padEscape('\r'), r'\x0d');
      expect(padEscape('ls'), 'ls');
    });

    test('what it writes is what the shortcut parses back', () {
      final shortcut =
          TerminalShortcut(label: '↑', value: padEscape('\x1b[A'));
      expect(shortcut.parsedValue, '\x1b[A');
    });
  });

  group('TouchPadConfig', () {
    test('the defaults are the four arrows plus four corners', () {
      final config = TouchPadConfig.defaults;
      expect(config.slot(PadDirection.up)?.parsedValue, '\x1b[A');
      expect(config.slot(PadDirection.down)?.parsedValue, '\x1b[B');
      expect(config.slot(PadDirection.left)?.parsedValue, '\x1b[D');
      expect(config.slot(PadDirection.right)?.parsedValue, '\x1b[C');
      for (final direction in PadDirection.values) {
        expect(config.slot(direction), isNotNull, reason: '${direction.id}');
      }
    });

    test('a rebound slot survives the round trip, an emptied one stays empty',
        () {
      final edited = TouchPadConfig.defaults
          .withSlot(PadDirection.upLeft,
              TerminalShortcut(label: 'GIT', value: 'git status\\r'))
          .withSlot(PadDirection.downLeft, null);

      final restored = TouchPadConfig.decode(edited.encode());
      expect(restored.slot(PadDirection.upLeft)?.label, 'GIT');
      expect(restored.slot(PadDirection.upLeft)?.parsedValue, 'git status\r');
      expect(restored.slot(PadDirection.downLeft), isNull);
      expect(restored.slot(PadDirection.up)?.parsedValue, '\x1b[A');
    });

    test('a corrupt blob falls back to a working pad, not an empty one', () {
      expect(TouchPadConfig.decode('not json').slots, isNotEmpty);
    });

    test('an unknown slot id is dropped without taking the rest with it', () {
      final raw = '{"up":{"label":"↑","value":"\\\\x1b[A"},'
          '"sideways":{"label":"?","value":"x"}}';
      final config = TouchPadConfig.decode(raw);
      expect(config.slot(PadDirection.up)?.parsedValue, '\x1b[A');
      expect(config.slots.length, 1);
    });
  });
}
