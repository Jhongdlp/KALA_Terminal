import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../services/app_lock.dart';
import '../services/device_key.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';
import 'update_dialog.dart';
import 'shortcut_manager_sheet.dart';

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
    final accentColorHex =
        context.select<AppState, String>((s) => s.accentColorHex);
    final monoFontChoice =
        context.select<AppState, String>((s) => s.monoFontChoice);
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
              Hairline(),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
                child: Text('COLOR DE ACENTO (MONOCHROME-PLUS)',
                    style: AppText.label(9, color: AppColors.muted)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                child: _AccentColorSelector(
                  value: accentColorHex,
                  onChanged: state.setAccentColorHex,
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
              Hairline(),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
                child: Text('TIPOGRAFÍA MONOESPACIADA',
                    style: AppText.label(9, color: AppColors.muted)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                child: _FontSelector(
                  value: monoFontChoice,
                  onChanged: state.setMonoFontChoice,
                ),
              ),
              Hairline(),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
                child: Text('DISTRIBUCIÓN DE ATAJOS',
                    style: AppText.label(9, color: AppColors.muted)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                child: _ShortcutLayoutSelector(
                  value: state.shortcutLayout,
                  onChanged: state.setShortcutLayout,
                ),
              ),
              Hairline(),
              ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                title: Text('PERSONALIZAR BOTONES DE TECLADO',
                    style: AppText.label(9, color: AppColors.muted)),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4.0),
                  child: Text(
                      'Arrastra para reordenar y activa/desactiva los atajos y botones del teclado inteligente.',
                      style: AppText.label(8.5,
                          color: AppColors.faint, spacing: 0.3)),
                ),
                trailing:
                    Icon(Icons.keyboard_arrow_right, color: AppColors.muted),
                onTap: () => ShortcutManagerSheet.show(context, state),
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

          // ---- Device SSH key ----------------------------------------------
          SwissPanel(
            title: 'Llave SSH del dispositivo',
            children: const [_DeviceKeyPanel()],
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
              Hairline(),
              const _UpdateCheckRow(),
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
/// The phone's own ed25519 SSH identity: shows its fingerprint when present,
/// generates it on demand, and copies the `authorized_keys` line. Profiles opt
/// in with "usar llave del dispositivo".
class _DeviceKeyPanel extends StatefulWidget {
  const _DeviceKeyPanel();

  @override
  State<_DeviceKeyPanel> createState() => _DeviceKeyPanelState();
}

class _DeviceKeyPanelState extends State<_DeviceKeyPanel> {
  String? _fingerprint;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final fp = await DeviceKey.fingerprint();
    if (!mounted) return;
    setState(() {
      _fingerprint = fp;
      _loaded = true;
    });
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(
      content: Text(message,
          style: AppText.mono(11, color: AppColors.bone, spacing: 0.3)),
      backgroundColor: AppColors.panelHi,
      duration: const Duration(milliseconds: 1800),
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _generate() async {
    // Regenerating invalidates the key on every server that trusts it — make
    // that explicit before overwriting.
    if (_fingerprint != null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.panel,
          title: Text('REGENERAR LLAVE',
              style: AppText.label(11, color: AppColors.bone, spacing: 1.4)),
          content: Text(
            'Los servidores que confían en la llave actual dejarán de aceptar '
            'este teléfono hasta que instales la nueva llave pública.',
            style: AppText.body(13, color: AppColors.muted),
          ),
          actions: [
            GhostButton(
              label: 'Cancelar',
              dense: true,
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
            InvertedButton(
              label: 'Regenerar',
              dense: true,
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await DeviceKey.generate();
    await _refresh();
    if (mounted) _toast('Llave ed25519 generada');
  }

  Future<void> _copyPublic() async {
    final line = await DeviceKey.publicLine();
    if (line == null) {
      _toast('Primero genera la llave');
      return;
    }
    await Clipboard.setData(ClipboardData(text: line));
    if (mounted) {
      _toast('Llave pública copiada — pégala en ~/.ssh/authorized_keys');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('IDENTIDAD ED25519',
              style: AppText.label(9, color: AppColors.muted)),
          const SizedBox(height: 5),
          Text(
            !_loaded
                ? '…'
                : _fingerprint ?? 'Sin generar — crea la llave para conectar '
                    'sin contraseña.',
            style: AppText.mono(10,
                color: _fingerprint != null
                    ? AppColors.bone
                    : AppColors.faint),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: GhostButton(
                  label: _fingerprint == null ? 'Generar' : 'Regenerar',
                  icon: Icons.vpn_key_outlined,
                  dense: true,
                  onPressed: _generate,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: InvertedButton(
                  label: 'Copiar pública',
                  icon: Icons.content_copy_outlined,
                  dense: true,
                  onPressed: _copyPublic,
                ),
              ),
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
                'Ya tienes la última versión instalada',
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
              'Error al buscar actualizaciones',
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
                'ACTUALIZACIONES',
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
                'BUSCAR ACTUALIZACIONES',
                style: AppText.mono(12, color: AppColors.accent, weight: FontWeight.w700),
              ),
          ],
        ),
      ),
    );
  }
}

class _AccentColorSelector extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const _AccentColorSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final preset in AppColors.accentPresets)
            GestureDetector(
              onTap: () => onChanged(preset.$1),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: preset.$1 == 'auto'
                      ? (Theme.of(context).brightness == Brightness.light
                          ? const Color(0xFF1A1916)
                          : const Color(0xFFECE7DD))
                      : preset.$3,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: value == preset.$1
                        ? AppColors.bone
                        : AppColors.hairline,
                    width: value == preset.$1 ? 3 : 1,
                  ),
                ),
                child: preset.$1 == 'auto'
                    ? Center(
                        child: Icon(
                          Icons.circle_outlined,
                          size: 14,
                          color: Theme.of(context).brightness == Brightness.light
                              ? const Color(0xFFECE7DD)
                              : const Color(0xFF1A1916),
                        ),
                      )
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}

