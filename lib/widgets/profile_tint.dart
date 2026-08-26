import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/connection_profile.dart';
import '../theme/app_theme.dart';
import 'color_picker_dialog.dart';

/// Per-profile signal color: the one hue allowed into a deliberately
/// monochrome UI.
///
/// The palette carries no hue precisely so that emphasis reads as structure
/// (inversion, hairlines) rather than decoration — so a color here has to earn
/// its place. It does: four SSH sessions are four identical black rectangles of
/// monospaced text, and the cost of typing the right command into the wrong one
/// is unbounded. The stripe answers "which machine am I on?" before the user
/// has read a single character.
///
/// It is therefore drawn as a **stripe or a dot, never a fill**: it must be
/// visible at a glance and still never compete with the content for contrast.

/// Presets offered in the profile form. Chosen to stay distinguishable from
/// each other *and* legible against both the dark and the paper palettes — a
/// pastel would vanish on paper, a neon would burn on OLED.
const List<(String, String)> kProfileColorPresets = [
  ('ROJO', '#E63946'),
  ('NARANJA', '#FF7A00'),
  ('ÁMBAR', '#E3B341'),
  ('VERDE', '#3FB950'),
  ('CIAN', '#22B8CF'),
  ('AZUL', '#4C8DFF'),
  ('VIOLETA', '#8B5CF6'),
  ('ROSA', '#E056A0'),
];

/// The color a profile signals with, or null when it signals nothing.
///
/// A production profile with no color of its own falls back to [AppColors
/// .danger] rather than staying untinted: marking a machine as production and
/// getting no visible difference would make the switch a lie.
Color? profileTint(ConnectionProfile? profile) {
  if (profile == null) return null;
  final custom =
      profile.colorHex == null ? null : AppColors.parseHex(profile.colorHex!);
  if (custom != null) return custom;
  return profile.isProduction ? AppColors.danger : null;
}

/// Vertical stripe for the leading edge of a list row. Collapses to nothing
/// (not to a gap) when the profile has no color, so untinted rows keep the
/// exact layout they had before.
class ProfileTintBar extends StatelessWidget {
  final Color? tint;
  final double height;

  const ProfileTintBar({super.key, required this.tint, this.height = 26});

  @override
  Widget build(BuildContext context) {
    if (tint == null) return const SizedBox.shrink();
    return Container(width: 3, height: height, color: tint);
  }
}

/// Horizontal band pinned to the top of the terminal. Deliberately drawn
/// *outside* the toolbar so it survives fullscreen: fullscreen is exactly when
/// the user has the least context about which session they are typing into.
class ProfileTintBand extends StatelessWidget {
  final Color? tint;

  const ProfileTintBand({super.key, required this.tint});

  @override
  Widget build(BuildContext context) {
    if (tint == null) return const SizedBox.shrink();
    return Container(height: 3, color: tint);
  }
}

/// `PROD` chip. Outlined in the tint rather than filled with it: a filled block
/// at this size reads as a button, and this is not one.
class ProdBadge extends StatelessWidget {
  final Color? tint;

  const ProdBadge({super.key, this.tint});

  @override
  Widget build(BuildContext context) {
    final color = tint ?? AppColors.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(border: Border.all(color: color, width: 1)),
      child: Text(tr('PROD'),
          style: AppText.mono(8, color: color, spacing: 0.8)),
    );
  }
}

/// Swatch row used by the profile form: the presets, a custom slot and "none".
class ProfileColorPicker extends StatelessWidget {
  final String? selectedHex;
  final ValueChanged<String?> onChanged;

  const ProfileColorPicker({
    super.key,
    required this.selectedHex,
    required this.onChanged,
  });

  bool get _isPreset =>
      kProfileColorPresets.any((p) => p.$2 == selectedHex?.toUpperCase());

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _Swatch(
          color: null,
          selected: selectedHex == null,
          label: tr('Sin color'),
          onTap: () => onChanged(null),
        ),
        for (final preset in kProfileColorPresets)
          _Swatch(
            color: AppColors.parseHex(preset.$2),
            selected: selectedHex?.toUpperCase() == preset.$2,
            label: tr(preset.$1),
            onTap: () => onChanged(preset.$2),
          ),
        // The custom slot shows the chosen color when it is not one of the
        // presets, so a hand-picked hue is visibly still selected.
        _Swatch(
          color: !_isPreset && selectedHex != null
              ? AppColors.parseHex(selectedHex!)
              : null,
          selected: !_isPreset && selectedHex != null,
          label: tr('Color personalizado'),
          icon: Icons.colorize,
          onTap: () async {
            final hex = await ColorPickerDialog.show(
              context,
              initialColor: (selectedHex == null
                      ? null
                      : AppColors.parseHex(selectedHex!)) ??
                  AppColors.accent,
            );
            if (hex != null) onChanged(hex.toUpperCase());
          },
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color? color;
  final bool selected;
  final String label;
  final IconData? icon;
  final VoidCallback onTap;

  const _Swatch({
    required this.color,
    required this.selected,
    required this.label,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      selected: selected,
      button: true,
      child: Tooltip(
        message: label,
        child: InkWell(
          onTap: onTap,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: color ?? Colors.transparent,
              // The selected swatch is ringed rather than checked: a tick mark
              // needs a contrasting color, which none of these hues guarantees.
              border: Border.all(
                color: selected ? AppColors.bone : AppColors.hairline,
                width: selected ? 2 : 1,
              ),
            ),
            child: color == null
                ? Icon(icon ?? Icons.block,
                    size: 14,
                    color: selected ? AppColors.bone : AppColors.faint)
                : null,
          ),
        ),
      ),
    );
  }
}
