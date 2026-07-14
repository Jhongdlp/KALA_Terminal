import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../models/connection_profile.dart';

/// Lifecycle of the server console: pick a server → connecting → managing.
enum ServerPhase { pickServer, connecting, ready, error }

/// Sections of the server console (segmented bar). [monitor] is the
/// analytics/auditing overview; the rest manage Docker.
enum ServerSection {
  monitor,
  containers,
  images,
  volumes,
  networks,
  compose,
  system,
}

/// One published port of a container: host port → container port/protocol.
class PortMapping {
  final String hostPort; // '8080'
  final String containerPort; // '80/tcp'
  const PortMapping(this.hostPort, this.containerPort);
}

class DockerContainer {
  final String id, name, image, state, status, ports;
  const DockerContainer({
    required this.id,
    required this.name,
    required this.image,
    required this.state,
    required this.status,
    required this.ports,
  });
  bool get running => state == 'running';
  bool get paused => state == 'paused';

  static final RegExp _portRe = RegExp(r':(\d+)->(\d+(?:-\d+)?/\w+)');

  /// Host-published ports parsed from the `docker ps` PORTS column,
  /// deduplicated (IPv4/IPv6 bindings repeat the same mapping).
  List<PortMapping> get publishedPorts {
    final seen = <String>{};
    final out = <PortMapping>[];
    for (final m in _portRe.allMatches(ports)) {
      if (seen.add('${m[1]}->${m[2]}')) {
        out.add(PortMapping(m[1]!, m[2]!));
      }
    }
    return out;
  }
}

/// Detailed view of one container, parsed from `docker inspect`.
class ContainerDetails {
  final String id, image, created, startedAt, state, restartPolicy, cmd;
  final int restartCount, exitCode;
  final List<String> ports; // '0.0.0.0:8080 → 80/tcp'
  final List<String> mounts; // 'bind /src → /dst'
  final List<String> networks; // 'bridge · 172.17.0.2'
  final List<String> env; // 'KEY=value'
  const ContainerDetails({
    required this.id,
    required this.image,
    required this.created,
    required this.startedAt,
    required this.state,
    required this.restartPolicy,
    required this.cmd,
    required this.restartCount,
    required this.exitCode,
    required this.ports,
    required this.mounts,
    required this.networks,
    required this.env,
  });
}

class DockerImage {
  final String id, repository, tag, size, createdSince;
  const DockerImage({
    required this.id,
    required this.repository,
    required this.tag,
    required this.size,
    required this.createdSince,
  });
  String get ref => '$repository:$tag';
}

class DockerVolume {
  final String name, driver;
  const DockerVolume({required this.name, required this.driver});
}

class DockerNetwork {
  final String id, name, driver, scope;
  const DockerNetwork({
    required this.id,
    required this.name,
    required this.driver,
    required this.scope,
  });

  /// Docker's default networks cannot be removed.
  bool get builtin => name == 'bridge' || name == 'host' || name == 'none';
}

class ComposeProject {
  final String name, status;
  final List<String> configFiles;
  const ComposeProject({
    required this.name,
    required this.status,
    required this.configFiles,
  });
}

class DockerDfRow {
  final String type, total, active, size, reclaimable;
  const DockerDfRow({
    required this.type,
    required this.total,
    required this.active,
    required this.size,
    required this.reclaimable,
  });
}

class RemoteCmdResult {
  final String stdout, stderr;
  final int? exitCode;
  const RemoteCmdResult(this.stdout, this.stderr, this.exitCode);
  bool get ok => exitCode == 0;

  /// stderr first (that's where tools complain), trimmed for SnackBars.
  String get errorText {
    final msg = (stderr.trim().isNotEmpty ? stderr : stdout).trim();
    return msg.length > 200 ? '${msg.substring(0, 200)}…' : msg;
  }
}

/// A watched system service on the monitor section.
class ServiceStatus {
  final String name;
  final String label;
  String status; // 'active' | 'inactive' | 'unknown'
  ServiceStatus(this.name, this.label, [this.status = 'unknown']);
  bool get active => status == 'active';
}

