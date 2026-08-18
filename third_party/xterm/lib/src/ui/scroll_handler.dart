import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/core.dart';

/// Handles scrolling gestures in the alternate screen buffer. In alternate
/// screen buffer, the terminal don't have a scrollback buffer, instead, the
/// scroll gestures are converted to escape sequences based on the current
/// report mode declared by the application.
///
/// Patched for KALA: upstream wrapped the terminal in a second [Scrollable]
/// ([InfiniteScrollView]) whose offset changes were translated into wheel
/// events. That nested scrollable swallowed the drag before xterm's own
/// recognisers could see it, so a long press could not extend a selection.
/// Instead we run a plain [VerticalDragGestureRecognizer] that competes in the
/// gesture arena like everyone else: it loses to a long press (selection) and
/// to the joystick drag, and wins an ordinary swipe. Touch drags also get a
/// fling, which is the only way to cross a long tmux/TUI history by hand.
class TerminalScrollGestureHandler extends StatefulWidget {
  const TerminalScrollGestureHandler({
    super.key,
    required this.terminal,
    required this.getCellOffset,
    required this.getLineHeight,
    this.simulateScroll = true,
    this.forceLocalMode = false,
    required this.child,
  });

  final Terminal terminal;

  /// Returns the cell offset for a **global** pixel offset.
  final CellOffset Function(Offset) getCellOffset;

  /// Returns the pixel height of lines in the terminal.
  final double Function() getLineHeight;

  /// Whether to simulate scroll events in the terminal when the application
  /// doesn't declare it supports mouse wheel events. true by default as it
  /// is the default behavior of most terminals.
  final bool simulateScroll;

  /// Keeps this handler out of the way entirely, so the terminal behaves like
  /// it does in the normal buffer (local scrollback, no wheel reporting).
  final bool forceLocalMode;

  final Widget child;

  @override
  State<TerminalScrollGestureHandler> createState() =>
      _TerminalScrollGestureHandlerState();
}

