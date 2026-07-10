import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/connection_profile.dart';
import '../providers/app_state.dart';
import '../services/server_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';

/// Server console: pick a saved SSH server (GCP-console style selector in the
/// header), then audit and manage it — monitor (CPU/RAM/disk/services) plus
/// Docker (containers, images, volumes, networks, compose, disk usage) — over
/// a dedicated SSH client, independent from the terminal sessions.
class ServerTab extends StatefulWidget {
  const ServerTab({super.key});

  @override
  State<ServerTab> createState() => _ServerTabState();
}

class _ServerTabState extends State<ServerTab> {
  Timer? _refreshTimer;
  final TextEditingController _pullController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // IndexedStack keeps every tab built, so gate on the tab actually being
      // visible to avoid polling the server in the background.
      _refreshTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        if (!mounted) return;
        final state = context.read<AppState>();
        final server = state.server;
        if (state.activeTabIndex == 4 &&
            server.phase == ServerPhase.ready &&
            !server.busy) {
          server.refresh();
        }
      });
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _pullController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    // AppColors is a global mutable palette; rebuild on theme change.
    context.select<AppState, AppThemeChoice>((s) => s.themeChoice);
    final server = state.server;

    return Container(
      color: AppColors.ink,
      child: ListenableBuilder(
        listenable: server,
        builder: (context, _) {
          switch (server.phase) {
            case ServerPhase.pickServer:
              return _buildPicker(context, state, server);
            case ServerPhase.connecting:
              return _buildConnecting(server);
            case ServerPhase.error:
              return _buildErrorScreen(server);
            case ServerPhase.ready:
              return _buildPanel(context, state, server);
          }
        },
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Phase: pick server
  // ---------------------------------------------------------------------

  Widget _buildPicker(
      BuildContext context, AppState state, ServerController server) {
    final remoteProfiles =
        state.profiles.where((p) => !p.isLocal).toList(growable: false);
    final active = state.connectionStatus == ConnectionStatus.remote
        ? state.activeProfile
        : null;

    if (remoteProfiles.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.dns_outlined, size: 48, color: AppColors.muted),
            const SizedBox(height: 16),
            Text('SIN PERFILES GUARDADOS',
                style: AppText.label(12, color: AppColors.bone, spacing: 1.5)),
            const SizedBox(height: 8),
            Text(
              'Crea una conexión SSH en la pestaña de Conexiones\npara auditar y administrar ese servidor.',
              textAlign: TextAlign.center,
              style: AppText.body(11, color: AppColors.muted),
            ),
          ],
        ),
      );
    }

    return ListView(
      children: [
        const ScreenHeader('SERVIDOR',
            eyebrow: 'CONSOLA DE ADMINISTRACIÓN Y AUDITORÍA'),
        if (active != null && !active.isLocal) ...[
          SwissPanel(
            title: 'CONEXIÓN ACTIVA',
            children: [
              _profileRow(active, server, meta: 'USAR ESTE SERVIDOR'),
            ],
          ),
          const SizedBox(height: 14),
        ],
        SwissPanel(
          title: 'SELECCIONA UN SERVIDOR',
          children: [
            for (int i = 0; i < remoteProfiles.length; i++) ...[
              if (i > 0) Hairline(),
              _profileRow(remoteProfiles[i], server),
            ],
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _profileRow(ConnectionProfile p, ServerController server,
      {String? meta}) {
    return LayerRow(
      glyph: const Icon(Icons.dns_outlined),
      title: p.name,
      meta: meta ?? '${p.username}@${p.host}:${p.port}',
      trailing: const Icon(Icons.chevron_right),
      onTap: () => server.connect(p),
    );
  }

  /// GCP-console style server switcher: bottom sheet listing every saved
  /// remote profile, current one highlighted.
  void _showServerPicker(
      BuildContext context, AppState state, ServerController server) {
    final remoteProfiles =
        state.profiles.where((p) => !p.isLocal).toList(growable: false);
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.panel,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('CAMBIAR DE SERVIDOR',
                  style:
                      AppText.label(11, color: AppColors.bone, spacing: 1.4)),
            ),
            Hairline(),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (int i = 0; i < remoteProfiles.length; i++) ...[
                    if (i > 0) Hairline(),
                    LayerRow(
                      glyph: const Icon(Icons.dns_outlined),
                      title: remoteProfiles[i].name,
                      meta:
                          '${remoteProfiles[i].username}@${remoteProfiles[i].host}:${remoteProfiles[i].port}',
                      active: remoteProfiles[i].id == server.profile?.id,
                      onTap: () {
                        Navigator.of(sheetCtx).pop();
                        if (remoteProfiles[i].id != server.profile?.id) {
                          server.connect(remoteProfiles[i]);
                        }
                      },
                    ),
                  ],
                ],
              ),
            ),
            Hairline(),
            InkWell(
              onTap: () {
                Navigator.of(sheetCtx).pop();
                server.disconnect();
              },
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    Icon(Icons.power_settings_new,
                        size: 16, color: AppColors.muted),
                    const SizedBox(width: 12),
                    Text('DESCONECTAR',
                        style: AppText.label(10,
                            color: AppColors.muted, spacing: 1.0)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Phase: connecting / error
  // ---------------------------------------------------------------------

  Widget _buildConnecting(ServerController server) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
          const SizedBox(height: 20),
          Text(
            'CONECTANDO A ${(server.profile?.name ?? '').toUpperCase()}…',
            style: AppText.label(11, color: AppColors.bone, spacing: 1.5),
          ),
          const SizedBox(height: 20),
          GhostButton(
            label: 'Cancelar',
            dense: true,
            onPressed: () => server.disconnect(),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorScreen(ServerController server) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 40, color: AppColors.danger),
            const SizedBox(height: 16),
            Text(
              (server.profile?.name ?? 'SERVIDOR').toUpperCase(),
              style: AppText.label(11, color: AppColors.muted, spacing: 1.5),
            ),
            const SizedBox(height: 10),
            Text(
              server.lastError ?? 'Error desconocido.',
              textAlign: TextAlign.center,
              style: AppText.body(12, color: AppColors.bone),
            ),
            const SizedBox(height: 24),
            if (server.needsSudoPassword) ...[
              InvertedButton(
                label: 'Introducir contraseña sudo',
                icon: Icons.key_outlined,
                dense: true,
                onPressed: () => _askSudoPassword(context, server),
              ),
              const SizedBox(height: 12),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                InvertedButton(
                  label: 'Reconectar',
                  icon: Icons.refresh,
                  dense: true,
                  onPressed: () => server.reconnect(),
                ),
                const SizedBox(width: 10),
                GhostButton(
                  label: 'Cambiar servidor',
                  dense: true,
                  onPressed: () => server.disconnect(),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Phase: ready — console shell
  // ---------------------------------------------------------------------

  Widget _buildPanel(
      BuildContext context, AppState state, ServerController server) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeaderBar(context, state, server),
        _buildSegmentBar(server),
        if (server.needsSudoPassword) _buildSudoBanner(server),
        if (server.lastError != null) _buildErrorBanner(server),
        Expanded(
          child: RefreshIndicator(
            color: AppColors.bone,
            backgroundColor: AppColors.panel,
            onRefresh: () => server.refresh(),
            child: _buildSection(context, state, server),
          ),
        ),
      ],
    );
  }

  Widget _buildHeaderBar(
      BuildContext context, AppState state, ServerController server) {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: AppColors.panel,
        border:
            Border(bottom: BorderSide(color: AppColors.hairline, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          // Server switcher (GCP-console project selector style).
          Expanded(
            child: InkWell(
              onTap: () => _showServerPicker(context, state, server),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.dns_outlined, size: 14, color: AppColors.accent),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      (server.profile?.name ?? '').toUpperCase(),
                      style:
                          AppText.mono(10, color: AppColors.bone, spacing: 1.0),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.unfold_more, size: 14, color: AppColors.muted),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (server.serverVersion != null) ...[
            MonoTag('v${server.serverVersion}', bordered: true),
            const SizedBox(width: 6),
          ],
          if (server.useSudo) ...[
            MonoTag('SUDO', bordered: true, color: AppColors.accent),
            const SizedBox(width: 6),
          ],
          if (server.loading || server.busy)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh, size: 16),
              color: AppColors.bone,
              onPressed: () => server.refresh(),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
        ],
      ),
    );
  }

  static const List<(ServerSection, String, IconData)> _sections = [
    (ServerSection.monitor, 'MONITOR', Icons.monitor_heart_outlined),
    (ServerSection.containers, 'CONTENEDORES', Icons.inventory_2_outlined),
    (ServerSection.images, 'IMÁGENES', Icons.layers_outlined),
    (ServerSection.volumes, 'VOLÚMENES', Icons.storage_outlined),
    (ServerSection.networks, 'REDES', Icons.lan_outlined),
    (ServerSection.compose, 'COMPOSE', Icons.account_tree_outlined),
    (ServerSection.system, 'SISTEMA', Icons.data_usage_outlined),
  ];

  Widget _buildSegmentBar(ServerController server) {
    return Container(
      decoration: BoxDecoration(
        border:
            Border(bottom: BorderSide(color: AppColors.hairline, width: 1)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (int i = 0; i < _sections.length; i++) ...[
              if (i > 0)
                Container(width: 1, height: 52, color: AppColors.hairline),
              _SegmentCell(
                label: _sections[i].$2,
                icon: _sections[i].$3,
                active: server.section == _sections[i].$1,
                onTap: () => server.setSection(_sections[i].$1),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSudoBanner(ServerController server) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.hairline, width: 1),
        color: AppColors.panel,
      ),
      child: Row(
        children: [
          Icon(Icons.key_outlined, size: 14, color: AppColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'SUDO REQUIERE CONTRASEÑA',
              style: AppText.mono(9, color: AppColors.bone, spacing: 1.0),
            ),
          ),
          GhostButton(
            label: 'Introducir',
            dense: true,
            onPressed: () => _askSudoPassword(context, server),
          ),
        ],
      ),
    );
  }

  /// Asks for the sudo password and validates it against the server before
  /// closing; a wrong password shows the error inline and lets the user
  /// retry. The password lives only in the controller's memory.
  Future<void> _askSudoPassword(
      BuildContext context, ServerController server) async {
    final controller = TextEditingController();
    String? error;
    bool validating = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          Future<void> submit() async {
            final pw = controller.text;
            if (pw.isEmpty || validating) return;
            setDialogState(() {
              validating = true;
              error = null;
            });
            final err = await server.submitSudoPassword(pw);
            if (!ctx.mounted) return;
            if (err == null) {
              Navigator.pop(ctx);
            } else {
              setDialogState(() {
                validating = false;
                error = err;
              });
            }
          }

          return AlertDialog(
            backgroundColor: AppColors.panel,
            title: Text('CONTRASEÑA SUDO',
                style: AppText.label(12, color: AppColors.bone, spacing: 1.5)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'El usuario "${server.profile?.username ?? ''}" no está en el '
                  'grupo docker. Introduce su contraseña sudo para ejecutar '
                  'Docker con permisos elevados en esta sesión.',
                  style: AppText.body(12, color: AppColors.muted),
                ),
                const SizedBox(height: 14),
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.ink,
                    border: Border.all(color: AppColors.hairline, width: 1),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: TextField(
                    controller: controller,
                    obscureText: true,
                    autofocus: true,
                    enabled: !validating,
                    style: AppText.mono(12, color: AppColors.bone),
                    onSubmitted: (_) => submit(),
                    decoration: InputDecoration(
                      hintText: 'contraseña',
                      hintStyle: AppText.mono(11, color: AppColors.faint),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 11),
                    ),
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(error!,
                      style: AppText.mono(9, color: AppColors.danger)),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: validating ? null : () => Navigator.pop(ctx),
                child: Text('CANCELAR',
                    style: AppText.mono(10,
                        color: AppColors.muted, spacing: 1.0)),
              ),
              TextButton(
                onPressed: validating ? null : submit,
                child: validating
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      )
                    : Text('CONFIRMAR',
                        style: AppText.mono(10,
                            color: AppColors.bone, spacing: 1.0)),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
  }

  Widget _buildErrorBanner(ServerController server) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.danger, width: 1),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 14, color: AppColors.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              server.lastError!,
              style: AppText.mono(9, color: AppColors.bone),
            ),
          ),
          GestureDetector(
            onTap: server.dismissError,
            behavior: HitTestBehavior.opaque,
            child: Icon(Icons.close, size: 14, color: AppColors.muted),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(
      BuildContext context, AppState state, ServerController server) {
    if (server.section != ServerSection.monitor && !server.dockerAvailable) {
      return _dockerUnavailable(server);
    }
    switch (server.section) {
      case ServerSection.monitor:
        return _buildMonitor(context, server);
      case ServerSection.containers:
        return _buildContainers(context, state, server);
      case ServerSection.images:
        return _buildImages(context, server);
      case ServerSection.volumes:
        return _buildVolumes(context, server);
      case ServerSection.networks:
        return _buildNetworks(context, server);
      case ServerSection.compose:
        return _buildCompose(context, server);
      case ServerSection.system:
        return _buildSystem(context, server);
    }
  }

  Widget _dockerUnavailable(ServerController server) {
    return _sectionList([
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
        child: Column(
          children: [
            Icon(Icons.inventory_2_outlined, size: 36, color: AppColors.muted),
            const SizedBox(height: 14),
            Text('DOCKER NO DISPONIBLE',
                style: AppText.label(11, color: AppColors.bone, spacing: 1.5)),
            const SizedBox(height: 8),
            Text(
              server.dockerNotice ?? 'No se pudo consultar Docker.',
              textAlign: TextAlign.center,
              style: AppText.body(11, color: AppColors.muted),
            ),
            if (server.needsSudoPassword) ...[
              const SizedBox(height: 16),
              InvertedButton(
                label: 'Introducir contraseña sudo',
                icon: Icons.key_outlined,
                dense: true,
                onPressed: () => _askSudoPassword(context, server),
              ),
            ],
          ],
        ),
      ),
    ]);
  }

  /// Scrollable list shell shared by every section, so pull-to-refresh works
  /// even when the section is empty.
  Widget _sectionList(List<Widget> children) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: children,
    );
  }

  Widget _emptyNote(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Center(
        child: Text(text,
            style: AppText.label(10, color: AppColors.muted, spacing: 1.2)),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Section: monitor (analytics / auditing)
  // ---------------------------------------------------------------------

  Widget _buildMonitor(BuildContext context, ServerController server) {
    final m = server.monitor;
    return _sectionList([
      if (m.loaded) ...[
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            '${m.hostname.toUpperCase()} · ${m.osInfo}',
            style: AppText.mono(9, color: AppColors.muted, spacing: 1.0),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
      GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: 3,
        crossAxisSpacing: 10,
        childAspectRatio: 0.9,
        children: [
          _metricCard(
            'CARGA CPU',
            m.loaded ? m.cpuLoad.toStringAsFixed(2) : '…',
            m.cpuLoad / 4.0,
            m.cpuLoad > 3.0 ? AppColors.danger : AppColors.accent,
          ),
          _metricCard(
            'MEMORIA RAM',
            m.loaded ? m.ramText : '…',
            m.ramPercent,
            m.ramPercent > 0.85 ? AppColors.danger : AppColors.accent,
          ),
          _metricCard(
            'DISCO',
            m.loaded ? m.diskText : '…',
            m.diskPercent,
            m.diskPercent > 0.9 ? AppColors.danger : AppColors.accent,
          ),
        ],
      ),
      const SizedBox(height: 14),
      SwissPanel(
        title: 'SERVICIOS DEL SISTEMA',
        margin: EdgeInsets.zero,
        children: [
          for (int i = 0; i < m.services.length; i++) ...[
            if (i > 0) Hairline(),
            _serviceRow(context, server, m.services[i]),
          ],
        ],
      ),
    ]);
  }

  Widget _metricCard(String title, String value, double progress, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: AppText.label(9, color: AppColors.muted, spacing: 1.0)),
          const SizedBox(height: 8),
          Text(value,
              style: AppText.mono(12,
                  color: AppColors.bone, weight: FontWeight.w700),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
          const Spacer(),
          LinearProgressIndicator(
            value: progress.clamp(0.0, 1.0),
            backgroundColor: AppColors.ink,
            color: color,
            minHeight: 4,
          ),
        ],
      ),
    );
  }

  Widget _serviceRow(
      BuildContext context, ServerController server, ServiceStatus s) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(
            s.active ? Icons.check_circle_outline : Icons.error_outline,
            size: 16,
            color: s.active ? Colors.green : AppColors.muted,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.name.toUpperCase(),
                    style: AppText.mono(11,
                        color: AppColors.bone, weight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(s.label, style: AppText.body(9, color: AppColors.muted)),
              ],
            ),
          ),
          GhostButton(
            label: s.active ? 'Detener' : 'Iniciar',
            dense: true,
            danger: s.active,
            onPressed: server.busy
                ? null
                : () => _runAction(() =>
                    server.controlService(s.name, s.active ? 'stop' : 'start')),
          ),
          const SizedBox(width: 8),
          GhostButton(
            label: 'Reiniciar',
            dense: true,
            onPressed: server.busy || !s.active
                ? null
                : () =>
                    _runAction(() => server.controlService(s.name, 'restart')),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Section: containers
  // ---------------------------------------------------------------------

  Widget _buildContainers(
      BuildContext context, AppState state, ServerController server) {
    final running = server.containers.where((c) => c.running).length;
    return _sectionList([
      SwissPanel(
        title: 'CONTENEDORES · $running/${server.containers.length} ACTIVOS',
        margin: EdgeInsets.zero,
        trailing: InkWell(
          onTap: server.busy ? null : () => server.fetchStats(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Text('STATS',
                style: AppText.mono(9,
                    color: server.busy ? AppColors.faint : AppColors.bone,
                    spacing: 1.2)),
          ),
        ),
        children: [
          if (server.containers.isEmpty) _emptyNote('SIN CONTENEDORES'),
          for (int i = 0; i < server.containers.length; i++) ...[
            if (i > 0) Hairline(),
            _containerRow(context, state, server, server.containers[i]),
          ],
        ],
      ),
    ]);
  }

  Widget _containerRow(BuildContext context, AppState state,
      ServerController server, DockerContainer c) {
    final stats = server.containerStats[c.id];
    final meta = [
      c.image,
      c.status,
      ?stats,
    ].join(' · ');
    return LayerRow(
      glyph: Icon(Icons.square,
          size: 10, color: c.running ? Colors.green : AppColors.muted),
      title: c.name,
      meta: meta,
      trailing: const Icon(Icons.more_horiz),
      onTrailingTap: () => _showContainerSheet(context, state, server, c),
      onTap: () => _showContainerSheet(context, state, server, c),
    );
  }

  void _showContainerSheet(BuildContext context, AppState state,
      ServerController server, DockerContainer c) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.panel,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(c.name.toUpperCase(),
                  style:
                      AppText.label(11, color: AppColors.bone, spacing: 1.4)),
            ),
            Hairline(),
            if (!c.running)
              _sheetTile(sheetCtx, Icons.play_arrow_outlined, 'INICIAR',
                  () => _runAction(() => server.containerAction(c.id, 'start'))),
            if (c.running)
              _sheetTile(sheetCtx, Icons.stop_outlined, 'DETENER',
                  () => _runAction(() => server.containerAction(c.id, 'stop'))),
            Hairline(),
            _sheetTile(sheetCtx, Icons.refresh, 'REINICIAR',
                () => _runAction(() => server.containerAction(c.id, 'restart'))),
            Hairline(),
            _sheetTile(sheetCtx, Icons.subject_outlined, 'VER LOGS',
                () => _showLogsSheet(context, server, c)),
            if (c.running) ...[
              Hairline(),
              _sheetTile(sheetCtx, Icons.terminal_outlined, 'ABRIR SHELL', () {
                state.connectToSSH(
                  server.profile!,
                  initialCommand: server.execShellCommand(c.id),
                  sessionName: 'docker:${c.name}',
                );
              }),
            ],
            Hairline(),
            _sheetTile(sheetCtx, Icons.delete_outline, 'ELIMINAR', () async {
              final ok = await _confirm(
                context,
                'ELIMINAR CONTENEDOR',
                c.running
                    ? '"${c.name}" está en ejecución: se detendrá y eliminará. Esta acción no se puede deshacer.'
                    : '¿Eliminar el contenedor "${c.name}"? Esta acción no se puede deshacer.',
              );
              if (!ok) return;
              await _runAction(() =>
                  server.containerAction(c.id, c.running ? 'rm -f' : 'rm'));
            }, danger: true),
          ],
        ),
      ),
    );
  }

  void _showLogsSheet(
      BuildContext context, ServerController server, DockerContainer c) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.panel,
      isScrollControlled: true,
      builder: (_) => _LogsSheet(server: server, container: c),
    );
  }

  // ---------------------------------------------------------------------
  // Section: images
  // ---------------------------------------------------------------------

  Widget _buildImages(BuildContext context, ServerController server) {
    return _sectionList([
      Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.panel,
                border: Border.all(color: AppColors.hairline, width: 1),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: TextField(
                controller: _pullController,
                style: AppText.mono(11, color: AppColors.bone),
                decoration: InputDecoration(
                  hintText: 'imagen:tag',
                  hintStyle: AppText.mono(11, color: AppColors.faint),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 11),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          InvertedButton(
            label: 'Pull',
            icon: Icons.download_outlined,
            dense: true,
            onPressed: server.busy
                ? null
                : () {
                    final ref = _pullController.text.trim();
                    if (ref.isEmpty) return;
                    _runAction(() => server.pullImage(ref)).then((_) {
                      if (mounted) _pullController.clear();
                    });
                  },
          ),
        ],
      ),
      const SizedBox(height: 12),
      SwissPanel(
        title: 'IMÁGENES · ${server.images.length}',
        margin: EdgeInsets.zero,
        children: [
          if (server.images.isEmpty) _emptyNote('SIN IMÁGENES'),
          for (int i = 0; i < server.images.length; i++) ...[
            if (i > 0) Hairline(),
            _imageRow(context, server, server.images[i]),
          ],
        ],
      ),
    ]);
  }

  Widget _imageRow(
      BuildContext context, ServerController server, DockerImage img) {
    return LayerRow(
      glyph: const Icon(Icons.layers_outlined),
      title: img.ref,
      meta: '${img.size} · ${img.createdSince} · ${img.id}',
      trailing: const Icon(Icons.more_horiz),
      onTrailingTap: () => _showImageSheet(context, server, img),
      onTap: () => _showImageSheet(context, server, img),
    );
  }

  void _showImageSheet(
      BuildContext context, ServerController server, DockerImage img) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.panel,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(img.ref.toUpperCase(),
                  style:
                      AppText.label(11, color: AppColors.bone, spacing: 1.4)),
            ),
            Hairline(),
            _sheetTile(sheetCtx, Icons.delete_outline, 'ELIMINAR', () async {
              if (!await _confirm(context, 'ELIMINAR IMAGEN',
                  '¿Eliminar la imagen "${img.ref}"?')) {
                return;
              }
              await _runAction(() => server.removeImage(img.id));
            }, danger: true),
            Hairline(),
            _sheetTile(sheetCtx, Icons.delete_forever_outlined,
                'FORZAR ELIMINACIÓN', () async {
              if (!await _confirm(
                  context,
                  'FORZAR ELIMINACIÓN',
                  'Se eliminará "${img.ref}" aunque tenga contenedores '
                      'detenidos que la usen.')) {
                return;
              }
              await _runAction(() => server.removeImage(img.id, force: true));
            }, danger: true),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Sections: volumes / networks
  // ---------------------------------------------------------------------

  Widget _buildVolumes(BuildContext context, ServerController server) {
    return _sectionList([
      SwissPanel(
        title: 'VOLÚMENES · ${server.volumes.length}',
        margin: EdgeInsets.zero,
        children: [
          if (server.volumes.isEmpty) _emptyNote('SIN VOLÚMENES'),
          for (int i = 0; i < server.volumes.length; i++) ...[
            if (i > 0) Hairline(),
            LayerRow(
              glyph: const Icon(Icons.storage_outlined),
              title: server.volumes[i].name,
              meta: server.volumes[i].driver,
              trailing: const Icon(Icons.delete_outline),
              onTrailingTap: () async {
                final v = server.volumes[i];
                if (!await _confirm(
                    context,
                    'ELIMINAR VOLUMEN',
                    '¿Eliminar el volumen "${v.name}"? Sus datos se perderán '
                        'de forma permanente.')) {
                  return;
                }
                await _runAction(() => server.removeVolume(v.name));
              },
            ),
          ],
        ],
      ),
    ]);
  }

  Widget _buildNetworks(BuildContext context, ServerController server) {
    return _sectionList([
      SwissPanel(
        title: 'REDES · ${server.networks.length}',
        margin: EdgeInsets.zero,
        children: [
          if (server.networks.isEmpty) _emptyNote('SIN REDES'),
          for (int i = 0; i < server.networks.length; i++) ...[
            if (i > 0) Hairline(),
            LayerRow(
              glyph: const Icon(Icons.lan_outlined),
              title: server.networks[i].name,
              meta:
                  '${server.networks[i].driver} · ${server.networks[i].scope}',
              trailing: server.networks[i].builtin
                  ? null
                  : const Icon(Icons.delete_outline),
              onTrailingTap: server.networks[i].builtin
                  ? null
                  : () async {
                      final n = server.networks[i];
                      if (!await _confirm(context, 'ELIMINAR RED',
                          '¿Eliminar la red "${n.name}"?')) {
                        return;
                      }
                      await _runAction(() => server.removeNetwork(n.id));
                    },
            ),
          ],
        ],
      ),
    ]);
  }

  // ---------------------------------------------------------------------
  // Section: compose
  // ---------------------------------------------------------------------

  Widget _buildCompose(BuildContext context, ServerController server) {
    if (!server.composeAvailable) {
      return _sectionList([
        _emptyNote('DOCKER COMPOSE V2 NO DISPONIBLE EN ESTE SERVIDOR'),
      ]);
    }
    return _sectionList([
      SwissPanel(
        title: 'PROYECTOS COMPOSE · ${server.composeProjects.length}',
        margin: EdgeInsets.zero,
        children: [
          if (server.composeProjects.isEmpty)
            _emptyNote('SIN PROYECTOS COMPOSE'),
          for (int i = 0; i < server.composeProjects.length; i++) ...[
            if (i > 0) Hairline(),
            _composeRow(context, server, server.composeProjects[i]),
          ],
        ],
      ),
    ]);
  }

  Widget _composeRow(
      BuildContext context, ServerController server, ComposeProject p) {
    final file = p.configFiles.isNotEmpty ? p.configFiles.first : '';
    return LayerRow(
      glyph: const Icon(Icons.account_tree_outlined),
      title: p.name,
      meta: [p.status, if (file.isNotEmpty) file].join(' · '),
      trailing: const Icon(Icons.more_horiz),
      onTrailingTap: () => _showComposeSheet(context, server, p),
      onTap: () => _showComposeSheet(context, server, p),
    );
  }

  void _showComposeSheet(
      BuildContext context, ServerController server, ComposeProject p) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.panel,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(p.name.toUpperCase(),
                  style:
                      AppText.label(11, color: AppColors.bone, spacing: 1.4)),
            ),
            Hairline(),
            _sheetTile(sheetCtx, Icons.play_arrow_outlined, 'LEVANTAR (UP -D)',
                () => _runAction(() => server.composeAction(p, 'up -d'))),
            Hairline(),
            _sheetTile(sheetCtx, Icons.refresh, 'REINICIAR',
                () => _runAction(() => server.composeAction(p, 'restart'))),
            Hairline(),
            _sheetTile(sheetCtx, Icons.stop_outlined, 'DETENER (DOWN)',
                () async {
              if (!await _confirm(
                  context,
                  'DETENER PROYECTO',
                  '"${p.name}": down detiene y elimina sus contenedores y '
                      'redes (los volúmenes se conservan).')) {
                return;
              }
              await _runAction(() => server.composeAction(p, 'down'));
            }, danger: true),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Section: system
  // ---------------------------------------------------------------------

  Widget _buildSystem(BuildContext context, ServerController server) {
    return _sectionList([
      SwissPanel(
        title: 'USO DE DISCO',
        margin: EdgeInsets.zero,
        children: [
          if (server.dfRows.isEmpty) _emptyNote('SIN DATOS'),
          if (server.dfRows.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: _dfRow('TIPO', 'TOTAL', 'ACTIVOS', 'TAMAÑO', 'LIBERABLE',
                  header: true),
            ),
          for (final row in server.dfRows)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: _dfRow(
                  row.type, row.total, row.active, row.size, row.reclaimable),
            ),
        ],
      ),
      const SizedBox(height: 14),
      SwissPanel(
        title: 'LIMPIEZA',
        margin: EdgeInsets.zero,
        children: [
          _pruneRow(context, server, 'CONTENEDORES DETENIDOS', 'container',
              'Se eliminarán todos los contenedores detenidos.'),
          Hairline(),
          _pruneRow(context, server, 'IMÁGENES SIN USO', 'image',
              'Se eliminarán las imágenes colgantes (sin etiqueta ni uso).'),
          Hairline(),
          _pruneRow(context, server, 'VOLÚMENES SIN USO', 'volume',
              'Se eliminarán los volúmenes anónimos que ningún contenedor usa. Sus datos se perderán.'),
          Hairline(),
          _pruneRow(context, server, 'REDES SIN USO', 'network',
              'Se eliminarán las redes que ningún contenedor usa.'),
          Hairline(),
          _pruneRow(context, server, 'LIMPIEZA COMPLETA', 'system',
              'docker system prune: contenedores detenidos, redes sin uso, imágenes colgantes y caché de build.'),
        ],
      ),
    ]);
  }

  Widget _dfRow(String a, String b, String c, String d, String e,
      {bool header = false}) {
    final color = header ? AppColors.muted : AppColors.bone;
    final style = AppText.mono(9, color: color, spacing: 0.5);
    return Row(
      children: [
        Expanded(flex: 3, child: Text(a.toUpperCase(), style: style)),
        Expanded(child: Text(b, style: style, textAlign: TextAlign.right)),
        Expanded(child: Text(c, style: style, textAlign: TextAlign.right)),
        Expanded(
            flex: 2, child: Text(d, style: style, textAlign: TextAlign.right)),
        Expanded(
            flex: 2, child: Text(e, style: style, textAlign: TextAlign.right)),
      ],
    );
  }

  Widget _pruneRow(BuildContext context, ServerController server, String label,
      String target, String warning) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: AppText.label(9, color: AppColors.bone, spacing: 1.0)),
          ),
          GhostButton(
            label: 'Purgar',
            dense: true,
            danger: true,
            onPressed: server.busy
                ? null
                : () async {
                    if (!await _confirm(context, label, warning)) return;
                    await _runAction(() => server.prune(target));
                  },
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Shared helpers
  // ---------------------------------------------------------------------

  Widget _sheetTile(
      BuildContext sheetCtx, IconData icon, String label, VoidCallback action,
      {bool danger = false}) {
    final fg = danger ? AppColors.danger : AppColors.bone;
    return InkWell(
      onTap: () {
        Navigator.of(sheetCtx).pop();
        action();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 16, color: fg),
            const SizedBox(width: 12),
            Text(label, style: AppText.label(10, color: fg, spacing: 1.0)),
          ],
        ),
      ),
    );
  }

  Future<void> _runAction(Future<String?> Function() fn) async {
    final err = await fn();
    if (err != null && err.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.panelHi,
          content: Text(err, style: AppText.mono(10, color: AppColors.bone)),
        ),
      );
    }
  }

  Future<bool> _confirm(BuildContext context, String title, String body) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text(title.toUpperCase(),
            style: AppText.label(12, color: AppColors.bone, spacing: 1.5)),
        content: Text(body, style: AppText.body(13, color: AppColors.bone)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('CANCELAR',
                style: AppText.mono(10, color: AppColors.muted, spacing: 1.0)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('CONFIRMAR',
                style:
                    AppText.mono(10, color: AppColors.danger, spacing: 1.0)),
          ),
        ],
      ),
    );
    return confirmed == true;
  }
}

