import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../services/distro_service.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';

/// Central configuration screen. Every persisted user preference lives here so
/// there is a single place to surface anything that can be tuned.
class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    // Only the theme and font size affect this screen; select them so it isn't
    // rebuilt by unrelated notifications.
    final themeChoice =
        context.select<AppState, AppThemeChoice>((s) => s.themeChoice);
    final terminalFontSize =
        context.select<AppState, double>((s) => s.terminalFontSize);
    final state = context.read<AppState>();

    return Container(
      color: AppColors.ink,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          // Not const: ScreenHeader reads the active AppColors palette at build
          // time, so a const (identical) instance would be skipped on rebuild
          // and keep the dark-theme title color when switching to light.
          ScreenHeader('Ajustes', eyebrow: 'Configuración'),

          // ---- Appearance ------------------------------------------------
          SwissPanel(
            title: 'Apariencia',
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
                child: Text('TEMA DE LA APLICACIÓN',
                    style: AppText.label(9, color: AppColors.muted)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                child: _ThemeSelector(
                  value: themeChoice,
                  onChanged: state.setThemeChoice,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ---- Terminal --------------------------------------------------
          SwissPanel(
            title: 'Terminal',
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('TAMAÑO DE FUENTE',
                          style: AppText.label(9, color: AppColors.muted)),
                    ),
                    Text('${terminalFontSize.toStringAsFixed(0)} PT',
                        style: AppText.mono(12, color: AppColors.bone)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  children: [
                    _StepButton(
                      icon: Icons.remove,
                      onTap: () => state.bumpTerminalFontSize(-1),
                    ),
                    Expanded(
                      child: Slider(
                        value: terminalFontSize,
                        min: AppState.minTerminalFontSize,
                        max: AppState.maxTerminalFontSize,
                        divisions: (AppState.maxTerminalFontSize -
                                AppState.minTerminalFontSize)
                            .round(),
                        activeColor: AppColors.bone,
                        inactiveColor: AppColors.hairline,
                        thumbColor: AppColors.bone,
                        onChanged: state.setTerminalFontSize,
                      ),
                    ),
                    _StepButton(
                      icon: Icons.add,
                      onTap: () => state.bumpTerminalFontSize(1),
                    ),
                  ],
                ),
              ),
              Hairline(),
              // Live preview of the chosen size.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Text(
                  r'user@kala:~$ echo "Hola"',
                  style: AppText.mono(terminalFontSize,
                      color: AppColors.bone),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ---- Linux environment (Android only) --------------------------
          if (Platform.isAndroid) ...[
            const _DistroPanel(),
            const SizedBox(height: 16),
          ],

          // ---- About -----------------------------------------------------
          SwissPanel(
            title: 'Acerca de',
            children: [
              _InfoRow(label: 'APLICACIÓN', value: 'KALA'),
              Hairline(),
              _InfoRow(label: 'PAQUETE', value: 'terminal_agent'),
            ],
          ),
        ],
      ),
    );
  }
}

/// Four-way segmented control: Sistema / Claro / Oscuro / OLED.
class _ThemeSelector extends StatelessWidget {
  final AppThemeChoice value;
  final ValueChanged<AppThemeChoice> onChanged;

