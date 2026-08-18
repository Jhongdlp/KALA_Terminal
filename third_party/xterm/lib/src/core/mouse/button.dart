enum TerminalMouseButton {
  left(id: 0),

  middle(id: 1),

  right(id: 2),

  wheelUp(id: 64 + 0, isWheel: true),

  wheelDown(id: 64 + 1, isWheel: true),

  wheelLeft(id: 64 + 2, isWheel: true),

  wheelRight(id: 64 + 3, isWheel: true),
  ;

  /// The id that is used to report a button press or release to the terminal.
  ///
  /// Buttons 4-7 (the wheel axes) are reported with bit 6 set and the *low*
  /// two bits holding the button minus four — so wheel up is 64, not 64 + 4.
  ///
  /// Patched for KALA: upstream reported 64 + 4 … 64 + 7, which sets bit 2 —
  /// the Shift modifier. Every wheel event therefore arrived at the remote as
  /// Shift+Wheel, which tmux leaves unbound (`S-WheelUpPane` has no default
  /// binding), so scrolling a tmux session or a TUI agent did nothing at all.
  final int id;

  /// Whether this button is a mouse wheel button.
  final bool isWheel;

  const TerminalMouseButton({required this.id, this.isWheel = false});
}
