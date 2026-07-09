import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../services/app_lock.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';

/// Central configuration screen. Every persisted user preference lives here so
/// there is a single place to surface anything that can be tuned.
class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    // Only the theme, icon scale, and font size affect this screen; select them
    // so it isn't rebuilt by unrelated notifications.
    final themeChoice =
        context.select<AppState, AppThemeChoice>((s) => s.themeChoice);
    final iconScale =
        context.select<AppState, AppIconScale>((s) => s.iconScale);
    final terminalFontSize =
        context.select<AppState, double>((s) => s.terminalFontSize);
    final terminalScheme =
        context.select<AppState, String>((s) => s.terminalScheme);
    final backGestureFolders =
        context.select<AppState, bool>((s) => s.backGestureNavigatesFolders);
    final syncTerminalPath =
        context.select<AppState, bool>((s) => s.syncTerminalPath);
    final appLockEnabled =
        context.select<AppState, bool>((s) => s.appLockEnabled);
    final agentAlerts =
        context.select<AppState, bool>((s) => s.agentAlertsEnabled);
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
              Hairline(),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
                child: Text('TAMAÑO DE ICONOS',
                    style: AppText.label(9, color: AppColors.muted)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                child: _IconScaleSelector(
                  value: iconScale,
                  onChanged: state.setIconScale,
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
              Hairline(),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
                child: Text('ESQUEMA DE COLOR',
                    style: AppText.label(9, color: AppColors.muted)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                child: _SchemeSelector(
                  value: terminalScheme,
                  onChanged: state.setTerminalScheme,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ---- Explorer --------------------------------------------------
          SwissPanel(
            title: 'Explorador',
            children: [
              ToggleRow(
                label: 'GESTO ATRÁS SUBE DE CARPETA',
                description:
                    'El gesto/botón atrás sube un nivel en el explorador en '
                    'vez de volver a Conexiones.',
                value: backGestureFolders,
                onChanged: state.setBackGestureNavigatesFolders,
              ),
              Hairline(),
              ToggleRow(
                label: 'SINCRONIZAR RUTA CON TERMINAL',
                description:
                    'Al navegar en el explorador de archivos, la terminal activa '
                    'cambia automáticamente de directorio.',
                value: syncTerminalPath,
                onChanged: state.setSyncTerminalPath,
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ---- Notifications ----------------------------------------------
          SwissPanel(
            title: 'Notificaciones',
            children: [
              ToggleRow(
                label: 'AVISOS DE AGENTE',
                description:
                    'Notifica cuando una sesión pide tu atención (campana u '
                    'OSC 9/777) con la app en segundo plano — p. ej. un agente '
                    'de IA esperando tu respuesta.',
                value: agentAlerts,
                onChanged: state.setAgentAlertsEnabled,
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ---- Security --------------------------------------------------
          SwissPanel(
            title: 'Seguridad',
            children: [
              ToggleRow(
                label: 'BLOQUEO DE LA APLICACIÓN',
                description:
                    'Pide tu huella (o el bloqueo del teléfono) al abrir KALA, '
                    'para proteger tus conexiones y claves guardadas.',
                value: appLockEnabled,
                onChanged: (value) => _onAppLockChanged(context, state, value),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ---- About -----------------------------------------------------
          SwissPanel(
            title: 'Acerca de',
            children: [
              _InfoRow(label: 'APLICACIÓN', value: 'KALA'),
              Hairline(),
              _InfoRow(label: 'PAQUETE', value: 'terminal_agent'),
              Hairline(),
              const _VersionRow(),
            ],
          ),
        ],
      ),
    );
  }

  /// Turns the app lock on/off. Enabling first checks the device can actually
  /// authenticate and then requires one successful auth, so the user confirms
  /// the mechanism works before it guards the next launch (no lock-out).
  Future<void> _onAppLockChanged(
      BuildContext context, AppState state, bool value) async {
    if (!value) {
      await state.setAppLockEnabled(false);
      return;
    }

    final supported = await AppLock.instance.isSupported();
    if (!context.mounted) return;
    if (!supported) {
      _showLockUnavailable(context);
      return;
    }

    final ok = await AppLock.instance.authenticate();
    if (!ok) return;
    await state.setAppLockEnabled(true);
  }

  void _showLockUnavailable(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: BorderSide(color: AppColors.hairline),
        ),
        title: Text('BLOQUEO NO DISPONIBLE',
            style: AppText.label(11, color: AppColors.bone)),
        content: Text(
          'Configura una huella o un bloqueo de pantalla (PIN, patrón o '
          'contraseña) en los ajustes de tu teléfono y vuelve a intentarlo.',
          style: AppText.body(13, color: AppColors.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('ENTENDIDO',
                style: AppText.label(10, color: AppColors.bone)),
          ),
        ],
      ),
    );
  }
}

/// Terminal color-scheme selector: AUTO (follows the app theme) plus the
/// fixed palettes in [AppTerminalTheme.schemes]. Each cell previews the
/// scheme's background + four accent colors.
class _SchemeSelector extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const _SchemeSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.hairline, width: 1),
      ),
      child: Row(
        children: [
          for (int i = 0; i < AppTerminalTheme.schemeOptions.length; i++) ...[
            if (i > 0) Container(width: 1, color: AppColors.hairline),
            Expanded(child: _schemeCell(context, AppTerminalTheme.schemeOptions[i])),
          ],
        ],
      ),
    );
  }

  Widget _schemeCell(BuildContext context, (String, String) option) {
    final (id, label) = option;
    final active = value == id;
    final theme = AppTerminalTheme.byId(id, Theme.of(context).brightness);
    final fg = active ? AppColors.ink : AppColors.bone;

    return Material(
      color: active ? AppColors.bone : Colors.transparent,
      child: InkWell(
        onTap: () => onChanged(id),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            children: [
              // Mini palette swatch: scheme background with 4 accent dots.
              Container(
                width: 44,
                height: 18,
                decoration: BoxDecoration(
                  color: theme.background,
                  border: Border.all(color: AppColors.hairline, width: 1),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final c in [
                      theme.red,
                      theme.green,
                      theme.yellow,
                      theme.blue
                    ])
                      Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.symmetric(horizontal: 1.5),
                        decoration:
                            BoxDecoration(color: c, shape: BoxShape.circle),
                      ),
                  ],
                ),
              ),
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

/// Three-way segmented control: PEQUEÑO / MEDIO / GRANDE.
class _IconScaleSelector extends StatelessWidget {
  final AppIconScale value;
  final ValueChanged<AppIconScale> onChanged;

  const _IconScaleSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    const options = <(AppIconScale, String, IconData)>[
      (AppIconScale.small, 'PEQUEÑO', Icons.text_decrease),
      (AppIconScale.medium, 'MEDIO', Icons.format_size),
      (AppIconScale.large, 'GRANDE', Icons.text_increase),
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

/// Reads the app's version + build number from the platform package metadata
/// (the `version:` in pubspec.yaml, bumped by scripts/release.sh) and shows it
/// in the About panel, so the running build is always identifiable.
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
        return _InfoRow(label: 'VERSIÓN', value: value);
      },
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
