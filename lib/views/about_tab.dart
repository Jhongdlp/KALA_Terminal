import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import 'whats_new_sheet.dart';
import '../widgets/swiss.dart';
import 'update_dialog.dart';
import '../l10n/l10n.dart';

/// Tab for displaying application information, the official icon, version info,
/// and checking for updates.
class AboutTab extends StatelessWidget {
  const AboutTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ContentColumn(
      color: AppColors.ink,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          ScreenHeader(tr('Acerca De'), eyebrow: tr('Información y Actualización')),

          // Premium App Logo presentation
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 32.0),
              child: Column(
                children: [
                  Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      color: AppColors.panel,
                      border: Border.all(color: AppColors.accent, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.accent.withOpacity(0.12),
                          blurRadius: 16,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Center(
                      child: Image.asset(
                        'assets/images/kammel_logo.png',
                        width: 56,
                        color: AppColors.accent,
                        filterQuality: FilterQuality.medium,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'KAMMEL SSH',
                    style: AppText.display(26, color: AppColors.bone),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    tr('CLIENTE SSH & TERMINAL AGENTE'),
                    style: AppText.mono(8.5, color: AppColors.muted, spacing: 1.5),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 8),

          SwissPanel(
            title: tr('Detalles de la Aplicación'),
            children: [
              _InfoRow(label: tr('APLICACIÓN'), value: 'KAMMEL SSH'),
              Hairline(),
              _InfoRow(label: tr('PAQUETE'), value: 'terminal_agent'),
              Hairline(),
              _InfoRow(label: tr('SITIO WEB'), value: 'kammel.app'),
              Hairline(),
              const _VersionRow(),
              Hairline(),
              const _ChangelogRow(),
              Hairline(),
              const _UpdateCheckRow(),
            ],
          ),
        ],
      ),
    );
  }
}

class _VersionRow extends StatelessWidget {
  const _VersionRow();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        final info = snapshot.data;
        final value = info == null
            ? '…'
            : '${info.version}+${info.buildNumber}';
        return _InfoRow(label: tr('VERSIÓN'), value: value);
      },
    );
  }
}

/// Opens the full version history. The changelog is shown automatically once
/// after an update; this is how someone who dismissed it — or who wants to know
/// what a version they skipped brought — gets back to it.
class _ChangelogRow extends StatelessWidget {
  const _ChangelogRow();

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => showChangelog(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(tr('NOVEDADES'),
                  style: AppText.label(9, color: AppColors.muted)),
            ),
            Text(tr('VER HISTORIAL'),
                style: AppText.mono(11, color: AppColors.bone)),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right, size: 16, color: AppColors.muted),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: AppText.label(9, color: AppColors.muted)),
          ),
          Text(value, style: AppText.mono(12, color: AppColors.bone)),
        ],
      ),
    );
  }
}

class _UpdateCheckRow extends StatefulWidget {
  const _UpdateCheckRow();

  @override
  State<_UpdateCheckRow> createState() => _UpdateCheckRowState();
}

class _UpdateCheckRowState extends State<_UpdateCheckRow> {
  bool _checking = false;

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final update = await UpdateService.checkForUpdate();
      if (!mounted) return;
      if (update != null) {
        showUpdateDialog(context, update);
      } else {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                tr('Ya tienes la última versión instalada'),
                style: AppText.mono(11, color: AppColors.bone),
              ),
              backgroundColor: AppColors.panelHi,
            ),
          );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              tr('Error al buscar actualizaciones'),
              style: AppText.mono(11, color: AppColors.bone),
            ),
            backgroundColor: AppColors.panelHi,
          ),
        );
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: _checking ? null : _check,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                tr('ACTUALIZACIONES'),
                style: AppText.label(9, color: AppColors.muted),
              ),
            ),
            if (_checking)
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  valueColor: AlwaysStoppedAnimation(AppColors.accent),
                ),
              )
            else
              Text(
                tr('BUSCAR ACTUALIZACIONES'),
                style: AppText.mono(12, color: AppColors.accent, weight: FontWeight.w700),
              ),
          ],
        ),
      ),
    );
  }
}