  const _ThemeSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    const options = <(AppThemeChoice, String, IconData)>[
      (AppThemeChoice.system, 'SISTEMA', Icons.brightness_auto_outlined),
      (AppThemeChoice.light, 'CLARO', Icons.light_mode_outlined),
      (AppThemeChoice.dark, 'OSCURO', Icons.dark_mode_outlined),
      (AppThemeChoice.oled, 'OLED', Icons.contrast_outlined),
    ];

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.hairline, width: 1),
      ),
      child: Row(
        children: [
          for (int i = 0; i < options.length; i++) ...[
            if (i > 0) Container(width: 1, color: AppColors.hairline),
            Expanded(
              child: _SegmentCell(
                label: options[i].$2,
                icon: options[i].$3,
                active: value == options[i].$1,
                onTap: () => onChanged(options[i].$1),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SegmentCell extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _SegmentCell({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = active ? AppColors.ink : AppColors.bone;
    return Material(
      color: active ? AppColors.bone : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            children: [
              Icon(icon, size: 17, color: fg),
              const SizedBox(height: 6),
              Text(label,
                  style: AppText.label(8,
                      color: fg,
                      weight: active ? FontWeight.w800 : FontWeight.w600,
                      spacing: 1.0)),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _StepButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, color: AppColors.bone, size: 18),
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }
}

/// Distro selector: lists every catalog entry with its install state and the
/// available action (activate / download / delete). Watches AppState so it
/// reflects live download progress.
class _DistroPanel extends StatelessWidget {
  const _DistroPanel();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final catalog = state.distroCatalog;

    return SwissPanel(
      title: 'Entorno Linux',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Text(
            'DISTRIBUCIÓN DE LA TERMINAL LOCAL',
            style: AppText.label(9, color: AppColors.muted),
          ),
        ),
        for (int i = 0; i < catalog.length; i++) ...[
          if (i > 0) Hairline(),
          _DistroRow(distro: catalog[i], state: state),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
          child: Text(
            'La descarga de Ubuntu/Debian necesita Wi-Fi la primera vez.',
            style: AppText.label(8.5, color: AppColors.faint, spacing: 0.4),
          ),
        ),
      ],
    );
  }
}

class _DistroRow extends StatelessWidget {
  final Distro distro;
  final AppState state;
  const _DistroRow({required this.distro, required this.state});

  @override
  Widget build(BuildContext context) {
    final id = distro.id;
    final installed = state.isDistroInstalled(id);
    final busy = state.isDistroBusy(id);
    final progress = state.distroProgress(id);
    final status = state.distroStatus(id);
    final active = state.activeDistroId == id;
    // Show a determinate bar while bytes are streaming in (progress < ~100%),
    // then an indeterminate bar for the CPU phases (decompress/extract) where
    // there's no fraction to report.
    final downloading = progress != null && progress < 0.999;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Selection indicator — filled azure when this distro is active.
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 10),
            child: Icon(
              active
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: active ? const Color(0xFF007AFF) : AppColors.faint,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(distro.name,
                        style: AppText.body(13,
                            color: AppColors.bone, weight: FontWeight.w700)),
                    const SizedBox(width: 8),
                    if (active)
                      MonoTag('ACTIVA', color: const Color(0xFF007AFF))
                    else if (installed)
                      MonoTag('INSTALADO', color: AppColors.muted)
                    else
                      MonoTag('~${distro.approxSizeMb} MB',
                          color: AppColors.faint),
                  ],
                ),
                const SizedBox(height: 3),
                Text(distro.description,
                    style: AppText.label(9, color: AppColors.muted, spacing: 0.3)),
                if (busy) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: downloading ? progress : null,
                      minHeight: 4,
                      backgroundColor: AppColors.hairline,
                      valueColor: const AlwaysStoppedAnimation(Color(0xFF007AFF)),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    downloading
                        ? 'Descargando… ${(progress * 100).toStringAsFixed(0)}%'
                        : (status ?? 'Trabajando…'),
                    style: AppText.mono(10, color: AppColors.muted),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          _DistroActions(
            distro: distro,
            state: state,
            installed: installed,
            busy: busy,
            active: active,
          ),
        ],
      ),
    );
  }
}

/// The trailing action buttons for one distro row.
class _DistroActions extends StatelessWidget {
  final Distro distro;
  final AppState state;
  final bool installed;
  final bool busy;
  final bool active;
  const _DistroActions({
    required this.distro,
    required this.state,
    required this.installed,
    required this.busy,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    if (!installed) {
      return GhostButton(
        label: 'Descargar',
        icon: Icons.download_outlined,
        dense: true,
        onPressed: () => _download(context),
      );
    }

    // Installed: offer to activate (if not already) and to delete (if not active).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (!active)
          InvertedButton(
            label: 'Activar',
            dense: true,
            onPressed: () => state.setActiveDistro(distro.id),
          ),
        if (!active) const SizedBox(height: 6),
        if (!active)
          GhostButton(
            label: 'Borrar',
            icon: Icons.delete_outline,
            dense: true,
            danger: true,
            onPressed: () => _confirmDelete(context),
          ),
      ],
    );
  }

  Future<void> _download(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await state.downloadDistro(distro.id);
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('No se pudo descargar ${distro.name}: $e'),
        backgroundColor: AppColors.danger,
      ));
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text('Borrar ${distro.name}',
            style: AppText.body(15, color: AppColors.bone)),
        content: Text(
          'Se eliminará su sistema de archivos para liberar espacio. '
          'Podrás volver a descargarla cuando quieras.',
          style: AppText.body(13, color: AppColors.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancelar',
                style: AppText.label(10, color: AppColors.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Borrar',
                style: AppText.label(10, color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok == true) await state.deleteDistro(distro.id);
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
