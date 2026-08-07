import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/dimens.dart';

/// Two children separated by a draggable divider.
///
/// The split is stored as a *fraction* so it survives a window resize, with
/// [minFirst]/[minSecond] applied afterwards as pixel floors, so a pane can
/// never be dragged to nothing. During a drag the live value is local state;
/// [onFractionChanged] fires once on release, so persisting it doesn't write to
/// disk on every frame.
///
/// Hand-rolled rather than pulling in a package: this needs exactly one
/// behaviour, and a package's theming fights the hairline aesthetic.
class SplitPane extends StatefulWidget {
  /// [Axis.horizontal] puts the children side by side (a vertical divider).
  final Axis axis;
  final Widget first;
  final Widget second;

  /// Share of the available extent given to [first], 0–1.
  final double fraction;
  final ValueChanged<double> onFractionChanged;

  final double minFirst;
  final double minSecond;
  final double thickness;

  const SplitPane({
    super.key,
    required this.axis,
    required this.first,
    required this.second,
    required this.fraction,
    required this.onFractionChanged,
    this.minFirst = Dim.paneMin,
    this.minSecond = Dim.paneMin,
    this.thickness = Dim.splitter,
  });

  @override
  State<SplitPane> createState() => _SplitPaneState();
}

class _SplitPaneState extends State<SplitPane> {
  /// Live fraction while dragging; null when the widget's value is in charge.
  double? _dragFraction;

  double get _fraction => _dragFraction ?? widget.fraction;

  @override
  Widget build(BuildContext context) {
    final horizontal = widget.axis == Axis.horizontal;

    return LayoutBuilder(
      builder: (context, constraints) {
        final total = horizontal ? constraints.maxWidth : constraints.maxHeight;
        final available = total - widget.thickness;

        // Too small to honour both floors: give up on the split rather than
        // overflow, and show the first pane alone.
        if (available < widget.minFirst + widget.minSecond) {
          return widget.first;
        }

        final firstExtent = (_fraction * available)
            .clamp(widget.minFirst, available - widget.minSecond);

        void onDrag(double delta) {
          setState(() {
            _dragFraction = ((firstExtent + delta) / available).clamp(0.0, 1.0);
          });
        }

        void onDragEnd() {
          final settled = _fraction.clamp(
            widget.minFirst / available,
            (available - widget.minSecond) / available,
          );
          setState(() => _dragFraction = null);
          widget.onFractionChanged(settled);
        }

        final handle = _SplitHandle(
          axis: widget.axis,
          thickness: widget.thickness,
          onDrag: onDrag,
          onDragEnd: onDragEnd,
        );

        final children = <Widget>[
          SizedBox(
            width: horizontal ? firstExtent : null,
            height: horizontal ? null : firstExtent,
            child: widget.first,
          ),
          handle,
          Expanded(child: widget.second),
        ];

        return horizontal
            ? Row(children: children)
            : Column(children: children);
      },
    );
  }
}

class _SplitHandle extends StatefulWidget {
  final Axis axis;
  final double thickness;
  final ValueChanged<double> onDrag;
  final VoidCallback onDragEnd;

  const _SplitHandle({
    required this.axis,
    required this.thickness,
    required this.onDrag,
    required this.onDragEnd,
  });

  @override
  State<_SplitHandle> createState() => _SplitHandleState();
}

class _SplitHandleState extends State<_SplitHandle> {
  bool _hovering = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final horizontal = widget.axis == Axis.horizontal;
    final active = _hovering || _dragging;

    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        // Opaque so the whole strip is grabbable, not just the painted hairline.
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: horizontal ? (_) => _start() : null,
        onHorizontalDragUpdate:
            horizontal ? (d) => widget.onDrag(d.delta.dx) : null,
        onHorizontalDragEnd: horizontal ? (_) => _end() : null,
        onVerticalDragStart: horizontal ? null : (_) => _start(),
        onVerticalDragUpdate:
            horizontal ? null : (d) => widget.onDrag(d.delta.dy),
        onVerticalDragEnd: horizontal ? null : (_) => _end(),
        child: SizedBox(
          width: horizontal ? widget.thickness : null,
          height: horizontal ? null : widget.thickness,
          child: Center(
            child: Container(
              width: horizontal ? 1 : double.infinity,
              height: horizontal ? double.infinity : 1,
              color: active ? AppColors.accent : AppColors.hairline,
            ),
          ),
        ),
      ),
    );
  }

  void _start() => setState(() => _dragging = true);

  void _end() {
    setState(() => _dragging = false);
    widget.onDragEnd();
  }
}
