import 'dart:async';
import 'package:flutter/gestures.dart';

/// Recognises the "hold a beat, then drag" joystick that sends arrow keys to
/// the terminal.
///
/// The terminal has to host four touch gestures at once and this recogniser is
/// the one that can starve the other three, so it is deliberately shy: it never
/// claims the gesture arena up front.
///
///  * **Tap** (focus / keyboard) — we never win a sweep, we reject on pointer
///    up instead, so xterm's tap recogniser always gets it.
///  * **Swipe** (scrollback, or wheel events in the alternate buffer) — any
///    movement past [stillSlop] *before* the hold qualifies rejects us
///    immediately, so a scroll that starts slowly is still a scroll.
///  * **Long press** (text selection) — once [armWindowEnd] passes without a
///    joystick drag having started we reject ourselves, so a finger that
///    drifts while resting can no longer steal the selection.
///  * **Pinch to zoom** — a second finger going down aborts the gesture.
///
/// That leaves exactly one window in which the joystick arms: the finger sat
/// still for [holdDelay], then moved [dragThreshold] before [armWindowEnd].
/// How far it then has to travel before arrows actually fire is the caller's
/// business (see `AppState.terminalGestureDeadzone`).
class JoystickGestureRecognizer extends OneSequenceGestureRecognizer {
  JoystickGestureRecognizer({
    required this.onJoystickStart,
    required this.onJoystickMove,
    required this.onJoystickEnd,
    this.isSelectionActive,
    super.debugOwner,
  });

  /// How long the finger must sit still before a drag counts as a joystick.
  static const holdDelay = Duration(milliseconds: 200);

  /// How far the finger may drift during [holdDelay] and still count as held.
  static const stillSlop = 9.0;

  /// How far the finger must travel *after* the hold to arm the joystick.
  ///
  /// [stillSlop] + [dragThreshold] is deliberately kept under [kTouchSlop]:
  /// the scrollable that hosts the terminal sits deeper in the tree, so its
  /// drag recogniser sees every move event first and would win the arena on
  /// any event that crosses both thresholds at once.
  static const dragThreshold = 8.0;

  /// When the joystick gives up so a long press can start a selection. Kept a
  /// hair under [kLongPressTimeout] so the outcome doesn't depend on which of
  /// two timers scheduled for the same instant happens to fire first.
  static const armWindowEnd = Duration(milliseconds: 460);

  void Function(Offset) onJoystickStart;
  void Function(Offset) onJoystickMove;
  void Function() onJoystickEnd;

  /// Returns true while a text selection is on screen. The joystick stands
  /// down then, so the selection handles and tap-to-dismiss keep working.
  bool Function()? isSelectionActive;

  Timer? _holdTimer;
  Timer? _abortTimer;
  Offset? _origin;

  /// Where the finger was when the hold qualified; the joystick drag is
  /// measured from here so drift during the hold doesn't count towards it.
  Offset? _holdOrigin;
  Offset? _lastPosition;
  int? _pointer;

  /// The finger stayed still for [holdDelay]; a drag may now arm the joystick.
  bool _qualified = false;

  /// This sequence can no longer become a joystick.
  bool _disqualified = false;

  /// We won the arena and are emitting arrow keys.
  bool _active = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_pointer != null) {
      // A second finger — this is a pinch, not a joystick.
      _abort();
      return;
    }
    if (isSelectionActive?.call() == true) return;

    startTrackingPointer(event.pointer, event.transform);
    _pointer = event.pointer;
    _origin = event.position;
    _lastPosition = event.position;
    _holdOrigin = null;
    _qualified = false;
    _disqualified = false;
    _active = false;

    _holdTimer = Timer(holdDelay, () {
      _qualified = true;
      _holdOrigin = _lastPosition;
    });
    // Past this deadline the finger belongs to text selection.
    _abortTimer = Timer(armWindowEnd, () {
      if (!_active) _abort();
    });
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;

    if (event is PointerMoveEvent) {
      final origin = _origin;
      if (origin == null) return;
      _lastPosition = event.position;

      if (_active) {
        onJoystickMove(event.position);
        return;
      }
      if (_disqualified) return;

      if (!_qualified) {
        // Moved before the hold qualified: it's a swipe, let it scroll.
        if ((event.position - origin).distance > stillSlop) _abort();
        return;
      }
      final holdOrigin = _holdOrigin ?? origin;
      if ((event.position - holdOrigin).distance > dragThreshold) {
        if (isSelectionActive?.call() == true) {
          _abort();
          return;
        }
        _active = true;
        _holdTimer?.cancel();
        _abortTimer?.cancel();
        resolve(GestureDisposition.accepted);
        onJoystickStart(holdOrigin);
        onJoystickMove(event.position);
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (_active) {
        stopTrackingPointer(event.pointer);
      } else {
        // Never armed: hand the pointer back to the tap / long-press
        // recognisers rather than winning the sweep.
        _abort();
      }
    }
  }

  /// Gives up this sequence for good. Safe to call more than once.
  void _abort() {
    if (_disqualified && _pointer == null) return;
    _disqualified = true;
    _holdTimer?.cancel();
    _holdTimer = null;
    _abortTimer?.cancel();
    _abortTimer = null;
    if (_pointer != null) resolve(GestureDisposition.rejected);
  }

  @override
  void rejectGesture(int pointer) {
    super.rejectGesture(pointer);
    if (_pointer == pointer) {
      stopTrackingPointer(pointer);
      _reset();
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) => _reset();

  void _reset() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _abortTimer?.cancel();
    _abortTimer = null;
    final wasActive = _active;
    _active = false;
    _qualified = false;
    _disqualified = false;
    _origin = null;
    _holdOrigin = null;
    _lastPosition = null;
    _pointer = null;
    if (wasActive) onJoystickEnd();
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _abortTimer?.cancel();
    super.dispose();
  }

  @override
  String get debugDescription => 'joystick';
}
