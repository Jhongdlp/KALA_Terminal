import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';

class VpsTab extends StatefulWidget {
  const VpsTab({super.key});

  @override
  State<VpsTab> createState() => _VpsTabState();
}

class _VpsTabState extends State<VpsTab> {
  bool _isLoading = false;
  Timer? _refreshTimer;
  
  // Parsed Stats
  String _hostname = 'Cargando...';
  String _osInfo = 'Detectando...';
  double _cpuLoad = 0.0;
  String _ramText = '...';
  double _ramUsedPercent = 0.0;
  String _diskText = '...';
  double _diskUsedPercent = 0.0;

  // Services Status
  final List<Map<String, dynamic>> _services = [
    {'name': 'nginx', 'status': 'unknown', 'label': 'Nginx Web Server'},
    {'name': 'docker', 'status': 'unknown', 'label': 'Docker Engine'},
    {'name': 'postgresql', 'status': 'unknown', 'label': 'PostgreSQL Database'},
    {'name': 'mysql', 'status': 'unknown', 'label': 'MySQL / MariaDB'},
    {'name': 'ssh', 'status': 'unknown', 'label': 'SSH Server'},
  ];

  @override
  void initState() {
    super.initState();
    // Load metrics initially and setup periodic refresh
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshStats();
      _refreshTimer = Timer.periodic(const Duration(seconds: 15), (_) => _refreshStats());
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<String> _runCommand(AppState state, String command) async {
    final session = state.activeSession;
    if (session == null || session.sshClient == null) return '';
    try {
      final run = await session.sshClient!.execute(command);
      return await run.stdout.cast<List<int>>().transform(utf8.decoder).join();
    } catch (e) {
      debugPrint('Error ejecutando comando VPS: $e');
      return '';
    }
  }

  Future<void> _refreshStats() async {
    final state = context.read<AppState>();
    if (state.connectionStatus != ConnectionStatus.remote) return;

    if (mounted) setState(() => _isLoading = true);

    try {
      // 1. Fetch OS & Hostname info
      final hostname = (await _runCommand(state, 'hostname')).trim();
      final osInfoRaw = await _runCommand(state, 'cat /etc/os-release | grep PRETTY_NAME | cut -d\'"\' -f2');
      final osInfo = osInfoRaw.trim().isNotEmpty ? osInfoRaw.trim() : 'Linux Genérico';

      // 2. Fetch CPU Load (from /proc/loadavg)
      final loadavg = await _runCommand(state, 'cat /proc/loadavg');
      double cpuLoad = 0.0;
      if (loadavg.isNotEmpty) {
        final parts = loadavg.split(' ');
        if (parts.isNotEmpty) {
          cpuLoad = double.tryParse(parts[0]) ?? 0.0;
        }
      }

      // 3. Fetch RAM Info (free -m)
      final freeOut = await _runCommand(state, 'free -m');
      String ramText = 'N/A';
      double ramPercent = 0.0;
      if (freeOut.isNotEmpty) {
        final lines = const LineSplitter().convert(freeOut);
        for (final line in lines) {
          if (line.startsWith('Mem:')) {
            final parts = line.split(RegExp(r'\s+'));
            if (parts.length >= 3) {
              final total = int.tryParse(parts[1]) ?? 1;
              final used = int.tryParse(parts[2]) ?? 0;
              ramPercent = used / total;
              ramText = '${used}MB / ${total}MB';
            }
          }
        }
      }

      // 4. Fetch Disk Info (df -h /)
      final dfOut = await _runCommand(state, 'df -h / | tail -n 1');
      String diskText = 'N/A';
      double diskPercent = 0.0;
      if (dfOut.isNotEmpty) {
        final parts = dfOut.split(RegExp(r'\s+'));
        if (parts.length >= 5) {
          final size = parts[1];
          final used = parts[2];
          final percentStr = parts[4].replaceAll('%', '');
          final percent = int.tryParse(percentStr) ?? 0;
          diskPercent = percent / 100.0;
          diskText = '$used / $size';
        }
      }

      // 5. Query systemd or rc-service for our defined services
      for (var s in _services) {
        final name = s['name'] as String;
        // Try systemctl first, fallback to rc-service (OpenRC)
        final sysctlActive = await _runCommand(state, 'command -v systemctl >/dev/null && systemctl is-active $name || echo "nosysctl"');
        if (sysctlActive.trim() != 'nosysctl') {
          s['status'] = sysctlActive.trim() == 'active' ? 'active' : 'inactive';
        } else {
          // OpenRC check
          final rcActive = await _runCommand(state, 'rc-service $name status 2>/dev/null | grep -q "started" && echo "active" || echo "inactive"');
          s['status'] = rcActive.trim() == 'active' ? 'active' : 'inactive';
        }
      }

      if (mounted) {
        setState(() {
          _hostname = hostname.isNotEmpty ? hostname : 'vps-server';
          _osInfo = osInfo;
          _cpuLoad = cpuLoad;
          _ramText = ramText;
          _ramUsedPercent = ramPercent;
          _diskText = diskText;
          _diskUsedPercent = diskPercent;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error actualizando métricas VPS: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _controlService(String name, String action) async {
    final state = context.read<AppState>();
    setState(() => _isLoading = true);

    try {
      // Check systemctl or rc-service
      final hasSysctl = (await _runCommand(state, 'command -v systemctl >/dev/null && echo "yes" || echo "no"')).trim() == 'yes';
      
      String command = '';
      if (hasSysctl) {
        command = 'sudo systemctl $action $name || systemctl $action $name';
      } else {
        // OpenRC mappings
        final rcAction = action == 'start' ? 'start' : (action == 'stop' ? 'stop' : 'restart');
        command = 'sudo rc-service $name $rcAction || rc-service $name $rcAction';
      }

      await _runCommand(state, command);
      await _refreshStats();
    } catch (e) {
      debugPrint('Error controlando servicio $name: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _buildMetricCard(String title, String value, double progress, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppText.label(9, color: AppColors.muted, spacing: 1.0)),
          const SizedBox(height: 8),
          Text(value, style: AppText.mono(12, color: AppColors.bone, weight: FontWeight.w700)),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              backgroundColor: AppColors.ink,
              color: color,
              minHeight: 4,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    final isRemote = state.connectionStatus == ConnectionStatus.remote;

    if (!isRemote) {
      return Container(
        color: AppColors.ink,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.dns_outlined, size: 48, color: AppColors.muted),
              const SizedBox(height: 16),
              Text(
                'SIN CONEXIÓN ACTIVA',
                style: AppText.label(12, color: AppColors.bone, spacing: 1.5),
              ),
              const SizedBox(height: 8),
              Text(
                'Conéctate a un VPS remoto desde la pestaña de Conexiones\npara ver las métricas de tu servidor.',
                textAlign: TextAlign.center,
                style: AppText.body(11, color: AppColors.muted),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      color: AppColors.ink,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Path/Server Header
          Container(
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.panel,
              border: Border(bottom: BorderSide(color: AppColors.hairline, width: 1)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(Icons.dns_outlined, size: 14, color: AppColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$_hostname ($_osInfo)'.toUpperCase(),
                    style: AppText.mono(10, color: AppColors.bone, spacing: 1.0),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_isLoading)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 16),
                    color: AppColors.bone,
                    onPressed: _refreshStats,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ],
            ),
          ),
          
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // 1. Grid of metrics
                GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 3,
                  crossAxisSpacing: 10,
                  childAspectRatio: 0.9,
                  children: [
                    _buildMetricCard(
                      'CARGA CPU', 
                      '${(_cpuLoad).toStringAsFixed(2)}', 
                      _cpuLoad / 4.0, // Scale relative to 4 cores load
                      _cpuLoad > 3.0 ? AppColors.danger : AppColors.accent
                    ),
                    _buildMetricCard(
                      'MEMORIA RAM', 
                      _ramText, 
                      _ramUsedPercent, 
                      _ramUsedPercent > 0.85 ? AppColors.danger : AppColors.accent
                    ),
                    _buildMetricCard(
                      'DISCO', 
                      _diskText, 
                      _diskUsedPercent, 
                      _diskUsedPercent > 0.9 ? AppColors.danger : AppColors.accent
                    ),
                  ],
                ),
                
                const SizedBox(height: 24),
                
                // 2. Services Management Header
                Text(
                  'SERVICIOS DEL SISTEMA',
                  style: AppText.label(10, color: AppColors.bone, spacing: 1.5),
                ),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.panel,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: AppColors.hairline),
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _services.length,
                    separatorBuilder: (_, __) => Hairline(),
                    itemBuilder: (context, idx) {
                      final s = _services[idx];
                      final name = s['name'] as String;
                      final label = s['label'] as String;
                      final status = s['status'] as String;
                      final isActive = status == 'active';

                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Row(
                          children: [
                            Icon(
                              isActive ? Icons.check_circle_outline : Icons.error_outline,
                              size: 16,
                              color: isActive ? Colors.green : AppColors.muted,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    name.toUpperCase(),
                                    style: AppText.mono(11, color: AppColors.bone, weight: FontWeight.w600),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    label,
                                    style: AppText.body(9, color: AppColors.muted),
                                  ),
                                ],
                              ),
                            ),
                            
                            // Start / Stop toggles
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                OutlinedButton(
                                  onPressed: () => _controlService(name, isActive ? 'stop' : 'start'),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                    side: BorderSide(color: isActive ? AppColors.danger : Colors.green),
                                    minimumSize: Size.zero,
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
                                  ),
                                  child: Text(
                                    isActive ? 'DETENER' : 'INICIAR',
                                    style: AppText.mono(8, color: isActive ? AppColors.danger : Colors.green),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton(
                                  onPressed: isActive ? () => _controlService(name, 'restart') : null,
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                    side: BorderSide(
                                      color: isActive ? AppColors.accent : AppColors.muted.withOpacity(0.3)
                                    ),
                                    minimumSize: Size.zero,
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
                                  ),
                                  child: Text(
                                    'REINICIAR',
                                    style: AppText.mono(8, color: isActive ? AppColors.accent : AppColors.muted),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
