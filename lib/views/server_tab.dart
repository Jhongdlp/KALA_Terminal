import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/connection_profile.dart';
import '../providers/app_state.dart';
import '../services/server_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/docker_logo.dart';
import '../widgets/swiss.dart';
import '../widgets/swiss_gauge_chart.dart';
import 'server_db_tab.dart';

/// Quick state filter for the containers list.
enum _ContainerFilter { all, running, stopped }

/// Server console: pick a saved SSH server (GCP-console style selector in the
/// header), then audit and manage it — monitor (CPU/RAM/disk/services) plus
/// Docker (containers, images, volumes, networks, compose, disk usage) — over
/// a dedicated SSH client, independent from the terminal sessions.
class ServerTab extends StatefulWidget {
  const ServerTab({super.key});

  @override
  State<ServerTab> createState() => _ServerTabState();
}

class _ServerTabState extends State<ServerTab>
    with SingleTickerProviderStateMixin {
  Timer? _refreshTimer;
  final TextEditingController _pullController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  String _containerQuery = '';
  _ContainerFilter _containerFilter = _ContainerFilter.all;

  /// Drives the slide-in navigation rail: 0 = closed, 1 = fully open.
  late final AnimationController _nav = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 180),
  );

  static const double _railWidth = 268;

  void _openNav() => _nav.forward();
  void _closeNav() => _nav.reverse();

  /// Turns a horizontal drag into rail progress so the panel tracks the
  /// finger: edge-swipe to open, swipe left on the rail to close.
  void _dragNav(DragUpdateDetails d) {
    _nav.value += d.primaryDelta! / _railWidth;
  }

  void _settleNav(DragEndDetails d) {
    final v = d.velocity.pixelsPerSecond.dx;
    if (v.abs() > 320) {
      v > 0 ? _nav.forward() : _nav.reverse();
    } else {
      _nav.value > 0.5 ? _nav.forward() : _nav.reverse();
    }
  }

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
    _nav.dispose();
    _pullController.dispose();
    _searchController.dispose();
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
        ScreenHeader(
          'SERVIDOR',
          eyebrow: 'CONSOLA DE ADMINISTRACIÓN Y AUDITORÍA',
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.accent, width: 1.5),
              color: AppColors.panel,
            ),
            child: Icon(
              Icons.analytics_outlined,
              color: AppColors.accent,
              size: 24,
            ),
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.panel,
            border: Border(
              left: BorderSide(color: AppColors.accent, width: 3),
              top: BorderSide(color: AppColors.hairline),
              right: BorderSide(color: AppColors.hairline),
              bottom: BorderSide(color: AppColors.hairline),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.monitor_heart_outlined, color: AppColors.accent, size: 18),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'MODO AUDITORÍA Y ANALÍTICAS',
                      style: AppText.mono(9, color: AppColors.accent, weight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Selecciona un servidor para monitorizar el rendimiento (CPU/RAM/disco), ver estadísticas y administrar contenedores Docker.',
                      style: AppText.body(9.5, color: AppColors.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
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

  Widget _buildPanel(
      BuildContext context, AppState state, ServerController server) {
    final content = Column(
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

    return Stack(
      children: [
        content,
        // Edge grab zone: swiping in from the left pulls the rail out.
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 20,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragUpdate: _dragNav,
            onHorizontalDragEnd: _settleNav,
          ),
        ),
        AnimatedBuilder(
          animation: _nav,
          builder: (context, child) {
            final t = _nav.value;
            if (t == 0) return const SizedBox.shrink();
            return Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onTap: _closeNav,
                    child: Container(
                      color: Colors.black.withOpacity(0.55 * t),
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  bottom: 0,
                  left: (t - 1) * _railWidth,
                  width: _railWidth,
                  child: GestureDetector(
                    onHorizontalDragUpdate: _dragNav,
                    onHorizontalDragEnd: _settleNav,
                    child: child,
                  ),
                ),
              ],
            );
          },
          child: _buildNavRail(context, state, server),
        ),
      ],
    );
  }

  Widget _buildHeaderBar(
      BuildContext context, AppState state, ServerController server) {
    final current = _sections.firstWhere((s) => s.$1 == server.section);
    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: AppColors.panel,
        border:
            Border(bottom: BorderSide(color: AppColors.hairline, width: 1)),
      ),
      padding: const EdgeInsets.only(left: 8, right: 12),
      child: Row(
        children: [
          // Menu button: the single, always-visible way into every section.
          InkWell(
            onTap: _openNav,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Icon(Icons.menu, size: 18, color: AppColors.bone),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: InkWell(
              onTap: _openNav,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          current.$2,
                          style: AppText.label(11,
                              color: AppColors.bone, spacing: 1.4),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.expand_more, size: 14, color: AppColors.muted),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(Icons.dns_outlined,
                          size: 9, color: AppColors.accent),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          server.profile?.name ?? '',
                          style: AppText.mono(8.5, color: AppColors.muted),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
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

  // A null icon renders the Docker whale ([DockerLogo]) instead.
  static const List<(ServerSection, String, IconData?)> _sections = [
    (ServerSection.monitor, 'MONITOR', Icons.monitor_heart_outlined),
    (ServerSection.containers, 'CONTENEDORES', null),
    (ServerSection.images, 'IMÁGENES', Icons.layers_outlined),
    (ServerSection.volumes, 'VOLÚMENES', Icons.storage_outlined),
    (ServerSection.networks, 'REDES', Icons.lan_outlined),
    (ServerSection.compose, 'COMPOSE', Icons.account_tree_outlined),
    (ServerSection.system, 'SISTEMA', Icons.data_usage_outlined),
    (ServerSection.database, 'BASE DE DATOS', Icons.storage_rounded),
  ];

  /// Slide-in navigation rail: server identity on top, every section listed
  /// vertically with a live count, disconnect at the bottom. Replaces the old
  /// horizontally scrollable segment bar, which hid half its tabs off-screen.
  Widget _buildNavRail(
      BuildContext context, AppState state, ServerController server) {
    final running = server.containers.where((c) => c.running).length;
    String? countFor(ServerSection s) => switch (s) {
          ServerSection.containers =>
            '$running/${server.containers.length}',
          ServerSection.images => '${server.images.length}',
          ServerSection.volumes => '${server.volumes.length}',
          ServerSection.networks => '${server.networks.length}',
          ServerSection.compose => '${server.composeProjects.length}',
          _ => null,
        };

    Widget item(ServerSection section) {
      final s = _sections.firstWhere((e) => e.$1 == section);
      return _NavItem(
        label: s.$2,
        icon: s.$3,
        count: countFor(section),
        active: server.section == section,
        onTap: () {
          server.setSection(section);
          _closeNav();
        },
      );
    }

    return Material(
      color: AppColors.panel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border:
              Border(right: BorderSide(color: AppColors.hairline, width: 1)),
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Server identity — doubles as the server switcher.
              InkWell(
                onTap: () {
                  _closeNav();
                  _showServerPicker(context, state, server);
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 12, 14),
                  child: Row(
                    children: [
                      Icon(Icons.dns_outlined,
                          size: 16, color: AppColors.accent),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              (server.profile?.name ?? '').toUpperCase(),
                              style: AppText.label(11,
                                  color: AppColors.bone, spacing: 1.3),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 3),
                            Text(
                              [
                                if (server.serverVersion != null)
                                  'docker v${server.serverVersion}',
                                'cambiar servidor',
                              ].join(' · '),
                              style: AppText.mono(8.5, color: AppColors.muted),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.unfold_more, size: 14, color: AppColors.muted),
                    ],
                  ),
                ),
              ),
              Hairline(),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 12),
                  children: [
                    _navGroup('SERVIDOR'),
                    item(ServerSection.monitor),
                    _navGroup('DOCKER'),
                    item(ServerSection.containers),
                    item(ServerSection.images),
                    item(ServerSection.volumes),
                    item(ServerSection.networks),
                    item(ServerSection.compose),
                    item(ServerSection.system),
                  ],
                ),
              ),
              Hairline(),
              InkWell(
                onTap: () {
                  _closeNav();
                  server.disconnect();
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Row(
                    children: [
                      Icon(Icons.power_settings_new,
                          size: 15, color: AppColors.muted),
                      const SizedBox(width: 12),
                      Text('DESCONECTAR',
                          style: AppText.label(9,
                              color: AppColors.muted, spacing: 1.2)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navGroup(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(label,
          style: AppText.label(8, color: AppColors.faint, spacing: 1.8)),
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
    if (server.section != ServerSection.monitor &&
        server.section != ServerSection.database &&
        !server.dockerAvailable) {
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
      case ServerSection.database:
        return ServerDbTab(server: server);
    }
  }

  Widget _dockerUnavailable(ServerController server) {
    return _sectionList([
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
        child: Column(
          children: [
            DockerLogo(size: 40, color: AppColors.muted),
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
        Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.panel,
            border: Border.all(color: AppColors.hairline),
          ),
          child: Row(
            children: [
              Icon(Icons.dns_outlined, size: 16, color: AppColors.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      m.hostname.toUpperCase(),
                      style: AppText.mono(11,
                          color: AppColors.bone, weight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      m.osInfo,
                      style: AppText.mono(8.5, color: AppColors.muted),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.green,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.green.withOpacity(0.4),
                      blurRadius: 4,
                      spreadRadius: 1,
                    )
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
      GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: 3,
        crossAxisSpacing: 10,
        childAspectRatio: 0.72,
        children: [
          SwissGaugeChart(
            value: m.cpuLoad / 4.0,
            label: 'CARGA CPU',
            valueText: m.loaded ? m.cpuLoad.toStringAsFixed(2) : '…',
            detailsText: m.loaded ? 'PROMEDIO' : '…',
            color: m.cpuLoad > 3.0 ? AppColors.danger : AppColors.accent,
          ),
          SwissGaugeChart(
            value: m.ramPercent,
            label: 'MEMORIA RAM',
            valueText: m.loaded ? '${(m.ramPercent * 100).toStringAsFixed(0)}%' : '…',
            detailsText: m.loaded ? m.ramText.replaceAll('MB', 'M') : '…',
            color: m.ramPercent > 0.85 ? AppColors.danger : AppColors.accent,
          ),
          SwissGaugeChart(
            value: m.diskPercent,
            label: 'DISCO',
            valueText: m.loaded ? '${(m.diskPercent * 100).toStringAsFixed(0)}%' : '…',
            detailsText: m.loaded ? m.diskText : '…',
            color: m.diskPercent > 0.9 ? AppColors.danger : AppColors.accent,
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
    final all = server.containers;
    final running = all.where((c) => c.running).length;
    final paused = all.where((c) => c.paused).length;
    final stopped = all.length - running - paused;

    final q = _containerQuery.trim().toLowerCase();
    final filtered = all.where((c) {
      final byState = switch (_containerFilter) {
        _ContainerFilter.all => true,
        _ContainerFilter.running => c.running || c.paused,
        _ContainerFilter.stopped => !c.running && !c.paused,
      };
      if (!byState) return false;
      if (q.isEmpty) return true;
      return c.name.toLowerCase().contains(q) ||
          c.image.toLowerCase().contains(q);
    }).toList(growable: false);

    return _sectionList([
      _dockerBanner(server, running, stopped, paused),
      const SizedBox(height: 10),
      _containerSearchBar(),
      const SizedBox(height: 8),
      Row(
        children: [
          _filterChip('TODOS · ${all.length}', _ContainerFilter.all),
          const SizedBox(width: 6),
          _filterChip('ACTIVOS · ${running + paused}', _ContainerFilter.running),
          const SizedBox(width: 6),
          _filterChip('DETENIDOS · $stopped', _ContainerFilter.stopped),
        ],
      ),
      const SizedBox(height: 12),
      SwissPanel(
        title: 'CONTENEDORES · ${filtered.length}/${all.length}',
        margin: EdgeInsets.zero,
        trailing: server.statsLoading
            ? const SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(strokeWidth: 1.2),
              )
            : InkWell(
                onTap: () => server.fetchStats(quiet: true),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  child: Text('STATS',
                      style: AppText.mono(9,
                          color: AppColors.bone, spacing: 1.2)),
                ),
              ),
        children: [
          if (all.isEmpty) _emptyNote('SIN CONTENEDORES'),
          if (all.isNotEmpty && filtered.isEmpty)
            _emptyNote('SIN RESULTADOS PARA EL FILTRO'),
          for (int i = 0; i < filtered.length; i++) ...[
            if (i > 0) Hairline(),
            _containerRow(context, state, server, filtered[i]),
          ],
        ],
      ),
    ]);
  }

  /// Docker Engine identity strip: whale logo, version and state summary.
  Widget _dockerBanner(
      ServerController server, int running, int stopped, int paused) {
    final summary = [
      if (server.serverVersion != null) 'v${server.serverVersion}',
      '$running activos',
      '$stopped detenidos',
      if (paused > 0) '$paused pausados',
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border(
          left: const BorderSide(color: kDockerBlue, width: 3),
          top: BorderSide(color: AppColors.hairline),
          right: BorderSide(color: AppColors.hairline),
          bottom: BorderSide(color: AppColors.hairline),
        ),
      ),
      child: Row(
        children: [
          const DockerLogo(size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('DOCKER ENGINE',
                    style: AppText.mono(11,
                        color: AppColors.bone,
                        weight: FontWeight.bold,
                        spacing: 1.2)),
                const SizedBox(height: 2),
                Text(summary, style: AppText.mono(8.5, color: AppColors.muted)),
              ],
            ),
          ),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.green,
              boxShadow: [
                BoxShadow(
                  color: Colors.green.withOpacity(0.4),
                  blurRadius: 4,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _containerSearchBar() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.hairline, width: 1),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Icon(Icons.search, size: 14, color: AppColors.muted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchController,
              style: AppText.mono(11, color: AppColors.bone),
              onChanged: (v) => setState(() => _containerQuery = v),
              decoration: InputDecoration(
                hintText: 'buscar por nombre o imagen',
                hintStyle: AppText.mono(11, color: AppColors.faint),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 11),
              ),
            ),
          ),
          if (_containerQuery.isNotEmpty)
            GestureDetector(
              onTap: () {
                _searchController.clear();
                setState(() => _containerQuery = '');
              },
              behavior: HitTestBehavior.opaque,
              child: Icon(Icons.close, size: 14, color: AppColors.muted),
            ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, _ContainerFilter value) {
    final active = _containerFilter == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _containerFilter = value),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? AppColors.bone : Colors.transparent,
            border: Border.all(
                color: active ? AppColors.bone : AppColors.hairline, width: 1),
          ),
          child: Text(label,
              style: AppText.mono(8.5,
                  color: active ? AppColors.ink : AppColors.muted,
                  weight: active ? FontWeight.w800 : FontWeight.w600,
                  spacing: 0.8)),
        ),
      ),
    );
  }

  static Color _containerStateColor(DockerContainer c) {
    if (c.running) return Colors.green;
    if (c.paused) return Colors.orange;
    if (c.state == 'restarting') return AppColors.accent;
    return AppColors.muted;
  }

  Widget _containerRow(BuildContext context, AppState state,
      ServerController server, DockerContainer c) {
    final stats = server.containerStats[c.id];
    final ports = c.publishedPorts;
    final stateColor = _containerStateColor(c);
    final detail = [
      c.status,
      if (ports.isNotEmpty)
        ports.map((p) => ':${p.hostPort}→${p.containerPort}').join(' '),
    ].join(' · ');
    return InkWell(
      onTap: () => _showContainerSheet(context, state, server, c),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Container(
                width: 8,
                height: 8,
                decoration:
                    BoxDecoration(shape: BoxShape.circle, color: stateColor),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(c.name,
                            style: AppText.body(13,
                                color: AppColors.bone,
                                weight: FontWeight.w700),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      const SizedBox(width: 8),
                      MonoTag(c.state, bordered: true, color: stateColor),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(c.image,
                      style: AppText.mono(9.5, color: AppColors.muted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(detail,
                      style: AppText.mono(9, color: AppColors.faint),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  if (stats != null) ...[
                    const SizedBox(height: 2),
                    Text(stats,
                        style: AppText.mono(9, color: AppColors.accent),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(Icons.more_horiz, size: 16, color: AppColors.muted),
            ),
          ],
        ),
      ),
    );
  }

  void _showContainerSheet(BuildContext context, AppState state,
      ServerController server, DockerContainer c) {
    final ports = c.publishedPorts;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.panel,
      isScrollControlled: true,
      builder: (sheetCtx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetCtx).size.height * 0.85),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                  child: Row(
                    children: [
                      DockerLogo(size: 16, color: _containerStateColor(c)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(c.name.toUpperCase(),
                                style: AppText.label(11,
                                    color: AppColors.bone, spacing: 1.4),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 2),
                            Text('${c.image} · ${c.status}',
                                style:
                                    AppText.mono(8.5, color: AppColors.muted),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Hairline(),
                if (!c.running && !c.paused)
                  _sheetTile(sheetCtx, Icons.play_arrow_outlined, 'INICIAR',
                      () => _runAction(
                          () => server.containerAction(c.id, 'start'))),
                if (c.paused)
                  _sheetTile(sheetCtx, Icons.play_arrow_outlined, 'REANUDAR',
                      () => _runAction(
                          () => server.containerAction(c.id, 'unpause'))),
                if (c.running) ...[
                  _sheetTile(sheetCtx, Icons.stop_outlined, 'DETENER',
                      () => _runAction(
                          () => server.containerAction(c.id, 'stop'))),
                  Hairline(),
                  _sheetTile(sheetCtx, Icons.pause_outlined, 'PAUSAR',
                      () => _runAction(
                          () => server.containerAction(c.id, 'pause'))),
                ],
                Hairline(),
                _sheetTile(sheetCtx, Icons.refresh, 'REINICIAR',
                    () => _runAction(
                        () => server.containerAction(c.id, 'restart'))),
                Hairline(),
                _sheetTile(sheetCtx, Icons.subject_outlined, 'VER LOGS',
                    () => _showLogsSheet(context, server, c)),
                Hairline(),
                _sheetTile(sheetCtx, Icons.info_outline, 'DETALLES (INSPECT)',
                    () => _showDetailsSheet(context, server, c)),
                if (c.running) ...[
                  Hairline(),
                  _sheetTile(sheetCtx, Icons.terminal_outlined, 'ABRIR SHELL',
                      () {
                    state.connectToSSH(
                      server.profile!,
                      initialCommand: server.execShellCommand(c.id),
                      sessionName: 'docker:${c.name}',
                    );
                  }),
                ],
                if (c.running && ports.isNotEmpty) ...[
                  Hairline(),
                  for (final p in ports)
                    _sheetTile(sheetCtx, Icons.open_in_browser_outlined,
                        'ABRIR PUERTO :${p.hostPort} EN NAVEGADOR', () {
                      final host = server.profile?.host;
                      if (host == null) return;
                      launchUrl(Uri.parse('http://$host:${p.hostPort}'),
                          mode: LaunchMode.externalApplication);
                    }),
                ],
                Hairline(),
                _sheetTile(sheetCtx, Icons.copy_outlined, 'COPIAR ID', () {
                  Clipboard.setData(ClipboardData(text: c.id));
                  _toast('ID copiado: ${c.id}');
                }),
                Hairline(),
                _sheetTile(sheetCtx, Icons.delete_outline, 'ELIMINAR',
                    () async {
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
        ),
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppColors.panelHi,
        content: Text(msg, style: AppText.mono(10, color: AppColors.bone)),
      ),
    );
  }

  void _showDetailsSheet(
      BuildContext context, ServerController server, DockerContainer c) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.panel,
      isScrollControlled: true,
      builder: (_) => _DetailsSheet(server: server, container: c),
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

/// Row in the slide-in navigation rail: icon (or Docker whale), label, and an
/// optional live count. The active row is marked with an accent edge and a
/// filled surface so the current section is unambiguous.
class _NavItem extends StatelessWidget {
  final String label;
  final IconData? icon; // null → Docker whale
  final String? count;
  final bool active;
  final VoidCallback onTap;

  const _NavItem({
    required this.label,
    required this.icon,
    required this.count,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = active ? AppColors.bone : AppColors.muted;
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: active ? AppColors.panelHi : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: active ? AppColors.accent : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(13, 12, 14, 12),
        child: Row(
          children: [
            icon != null
                ? Icon(icon, size: 16, color: fg)
                : DockerLogo(size: 16, color: active ? fg : kDockerBlue),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: AppText.label(10,
                    color: fg,
                    weight: active ? FontWeight.w800 : FontWeight.w600,
                    spacing: 1.2),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (count != null)
              Text(count!,
                  style: AppText.mono(9,
                      color: active ? AppColors.accent : AppColors.faint)),
          ],
        ),
      ),
    );
  }
}

/// Full-height logs viewer: tail selector, refresh, follow mode (re-fetches
/// every few seconds and sticks to the bottom) and copy-all.
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
  bool _follow = false;
  Timer? _followTimer;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _followTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet) setState(() => _loading = true);
    final logs =
        await widget.server.fetchLogs(widget.container.id, tail: _tail);
    if (!mounted) return;
    setState(() {
      _logs = logs;
      if (!quiet) _loading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _toggleFollow() {
    setState(() => _follow = !_follow);
    _followTimer?.cancel();
    _followTimer = null;
    if (_follow) {
      _followTimer = Timer.periodic(
          const Duration(seconds: 3), (_) => _load(quiet: true));
      _load(quiet: true);
    }
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
                GestureDetector(
                  onTap: _toggleFollow,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    color: _follow ? AppColors.accent : Colors.transparent,
                    child: Text('SEGUIR',
                        style: AppText.mono(9,
                            color: _follow ? AppColors.ink : AppColors.muted,
                            spacing: 0.8)),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy_outlined, size: 15),
                  color: AppColors.bone,
                  tooltip: 'Copiar logs',
                  onPressed: _logs.isEmpty
                      ? null
                      : () {
                          Clipboard.setData(ClipboardData(text: _logs));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              backgroundColor: AppColors.panelHi,
                              content: Text('Logs copiados al portapapeles',
                                  style: AppText.mono(10,
                                      color: AppColors.bone)),
                            ),
                          );
                        },
                ),
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

/// Detail sheet backed by `docker inspect`: state, network, ports, mounts
/// and environment, with selectable mono values.
class _DetailsSheet extends StatefulWidget {
  final ServerController server;
  final DockerContainer container;
  const _DetailsSheet({required this.server, required this.container});

  @override
  State<_DetailsSheet> createState() => _DetailsSheetState();
}

class _DetailsSheetState extends State<_DetailsSheet> {
  ContainerDetails? _details;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final (details, error) =
        await widget.server.inspectContainer(widget.container.id);
    if (!mounted) return;
    setState(() {
      _details = details;
      _error = error;
      _loading = false;
    });
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Text(text,
          style: AppText.label(9, color: AppColors.muted, spacing: 1.6)),
    );
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(label,
                style: AppText.mono(8.5, color: AppColors.muted, spacing: 0.8)),
          ),
          Expanded(
            child: SelectableText(value.isEmpty ? '—' : value,
                style: AppText.mono(10, color: AppColors.bone)),
          ),
        ],
      ),
    );
  }

  Widget _lines(List<String> values) {
    if (values.isEmpty) return _kv('', '—');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: SelectableText(values.join('\n'),
          style: AppText.mono(10, color: AppColors.bone)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _details;
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
                const DockerLogo(size: 16),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'DETALLES · ${widget.container.name.toUpperCase()}',
                    style:
                        AppText.label(10, color: AppColors.bone, spacing: 1.2),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
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
              child: _loading
                  ? const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      ),
                    )
                  : _error != null || d == null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              _error ?? 'No se pudieron obtener los detalles.',
                              textAlign: TextAlign.center,
                              style: AppText.mono(10, color: AppColors.danger),
                            ),
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.only(bottom: 24),
                          children: [
                            _sectionTitle('GENERAL'),
                            _kv('ID', d.id),
                            _kv('IMAGEN', d.image),
                            _kv('ESTADO', d.state),
                            _kv('CREADO', d.created),
                            _kv('INICIADO', d.startedAt),
                            if (!widget.container.running)
                              _kv('EXIT CODE', '${d.exitCode}'),
                            _kv('REINICIOS', '${d.restartCount}'),
                            _kv('POLÍTICA', d.restartPolicy),
                            if (d.cmd.isNotEmpty) _kv('COMANDO', d.cmd),
                            _sectionTitle('RED'),
                            _lines(d.networks),
                            _sectionTitle('PUERTOS'),
                            _lines(d.ports),
                            _sectionTitle('MONTAJES'),
                            _lines(d.mounts),
                            _sectionTitle('ENTORNO · ${d.env.length}'),
                            _lines(d.env),
                          ],
                        ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SegmentCell extends StatelessWidget {
  final String label;
  final IconData? icon;
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
              icon != null
                  ? Icon(icon, size: 16, color: fg)
                  : DockerLogo(size: 16, color: active ? fg : kDockerBlue),
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