/// Snapshot of the monitor (analytics) section. Replaced wholesale on
/// disconnect so stale numbers never leak across servers.
class ServerMonitor {
  String hostname = '';
  String osInfo = '';
  double cpuLoad = 0;
  String ramText = '—';
  double ramPercent = 0;
  String diskText = '—';
  double diskPercent = 0;
  bool loaded = false;
  final List<ServiceStatus> services = [
    ServiceStatus('nginx', 'Nginx Web Server'),
    ServiceStatus('docker', 'Docker Engine'),
    ServiceStatus('postgresql', 'PostgreSQL Database'),
    ServiceStatus('mysql', 'MySQL / MariaDB'),
    ServiceStatus('ssh', 'SSH Server'),
  ];
}

/// State + remote command layer for the server console (monitor + Docker).
///
/// Owned by AppState so the connection, sudo mode, active section and cached
/// data survive tab switches. It opens its own dedicated [SSHClient] via the
/// injected [openClient] (independent from any terminal session) and runs
/// every command on a one-off exec channel.
class ServerController extends ChangeNotifier {
  ServerController({required this.openClient});

  final Future<SSHClient> Function(ConnectionProfile profile,
      {void Function(String msg)? onNotice}) openClient;

  ServerPhase phase = ServerPhase.pickServer;
  ServerSection section = ServerSection.monitor;
  ConnectionProfile? profile;
  SSHClient? _client;

  /// Sticky per connection: flips on the first permission-denied fallback.
  bool useSudo = false;

  /// Sudo needs a password and we don't have a valid one — the UI should
  /// prompt the user (see [submitSudoPassword]).
  bool needsSudoPassword = false;

  /// In-memory only, cleared on disconnect. Fed to `sudo -S` via stdin so it
  /// never appears on the remote command line (visible in `ps`).
  String? _sudoPassword;

  /// Docker engine reachable on this server. When false the Docker sections
  /// show [dockerNotice] instead of lists; the monitor keeps working.
  bool dockerAvailable = false;
  String? dockerNotice;
  String? serverVersion;
  bool composeAvailable = false;

  /// Banner text shown in the panel; null = no error.
  String? lastError;

  /// An action (start/stop/pull/prune/…) is in flight — disables buttons.
  bool busy = false;

  /// A list refresh is in flight.
  bool loading = false;

  ServerMonitor monitor = ServerMonitor();
  List<DockerContainer> containers = [];
  Map<String, String> containerStats = {};
  List<DockerImage> images = [];
  List<DockerVolume> volumes = [];
  List<DockerNetwork> networks = [];
  List<ComposeProject> composeProjects = [];
  List<DockerDfRow> dfRows = [];

  /// Bumped on connect/disconnect so awaited work from a previous connection
  /// (or a cancelled connect) can detect it's stale and bail out.
  int _generation = 0;

  bool get connected => phase == ServerPhase.ready && _client != null;

  Future<void> connect(ConnectionProfile p) async {
    disconnect(silent: true);
    final gen = ++_generation;
    profile = p;
    phase = ServerPhase.connecting;
    lastError = null;
    notifyListeners();

    try {
      final client = await openClient(p);
      if (gen != _generation) {
        client.close();
        return;
      }
      _client = client;

      // Surface connection loss while the panel is open.
      client.done.then((_) => _onConnectionLost(gen),
          onError: (_) => _onConnectionLost(gen));

      // Docker probe. One shot detects everything at once: docker missing
      // (127), the daemon being down, or a socket permission error (which
      // triggers the sudo fallback inside runDocker). A failure here only
      // disables the Docker sections — the monitor still works.
      final probe = await runDocker("version --format '{{.Server.Version}}'");
      if (gen != _generation) return;
      if (probe.ok) {
        dockerAvailable = true;
        serverVersion = probe.stdout.trim();
        final compose = await runDocker('compose version --short');
        if (gen != _generation) return;
        composeAvailable = compose.ok;
      } else {
        dockerAvailable = false;
        dockerNotice = _describeProbeFailure(probe);
      }

      phase = ServerPhase.ready;
      notifyListeners();
      await refresh();
    } catch (e) {
      if (gen != _generation) return;
      lastError = 'No se pudo conectar: $e';
      phase = ServerPhase.error;
      notifyListeners();
    }
  }

