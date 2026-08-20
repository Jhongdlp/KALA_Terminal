import 'package:flutter/material.dart';

import '../theme/breakpoints.dart';

/// Guarantees a control is big enough to hit with a thumb.
///
/// The app's icon buttons are drawn at 14–16px with 4–6px of padding, which
/// looks right in a dense IDE bar and lands well under the 48dp minimum every
/// touch guideline asks for — closing a live SSH session by mistake is the kind
/// of miss that costs real work. This widget keeps the *visual* size exactly as
/// it was and only grows the hit area around it.
///
/// The minimum is width-class aware: a pointer is precise, so the desktop shell
/// keeps its density (and a 48dp floor would blow up the toolbars) while touch
/// layouts get the full target.
class TapTarget extends StatelessWidget {
  /// Minimum square side under a finger.
  static const double touchMin = 48;

  /// Minimum square side under a mouse.
  static const double pointerMin = 32;

  final Widget child;

  /// Overrides the resolved minimum, for the rare bar that genuinely can't
  /// afford it (the 46px terminal toolbar clamps to its own height).
  final double? min;

  const TapTarget({super.key, required this.child, this.min});

  /// The minimum that applies at [context]'s width class.
  static double minFor(BuildContext context) =>
      (Layout.maybeOf(context)?.isDesktop ?? false) ? pointerMin : touchMin;

  @override
  Widget build(BuildContext context) {
    final side = min ?? minFor(context);
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: side, minHeight: side),
      child: Center(widthFactor: 1, heightFactor: 1, child: child),
    );
  }
}

/// A bare icon button that is always thumb-sized, always labelled for a screen
/// reader, and always shows a tooltip on desktop.
///
/// Prefer this over a hand-rolled `GestureDetector(child: Icon(...))`: those
/// are what left most of the app's chrome both untappable and unreadable by
/// TalkBack.
class IconTapTarget extends StatelessWidget {
  final IconData icon;
  final double size;
  final Color? color;

  /// Spoken by the screen reader and shown as the tooltip. Required — an
  /// unlabelled icon button is invisible to anyone not looking at it.
  final String label;
  final VoidCallback? onTap;
  final double? min;

  const IconTapTarget({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.size = 16,
    this.color,
    this.min,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      // On touch a tooltip only ever appears on long-press, where it would
      // fight real long-press actions; the Semantics label is what matters
      // there and it is set either way.
      triggerMode: (Layout.maybeOf(context)?.isDesktop ?? false)
          ? TooltipTriggerMode.longPress
          : TooltipTriggerMode.manual,
      child: Semantics(
        button: true,
        label: label,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: TapTarget(
            min: min,
            child: Icon(icon, size: size, color: color),
          ),
        ),
      ),
    );
  }
}
