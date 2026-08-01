import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/connection_profile.dart';
import '../models/ssh_tunnel.dart';
import '../providers/app_state.dart';
import '../services/tunnel_manager.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';
import 'tunnel_editor_sheet.dart';

/// Live view of every port forward in the app: state, traffic, errors and
/// start/stop control, grouped by session.
class TunnelsTab extends StatelessWidget {
  const TunnelsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    // Listen to the manager directly so byte counters don't rebuild the app.
    final manager = context.watch<TunnelManager>();
    final groups = manager.overview;

    return Container(
      color: AppColors.ink,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          ScreenHeader(
            'TÚNELES',
            eyebrow: groups.isEmpty
                ? 'PORT FORWARDING'
                : '${manager.activeCount()} ACTIVOS',
          ),
          if (manager.hasLanExposure) const _LanWarningBanner(),
          if (groups.isEmpty)
            const _EmptyState()
          else
            for (final group in groups) ...[
              _SessionPanel(
                sessionId: group.id,
                sessionName: group.name,
                tunnels: group.tunnels,
                manager: manager,
                state: state,
              ),
              const SizedBox(height: 16),
            ],
        ],
      ),
    );
  }
}

class _SessionPanel extends StatelessWidget {
  final String sessionId;
  final String sessionName;
  final List<TunnelRuntime> tunnels;
  final TunnelManager manager;
  final AppState state;

  const _SessionPanel({
    required this.sessionId,
    required this.sessionName,
    required this.tunnels,
    required this.manager,
    required this.state,
  });

  @override
  Widget build(BuildContext context) {
    return SwissPanel(
      title: sessionName,
      trailing: MonoTag('${manager.activeCount(sessionId)}/${tunnels.length}'),
      children: [
        for (var i = 0; i < tunnels.length; i++) ...[
          if (i > 0) Hairline(),
          TunnelRow(
            sessionId: sessionId,
            runtime: tunnels[i],
            manager: manager,
            state: state,
          ),
        ],
      ],
    );
  }
}

/// One tunnel: state dot, description, live counters, and its error (if any)
/// with a retry button. Shared with the console's tunnel sheet.
class TunnelRow extends StatelessWidget {
  final String sessionId;
  final TunnelRuntime runtime;
  final TunnelManager manager;
  final AppState state;

  const TunnelRow({
    super.key,
    required this.sessionId,
    required this.runtime,
    required this.manager,
    required this.state,
  });