  /// Closes the client and resets everything (including the sudo mode) back
  /// to the server picker. [silent] skips the notify (used from [connect]).
  void disconnect({bool silent = false}) {
    _generation++;
    _client?.close();
    _client = null;
    profile = null;
    phase = ServerPhase.pickServer;
    section = ServerSection.monitor;
    useSudo = false;
    needsSudoPassword = false;
    _sudoPassword = null;
    dockerAvailable = false;
    dockerNotice = null;
    serverVersion = null;
    composeAvailable = false;
    lastError = null;
    busy = false;
    loading = false;
    statsLoading = false;
    monitor = ServerMonitor();
    containers = [];
    containerStats = {};
    images = [];
    volumes = [];
    networks = [];
    composeProjects = [];
    dfRows = [];
    if (!silent) notifyListeners();
  }

  Future<void> reconnect() async {
    final p = profile;
    if (p == null) return;
    await connect(p);
  }

  void _onConnectionLost(int gen) {
    if (gen != _generation) return;
    if (phase != ServerPhase.ready && phase != ServerPhase.connecting) return;
    lastError = 'CONEXIÓN PERDIDA CON EL SERVIDOR';
    phase = ServerPhase.error;
    notifyListeners();
  }

  void dismissError() {
    lastError = null;
    notifyListeners();
  }

  void setSection(ServerSection s) {
    if (section == s) return;
    section = s;
    notifyListeners();
    refresh();
  }

