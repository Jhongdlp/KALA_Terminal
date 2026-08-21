import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A floating panel pinned to the left or right edge of its [Stack], which the
/// user can pick up with a long press and move.
///
/// It never floats free: a drag chooses a *vertical* position and a *side*,
/// and the panel snaps against whichever edge the finger is nearer. That keeps
/// it out of the content it overlays — a panel parked mid-screen would cover a
/// file row with no way to tell which one.
///
/// Positioning goes through [Alignment] rather than raw offsets: an alignment
/// of -1…1 is resolved against the child's own measured size, so the panel
/// cannot end up half off-screen no matter how tall it grows when it opens.
/// Nothing here needs to know the dock's height.
///
/// Must be placed inside a [Stack].
class EdgeDock extends StatefulWidget {
  /// True when parked against the left edge.
  final bool left;

  /// Vertical position as an [Alignment] y: -1 top, 0 centre, 1 bottom.
  final double y;

  /// Fired once, when a drag ends. The caller persists the new resting place.
  final void Function(bool left, double y) onMoved;

  /// Builds the panel. [left] is the side it is currently drawn on, which the
  /// content needs so its chevron and rounded corners face outward.
  final Widget Function(BuildContext context, bool left, bool dragging) builder;

  const EdgeDock({
    super.key,
    required this.left,
    required this.y,
    required this.onMoved,
    required this.builder,
  });

  @override
  State<EdgeDock> createState() => _EdgeDockState();
}

class _EdgeDockState extends State<EdgeDock> {
  /// Identifies the full drag area. The gesture reports positions local to the
  /// *dock*, which moves as it is dragged; the side and the vertical fraction
  /// only mean anything against the area behind it.
  final GlobalKey _areaKey = GlobalKey();

  /// Live position while a drag is in flight; null when parked.
  bool? _dragLeft;
  double? _dragY;

  bool get _left => _dragLeft ?? widget.left;
  double get _y => _dragY ?? widget.y;
  bool get _dragging => _dragY != null;

  void _update(Offset global) {
    final box = _areaKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || box.size.isEmpty) return;
    final local = box.globalToLocal(global);
    final left = local.dx < box.size.width / 2;
    final y = ((local.dy / box.size.height) * 2 - 1).clamp(-1.0, 1.0);
    if (left != _left) HapticFeedback.selectionClick();
    setState(() {
      _dragLeft = left;
      _dragY = y;
    });
  }

  void _end() {
    if (!_dragging) return;
    final left = _left;
    final y = _y;
    setState(() {
      _dragLeft = null;
      _dragY = null;
    });
    widget.onMoved(left, y);
  }

  @override
  Widget build(BuildContext context) {
    // `Align` only takes hits on its child, so filling the stack here does not
    // steal taps from the list underneath.
    return Positioned.fill(
      child: AnimatedAlign(
        key: _areaKey,
        // Instant while the finger is down — a tween would lag behind the drag
        // — and eased on release, so the snap to the edge reads as a snap.
        duration:
            _dragging ? Duration.zero : const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        alignment: Alignment(_left ? -1 : 1, _y),
        child: GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          onLongPressStart: (d) {
            HapticFeedback.mediumImpact();
            _update(d.globalPosition);
          },
          onLongPressMoveUpdate: (d) => _update(d.globalPosition),
          onLongPressEnd: (_) => _end(),
          onLongPressCancel: _end,
          child: AnimatedScale(
            // The lift is the only thing that says "you are holding it now":
            // without it a long press looks like nothing happened until the
            // finger moves.
            scale: _dragging ? 1.15 : 1.0,
            duration: const Duration(milliseconds: 120),
            child: widget.builder(context, _left, _dragging),
          ),
        ),
      ),
    );
  }
}
