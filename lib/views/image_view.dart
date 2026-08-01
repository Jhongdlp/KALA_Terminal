import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme/app_theme.dart';
import '../l10n/l10n.dart';

/// Renders an image from in-memory [data] inside the editor tab, with
/// pinch/drag zoom via [InteractiveViewer]. SVG goes through flutter_svg;
/// raster formats (PNG/JPG/GIF/WebP/BMP) through [Image.memory]. [sourceName]
/// is the file path, used only to pick the SVG path by extension.
class ImageView extends StatelessWidget {
  final Uint8List data;
  final String sourceName;

  const ImageView({super.key, required this.data, required this.sourceName});

  bool get _isSvg => sourceName.toLowerCase().endsWith('.svg');

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.ink,
      width: double.infinity,
      height: double.infinity,
      child: InteractiveViewer(
        minScale: 0.5,
        maxScale: 10,
        boundaryMargin: const EdgeInsets.all(120),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _isSvg
                ? SvgPicture.memory(
                    data,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) =>
                        _ImageError(error: error),
                  )
                : Image.memory(
                    data,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.medium,
                    errorBuilder: (context, error, stackTrace) =>
                        _ImageError(error: error),
                  ),
          ),
        ),
      ),
    );
  }
}

/// Shown when the bytes can't be decoded (corrupt file, unsupported variant).
class _ImageError extends StatelessWidget {
  final Object error;

  const _ImageError({required this.error});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.broken_image_outlined, size: 36, color: AppColors.faint),
        const SizedBox(height: 14),
        Text(tr('NO SE PUDO ABRIR LA IMAGEN'),
            style: AppText.mono(9, color: AppColors.muted, spacing: 1.5)),
        const SizedBox(height: 8),
        Text('$error',
            textAlign: TextAlign.center,
            style: AppText.body(11, color: AppColors.faint)),
      ],
    );
  }
}
