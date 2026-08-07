import 'breakpoints.dart';

/// Spacing and sizing scale.
///
/// It mirrors the rhythm already present in the code (4/6/8/12/16/20, with 16
/// as the standard gutter), so the existing inline literals are *already* on
/// scale and none of them has to be migrated for these tokens to be correct.
///
/// Use these in the desktop shell, in [swiss.dart]'s shared primitives, and in
/// the pane chrome bars. Do not sweep the rest of the app onto them: it would
/// be a large mechanical rewrite with no visual payoff.
class Dim {
  Dim._();

  // Spacing scale.
  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x5 = 20;
  static const double x6 = 24;
  static const double x8 = 32;

  /// Standard horizontal screen gutter (SwissPanel's margin).
  static const double gutter = 16;

  // Chrome heights the desktop shell has to line up against. Each mirrors a
  // height already hardcoded in the corresponding view.
  static const double topNav = 54; // home_view.dart
  static const double toolbar = 46; // terminal_tab.dart
  static const double editorBar = 44; // editor_tab.dart
  static const double pathBar = 42; // explorer_tab.dart
  static const double serverBar = 52; // server_tab.dart
  static const double serverRail = 268; // server_tab.dart `_railWidth`

  // Desktop shell.
  static const double railWidth = 56;
  static const double splitter = 6;

  /// Smallest a workspace pane may be dragged to.
  static const double paneMin = 220;

  /// Readable column width for list-style screens (settings, connections…).
  static const double contentMax = 760;

  /// Vertical row padding. Desktop trades touch target for density; keeping it
  /// behind a token gives a future compact/comfortable setting one hook.
  static double rowPadV(WidthClass width) =>
      width == WidthClass.compact ? 12 : 8;
}
