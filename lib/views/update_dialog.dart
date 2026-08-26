import 'package:flutter/material.dart';

import '../services/update_service.dart';
import '../theme/app_theme.dart';
import 'release_notes_view.dart';
import '../l10n/l10n.dart';

/// Shows the "new version available" dialog for [update]. While downloading it
/// is non-dismissible and swaps its actions for a progress bar; on success the
/// system installer takes over, on failure it surfaces a SnackBar.
Future<void> showUpdateDialog(BuildContext context, AppUpdate update) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (_) => _UpdateDialog(update: update),
  );
}

class _UpdateDialog extends StatefulWidget {
  final AppUpdate update;
  const _UpdateDialog({required this.update});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _downloading = false;
  double _progress = 0;

  Future<void> _start() async {
    setState(() => _downloading = true);
    final error = await UpdateService.downloadAndInstall(
      widget.update,
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
    );
    if (!mounted) return;
    Navigator.of(context).pop();
    if (error != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final notes = widget.update.notes;
    return PopScope(
      // Block back-dismiss mid-download so the file finishes writing.
      canPop: !_downloading,
      child: AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        title: Row(
          children: [
            Icon(Icons.system_update_alt, size: 18, color: AppColors.bone),
            const SizedBox(width: 10),
            Text(tr('NUEVA VERSIÓN'), style: AppText.label(12, color: AppColors.bone)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('Versión {0} disponible', [widget.update.version]),
              style: AppText.body(14, color: AppColors.bone),
            ),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                constraints: const BoxConstraints(maxHeight: 260),
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.ink,
                  border: Border.all(color: AppColors.hairline, width: 1),
                ),
                child: SingleChildScrollView(
                  child: ReleaseNotesView(notes),
                ),
              ),
              const SizedBox(height: 8),
              // These notes come off GitHub and are generated in English (see
              // scripts/changelog_notes.py). Saying so is cheaper than leaving
              // a Spanish or Chinese user wondering why one box switched
              // language; the same list arrives translated in NOVEDADES once
              // the update is installed.
              Text(
                tr('Resumen en inglés. Lo verás en tu idioma en NOVEDADES tras actualizar.'),
                style: AppText.body(10, color: AppColors.faint),
              ),
            ],
            if (_downloading) ...[
              const SizedBox(height: 18),
              ClipRect(
                child: LinearProgressIndicator(
                  value: _progress > 0 ? _progress : null,
                  minHeight: 4,
                  backgroundColor: AppColors.hairline,
                  valueColor: AlwaysStoppedAnimation(AppColors.bone),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _progress > 0
                    ? tr('Descargando {0}%', [(_progress * 100).toStringAsFixed(0)])
                    : tr('Descargando…'),
                style: AppText.mono(10, color: AppColors.muted),
              ),
            ],
          ],
        ),
        actions: _downloading
            ? null
            : [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(tr('DESPUÉS'),
                      style: AppText.label(11, color: AppColors.muted)),
                ),
                TextButton(
                  onPressed: _start,
                  child: Text(tr('ACTUALIZAR'),
                      style: AppText.label(11, color: AppColors.bone)),
                ),
              ],
      ),
    );
  }
}
