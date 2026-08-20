import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../providers/app_state.dart';
import '../services/backup_service.dart';
import '../theme/app_theme.dart';
import '../widgets/adaptive_sheet.dart';
import '../widgets/swiss.dart';

/// Export / restore of the whole configuration.
///
/// Two buttons and one switch. The switch is the only interesting decision:
/// including secrets turns the backup into a plaintext file holding every
/// password and private key the user owns, so it is off by default and says so
/// in words rather than in a tooltip.
void showBackupSheet(BuildContext context) {
  showAdaptiveSheet(
    context,
    backgroundColor: AppColors.panel,
    isScrollControlled: true,
    maxWidth: 520,
    builder: (sheetCtx) => const _BackupSheet(),
  );
}

class _BackupSheet extends StatefulWidget {
  const _BackupSheet();

  @override
  State<_BackupSheet> createState() => _BackupSheetState();
}

class _BackupSheetState extends State<_BackupSheet> {
  bool _includeSecrets = false;
  bool _busy = false;
  String? _result;
  bool _resultIsError = false;

  Future<void> _export() async {
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final envelope = await BackupService.build(includeSecrets: _includeSecrets);
      final file = await BackupService.writeToDisk(envelope);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _resultIsError = false;
        _result = tr('Copia guardada en {0}', [file.path]);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _resultIsError = true;
        _result = tr('No se pudo guardar la copia: {0}', [e]);
      });
    }
  }

  Future<void> _import() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text(tr('RESTAURAR COPIA'),
            style: AppText.label(11, color: AppColors.bone, spacing: 1.4)),
        content: Text(
            tr('Los ajustes y perfiles que estén en la copia sustituirán a los actuales. Lo que no esté en ella se conserva. Tus sesiones abiertas no se tocan.'),
            style: AppText.body(12, color: AppColors.muted)),
        actions: [
          GhostButton(
              label: tr('Cancelar'),
              dense: true,
              onPressed: () => Navigator.of(ctx).pop(false)),
          GhostButton(
              label: tr('Restaurar'),
              dense: true,
              onPressed: () => Navigator.of(ctx).pop(true)),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _busy = true;
      _result = null;
    });
    final outcome = await BackupService.pickAndRestore();
    if (!mounted) return;

    if (outcome.error != null) {
      setState(() {
        _busy = false;
        _resultIsError = true;
        _result = outcome.error;
      });
      return;
    }
    if (outcome.keys == 0 && outcome.secrets == 0) {
      // The picker was dismissed — say nothing, that's not a failure.
      setState(() => _busy = false);
      return;
    }

    await context.read<AppState>().reloadFromDisk();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _resultIsError = false;
      _result = outcome.secrets > 0
          ? tr('Restaurados {0} ajustes y {1} credencial(es).',
              [outcome.keys, outcome.secrets])
          : tr('Restaurados {0} ajustes.', [outcome.keys]);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(tr('COPIA DE SEGURIDAD'),
                  style:
                      AppText.label(11, color: AppColors.bone, spacing: 1.4)),
              const SizedBox(height: 10),
              Text(
                tr('Guarda en un archivo tus servidores, grupos, prompts, teclas rápidas, colores y servidores conocidos. Sirve para cambiar de teléfono o para no perderlo todo al reinstalar.'),
                style: AppText.body(12, color: AppColors.muted),
              ),
              const SizedBox(height: 16),
              Hairline(),
              ToggleRow(
                label: tr('INCLUIR CONTRASEÑAS Y LLAVES'),
                description: tr(
                    'El archivo quedará SIN CIFRAR: cualquiera que lo abra verá tus credenciales. Actívalo sólo si vas a guardarlo en un sitio seguro.'),
                value: _includeSecrets,
                onChanged: (v) => setState(() => _includeSecrets = v),
              ),
              Hairline(),
              const SizedBox(height: 16),
              InvertedButton(
                label: tr('Exportar copia'),
                icon: Icons.upload_file,
                expand: true,
                onPressed: _busy ? null : _export,
              ),
              const SizedBox(height: 10),
              GhostButton(
                label: tr('Restaurar desde archivo'),
                icon: Icons.download_outlined,
                onPressed: _busy ? null : _import,
              ),
              if (_busy) ...[
                const SizedBox(height: 16),
                Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: AppColors.muted),
                  ),
                ),
              ],
              if (_result != null) ...[
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                        _resultIsError
                            ? Icons.error_outline
                            : Icons.check_circle_outline,
                        size: 14,
                        color: _resultIsError
                            ? AppColors.danger
                            : AppColors.accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SelectableText(_result!,
                          style: AppText.mono(10,
                              color: _resultIsError
                                  ? AppColors.danger
                                  : AppColors.muted)),
                    ),
                    if (!_resultIsError)
                      GhostButton(
                        label: tr('Copiar'),
                        dense: true,
                        onPressed: () =>
                            Clipboard.setData(ClipboardData(text: _result!)),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
