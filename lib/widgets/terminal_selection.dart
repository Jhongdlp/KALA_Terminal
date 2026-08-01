import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../theme/app_theme.dart';
import '../l10n/l10n.dart';

/// Android/Termux-style text-selection layer for a [TerminalView].
///
/// The bare [TerminalView] only selects whole words while a long-press drag is
/// held, with no way to adjust the selection afterwards. This widget overlays
/// the terminal with the familiar mobile affordances: once a selection exists
/// (long-press or double-tap on the terminal), it shows two draggable teardrop
/// handles with character precision plus a floating COPIAR / PEGAR / TODO
/// action bar. Dragging a handle near the top/bottom edge auto-scrolls the
/// scrollback buffer.
///
/// It must wrap the [TerminalView] directly (same size) and needs the view's
/// [TerminalViewState] key plus its [ScrollController] to map buffer cells to
/// pixels and to auto-scroll.
class TerminalSelectionArea extends StatefulWidget {
  const TerminalSelectionArea({
    super.key,
    required this.terminal,
    required this.controller,
    required this.terminalViewKey,
    required this.scrollController,
    required this.onSendInput,
    this.onToast,
    required this.child,
  });

  /// The active session's terminal (same instance rendered by [child]).
  final Terminal terminal;

  /// Selection controller shared with the [TerminalView].
  final TerminalController controller;

  /// Key attached to the [TerminalView] inside [child]; gives access to the
  /// render object that maps cells to pixels.
  final GlobalKey<TerminalViewState> terminalViewKey;

  /// Scroll controller shared with the [TerminalView]; used to auto-scroll
  /// while dragging a handle near the viewport edges.
  final ScrollController scrollController;

  /// Sends raw text to the active shell (used by PEGAR).
  final void Function(String text) onSendInput;

  /// Optional feedback callback (e.g. a snackbar) after copying.
  final void Function(String message)? onToast;

  final Widget child;

  @override
  State<TerminalSelectionArea> createState() => _TerminalSelectionAreaState();
}

class _TerminalSelectionAreaState extends State<TerminalSelectionArea> {
  final GlobalKey _stackKey = GlobalKey();

  // Terminal currently being listened to; re-pointed on session switches so
  // handle positions track new output (anchors shift as lines scroll by).
  Terminal? _listenedTerminal;

  // Avoids a setState per terminal-output tick while nothing is selected.
  bool _hadSelection = false;

  // Drag state for the handle currently under the user's finger. `_dragFixed`
  // is the selection endpoint that stays put; null when no drag is active.
  CellOffset? _dragFixed;
  bool _dragIsStart = false;
  Offset _dragTipDelta = Offset.zero;
  int? _dragActiveRow;

