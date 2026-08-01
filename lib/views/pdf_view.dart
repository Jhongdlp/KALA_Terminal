import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import '../theme/app_theme.dart';
import '../l10n/l10n.dart';

/// Renders a PDF from in-memory [data] using pdfrx, styled to sit inside the
/// editor tab. [sourceName] identifies the document to the viewer (the file
/// path); it must be unique per open file so the viewer reloads correctly.
class PdfView extends StatelessWidget {
  final Uint8List data;
  final String sourceName;

  const PdfView({super.key, required this.data, required this.sourceName});

  @override
  Widget build(BuildContext context) {
    return PdfViewer.data(
      data,
      sourceName: sourceName,
      params: PdfViewerParams(
        backgroundColor: AppColors.ink,
        margin: 8.0,
        loadingBannerBuilder: (context, bytesDownloaded, totalBytes) => Center(
          child: Text(tr('CARGANDO PDF…'),
              style: AppText.mono(9, color: AppColors.muted, spacing: 1.5)),
        ),
        errorBannerBuilder: (context, error, stackTrace, documentRef) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 36, color: AppColors.faint),
              const SizedBox(height: 14),
              Text(tr('NO SE PUDO ABRIR EL PDF'),
                  style: AppText.mono(9, color: AppColors.muted, spacing: 1.5)),
              const SizedBox(height: 8),
              Text('$error',
                  textAlign: TextAlign.center,
                  style: AppText.body(11, color: AppColors.faint)),
            ],
          ),
        ),
      ),
    );
  }
}
