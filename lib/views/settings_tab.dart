import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../services/app_lock.dart';
import '../services/device_key.dart';
import '../services/known_hosts.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';
import '../l10n/l10n.dart';

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
          ScreenHeader(tr('Ajustes'), eyebrow: tr('Configuración')),

          // ---- Language ----------------------------------------------------
          SwissPanel(
            title: tr('Idioma'),
            children: const [_LanguagePanel()],
          ),
          const SizedBox(height: 16),

          // ---- Explorer --------------------------------------------------
          SwissPanel(
            title: tr('Explorador'),
            children: [
              ToggleRow(
                label: tr('GESTO ATRÁS SUBE DE CARPETA'),
                description:
                    tr('El gesto/botón atrás sube un nivel en el explorador en vez de volver a Conexiones.'),
                value: backGestureFolders,
                onChanged: state.setBackGestureNavigatesFolders,
              ),
              Hairline(),
              ToggleRow(
                label: tr('SINCRONIZAR RUTA CON TERMINAL'),
                description:
                    tr('Al navegar en el explorador de archivos, la terminal activa cambia automáticamente de directorio.'),
                value: syncTerminalPath,
                onChanged: state.setSyncTerminalPath,
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ---- Notifications ----------------------------------------------
          // The settings themselves live in their own screen (drawer →
          // NOTIFICACIONES); this is just a signpost, so there is exactly one
          // place where alerts are configured.
          SwissPanel(
            title: tr('Notificaciones'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr('AVISOS DE AGENTE'),
                        style: AppText.label(9, color: AppColors.muted)),
                    const SizedBox(height: 5),
                    Text(
                      agentAlerts
                          ? tr('Activados. Configura qué avisar, con cuánta fuerza y cuándo en la pantalla de Notificaciones.')
                          : tr('Desactivados. Actívalos en la pantalla de Notificaciones.'),
                      style: AppText.label(8.5,
                          color: AppColors.faint, spacing: 0.3),
                    ),
                    const SizedBox(height: 10),
                    GhostButton(
                      label: tr('ABRIR NOTIFICACIONES'),
                      onPressed: () => state.setActiveTabIndex(8),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ---- Security --------------------------------------------------
          SwissPanel(
            title: tr('Seguridad'),
            children: [
              ToggleRow(
                label: tr('BLOQUEO DE LA APLICACIÓN'),
                description:
                    tr('Pide tu huella (o el bloqueo del teléfono) al abrir KAMMEL SSH, para proteger tus conexiones y claves guardadas.'),
                value: appLockEnabled,
                onChanged: (value) => _onAppLockChanged(context, state, value),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ---- Device SSH key ----------------------------------------------
          SwissPanel(
            title: tr('Llave SSH del dispositivo'),
            children: const [_DeviceKeyPanel()],
          ),
          const SizedBox(height: 16),

          // ---- Pinned host keys --------------------------------------------
          SwissPanel(
            title: tr('Servidores conocidos'),
            children: const [_KnownHostsPanel()],
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
        title: Text(tr('BLOQUEO NO DISPONIBLE'),
            style: AppText.label(11, color: AppColors.bone)),
        content: Text(
          tr('Configura una huella o un bloqueo de pantalla (PIN, patrón o contraseña) en los ajustes de tu teléfono y vuelve a intentarlo.'),
          style: AppText.body(13, color: AppColors.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('ENTENDIDO'),
                style: AppText.label(10, color: AppColors.bone)),
          ),
        ],
      ),
    );
  }
}

/// Picks the UI language. Writing to [L10n] remounts the whole app (see
/// `main.dart`), so the change is visible immediately and survives restarts.
class _LanguagePanel extends StatelessWidget {
  const _LanguagePanel();

  @override
  Widget build(BuildContext context) {
    final current = L10n.lang;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          child: Text(
            tr('Cambia el idioma de la interfaz. Los mensajes que escribe el servidor en la terminal no se traducen.'),
            style: AppText.body(11, color: AppColors.muted),
          ),
        ),
        for (final lang in AppLang.values) ...[
          Hairline(),
          InkWell(
            onTap: () => L10n.setLang(lang),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Row(
                children: [
                  Icon(
                    lang == current
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 16,
                    color:
                        lang == current ? AppColors.bone : AppColors.hairline,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      lang.label,
                      style: AppText.label(11,
                          color: lang == current
                              ? AppColors.bone
                              : AppColors.muted),
                    ),
                  ),
                  MonoTag(lang.code.toUpperCase()),
                ],
              ),
            ),
          ),
        ],
      ],
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
          title: Text(tr('REGENERAR LLAVE'),
              style: AppText.label(11, color: AppColors.bone, spacing: 1.4)),
          content: Text(
            tr('Los servidores que confían en la llave actual dejarán de aceptar este teléfono hasta que instales la nueva llave pública.'),
            style: AppText.body(13, color: AppColors.muted),
          ),
          actions: [
            GhostButton(
              label: tr('Cancelar'),
              dense: true,
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
            InvertedButton(
              label: tr('Regenerar'),
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
    if (mounted) _toast(tr('Llave ed25519 generada'));
  }

  Future<void> _copyPublic() async {
    final line = await DeviceKey.publicLine();
    if (line == null) {
      _toast(tr('Primero genera la llave'));
      return;
    }
    await Clipboard.setData(ClipboardData(text: line));
    if (mounted) {
      _toast(tr('Llave pública copiada — pégala en ~/.ssh/authorized_keys'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('IDENTIDAD ED25519'),
              style: AppText.label(9, color: AppColors.muted)),
          const SizedBox(height: 5),
          Text(
            !_loaded
                ? '…'
                : _fingerprint ?? tr('Sin generar — crea la llave para conectar sin contraseña.'),
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
                  label: _fingerprint == null ? tr('Generar') : tr('Regenerar'),
                  icon: Icons.vpn_key_outlined,
                  dense: true,
                  onPressed: _generate,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: InvertedButton(
                  label: tr('Copiar pública'),
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

/// The pinned host keys (see [KnownHosts]). Lets the user audit what the app
/// trusts and forget an entry — needed after legitimately rebuilding a server,
/// so the next connection asks again instead of showing the "identity changed"
/// warning.
class _KnownHostsPanel extends StatefulWidget {
  const _KnownHostsPanel();

  @override
  State<_KnownHostsPanel> createState() => _KnownHostsPanelState();
}

class _KnownHostsPanelState extends State<_KnownHostsPanel> {
  List<KnownHost>? _hosts;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final hosts = await KnownHosts.instance.entries();
    if (!mounted) return;
    setState(() => _hosts = hosts);
  }

  Future<void> _forget(KnownHost host) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text(tr('OLVIDAR SERVIDOR'),
            style: AppText.label(11, color: AppColors.bone, spacing: 1.4)),
        content: Text(
          tr('La próxima vez que te conectes a {0} se te volverá a preguntar por su identidad. Hazlo sólo si sabes por qué cambió (reinstalación, migración…).', [host.id]),
          style: AppText.body(12, color: AppColors.muted),
        ),
        actions: [
          GhostButton(
              label: tr('Cancelar'),
              dense: true,
              onPressed: () => Navigator.of(ctx).pop(false)),
          GhostButton(
              label: tr('Olvidar'),
              dense: true,
              danger: true,
              onPressed: () => Navigator.of(ctx).pop(true)),
        ],
      ),
    );
    if (confirmed != true) return;
    await KnownHosts.instance.forget(host.host, host.port);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final hosts = _hosts;
    if (hosts == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: SizedBox(
            height: 14,
            width: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5)),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Text(
            hosts.isEmpty
                ? tr('Aún no has confiado en ningún servidor. La primera vez que te conectes a cada uno, KAMMEL te mostrará su huella para que la confirmes.')
                : tr('Huellas guardadas. Si alguna cambia sin motivo, la conexión se bloquea: puede ser un intento de suplantación.'),
            style: AppText.body(11, color: AppColors.muted),
          ),
        ),
        for (final host in hosts) ...[
          Hairline(),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(host.id,
                          style: AppText.mono(12, color: AppColors.bone)),
                      const SizedBox(height: 2),
                      Text(host.fingerprint,
                          style: AppText.mono(9, color: AppColors.muted),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                MonoTag(host.keyType),
                InkWell(
                  onTap: () => _forget(host),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(Icons.delete_outline,
                        size: 15, color: AppColors.danger),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
