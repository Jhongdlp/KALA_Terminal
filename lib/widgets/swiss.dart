import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../theme/breakpoints.dart';
import '../theme/dimens.dart';

/// A full-bleed background with its content clamped to a readable column.
///
/// Drop-in replacement for the `Container(color: AppColors.ink, child: …)` that
/// every list-style screen used as its root: the colour still paints edge to
/// edge, but the scrollable stops stretching 8pt labels across the full width
/// of a desktop window. A no-op below [maxWidth], so the compact layout is
/// unchanged.
///
/// Wraps the whole scrollable, header included — centring each panel on its own
/// would leave a ragged left edge.
class ContentColumn extends StatelessWidget {
  /// Background, painted full width. Defaults to the app canvas.
  final Color? color;
  final double maxWidth;
  final Widget child;

  const ContentColumn({
    super.key,
    this.color,
    this.maxWidth = Dim.contentMax,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: color ?? AppColors.ink,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: child,
          ),
        ),
      );
}

/// 1px hairline divider.
class Hairline extends StatelessWidget {
  final double indent;
  final double endIndent;
  const Hairline({super.key, this.indent = 0, this.endIndent = 0});

  @override
  Widget build(BuildContext context) => Container(
        height: 1,
        margin: EdgeInsets.only(left: indent, right: endIndent),
        color: AppColors.hairline,
      );
}

/// Giant uppercase Anton wordmark for a screen, with a small mono eyebrow.
class ScreenHeader extends StatelessWidget {
  final String title;
  final String? eyebrow;
  final Widget? trailing;
  final Widget? leading;
  const ScreenHeader(this.title, {super.key, this.eyebrow, this.trailing, this.leading});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (eyebrow != null) ...[
                  Text(eyebrow!.toUpperCase(),
                      style: AppText.mono(9,
                          color: AppColors.muted, spacing: 2)),
                  const SizedBox(height: 6),
                ],
                Text(
                  title.toUpperCase(),
                  style: AppText.display(46),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ],
      ),
    );
  }
}

/// A bordered "panel" (Photoshop-layers container) with a mono title bar.
class SwissPanel extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final List<Widget> children;
  final EdgeInsetsGeometry margin;

  const SwissPanel({
    super.key,
    required this.title,
    required this.children,
    this.trailing,
    this.margin = const EdgeInsets.symmetric(horizontal: 16),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.hairline, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Title bar
          Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: AppColors.hairline, width: 1),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(title.toUpperCase(),
                      style: AppText.label(9,
                          color: AppColors.muted, spacing: 1.6)),
                ),
                ?trailing,
              ],
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}

/// A "layer" row: leading glyph, title, mono meta, optional trailing.
/// When [active] the row inverts to a bone block with ink text.
class LayerRow extends StatelessWidget {
  final Widget glyph;
  final String title;
  final String? meta;
  final Widget? trailing;
  final bool active;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onTrailingTap;