  Future<void> refresh() async {
    if (_client == null) return;
    final gen = _generation;
    loading = true;
    notifyListeners();
    try {
      switch (section) {
        case ServerSection.monitor:
          await _refreshMonitor();
        case ServerSection.containers:
          await _refreshContainers();
        case ServerSection.images:
          await _refreshImages();
        case ServerSection.volumes:
          await _refreshVolumes();
        case ServerSection.networks:
          await _refreshNetworks();
        case ServerSection.compose:
          await _refreshCompose();
        case ServerSection.system:
          await _refreshDf();
      }
    } finally {
      if (gen == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  // ---------------------------------------------------------------------
  // Remote command plumbing
  // ---------------------------------------------------------------------

  /// Runs [cmd] on a fresh exec channel, capturing stdout/stderr concurrently
  /// and waiting for the exit code. Does not touch any terminal session.
  /// [stdinInput] is written to the remote stdin and the stream closed —
  /// used to feed `sudo -S` its password without putting it on the command
  /// line.
  Future<RemoteCmdResult> _run(String cmd, {String? stdinInput}) async {
    final client = _client;
    if (client == null) {
      return const RemoteCmdResult('', 'Sin conexión con el servidor.', 1);
    }
    final s = await client.execute(cmd);
    if (stdinInput != null) {
      s.stdin.add(Uint8List.fromList(utf8.encode(stdinInput)));
      await s.stdin.close();
    }
    final results = await Future.wait([
      utf8.decoder.bind(s.stdout.cast<List<int>>()).join(),
      utf8.decoder.bind(s.stderr.cast<List<int>>()).join(),
    ]);
    await s.done;
    return RemoteCmdResult(results[0], results[1], s.exitCode);
  }

  /// Runs [cmd] with elevated privileges using whatever sudo mode this
  /// connection has established; falls back to running it plain (the user
  /// may have rights of their own, e.g. via polkit).
  Future<RemoteCmdResult> _runPrivileged(String cmd) async {
    final pw = _sudoPassword;
    if (pw != null) {
      final r = await _run("sudo -S -p '' $cmd", stdinInput: '$pw\n');
      if (r.ok || !_isWrongSudoPassword(r)) return r;
    } else {
      final r = await _run('sudo -n $cmd');
      if (r.ok) return r;
    }
    return _run(cmd);
  }

  /// Runs `docker [args]`, escalating to sudo when the failure is a socket
  /// permission error. Escalation order: `sudo -n` (NOPASSWD), then `sudo -S`
  /// with the SSH profile password (often the same account), then asking the
  /// user via [needsSudoPassword]/[submitSudoPassword].
  Future<RemoteCmdResult> runDocker(String args) async {
    if (useSudo) return _runSudoDocker(args);
    final r = await _run('docker $args');
    if (_isPermissionDenied(r)) return _escalate(args);
    return r;
  }

  /// A sudo docker command for this connection, honoring the stored password.
  Future<RemoteCmdResult> _runSudoDocker(String args) async {
    final pw = _sudoPassword;
    if (pw == null) return _run('sudo -n docker $args');
    final r = await _run("sudo -S -p '' docker $args", stdinInput: '$pw\n');
    if (_isWrongSudoPassword(r)) {
      // The stored password stopped working (changed server-side?): re-ask.
      _sudoPassword = null;
      needsSudoPassword = true;
      notifyListeners();
      return const RemoteCmdResult(
          '', 'La contraseña sudo ya no es válida; introdúcela de nuevo.', 1);
    }
    return r;
  }

  /// First permission-denied on this connection: find a working sudo mode.
  Future<RemoteCmdResult> _escalate(String args) async {
    final sr = await _run('sudo -n docker $args');
    if (sr.ok) {
      useSudo = true;
      notifyListeners();
      return sr;
    }
    if (!sr.stderr.contains('password is required')) {
      // Not a password problem (e.g. user not in sudoers): report as-is.
      return sr;
    }
    // Silently try the SSH profile password — it's usually the same account.
    final profilePw = profile?.password;
    if (profilePw != null && profilePw.isNotEmpty) {
      final pr = await _run("sudo -k -S -p '' docker $args",
          stdinInput: '$profilePw\n');
      if (pr.ok) {
        useSudo = true;
        _sudoPassword = profilePw;
        notifyListeners();
        return pr;
      }
    }
    needsSudoPassword = true;
    notifyListeners();
    return const RemoteCmdResult(
        '',
        'Docker requiere permisos elevados y sudo pide contraseña. '
        'Introdúcela para continuar.',
        1);
  }

  /// Validates [password] against sudo on the server; on success it is kept
  /// for the rest of the connection and the Docker sections are enabled.
  /// Returns null on success or an error message.
  Future<String?> submitSudoPassword(String password) async {
    if (_client == null) return 'Sin conexión con el servidor.';
    final gen = _generation;
    busy = true;
    notifyListeners();
    try {
      // -k ignores any cached timestamp so this is a real validation.
      final r = await _run(
          "sudo -k -S -p '' docker version --format '{{.Server.Version}}'",
          stdinInput: '$password\n');
      if (gen != _generation) return null;
      if (!r.ok) {
        return _isWrongSudoPassword(r) ? 'Contraseña incorrecta.' : r.errorText;
      }
      _sudoPassword = password;
      useSudo = true;
      needsSudoPassword = false;
      dockerAvailable = true;
      dockerNotice = null;
      serverVersion = r.stdout.trim();
      lastError = null;
      notifyListeners();

      final compose = await runDocker('compose version --short');
      if (gen != _generation) return null;
      composeAvailable = compose.ok;
      notifyListeners();
      await refresh();
      return null;
    } finally {
      if (gen == _generation) {
        busy = false;
        notifyListeners();
      }
    }
  }

  /// With `-p ''` and stdin closed after one line, a bad password surfaces as
  /// "incorrect password attempt(s)" or "no password was provided".
  static bool _isWrongSudoPassword(RemoteCmdResult r) =>
      !r.ok &&
      (r.stderr.contains('incorrect password') ||
          r.stderr.contains('no password was provided'));

  static bool _isPermissionDenied(RemoteCmdResult r) =>
      !r.ok &&
      r.stderr.toLowerCase().contains('permission denied') &&
      r.stderr.contains('docker.sock');

  String _describeProbeFailure(RemoteCmdResult r) {
    if (r.exitCode == 127 ||
        r.stderr.contains('command not found') ||
        r.stderr.contains('not found')) {
      return 'Docker no está instalado en este servidor.';
    }
    if (r.stderr.contains('Cannot connect to the Docker daemon')) {
      return 'El daemon de Docker no está activo en este servidor.';
    }
    return r.errorText.isEmpty
        ? 'No se pudo consultar Docker en el servidor.'
        : r.errorText;
  }

  /// Docker ids/names charset — anything else is refused rather than quoted.
  static final RegExp _safeToken = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.\-]*$');

  /// Image refs / compose paths: broader charset, still no quotes or spaces.
  static final RegExp _safeRef = RegExp(r"^[A-Za-z0-9][A-Za-z0-9_.:/@~\-]*$");

  static bool isSafeToken(String s) => _safeToken.hasMatch(s);

  static String? _guardToken(String s) =>
      _safeToken.hasMatch(s) ? null : 'Identificador no válido: $s';

  static String? _guardRef(String s) =>
      _safeRef.hasMatch(s) ? null : 'Referencia no válida: $s';

  /// Runs an action command; returns null on success or an error message.
  Future<String?> _action(Future<RemoteCmdResult> Function() run) async {
    busy = true;
    notifyListeners();
    try {
      final r = await run();
      return r.ok ? null : r.errorText;
    } catch (e) {
      return e.toString();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------
  // Monitor (analytics / auditing overview)
  // ---------------------------------------------------------------------

  /// One compound command per refresh — a single exec round-trip instead of
  /// nine — emitting one `TAG|value` line per metric.
  static const String _monitorCmd = r'''
echo "H|$(hostname 2>/dev/null)"
echo "O|$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
echo "L|$(cat /proc/loadavg 2>/dev/null)"
echo "M|$(free -m 2>/dev/null | grep -i '^mem:')"
echo "D|$(df -h / 2>/dev/null | tail -n 1)"
if command -v systemctl >/dev/null 2>&1; then
  echo "S|$(systemctl is-active nginx docker postgresql mysql ssh 2>/dev/null | tr '\n' ',')"
else
  echo "S|$(for s in nginx docker postgresql mysql ssh; do rc-service $s status >/dev/null 2>&1 && printf active, || printf inactive,; done)"
fi
''';

  Future<void> _refreshMonitor() async {
    final r = await _run(_monitorCmd);
    if (!r.ok && r.stdout.trim().isEmpty) {
      lastError = r.errorText;
      return;
    }
    final m = ServerMonitor();
    for (final line in const LineSplitter().convert(r.stdout)) {
      final sep = line.indexOf('|');
      if (sep < 1) continue;
      final tag = line.substring(0, sep);
      final value = line.substring(sep + 1).trim();
      switch (tag) {
        case 'H':
          m.hostname = value;
        case 'O':
          m.osInfo = value.isNotEmpty ? value : 'Linux Genérico';
        case 'L':
          m.cpuLoad = double.tryParse(value.split(' ').first) ?? 0;
        case 'M':
          final parts = value.split(RegExp(r'\s+'));
          if (parts.length >= 3) {
            final total = int.tryParse(parts[1]) ?? 1;
            final used = int.tryParse(parts[2]) ?? 0;
            m.ramPercent = total > 0 ? used / total : 0;
            m.ramText = '${used}MB / ${total}MB';
          }
        case 'D':
          final parts = value.split(RegExp(r'\s+'));
          if (parts.length >= 5) {
            final percent =
                int.tryParse(parts[4].replaceAll('%', '')) ?? 0;
            m.diskPercent = percent / 100.0;
            m.diskText = '${parts[2]} / ${parts[1]}';
          }
        case 'S':
          final statuses = value.split(',');
          for (int i = 0;
              i < m.services.length && i < statuses.length;
              i++) {
            final s = statuses[i].trim();
            m.services[i].status = s == 'active' ? 'active' : 'inactive';
          }
      }
    }
    m.loaded = true;
    monitor = m;
  }

  static const Set<String> _knownServices = {
    'nginx',
    'docker',
    'postgresql',
    'mysql',
    'ssh',
  };

  /// 'start' | 'stop' | 'restart' on a watched system service.
  Future<String?> controlService(String name, String action) async {
    if (!_knownServices.contains(name)) return 'Servicio no reconocido.';
    if (!const {'start', 'stop', 'restart'}.contains(action)) {
      return 'Acción no válida.';
    }
    final err = await _action(() => _runPrivileged(
        'sh -c "command -v systemctl >/dev/null && systemctl $action $name '
        '|| rc-service $name $action"'));
    await refresh();
    return err;
  }

  // ---------------------------------------------------------------------
  // Containers
  // ---------------------------------------------------------------------

  Future<void> _refreshContainers() async {
    if (!dockerAvailable) return;
    final r = await runDocker(
        "ps -a --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.State}}|{{.Status}}|{{.Ports}}'");
    if (!r.ok) {
      lastError = r.errorText;
      return;
    }
    containers = _parseLines(r.stdout, 6)
        .map((f) => DockerContainer(
              id: f[0],
              name: f[1],
              image: f[2],
              state: f[3],
              status: f[4],
              ports: f[5],
            ))
        .toList();
    // Refresh CPU/MEM figures in the background so the list paints first
    // (`docker stats --no-stream` takes a couple of seconds).
    if (containers.any((c) => c.running)) {
      unawaited(fetchStats(quiet: true));
    } else {
      containerStats = {};
    }
  }

  static const Set<String> _containerVerbs = {
    'start',
    'stop',
    'restart',
    'pause',
    'unpause',
    'kill',
    'rm',
    'rm -f',
  };

  /// One of [_containerVerbs].
  Future<String?> containerAction(String id, String verb) async {
    if (!_containerVerbs.contains(verb)) return 'Acción no válida.';
    final guard = _guardToken(id);
    if (guard != null) return guard;
    final err = await _action(() => runDocker("$verb '$id'"));
    await refresh();
    return err;
  }

  /// Full detail of one container. Returns the details or an error message.
  Future<(ContainerDetails?, String?)> inspectContainer(String id) async {
    final guard = _guardToken(id);
    if (guard != null) return (null, guard);
    final r = await runDocker("inspect '$id'");
    if (!r.ok) return (null, r.errorText);
    try {
      final j = ((jsonDecode(r.stdout) as List).first) as Map<String, dynamic>;
      final state = j['State'] as Map<String, dynamic>? ?? const {};
      final config = j['Config'] as Map<String, dynamic>? ?? const {};
      final host = j['HostConfig'] as Map<String, dynamic>? ?? const {};
      final net = j['NetworkSettings'] as Map<String, dynamic>? ?? const {};

      final ports = <String>[];
      final seenPorts = <String>{};
      (net['Ports'] as Map<String, dynamic>? ?? const {})
          .forEach((cPort, binds) {
        if (binds is List && binds.isNotEmpty) {
          for (final b in binds) {
            final line = '${b['HostIp']}:${b['HostPort']} → $cPort';
            if (seenPorts.add(line)) ports.add(line);
          }
        } else {
          ports.add('$cPort (sin publicar)');
        }
      });

      final mounts = <String>[
        for (final m in (j['Mounts'] as List? ?? const []))
          '${m['Type']} ${m['Source'] ?? m['Name'] ?? '?'} → ${m['Destination']}',
      ];
      final networks = <String>[
        for (final e
            in (net['Networks'] as Map<String, dynamic>? ?? const {}).entries)
          '${e.key} · ${(e.value as Map)['IPAddress'] ?? '—'}',
      ];
      final policy =
          (host['RestartPolicy'] as Map<String, dynamic>?)?['Name'] as String?;
      final rawId = j['Id'] as String? ?? id;
      return (
        ContainerDetails(
          id: rawId.length > 12 ? rawId.substring(0, 12) : rawId,
          image: config['Image'] as String? ?? '',
          created: _fmtIso(j['Created'] as String?),
          startedAt: _fmtIso(state['StartedAt'] as String?),
          state: state['Status'] as String? ?? '',
          restartPolicy: (policy == null || policy.isEmpty) ? 'no' : policy,
          cmd: (config['Cmd'] as List?)?.join(' ') ?? '',
          restartCount: j['RestartCount'] as int? ?? 0,
          exitCode: state['ExitCode'] as int? ?? 0,
          ports: ports,
          mounts: mounts,
          networks: networks,
          env: List<String>.from(config['Env'] as List? ?? const []),
        ),
        null
      );
    } catch (e) {
      return (null, 'No se pudo interpretar docker inspect: $e');
    }
  }

  /// ISO-8601 → 'YYYY-MM-DD HH:MM' local, or '—' for Docker's zero time.
  static String _fmtIso(String? iso) {
    final t = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
    if (t == null || t.year < 2000) return '—';
    String p(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${p(t.month)}-${p(t.day)} ${p(t.hour)}:${p(t.minute)}';
  }

  Future<String> fetchLogs(String id, {int tail = 200}) async {
    final guard = _guardToken(id);
    if (guard != null) return guard;
    // docker splits its own stdout/stderr streams; 2>&1 keeps them interleaved
    // in arrival order like a terminal would show them.
    final r = await runDocker("logs --tail $tail '$id' 2>&1");
    return r.ok ? r.stdout : r.errorText;
  }

  /// A stats refresh is in flight (kept apart from [busy] so it never
  /// disables the action buttons).
  bool statsLoading = false;

  Future<void> fetchStats({bool quiet = false}) async {
    if (statsLoading || !dockerAvailable) return;
    final gen = _generation;
    statsLoading = true;
    notifyListeners();
    try {
      final r = await runDocker(
          "stats --no-stream --format '{{.ID}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}'");
      if (gen != _generation) return;
      if (r.ok) {
        containerStats = {
          for (final f in _parseLines(r.stdout, 4))
            f[0]: 'CPU ${f[1]} · MEM ${f[2]} (${f[3]})',
        };
      } else if (!quiet) {
        lastError = r.errorText;
      }
    } finally {
      if (gen == _generation) {
        statsLoading = false;
        notifyListeners();
      }
    }
  }

  /// Command for the "ABRIR SHELL" terminal session: bash if available,
  /// plain sh otherwise. Includes the sudo prefix when this connection
  /// needed it. With password-mode sudo the terminal session is interactive
  /// (it has a PTY), so plain `sudo` simply prompts the user there.
  String execShellCommand(String id) {
    final prefix = !useSudo
        ? ''
        : _sudoPassword != null
            ? 'sudo '
            : 'sudo -n ';
    return "${prefix}docker exec -it '$id' "
        'sh -c "command -v bash >/dev/null && exec bash || exec sh"';
  }

  // ---------------------------------------------------------------------
  // Images
  // ---------------------------------------------------------------------

  Future<void> _refreshImages() async {
    if (!dockerAvailable) return;
    final r = await runDocker(
        "images --format '{{.ID}}|{{.Repository}}|{{.Tag}}|{{.Size}}|{{.CreatedSince}}'");
    if (!r.ok) {
      lastError = r.errorText;
      return;
    }
    images = _parseLines(r.stdout, 5)
        .map((f) => DockerImage(
              id: f[0],
              repository: f[1],
              tag: f[2],
              size: f[3],
              createdSince: f[4],
            ))
        .toList();
  }

  Future<String?> removeImage(String id, {bool force = false}) async {
    final guard = _guardToken(id);
    if (guard != null) return guard;
    final err =
        await _action(() => runDocker("rmi ${force ? '-f ' : ''}'$id'"));
    await refresh();
    return err;
  }

  Future<String?> pullImage(String ref) async {
    final guard = _guardRef(ref);
    if (guard != null) return guard;
    final err = await _action(() => runDocker("pull '$ref'"));
    await refresh();
    return err;
  }

  // ---------------------------------------------------------------------
  // Volumes / Networks
  // ---------------------------------------------------------------------

  Future<void> _refreshVolumes() async {
    if (!dockerAvailable) return;
    final r = await runDocker("volume ls --format '{{.Name}}|{{.Driver}}'");
    if (!r.ok) {
      lastError = r.errorText;
      return;
    }
    volumes = _parseLines(r.stdout, 2)
        .map((f) => DockerVolume(name: f[0], driver: f[1]))
        .toList();
  }

  Future<String?> removeVolume(String name) async {
    final guard = _guardToken(name);
    if (guard != null) return guard;
    final err = await _action(() => runDocker("volume rm '$name'"));
    await refresh();
    return err;
  }

  Future<void> _refreshNetworks() async {
    if (!dockerAvailable) return;
    final r = await runDocker(
        "network ls --format '{{.ID}}|{{.Name}}|{{.Driver}}|{{.Scope}}'");
    if (!r.ok) {
      lastError = r.errorText;
      return;
    }
    networks = _parseLines(r.stdout, 4)
        .map((f) =>
            DockerNetwork(id: f[0], name: f[1], driver: f[2], scope: f[3]))
        .toList();
  }

  Future<String?> removeNetwork(String id) async {
    final guard = _guardToken(id);
    if (guard != null) return guard;
    final err = await _action(() => runDocker("network rm '$id'"));
    await refresh();
    return err;
  }

  // ---------------------------------------------------------------------
  // Compose
  // ---------------------------------------------------------------------

  Future<void> _refreshCompose() async {
    if (!dockerAvailable || !composeAvailable) {
      composeProjects = [];
      return;
    }
    final r = await runDocker('compose ls --all --format json');
    if (!r.ok) {
      lastError = r.errorText;
      return;
    }
    composeProjects = _parseComposeLs(r.stdout);
  }

  /// Newer compose v2 prints a JSON array; older builds print one JSON object
  /// per line (NDJSON). Accept both.
  static List<ComposeProject> _parseComposeLs(String out) {
    List<dynamic> raw;
    try {
      final decoded = jsonDecode(out.trim());
      raw = decoded is List ? decoded : [decoded];
    } catch (_) {
      raw = [];
      for (final line in const LineSplitter().convert(out)) {
        if (line.trim().isEmpty) continue;
        try {
          raw.add(jsonDecode(line));
        } catch (_) {}
      }
    }
    return raw.whereType<Map<String, dynamic>>().map((m) {
      final files = (m['ConfigFiles'] as String? ?? '')
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      return ComposeProject(
        name: m['Name'] as String? ?? '',
        status: m['Status'] as String? ?? '',
        configFiles: files,
      );
    }).toList();
  }

  /// 'up -d' | 'down' | 'restart'
  Future<String?> composeAction(ComposeProject p, String verb) async {
    if (p.configFiles.isEmpty) {
      return 'El proyecto no expone sus archivos compose.';
    }
    final flags = StringBuffer();
    for (final f in p.configFiles) {
      final guard = _guardRef(f);
      if (guard != null) return guard;
      flags.write("-f '$f' ");
    }
    final err = await _action(() => runDocker('compose $flags$verb'));
    await refresh();
    return err;
  }

  // ---------------------------------------------------------------------
  // System
  // ---------------------------------------------------------------------

  Future<void> _refreshDf() async {
    if (!dockerAvailable) return;
    final r = await runDocker(
        "system df --format '{{.Type}}|{{.TotalCount}}|{{.Active}}|{{.Size}}|{{.Reclaimable}}'");
    if (!r.ok) {
      lastError = r.errorText;
      return;
    }
    dfRows = _parseLines(r.stdout, 5)
        .map((f) => DockerDfRow(
              type: f[0],
              total: f[1],
              active: f[2],
              size: f[3],
              reclaimable: f[4],
            ))
        .toList();
  }

  /// 'container' | 'image' | 'volume' | 'network' | 'system'
  Future<String?> prune(String what) async {
    const allowed = {'container', 'image', 'volume', 'network', 'system'};
    if (!allowed.contains(what)) return 'Objetivo de limpieza no válido.';
    final err = await _action(() => runDocker('$what prune -f'));
    await refresh();
    return err;
  }

  // ---------------------------------------------------------------------

  /// Splits pipe-delimited `--format` output into rows of at least
  /// [fields] columns (missing trailing fields become '').
  static List<List<String>> _parseLines(String out, int fields) {
    final rows = <List<String>>[];
    for (final line in const LineSplitter().convert(out)) {
      if (line.trim().isEmpty) continue;
      final parts = line.split('|');
      if (parts.length < fields) {
        parts.addAll(List.filled(fields - parts.length, ''));
      }
      rows.add(parts);
    }
    return rows;
  }

  @override
  void dispose() {
    _generation++;
    _client?.close();
    _client = null;
    super.dispose();
  }
}
