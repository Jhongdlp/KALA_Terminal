import 'package:flutter/material.dart';

/// One key drawn in the quick-keyboard grid.
///
/// A key either sends [data] straight to the PTY, or triggers a named
/// [action] handled by the host view (`ctrl`, `shift`, `attach`, …). Exactly
/// one of the two is set.
@immutable
class QuickKey {
  /// Spanish source label — drawn through `tr()`, so it doubles as the l10n key.
  final String label;

  /// Raw bytes sent to the terminal. Null for action keys.
  final String? data;

  /// Named action handled by the host (`ctrl`, `shift`, `attach`, `prompts`,
  /// `commit`, `links`, `settings`). Null for data keys.
  final String? action;

  final IconData? icon;

  /// Draws inverted at rest (used for `^C`, the one destructive key).
  final bool accent;

  const QuickKey(this.label, {this.data, this.action, this.icon, this.accent = false});
}

/// A page of the quick keyboard. The user picks which ones are visible and in
/// what order; [mine] holds their own shortcuts, the rest are built in.
enum QuickKeyLayer { control, nav, fn, actions, mine }

extension QuickKeyLayerInfo on QuickKeyLayer {
  /// Stable id used in shared_preferences — never reorder the enum instead.
  String get id {
    switch (this) {
      case QuickKeyLayer.control:
        return 'control';
      case QuickKeyLayer.nav:
        return 'nav';
      case QuickKeyLayer.fn:
        return 'fn';
      case QuickKeyLayer.actions:
        return 'actions';
      case QuickKeyLayer.mine:
        return 'mine';
    }
  }

  /// Tab label (Spanish source, drawn through `tr()`).
  String get label {
    switch (this) {
      case QuickKeyLayer.control:
        return 'CTRL';
      case QuickKeyLayer.nav:
        return 'NAV';
      case QuickKeyLayer.fn:
        return 'FN';
      case QuickKeyLayer.actions:
        return 'ACCIONES';
      case QuickKeyLayer.mine:
        return 'MIS';
    }
  }

  static QuickKeyLayer? fromId(String id) {
    for (final l in QuickKeyLayer.values) {
      if (l.id == id) return l;
    }
    return null;
  }
}

/// The keys that never move: whatever the layer, these stay put so muscle
/// memory holds. `^C` is here because it is the single most-pressed key in a
/// terminal, and it must never be one tap away behind a layer switch.
///
/// Two shapes, picked by [TerminalShortcutLayout]: with the arrows inline the
/// row is 8 cells wide and SHIFT/`^D` move to the [QuickKeyLayer.control] and
/// [QuickKeyLayer.nav] pages; without them it is a 6-cell row and the arrows
/// live in NAV (or in the side d-pad).
const List<QuickKey> kFixedKeysInline = [
  QuickKey('ESC', data: '\x1b'),
  QuickKey('TAB', data: '\t'),
  QuickKey('CTRL', action: 'ctrl'),
  QuickKey('^C', data: '\x03', accent: true),
  QuickKey('←', data: '\x1b[D'),
  QuickKey('↑', data: '\x1b[A'),
  QuickKey('↓', data: '\x1b[B'),
  QuickKey('→', data: '\x1b[C'),
];

const List<QuickKey> kFixedKeys = [
  QuickKey('ESC', data: '\x1b'),
  QuickKey('TAB', data: '\t'),
  QuickKey('CTRL', action: 'ctrl'),
  QuickKey('SHIFT', action: 'shift'),
  QuickKey('^C', data: '\x03', accent: true),
  QuickKey('^D', data: '\x04'),
];

/// Control codes. `^C` is deliberately absent — it is on the fixed row.
const List<QuickKey> kControlKeys = [
  QuickKey('^A', data: '\x01'),
  QuickKey('^B', data: '\x02'),
  QuickKey('^D', data: '\x04'),
  QuickKey('^E', data: '\x05'),
  QuickKey('^K', data: '\x0b'),
  QuickKey('^L', data: '\x0c'),
  QuickKey('^R', data: '\x12'),
  QuickKey('^U', data: '\x15'),
  QuickKey('^W', data: '\x17'),
  QuickKey('^X', data: '\x18'),
  QuickKey('^Z', data: '\x1a'),
  QuickKey('^⌦', data: '\x1b[3;5~'),
];

/// The four arrows, as their own block: they appear either on the fixed row,
/// in the side d-pad cluster, or (only when neither is drawing them) prepended
/// to [kNavKeys].
const List<QuickKey> kArrowKeys = [
  QuickKey('←', data: '\x1b[D'),
  QuickKey('↑', data: '\x1b[A'),
  QuickKey('↓', data: '\x1b[B'),
  QuickKey('→', data: '\x1b[C'),
];

/// Cursor and editing keys.
///
/// Drawn as glyphs, not words: a 12-key layer at one row gets ~25px cells,
/// where "RE PÁG" would be shrunk to an unreadable 7px by the label's
/// [FittedBox]. `⇱ ⇲ ⇞ ⇟ ⌦ ⇤` are the standard keycap glyphs and stay
/// full-size. Eight keys — not twelve — because the arrows are only folded in
/// when nothing else is showing them, which is what keeps these cells wide.
const List<QuickKey> kNavKeys = [
  QuickKey('⇱', data: '\x1b[H'),
  QuickKey('⇲', data: '\x1b[F'),
  QuickKey('⇞', data: '\x1b[5~'),
  QuickKey('⇟', data: '\x1b[6~'),
  QuickKey('INS', data: '\x1b[2~'),
  QuickKey('⌦', data: '\x1b[3~'),
  QuickKey('⇤', data: '\x1b[Z'),
  QuickKey('SHIFT', action: 'shift'),
];

const List<QuickKey> kFnKeys = [
  QuickKey('F1', data: '\x1bOP'),
  QuickKey('F2', data: '\x1bOQ'),
  QuickKey('F3', data: '\x1bOR'),
  QuickKey('F4', data: '\x1bOS'),
  QuickKey('F5', data: '\x1b[15~'),
  QuickKey('F6', data: '\x1b[17~'),
  QuickKey('F7', data: '\x1b[18~'),
  QuickKey('F8', data: '\x1b[19~'),
  QuickKey('F9', data: '\x1b[20~'),
  QuickKey('F10', data: '\x1b[21~'),
  QuickKey('F11', data: '\x1b[23~'),
  QuickKey('F12', data: '\x1b[24~'),
];

/// Icons for the `system:` shortcuts that make up the ACCIONES page.
const Map<String, IconData> kSystemActionIcons = {
  'agents': Icons.smart_toy_outlined,
  'attach': Icons.attach_file,
  'prompts': Icons.bolt_outlined,
  'commit': Icons.commit_outlined,
  'links': Icons.link,
  'select': Icons.highlight_alt,
  'settings': Icons.settings,
};
