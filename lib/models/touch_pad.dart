import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'terminal_shortcut.dart';

/// The eight slots of the terminal's touch pad.
///
/// The four cardinals are reachable two ways — dragging the armed pad (where
/// they repeat) and the radial menu — so they must mean the same thing in
/// both. The corners exist only in the radial: a diagonal drag is not a
/// gesture anyone performs on purpose, but a diagonal *pick* from a menu drawn
/// under the thumb is.
enum PadDirection { up, down, left, right, upLeft, upRight, downLeft, downRight }

extension PadDirectionInfo on PadDirection {
  /// Stable id used in shared_preferences — never reorder the enum instead.
  String get id => name;

  bool get isCorner =>
      this == PadDirection.upLeft ||
      this == PadDirection.upRight ||
      this == PadDirection.downLeft ||
      this == PadDirection.downRight;

  /// Spanish source label — drawn through `tr()`, so it doubles as the l10n key.
  String get label => switch (this) {
        PadDirection.up => 'ARRIBA',
        PadDirection.down => 'ABAJO',
        PadDirection.left => 'IZQUIERDA',
        PadDirection.right => 'DERECHA',
        PadDirection.upLeft => 'ESQUINA ↖',
        PadDirection.upRight => 'ESQUINA ↗',
        PadDirection.downLeft => 'ESQUINA ↙',
        PadDirection.downRight => 'ESQUINA ↘',
      };

  /// Unit-ish vector pointing at the slot in **screen** coordinates (y grows
  /// downwards), used to lay the radial out and to place the HUD glyph.
  Offset get vector {
    const d = math.sqrt1_2;
    return switch (this) {
      PadDirection.up => const Offset(0, -1),
      PadDirection.down => const Offset(0, 1),
      PadDirection.left => const Offset(-1, 0),
      PadDirection.right => const Offset(1, 0),
      PadDirection.upLeft => const Offset(-d, -d),
      PadDirection.upRight => const Offset(d, -d),
      PadDirection.downLeft => const Offset(-d, d),
      PadDirection.downRight => const Offset(d, d),
    };
  }

  static PadDirection? fromId(String id) {
    for (final d in PadDirection.values) {
      if (d.id == id) return d;
    }
    return null;
  }
}

/// Which slot a drag of [delta] is pointing at, or null inside [deadzone].
///
/// With [corners] false only the four cardinals can win and the winner is the
/// dominant axis — the same rule the repeat drag has always used, so a sloppy
/// upward swipe still means "up" rather than "nothing". With [corners] true
/// (the radial is open) the circle is split into eight equal 45° sectors.
PadDirection? padDirectionFor(
  Offset delta, {
  required double deadzone,
  required bool corners,
}) {
  if (delta.distance < deadzone) return null;
  if (!corners) {
    return delta.dx.abs() > delta.dy.abs()
        ? (delta.dx > 0 ? PadDirection.right : PadDirection.left)
        : (delta.dy > 0 ? PadDirection.down : PadDirection.up);
  }
  // Sectors of 45°, starting at "right" and going clockwise on screen.
  const order = [
    PadDirection.right,
    PadDirection.downRight,
    PadDirection.down,
    PadDirection.downLeft,
    PadDirection.left,
    PadDirection.upLeft,
    PadDirection.up,
    PadDirection.upRight,
  ];
  final angle = math.atan2(delta.dy, delta.dx);
  final sector = ((angle + math.pi / 8) / (math.pi / 4)).floor();
  return order[((sector % 8) + 8) % 8];
}

/// Escapes raw bytes into the literal form [TerminalShortcut.parsedValue]
/// reads back, so a slot picked from a built-in key survives a JSON
/// round-trip as readable text (`\x1b[A`) rather than a control character
/// smuggled into a preferences string.
String padEscape(String raw) {
  final out = StringBuffer();
  for (final rune in raw.runes) {
    if (rune < 0x20 || rune == 0x7f) {
      out.write('\\x${rune.toRadixString(16).padLeft(2, '0')}');
    } else {
      out.writeCharCode(rune);
    }
  }
  return out.toString();
}

/// What each slot of the pad sends, as user-editable [TerminalShortcut]s: the
/// same vocabulary as the quick keyboard, so anything that can sit on a key
/// (raw bytes, an escape sequence, a `system:` action) can sit on the pad.
class TouchPadConfig {
  final Map<PadDirection, TerminalShortcut> slots;

  const TouchPadConfig(this.slots);

  /// Cardinals are the arrows — the pad's whole point is history and cursor
  /// movement without the soft keyboard. The corners hold the four keys most
  /// worth reaching without it: escape, tab, interrupt and enter.
  static TouchPadConfig get defaults => TouchPadConfig({
        PadDirection.up: TerminalShortcut(label: '↑', value: r'\x1b[A'),
        PadDirection.down: TerminalShortcut(label: '↓', value: r'\x1b[B'),
        PadDirection.left: TerminalShortcut(label: '←', value: r'\x1b[D'),
        PadDirection.right: TerminalShortcut(label: '→', value: r'\x1b[C'),
        PadDirection.upLeft: TerminalShortcut(label: 'ESC', value: r'\x1b'),
        PadDirection.upRight: TerminalShortcut(label: 'TAB', value: r'\t'),
        PadDirection.downLeft: TerminalShortcut(label: '^C', value: r'\x03'),
        PadDirection.downRight: TerminalShortcut(label: '⏎', value: r'\r'),
      });

  TerminalShortcut? slot(PadDirection direction) => slots[direction];

  /// A slot with no shortcut is drawn as an empty cell and fires nothing —
  /// that is how a user removes one they keep hitting by accident.
  TouchPadConfig withSlot(PadDirection direction, TerminalShortcut? shortcut) {
    final next = Map<PadDirection, TerminalShortcut>.from(slots);
    if (shortcut == null) {
      next.remove(direction);
    } else {
      next[direction] = shortcut;
    }
    return TouchPadConfig(next);
  }

  Map<String, dynamic> toJson() => {
        for (final e in slots.entries) e.key.id: e.value.toJson(),
      };

  /// Unknown ids are dropped rather than throwing: a blob written by a newer
  /// build (a ninth slot, say) must still load its other seven.
  factory TouchPadConfig.fromJson(Map<String, dynamic> json) {
    final slots = <PadDirection, TerminalShortcut>{};
    for (final entry in json.entries) {
      final direction = PadDirectionInfo.fromId(entry.key);
      final value = entry.value;
      if (direction == null || value is! Map) continue;
      try {
        slots[direction] =
            TerminalShortcut.fromJson(Map<String, dynamic>.from(value));
      } catch (_) {
        // A malformed slot is skipped; the rest of the pad still loads.
      }
    }
    return TouchPadConfig(slots);
  }

  String encode() => jsonEncode(toJson());

  static TouchPadConfig decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) return TouchPadConfig.fromJson(json);
    } catch (_) {
      // Corrupt blob — the defaults are a working pad, an empty one is not.
    }
    return defaults;
  }
}
