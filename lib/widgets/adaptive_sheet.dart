import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/breakpoints.dart';
import '../theme/dimens.dart';

/// Presents [builder] as a bottom sheet on a compact layout, and as a centred,
/// width-constrained dialog on a desktop one.
///
/// A bottom sheet is a phone idiom: on a 1920px window it becomes a full-width
/// strip glued to the bottom edge, far from wherever the user clicked. This
/// keeps the touch presentation exactly as it was and swaps it above
/// [Layout.kDesktop].
///
/// The signature mirrors [showModalBottomSheet] and returns the same
/// `Future<T?>`, so migrating a call site is a rename plus one or two optional
/// arguments. Sheet bodies generally need no change: they already use
/// `MainAxisSize.min` with a `Flexible` list, which lays out correctly inside a
/// bounded dialog.
///
/// The width class is read from the **calling** context, before the route is
/// pushed — a sheet builder runs on a route above the shell and cannot see the
/// [Layout] inherited widget, so it falls back to `MediaQuery` there.
Future<T?> showAdaptiveSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool isDismissible = true,

  /// Fraction of the viewport height the content may occupy, as a **maximum** —
  /// shorter content still sizes to itself, matching what the migrated call
  /// sites expressed as `constraints: BoxConstraints(maxHeight: …)`.
  ///
  /// Leave null to keep Flutter's own default cap on the compact layout.
  double? heightFactor,

  /// Desktop only. Pick per content: pickers/lists ~460–520, forms ~560,
  /// detail views ~720, diffs and logs ~1000.
  double maxWidth = 560,
  Color? backgroundColor,
}) {
  final isDesktop = Layout.maybeOf(context)?.isDesktop ??
      (MediaQuery.sizeOf(context).width >= Layout.kDesktop);

  if (!isDesktop) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: backgroundColor ?? AppColors.panel,
      isScrollControlled: isScrollControlled,
      isDismissible: isDismissible,
      constraints: heightFactor == null
          ? null
          : BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * heightFactor,
            ),
      builder: builder,
    );
  }

  return showDialog<T>(
    context: context,
    barrierDismissible: isDismissible,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(Dim.x8),
      backgroundColor: backgroundColor ?? AppColors.panel,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: MediaQuery.sizeOf(ctx).height * (heightFactor ?? 0.9),
        ),
        // Sheet bodies assume an ambient Material (InkWell ripples, ListTile).
        // Dialog supplies one, but its own surface would double-paint the
        // sheet's background, so keep this layer transparent.
        child: Material(color: Colors.transparent, child: builder(ctx)),
      ),
    ),
  );
}