  @override
  Widget build(BuildContext context) {
    final tunnel = runtime.config;
    final color = switch (runtime.state) {
      TunnelState.active => AppColors.accent,
      TunnelState.failed => AppColors.danger,
      TunnelState.starting => AppColors.bone,
      TunnelState.stopped => AppColors.muted,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayerRow(
          glyph: Icon(_glyphFor(tunnel.kind), size: 16, color: color),
          title: tunnel.label.isEmpty
              ? tunnel.describe(boundPort: runtime.boundPort)
              : tunnel.label,
          meta: _meta(),
          trailing: Switch(
            value: runtime.isUp || runtime.isBusy,
            onChanged: (on) {
              if (on) {
                manager.start(sessionId, tunnel.id);
              } else {
                manager.stop(sessionId, tunnel.id);
              }
            },
          ),
          onTap: () => _showActions(context),
        ),
        if (runtime.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(runtime.error!,
                    style: AppText.body(11, color: AppColors.danger)),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: GhostButton(
                    label: 'Reintentar',
                    icon: Icons.refresh,
                    dense: true,
                    onPressed: () => manager.restart(sessionId, tunnel.id),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// Second line: what it points at, plus live traffic while it's up.
  String _meta() {
    final tunnel = runtime.config;
    final parts = <String>[tunnel.describe(boundPort: runtime.boundPort)];
    switch (runtime.state) {
      case TunnelState.active:
        // The SOCKS server is owned by dartssh2, which doesn't report per
        // connection stats — so don't show numbers we can't measure.
        if (tunnel.kind != TunnelKind.dynamicSocks) {
          parts.add('${runtime.liveConnections} conex.');
          parts.add('↑${_bytes(runtime.bytesUp)} ↓${_bytes(runtime.bytesDown)}');
        } else {
          parts.add('activo');
        }
      case TunnelState.starting:
        parts.add('abriendo…');
      case TunnelState.failed:
        parts.add('error');
      case TunnelState.stopped:
        parts.add('parado');
    }
    if (tunnel.exposeToLan && tunnel.kind.listensOnDevice) {
      parts.add('RED LOCAL');
    }
    return parts.join('  ·  ');
  }

  static IconData _glyphFor(TunnelKind kind) => switch (kind) {
        TunnelKind.local => Icons.south_west,
        TunnelKind.dynamicSocks => Icons.hub_outlined,
        TunnelKind.remote => Icons.north_east,
      };

  static String _bytes(int n) {
    if (n < 1024) return '${n}B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(0)}KB';
    if (n < 1024 * 1024 * 1024) return '${(n / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }

  void _showActions(BuildContext context) {
    final tunnel = runtime.config;
    final address = runtime.localAddress;

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.panel,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
              child: Text(
                tunnel.label.isEmpty ? tunnel.toSpec() : tunnel.label,
                style: AppText.label(11, color: AppColors.bone, spacing: 1.4),
              ),
            ),
            Hairline(),
            if (runtime.isUp && tunnel.looksLikeHttp && address != null)
              _tile(sheetCtx, Icons.open_in_browser, 'ABRIR EN EL NAVEGADOR',
                  () async {
                final port = runtime.boundPort ?? tunnel.listenPort;
                final uri = Uri.parse(
                    '${tunnel.destPort == 443 ? 'https' : 'http'}://localhost:$port');
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }),
            if (address != null)
              _tile(
                sheetCtx,
                Icons.copy,
                tunnel.kind == TunnelKind.dynamicSocks
                    ? 'COPIAR PROXY SOCKS5'
                    : 'COPIAR DIRECCIÓN',
                () async {
                  await Clipboard.setData(ClipboardData(text: address));
                },
              ),
            _tile(sheetCtx, Icons.refresh, 'REINICIAR',
                () => manager.restart(sessionId, tunnel.id)),
            if (runtime.isUp || runtime.isBusy)
              _tile(sheetCtx, Icons.stop, 'PARAR',
                  () => manager.stop(sessionId, tunnel.id))
            else
              _tile(sheetCtx, Icons.play_arrow, 'ARRANCAR',
                  () => manager.start(sessionId, tunnel.id)),
            Hairline(),
            _tile(sheetCtx, Icons.edit, 'EDITAR', () => _edit(context)),
            _tile(sheetCtx, Icons.delete_outline, 'ELIMINAR DEL PERFIL',
                () => _delete(context),
                danger: true),
            if (runtime.errorDetail != null) ...[
              Hairline(),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(runtime.errorDetail!,
                    style: AppText.mono(10, color: AppColors.faint)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tile(BuildContext sheetCtx, IconData icon, String label,
      VoidCallback onTap,
      {bool danger = false}) {
    final color = danger ? AppColors.danger : AppColors.bone;
    return InkWell(
      onTap: () {
        Navigator.of(sheetCtx).pop();
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 12),
            Text(label, style: AppText.label(10, color: color, spacing: 1.0)),
          ],
        ),
      ),
    );
  }

  /// Tunnels live on the profile, so editing one means saving the profile —
  /// which `AppState.saveProfile` then applies to the live session without a
  /// reconnect.
  Future<void> _edit(BuildContext context) async {
    final profile = _profile();
    if (profile == null) return;
    final edited = await showTunnelEditor(context, initial: runtime.config);
    if (edited == null) return;
    final list = profile.tunnels
        .map((t) => t.id == edited.id ? edited : t)
        .toList();
    await state.saveProfile(profile.copyWith(tunnels: list));
  }

  Future<void> _delete(BuildContext context) async {
    final profile = _profile();
    if (profile == null) return;
    final list =
        profile.tunnels.where((t) => t.id != runtime.config.id).toList();
    await state.saveProfile(profile.copyWith(tunnels: list));
  }

  /// The saved profile behind this session, if it still exists. Editing a
  /// tunnel from here writes to that profile.
  ConnectionProfile? _profile() {
    for (final session in state.sessions) {
      if (session.id != sessionId) continue;
      final id = session.activeProfile?.id;
      if (id == null) return null;
      for (final p in state.profiles) {
        if (p.id == id) return p;
      }
      return null;
    }
    return null;
  }
}

class _LanWarningBanner extends StatelessWidget {
  const _LanWarningBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.danger, width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.danger),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Hay un túnel abierto a tu red local. Cualquier dispositivo del '
              'wifi puede usarlo mientras siga activo.',
              style: AppText.body(11, color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }
}

/// First-run explanation. Without it a tunnel list is meaningless to anyone who
/// hasn't used `ssh -L` before.
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwissPanel(
            title: 'QUÉ ES UN TÚNEL',
            margin: EdgeInsets.zero,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Tu conexión SSH ya es un canal cifrado. Un túnel aprovecha '
                  'ese canal para llevar el tráfico de otras aplicaciones.',
                  style: AppText.body(12, color: AppColors.muted),
                ),
              ),
              Hairline(),
              for (final kind in TunnelKind.values) ...[
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 28,
                        child: Text(kind.flag,
                            style: AppText.mono(12,
                                color: AppColors.accent,
                                weight: FontWeight.w700)),
                      ),
                      Expanded(
                        child: Text(kind.blurb,
                            style: AppText.body(11, color: AppColors.muted)),
                      ),
                    ],
                  ),
                ),
                if (kind != TunnelKind.values.last) Hairline(),
              ],
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Los túneles se configuran dentro de cada perfil de conexión y se '
            'abren al conectar.',
            style: AppText.body(11, color: AppColors.faint),
          ),
          const SizedBox(height: 12),
          InvertedButton(
            label: 'Ir a conexiones',
            icon: Icons.dns_outlined,
            expand: true,
            onPressed: () =>
                Provider.of<AppState>(context, listen: false)
                    .setActiveTabIndex(0),
          ),
        ],
      ),
    );
  }
}