/// Fixed-width variant of settings' segment cell for the horizontally
/// scrollable section bar (7 labels don't fit a phone width with Expanded).
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
        child: Container(
          width: 106,
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(height: 5),
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

/// Full-height logs viewer: tail selector + refresh, monospace selectable
/// output. v1 is tail-and-refresh (no follow/streaming).
class _LogsSheet extends StatefulWidget {
  final ServerController server;
  final DockerContainer container;
  const _LogsSheet({required this.server, required this.container});

  @override
  State<_LogsSheet> createState() => _LogsSheetState();
}

class _LogsSheetState extends State<_LogsSheet> {
  static const _tails = [100, 500, 1000];
  int _tail = 100;
  String _logs = '';
  bool _loading = true;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final logs =
        await widget.server.fetchLogs(widget.container.id, tail: _tail);
    if (!mounted) return;
    setState(() {
      _logs = logs;
      _loading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.85,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
            decoration: BoxDecoration(
              border: Border(
                  bottom: BorderSide(color: AppColors.hairline, width: 1)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'LOGS · ${widget.container.name.toUpperCase()}',
                    style:
                        AppText.label(10, color: AppColors.bone, spacing: 1.2),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                for (final t in _tails) ...[
                  GestureDetector(
                    onTap: () {
                      if (_tail == t) return;
                      _tail = t;
                      _load();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 5),
                      color: _tail == t ? AppColors.bone : Colors.transparent,
                      child: Text('$t',
                          style: AppText.mono(9,
                              color: _tail == t
                                  ? AppColors.ink
                                  : AppColors.muted)),
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
                IconButton(
                  icon: const Icon(Icons.refresh, size: 16),
                  color: AppColors.bone,
                  onPressed: _loading ? null : _load,
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              color: AppColors.ink,
              padding: const EdgeInsets.all(12),
              child: _loading
                  ? const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      ),
                    )
                  : SingleChildScrollView(
                      controller: _scroll,
                      child: SelectableText(
                        _logs.isEmpty ? '(sin salida)' : _logs,
                        style: AppText.mono(10, color: AppColors.bone),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
