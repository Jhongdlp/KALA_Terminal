import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/terminal_shortcut.dart';
import '../models/touch_pad.dart';
import '../theme/app_theme.dart';

/// What the pad is doing right now.
enum TouchPadMode {
  /// The finger has held long enough to arm the pad, but hasn't moved yet.
  /// Drawn as a bare ring: this is the affordance the gesture never had.
  armed,

  /// Dragged past the deadzone — the direction's key is repeating.
  repeat,

  /// Held still on the armed pad: the eight slots are on screen and the one
  /// under the finger fires on release.
  radial,
}

/// The pad's on-screen half: a ring at the finger, the direction chip while a
/// key repeats, and the eight-slot radial.
///
/// It is pure paint — every pointer event belongs to `JoystickGestureRecognizer`
/// (and, for the radial, to the same already-won pointer), so the whole overlay
/// is wrapped in an [IgnorePointer] by the caller. Positions are **local** to
/// the terminal's stack.
class TouchPadOverlay extends StatelessWidget {
  const TouchPadOverlay({
    super.key,
    required this.origin,
    required this.mode,
    required this.config,
    this.current,
    this.active,
    this.accelerated = false,
    this.tension = 0,
  });

  /// Where the finger was when the pad armed; every direction is measured
  /// from here, so it is also the centre of the radial.
  final Offset origin;

  /// Where the finger is now. Null before the first move.
  final Offset? current;

  final TouchPadMode mode;
  final TouchPadConfig config;

  /// The slot the finger is currently pointing at, if any.
  final PadDirection? active;

  /// The repeat has ramped past its halfway point — drawn as a double glyph,
  /// the same way the old HUD did, because "it is going fast now" is the one
  /// thing the user cannot otherwise see.
  final bool accelerated;

  /// 0…1 pull, used to fill the ring while repeating.
  final double tension;

  static const double _ringRadius = 26;
  static const double _radialRadius = 92;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          children: [
            _ring(),
            if (mode == TouchPadMode.repeat && active != null)
              ..._repeatChips(size),
            if (mode == TouchPadMode.radial) ..._radialChips(size),
          ],
        );
      },
    );
  }

  /// The ring itself. It doubles as the radial's "release here to cancel"
  /// target, so in that mode it carries a × instead of a dot.
  Widget _ring() {
    final radial = mode == TouchPadMode.radial;
    final hot = mode == TouchPadMode.repeat && accelerated;
    return Positioned(
      left: origin.dx - _ringRadius,
      top: origin.dy - _ringRadius,
      width: _ringRadius * 2,
      height: _ringRadius * 2,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.ink.withValues(alpha: radial ? 0.92 : 0.55),
          border: Border.all(
            color: hot
                ? AppColors.accent
                : (radial || active != null)
                    ? AppColors.bone
                    : AppColors.hairline,
            width: hot ? 1.6 : 1,
          ),
        ),
        child: Center(
          child: radial
              ? Icon(Icons.close, size: 14, color: AppColors.muted)
              : _tensionDot(),
        ),
      ),
    );
  }

  /// A dot that grows with the pull, so the speed ramp is visible before the
  /// keys start flying.
  Widget _tensionDot() {
    final scale = 4.0 + 6.0 * tension.clamp(0.0, 1.0);
    return Container(
      width: scale,
      height: scale,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: accelerated ? AppColors.accent : AppColors.bone,
      ),
    );
  }

  /// While repeating: the slot's label just outside the ring, on the side the
  /// finger is pulling towards, plus the repeat glyph.
  List<Widget> _repeatChips(Size size) {
    final direction = active!;
    final shortcut = config.slot(direction);
    return [
      _chip(
        size: size,
        center: origin + direction.vector * (_ringRadius + 30),
        label: shortcut == null ? '—' : tr(shortcut.label),
        selected: true,
        accent: accelerated,
        trailing: accelerated ? '»' : null,
      ),
    ];
  }

  /// The eight slots, laid out around the origin. Chips are clamped into the
  /// viewport individually rather than moving the whole radial: the direction
  /// the finger has to travel is measured from where it actually pressed, so
  /// shifting the drawing would make the two disagree.
  List<Widget> _radialChips(Size size) {
    return [
      for (final direction in PadDirection.values)
        if (config.slot(direction) != null || !direction.isCorner)
          _chip(
            size: size,
            center: origin + direction.vector * _radialRadius,
            label: () {
              final shortcut = config.slot(direction);
              return shortcut == null ? '—' : tr(shortcut.label);
            }(),
            selected: active == direction,
            accent: false,
          ),
    ];
  }

  Widget _chip({
    required Size size,
    required Offset center,
    required String label,
    required bool selected,
    required bool accent,
    String? trailing,
  }) {
    const width = 62.0;
    const height = 30.0;
    // Keep it on screen — a slot drawn half outside the terminal cannot be
    // read, and the pad is most often used near an edge with one thumb.
    final left = (center.dx - width / 2)
        .clamp(4.0, math.max(4.0, size.width - width - 4))
        .toDouble();
    final top = (center.dy - height / 2)
        .clamp(4.0, math.max(4.0, size.height - height - 4))
        .toDouble();
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? (accent ? AppColors.accent : AppColors.bone)
              : AppColors.ink.withValues(alpha: 0.92),
          border: Border.all(
            color: selected ? Colors.transparent : AppColors.hairline,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          trailing == null ? label : '$label $trailing',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.mono(
            12,
            color: selected ? AppColors.ink : AppColors.bone,
            weight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// The pad's slots drawn as a static 3×3 grid, for the settings screen. The
/// centre cell is the cancel target, which is why it is never editable.
class TouchPadGrid extends StatelessWidget {
  const TouchPadGrid({
    super.key,
    required this.config,
    required this.onTap,
  });

  final TouchPadConfig config;
  final void Function(PadDirection direction) onTap;

  static const List<PadDirection?> _layout = [
    PadDirection.upLeft,
    PadDirection.up,
    PadDirection.upRight,
    PadDirection.left,
    null,
    PadDirection.right,
    PadDirection.downLeft,
    PadDirection.down,
    PadDirection.downRight,
  ];

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      childAspectRatio: 1.6,
      children: [
        for (final direction in _layout)
          if (direction == null)
            Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.hairline),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Icon(Icons.touch_app_outlined,
                  size: 14, color: AppColors.faint),
            )
          else
            _Cell(
              direction: direction,
              shortcut: config.slot(direction),
              onTap: () => onTap(direction),
            ),
      ],
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.direction,
    required this.shortcut,
    required this.onTap,
  });

  final PadDirection direction;
  final TerminalShortcut? shortcut;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final empty = shortcut == null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: empty ? Colors.transparent : AppColors.panelHi,
          border: Border.all(color: AppColors.hairline),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          empty ? '+' : tr(shortcut!.label),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.mono(
            13,
            color: empty ? AppColors.faint : AppColors.bone,
            weight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