  const LayerRow({
    super.key,
    required this.glyph,
    required this.title,
    this.meta,
    this.trailing,
    this.active = false,
    this.onTap,
    this.onLongPress,
    this.onTrailingTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = active ? AppColors.ink : AppColors.bone;
    final metaFg = active ? AppColors.ink : AppColors.muted;

    // Material *outside* the InkWell, not a Container inside it: an opaque
    // child painted over the ink swallows the hover and focus overlays, which
    // is why rows never highlighted under a mouse. Material also gives the row
    // a click cursor for free when onTap is set.
    return Material(
      color: active ? AppColors.accent : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 12,
            // Desktop trades touch target for density.
            vertical: Dim.rowPadV(
              Layout.maybeOf(context)?.widthClass ?? WidthClass.compact,
            ),
          ),
          child: Row(
            children: [
              IconTheme(
                data: IconThemeData(color: fg, size: 16),
                child: glyph,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style:
                            AppText.body(13, color: fg, weight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    if (meta != null) ...[
                      const SizedBox(height: 3),
                      Text(meta!,
                          style: AppText.mono(10, color: metaFg, spacing: 0.2),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: onTrailingTap,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    child: IconTheme(
                      data: IconThemeData(
                          color: active ? AppColors.ink : AppColors.muted,
                          size: 16),
                      child: trailing!,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Primary action: inverted bone block with ink label (the BOUNCE button).
class InvertedButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool dense;
  final bool expand;

  const InvertedButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.dense = false,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final bg = enabled ? AppColors.accent : AppColors.hairline;
    final fg = enabled ? AppColors.ink : AppColors.muted;
    final factor = context.select<AppState, double>((s) => s.uiIconFactor);
    final iconSz = ((dense ? 13.0 : 15.0) * factor).roundToDouble();
    final child = Material(
      color: bg,
      child: InkWell(
        onTap: onPressed,
        // Don't steal focus when tapped: otherwise tapping this button while a
        // TextField is focused (e.g. inside the SSH profile sheet) dismisses the
        // keyboard, the sheet reflows on the shrinking viewInsets, and the
        // in-flight tap is cancelled — so the first tap appears to do nothing.
        canRequestFocus: false,
        child: Padding(
          padding: EdgeInsets.symmetric(
              horizontal: dense ? 10 : 16, vertical: dense ? 7 : 12),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: iconSz, color: fg),
                const SizedBox(width: 7),
              ],
              // Flexible, not bare: a long label on a narrow phone otherwise
              // overflows the button instead of ellipsising inside it.
              Flexible(
                child: Text(label.toUpperCase(),
                    style: AppText.label(dense ? 9 : 10,
                        color: fg, weight: FontWeight.w800, spacing: 1.0),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: child) : child;
  }
}

/// Secondary action: hairline outline, bone label. [danger] thickens emphasis.
class GhostButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool dense;
  final bool danger;

  const GhostButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.dense = false,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = danger ? AppColors.danger : AppColors.bone;
    final factor = context.select<AppState, double>((s) => s.uiIconFactor);
    final iconSz = ((dense ? 13.0 : 15.0) * factor).roundToDouble();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        // See InvertedButton: keep focus on the active TextField so tapping this
        // button doesn't close the keyboard and cancel its own tap.
        canRequestFocus: false,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
                color: danger ? AppColors.danger : AppColors.hairline, width: 1),
          ),
          padding: EdgeInsets.symmetric(
              horizontal: dense ? 10 : 16, vertical: dense ? 7 : 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: iconSz, color: fg),
                const SizedBox(width: 7),
              ],
              Flexible(
                child: Text(label.toUpperCase(),
                    style: AppText.label(dense ? 9 : 10,
                        color: fg, weight: FontWeight.w800, spacing: 1.0),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tiny mono uppercase tag (LOCAL / REMOTO (SFTP) / CARPETA / size).
class MonoTag extends StatelessWidget {
  final String text;
  final bool bordered;
  // Nullable so it can default to the (mutable, theme-dependent) AppColors.muted
  // resolved at build time — a non-const default value isn't allowed here.
  final Color? color;
  const MonoTag(this.text,
      {super.key, this.bordered = false, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.muted;
    final label = Text(text.toUpperCase(),
        style: AppText.mono(8, color: c, spacing: 1.0));
    if (!bordered) return label;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(border: Border.all(color: c, width: 1)),
      child: label,
    );
  }
}

/// A labelled on/off row: uppercase label + helper text on the left, a Switch
/// on the right. Matches the flat IDE styling used across settings and forms.
class ToggleRow extends StatelessWidget {
  final String label;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;

  const ToggleRow({
    super.key,
    required this.label,
    required this.description,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 8, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppText.label(9, color: AppColors.muted)),
                const SizedBox(height: 5),
                Text(description,
                    style: AppText.label(8.5,
                        color: AppColors.faint, spacing: 0.3)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppColors.ink,
            activeTrackColor: AppColors.accent,
            inactiveThumbColor: AppColors.muted,
            inactiveTrackColor: AppColors.hairline,
          ),
        ],
      ),
    );
  }
}