class _FontSelector extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const _FontSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.hairline, width: 1),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _buildCell(AppText.monoFontOptions[0]),
              Container(width: 1, height: 40, color: AppColors.hairline),
              _buildCell(AppText.monoFontOptions[1]),
              Container(width: 1, height: 40, color: AppColors.hairline),
              _buildCell(AppText.monoFontOptions[2]),
            ],
          ),
          Container(height: 1, color: AppColors.hairline),
          Row(
            children: [
              _buildCell(AppText.monoFontOptions[3]),
              Container(width: 1, height: 40, color: AppColors.hairline),
              _buildCell(AppText.monoFontOptions[4]),
              Container(width: 1, height: 40, color: AppColors.hairline),
              _buildCell(AppText.monoFontOptions[5]),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCell((String, String) option) {
    final (id, label) = option;
    final active = value == id;
    final fg = active ? AppColors.ink : AppColors.bone;
    final fontFamily = AppText.resolveMonoFontFamily(id);

    return Expanded(
      child: Material(
        color: active ? AppColors.accent : Colors.transparent,
        child: InkWell(
          onTap: () => onChanged(id),
          child: Container(
            height: 40,
            alignment: Alignment.center,
            child: Text(
              label.toUpperCase(),
              style: TextStyle(
                fontSize: 8.5,
                fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                color: fg,
                fontFamily: fontFamily,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShortcutLayoutSelector extends StatelessWidget {
  final TerminalShortcutLayout value;
  final ValueChanged<TerminalShortcutLayout> onChanged;

  const _ShortcutLayoutSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.panelHi,
        border: Border.all(color: AppColors.hairline),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<TerminalShortcutLayout>(
          value: value,
          dropdownColor: AppColors.panel,
          iconEnabledColor: AppColors.bone,
          isExpanded: true,
          style: AppText.mono(11, color: AppColors.bone),
          items: const [
            DropdownMenuItem(
              value: TerminalShortcutLayout.classic,
              child: Text('CLÁSICO (DOBLE FILA)'),
            ),
            DropdownMenuItem(
              value: TerminalShortcutLayout.dpadLeft,
              child: Text('D-PAD A LA IZQUIERDA'),
            ),
            DropdownMenuItem(
              value: TerminalShortcutLayout.dpadRight,
              child: Text('D-PAD A LA DERECHA'),
            ),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}