class _TerminalScrollGestureHandlerState
    extends State<TerminalScrollGestureHandler> {
  /// Whether the application is in alternate screen buffer. If false, then this
  /// widget does nothing.
  var isAltBuffer = false;

  /// Global position of the last pointer seen, used to place the reported
  /// mouse event on the right cell (tmux routes a wheel event to the pane
  /// under the cursor, so this has to be right).
  var lastPointerPosition = Offset.zero;

  /// Pixels dragged but not yet turned into whole scroll events.
  double _accumulator = 0;

  Timer? _flingTimer;

  /// Remaining fling velocity, in pixels per second.
  double _flingVelocity = 0;

  @override
  void initState() {
    widget.terminal.addListener(_onTerminalUpdated);
    isAltBuffer = widget.terminal.isUsingAltBuffer;
    super.initState();
  }

  @override
  void dispose() {
    _flingTimer?.cancel();
    widget.terminal.removeListener(_onTerminalUpdated);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TerminalScrollGestureHandler oldWidget) {
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_onTerminalUpdated);
      widget.terminal.addListener(_onTerminalUpdated);
      isAltBuffer = widget.terminal.isUsingAltBuffer;
      _stopFling();
      _accumulator = 0;
    }
    super.didUpdateWidget(oldWidget);
  }

  void _onTerminalUpdated() {
    if (isAltBuffer != widget.terminal.isUsingAltBuffer) {
      isAltBuffer = widget.terminal.isUsingAltBuffer;
      _stopFling();
      _accumulator = 0;
      setState(() {});
    }
  }

  /// Send a single scroll event to the terminal. If [simulateScroll] is true,
  /// then if the application doesn't recognize mouse wheel events, this method
  /// will simulate scroll events by sending up/down arrow keys.
  void _sendScrollEvent(bool up) {
    final position = widget.getCellOffset(lastPointerPosition);

    final handled = widget.terminal.mouseInput(
      up ? TerminalMouseButton.wheelUp : TerminalMouseButton.wheelDown,
      TerminalMouseButtonState.down,
      position,
    );

    if (!handled && widget.simulateScroll) {
      widget.terminal.keyInput(
        up ? TerminalKey.arrowUp : TerminalKey.arrowDown,
      );
    }
  }

  /// Turns whole lines of accumulated movement into scroll events. A positive
  /// accumulator means the content was dragged *down*, which reveals earlier
  /// output — a wheel-up.
  void _flush() {
    final lineHeight = widget.getLineHeight();
    if (lineHeight <= 0) return;
    // Bounded so a pathological delta can't lock up the frame.
    var budget = 64;
    while (_accumulator.abs() >= lineHeight && budget-- > 0) {
      final up = _accumulator > 0;
      _sendScrollEvent(up);
      _accumulator += up ? -lineHeight : lineHeight;
    }
    if (budget <= 0) _accumulator = 0;
  }

  // ---- Touch drag ----------------------------------------------------------

  void _onDragStart(DragStartDetails details) {
    _stopFling();
    lastPointerPosition = details.globalPosition;
    _accumulator = 0;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    lastPointerPosition = details.globalPosition;
    _accumulator += details.delta.dy;
    _flush();
  }

  void _onDragEnd(DragEndDetails details) {
    _startFling(details.velocity.pixelsPerSecond.dy);
  }

  void _startFling(double velocity) {
    _stopFling();
    // Only fling when the application actually consumes wheel events. When it
    // doesn't, [_sendScrollEvent] falls back to arrow keys, and a fling would
    // dump a hundred of them into whatever has the prompt.
    if (!widget.terminal.mouseMode.reportScroll) return;
    if (velocity.abs() < _minFlingVelocity) return;
    _flingVelocity = velocity.clamp(-_maxFlingVelocity, _maxFlingVelocity);
    _flingTimer = Timer.periodic(_flingTick, (timer) {
      if (!mounted) {
        _stopFling();
        return;
      }
      _accumulator += _flingVelocity * (_flingTick.inMilliseconds / 1000);
      _flush();
      _flingVelocity *= _flingFriction;
      if (_flingVelocity.abs() < _minFlingVelocity / 2) _stopFling();
    });
  }

  void _stopFling() {
    _flingTimer?.cancel();
    _flingTimer = null;
    _flingVelocity = 0;
  }

  // Every scroll event this emits makes the remote application repaint and
  // push a full screen back over SSH, so the fling runs at half frame rate:
  // at 60Hz a single flick buried the link in redraws.
  static const _flingTick = Duration(milliseconds: 32);
  static const _flingFriction = 0.88;
  static const _minFlingVelocity = 240.0;
  static const _maxFlingVelocity = 6000.0;

  // ---- Mouse wheel ---------------------------------------------------------

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    _stopFling();
    lastPointerPosition = event.position;
    // A wheel-down (positive dy) reveals later output, the opposite sign of a
    // drag that pulls the content down.
    _accumulator -= event.scrollDelta.dy;
    _flush();
  }

  @override
  Widget build(BuildContext context) {
    if (!isAltBuffer || widget.forceLocalMode) {
      return widget.child;
    }

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerSignal: _onPointerSignal,
      onPointerDown: (event) {
        lastPointerPosition = event.position;
        _stopFling();
      },
      child: RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: <Type, GestureRecognizerFactory>{
          VerticalDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<
                  VerticalDragGestureRecognizer>(
            () => VerticalDragGestureRecognizer(
              debugOwner: this,
              supportedDevices: const {
                PointerDeviceKind.touch,
                PointerDeviceKind.stylus,
                PointerDeviceKind.invertedStylus,
                PointerDeviceKind.trackpad,
              },
            ),
            (VerticalDragGestureRecognizer instance) {
              instance
                ..onStart = _onDragStart
                ..onUpdate = _onDragUpdate
                ..onEnd = _onDragEnd
                ..onCancel = _stopFling;
            },
          ),
        },
        child: widget.child,
      ),
    );
  }
}