  static const double _handleTouch = 50; // hit target
  static const double _handleVisual = 24; // painted teardrop
  static const double _barHeight = 35;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onSelectionSourceChanged);
    _syncTerminalListener();
  }

  @override
  void didUpdateWidget(TerminalSelectionArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onSelectionSourceChanged);
      widget.controller.addListener(_onSelectionSourceChanged);
    }
    _syncTerminalListener();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onSelectionSourceChanged);
    _listenedTerminal?.removeListener(_onSelectionSourceChanged);
    super.dispose();
  }

  void _syncTerminalListener() {
    if (identical(_listenedTerminal, widget.terminal)) return;
    _listenedTerminal?.removeListener(_onSelectionSourceChanged);
    _listenedTerminal = widget.terminal;
    widget.terminal.addListener(_onSelectionSourceChanged);
  }

  void _onSelectionSourceChanged() {
    final hasSelection = widget.controller.selection != null;
    if (!hasSelection && !_hadSelection) return;
    _hadSelection = hasSelection;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    _syncTerminalListener();
    return NotificationListener<ScrollNotification>(
      onNotification: (_) {
        // Reposition handles while the terminal scrolls under a selection.
        if (widget.controller.selection != null && mounted) setState(() {});
        return false;
      },
      child: Stack(
        key: _stackKey,
        children: [
          widget.child,
          ..._buildSelectionOverlay(),
        ],
      ),
    );
  }

  // ---- Overlay geometry ------------------------------------------------------

  List<Widget> _buildSelectionOverlay() {
    final selection = widget.controller.selection?.normalized;
    final viewState = widget.terminalViewKey.currentState;
    final stackBox = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (selection == null ||
        viewState == null ||
        stackBox == null ||
        !stackBox.hasSize) {
      return const [];
    }
    final render = viewState.renderTerminal;
    if (!render.attached) return const [];

    final cell = render.cellSize;
    Offset toStack(Offset terminalLocal) =>
        stackBox.globalToLocal(render.localToGlobal(terminalLocal));

    // Each handle's tip sits on the text baseline: bottom-left of the first
    // selected cell, bottom of the exclusive end column for the last one.
    final startTip =
        toStack(render.getOffset(selection.begin) + Offset(0, cell.height));
    final endTip =
        toStack(render.getOffset(selection.end) + Offset(0, cell.height));
    final bounds = stackBox.size;

    bool tipVisible(Offset tip) =>
        tip.dy >= 0 && tip.dy <= bounds.height + _handleTouch;

    return [
      if (tipVisible(startTip)) _handle(tip: startTip, isStart: true),
      if (tipVisible(endTip)) _handle(tip: endTip, isStart: false),
      _actionBar(startTip, endTip, cell.height, bounds),
    ];
  }

  // ---- Handles ---------------------------------------------------------------

  Widget _handle({required Offset tip, required bool isStart}) {
    final radius = Radius.circular(_handleVisual);
    return Positioned(
      // The teardrop's square corner is its tip: top-right corner for the
      // start handle (body hangs down-left), top-left for the end handle.
      left: isStart ? tip.dx - _handleTouch : tip.dx,
      top: tip.dy,
      width: _handleTouch,
      height: _handleTouch,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onPanStart: (details) => _onHandlePanStart(isStart, details),
        onPanUpdate: _onHandlePanUpdate,
        onPanEnd: (_) => _dragFixed = null,
        onPanCancel: () => _dragFixed = null,
        child: Align(
          alignment: isStart ? Alignment.topRight : Alignment.topLeft,
          child: Container(
            width: _handleVisual,
            height: _handleVisual,
            decoration: BoxDecoration(
              color: AppColors.bone,
              border: Border.all(color: AppColors.ink, width: 1),
              borderRadius: BorderRadius.only(
                topLeft: isStart ? radius : Radius.zero,
                topRight: isStart ? Radius.zero : radius,
                bottomLeft: radius,
                bottomRight: radius,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onHandlePanStart(bool isStart, DragStartDetails details) {
    final selection = widget.controller.selection?.normalized;
    final viewState = widget.terminalViewKey.currentState;
    if (selection == null || viewState == null) return;
    final render = viewState.renderTerminal;

    _dragIsStart = isStart;
    _dragFixed = isStart ? selection.end : selection.begin;
    final initialCell = isStart ? selection.begin : selection.end;
    _dragActiveRow = initialCell.y;

    // Remember where the finger landed relative to the handle's tip so the
    // selection edge tracks the tip, not the center of the finger.
    final tipLocal =
        render.getOffset(initialCell) +
            Offset(0, render.cellSize.height);
    _dragTipDelta = details.globalPosition - render.localToGlobal(tipLocal);
  }

  void _onHandlePanUpdate(DragUpdateDetails details) {
    final fixed = _dragFixed;
    final viewState = widget.terminalViewKey.currentState;
    if (fixed == null || viewState == null) return;
    final render = viewState.renderTerminal;

    final tipLocal = render.globalToLocal(details.globalPosition - _dragTipDelta);
    // The tip rides the baseline; the character being selected is the one in
    // the row above it.
    final cellHeight = render.cellSize.height;
    final rawCellOffset =
        render.getCellOffset(tipLocal - Offset(0, cellHeight / 2));

    if (_dragActiveRow != null) {
      final activeBaselineY =
          render.getOffset(CellOffset(0, _dragActiveRow!)).dy + cellHeight;
      final dyDiff = tipLocal.dy - activeBaselineY;
      if (dyDiff.abs() > 2.2 * cellHeight) {
        _dragActiveRow = rawCellOffset.y;
      }
    } else {
      _dragActiveRow = rawCellOffset.y;
    }

    final cellOffset = CellOffset(rawCellOffset.x, _dragActiveRow!);

    // Selection ranges are begin-inclusive / end-exclusive in x, hence the +1
    // when moving the end handle (mirrors RenderTerminal.selectCharacters).
    var begin = _dragIsStart ? cellOffset : fixed;
    var end = _dragIsStart
        ? fixed
        : CellOffset(cellOffset.x + 1, cellOffset.y);
    if (end.isBefore(begin)) {
      final swap = begin;
      begin = end;
      end = swap;
    }
    if (begin.isEqual(end)) end = CellOffset(begin.x + 1, begin.y);

    final buffer = widget.terminal.buffer;
    widget.controller.setSelection(
      buffer.createAnchorFromOffset(begin),
      buffer.createAnchorFromOffset(end),
    );

    // Auto-scroll when the drag reaches the viewport edges.
    if (widget.scrollController.hasClients) {
      const edge = 48.0;
      final position = widget.scrollController.position;
      double delta = 0;
      if (tipLocal.dy < edge) {
        delta = -render.lineHeight;
      } else if (tipLocal.dy > render.size.height - edge) {
        delta = render.lineHeight;
      }
      if (delta != 0) {
        position.jumpTo((position.pixels + delta)
            .clamp(position.minScrollExtent, position.maxScrollExtent));
      }
    }
  }

  // ---- Floating action bar -----------------------------------------------------

  Widget _actionBar(
      Offset startTip, Offset endTip, double lineHeight, Size bounds) {
    // Prefer floating above the first selected line; fall back to below the
    // end handle, then to vertically centered when the selection fills the
    // viewport.
    var top = startTip.dy - lineHeight - _barHeight - 10;
    if (top < 6) {
      top = endTip.dy + _handleTouch * 0.7;
      if (top > bounds.height - _barHeight - 6) {
        top = (bounds.height - _barHeight) / 2;
      }
    }

    return Positioned(
      left: 0,
      right: 0,
      top: top,
      child: Center(
        child: Material(
          color: AppColors.panelHi,
          shape: RoundedRectangleBorder(
            side: BorderSide(color: AppColors.hairline, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _barAction(tr('COPIAR'), _copy),
              _barDivider(),
              _barAction(tr('PEGAR'), _paste),
              _barDivider(),
              _barAction(tr('TODO'), _selectAll),
            ],
          ),
        ),
      ),
    );
  }

  Widget _barAction(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: _barHeight,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        child: Text(label,
            style: AppText.label(10, color: AppColors.bone, spacing: 1.2)),
      ),
    );
  }

  Widget _barDivider() =>
      Container(width: 1, height: _barHeight, color: AppColors.hairline);

  // ---- Actions ---------------------------------------------------------------

  Future<void> _copy() async {
    final selection = widget.controller.selection?.normalized;
    if (selection == null) return;
    final text = widget.terminal.buffer.getText(selection);
    widget.controller.clearSelection();
    await Clipboard.setData(ClipboardData(text: text));
    widget.onToast?.call(tr('Copiado al portapapeles'));
  }

  Future<void> _paste() async {
    widget.controller.clearSelection();
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    widget.onSendInput(text);
  }

  void _selectAll() {
    final buffer = widget.terminal.buffer;
    widget.controller.setSelection(
      buffer.createAnchor(0, 0),
      buffer.createAnchor(widget.terminal.viewWidth, buffer.lines.length - 1),
    );
  }
}
