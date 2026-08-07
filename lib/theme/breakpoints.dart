import 'package:flutter/widgets.dart';

/// Layout width classes.
///
/// Derived from the shell's own box, never from `Platform.isLinux`: a Linux
/// window dragged narrow gets the touch layout, and a 1200px Android tablet
/// gets the desktop shell. That is also what makes the breakpoint testable by
/// hand — just resize the window.
enum WidthClass {
  /// Phone-shaped. The historical layout: top nav strip + one screen at a time.
  compact,

  /// Desktop shell with the workspace split in two columns.
  medium,

  /// Desktop shell with room for a third column (explorer *and* git alongside).
  expanded,
}

/// The shell's layout decision, published once per layout pass of [HomeView].
///
/// It deliberately carries only the width *class*, not the pixel width:
/// [updateShouldNotify] then fires once per breakpoint crossing instead of once
/// per pixel of a window drag. A widget that needs real pixels uses its own
/// [LayoutBuilder] — see [BoxWidthClass].
class Layout extends InheritedWidget {
  const Layout({super.key, required this.widthClass, required super.child});

  final WidthClass widthClass;

  /// Below this the touch layout is used. Chosen so a half-screen window on a
  /// 1080p display still gets the desktop shell.
  static const double kDesktop = 900;

  /// Above this the workspace gets a third column.
  static const double kWide = 1400;

  static WidthClass classify(double width) => width >= kWide
      ? WidthClass.expanded
      : width >= kDesktop
          ? WidthClass.medium
          : WidthClass.compact;

  /// Listening read: the caller rebuilds when the layout crosses a breakpoint.
  static Layout of(BuildContext context) {
    final layout = context.dependOnInheritedWidgetOfExactType<Layout>();
    assert(layout != null, 'Layout.of() called outside the app shell');
    return layout!;
  }

  /// Non-listening, null-safe read. Sheets and dialogs build on a route *above*
  /// the shell and cannot see the [Layout], so callers there fall back to
  /// `MediaQuery`.
  static Layout? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<Layout>();

  bool get isDesktop => widthClass != WidthClass.compact;
  bool get isWide => widthClass == WidthClass.expanded;

  @override
  bool updateShouldNotify(Layout oldWidget) =>
      oldWidget.widthClass != widthClass;
}

/// Width class of the box a widget actually occupies.
///
/// Prefer this over [Layout.of] *inside* a screen body: a 300px explorer pane
/// on a 1920px display is compact, and should lay itself out as such.
extension BoxWidthClass on BoxConstraints {
  WidthClass get widthClass => Layout.classify(maxWidth);
}
