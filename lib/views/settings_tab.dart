import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../services/app_lock.dart';
import '../services/device_key.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';

/// Central configuration screen for general app settings (Explorer, Notifications, Security, and SSH keys).
class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
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
          ScreenHeader('Ajustes', eyebrow: 'Configuración'),

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
                    'Pide tu huella (o el bloqueo del teléfono) al abrir KAMMEL SSH, '
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

/// The phone's own ed25519 SSH identity: shows its fingerprint when present,
/// generates it on demand, and copies the `authorized_keys` line.
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
