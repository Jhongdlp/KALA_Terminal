import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../models/ssh_tunnel.dart';
import '../l10n/l10n.dart';

/// Live state of a tunnel.
enum TunnelState { stopped, starting, active, failed }

/// The running counterpart of an [SshTunnel]: everything that only exists while
/// a tunnel is up (bound port, open sockets, counters, last error).
///
/// One runtime per tunnel id per session. Kept alive across reconnects so the
/// UI doesn't blink and [desired] survives a dropped connection.
class TunnelRuntime {
  SshTunnel config;

  TunnelState state = TunnelState.stopped;

  /// User-facing reason for [TunnelState.failed], already in Spanish.
  String? error;

  /// Raw exception text behind [error], shown only on demand.
  String? errorDetail;

  /// Port actually bound. Differs from `config.listenPort` when a remote
  /// forward asks the server to pick one (port 0).
  int? boundPort;

  int liveConnections = 0;
  int totalConnections = 0;
  int bytesUp = 0;
  int bytesDown = 0;
  DateTime? startedAt;

  /// The user wants this tunnel running. Set when it is started (manually or by
  /// autoStart) and cleared only when the user stops it, so a reconnect brings
  /// back exactly the tunnels that were up.
  bool desired = false;

  /// True when the tunnel was closed by its own inactivity timer rather than by
  /// the user or a failure — the row says so instead of just "parado".
  bool stoppedForIdle = false;

  /// When the idle countdown will fire, for the "se cerrará en N min" hint.
  DateTime? idleDeadline;

  // ---- internals -----------------------------------------------------------
  ServerSocket? _server;
  Timer? _idleTimer;
  SSHDynamicForward? _dynamic;
  SSHRemoteForward? _remote;
  StreamSubscription<Socket>? _acceptSub;
  StreamSubscription<SSHForwardChannel>? _remoteSub;
  final List<_Bridge> _bridges = [];

  TunnelRuntime(this.config);

  bool get isBusy => state == TunnelState.starting;
  bool get isUp => state == TunnelState.active;

  /// Address to hand the user (browser, proxy settings). Null for remote
  /// forwards, which don't listen on this device.
  String? get localAddress {
    if (!config.kind.listensOnDevice) return null;
    final host = config.exposeToLan ? '0.0.0.0' : 'localhost';
    return '$host:${boundPort ?? config.listenPort}';
  }
}

/// A single proxied connection: one device socket paired with one SSH channel.
class _Bridge {
  final Socket socket;
  final SSHForwardChannel channel;
  StreamSubscription? socketSub;
  StreamSubscription? channelSub;

  /// Each side is "done" once it has sent EOF. The pair is only torn down when
  /// both are, so a half-closed connection can still deliver its reply.
  bool socketDone = false;
  bool channelDone = false;
  bool closed = false;

  _Bridge(this.socket, this.channel);
}

/// Per-session bucket of tunnels plus the SSH client they ride on.
class _SessionTunnels {
  final String sessionId;
  String sessionName;
  SSHClient? client;
  void Function(String message)? log;
  final List<TunnelRuntime> tunnels = [];

  _SessionTunnels(this.sessionId, this.sessionName);
}

/// Owns every port forward in the app.
///
/// Deliberately kept out of `AppState` (already a 4k-line god object) and
/// deliberately unaware of `TerminalSession`: it only needs a session id, a
/// name for the UI and a live [SSHClient]. Tunnels are tied to their session —
/// when the session dies they stop, and when it reconnects the ones that were
/// up come back.
class TunnelManager extends ChangeNotifier {
  final Map<String, _SessionTunnels> _sessions = {};

  Timer? _throttle;
  bool _disposed = false;

  // ---- read API ------------------------------------------------------------

  List<TunnelRuntime> forSession(String sessionId) =>
      List.unmodifiable(_sessions[sessionId]?.tunnels ?? const []);

  /// Sessions that currently have tunnels configured, in insertion order.
  List<({String id, String name, List<TunnelRuntime> tunnels})> get overview =>
      _sessions.values
          .where((s) => s.tunnels.isNotEmpty)
          .map((s) => (
                id: s.sessionId,
                name: s.sessionName,
                tunnels: List<TunnelRuntime>.unmodifiable(s.tunnels)
              ))
          .toList();

  bool get isEmpty => _sessions.values.every((s) => s.tunnels.isEmpty);

  int activeCount([String? sessionId]) {
    final buckets = sessionId == null
        ? _sessions.values
        : [if (_sessions[sessionId] != null) _sessions[sessionId]!];
    return buckets.fold(
        0, (n, s) => n + s.tunnels.where((t) => t.isUp).length);
  }

  int failedCount([String? sessionId]) {
    final buckets = sessionId == null
        ? _sessions.values
        : [if (_sessions[sessionId] != null) _sessions[sessionId]!];
    return buckets.fold(0,
        (n, s) => n + s.tunnels.where((t) => t.state == TunnelState.failed).length);
  }

  /// True when any running tunnel is bound to all interfaces — drives the
  /// permanent warning banner.
  bool get hasLanExposure => _sessions.values.any((s) => s.tunnels
      .any((t) => t.isUp && t.config.exposeToLan && t.config.kind.listensOnDevice));

  TunnelRuntime? find(String sessionId, String tunnelId) {
    final bucket = _sessions[sessionId];
    if (bucket == null) return null;
    for (final t in bucket.tunnels) {
      if (t.config.id == tunnelId) return t;
    }
    return null;
  }

  // ---- session lifecycle ---------------------------------------------------

  /// Called right after a session's SSH client is up. Reconciles the runtime
  /// list with the profile's tunnels and starts the ones that should be up:
  /// `autoStart` on a fresh connect, plus anything the user had running before
  /// a drop ([TunnelRuntime.desired]).
  Future<void> syncOnConnect({
    required String sessionId,
    required String sessionName,
    required SSHClient client,
    required List<SshTunnel> tunnels,
    void Function(String message)? log,
  }) async {
    final bucket = _sessions.putIfAbsent(
        sessionId, () => _SessionTunnels(sessionId, sessionName));
    bucket.sessionName = sessionName;
    bucket.client = client;
    bucket.log = log;

    _reconcile(bucket, tunnels);
    notifyListeners();

    for (final rt in List<TunnelRuntime>.from(bucket.tunnels)) {
      if (rt.config.autoStart || rt.desired) {
        await start(sessionId, rt.config.id);
      }
    }
  }

  /// Applies an edited profile to a live session without reconnecting: new
  /// tunnels appear (and auto-start), removed ones are torn down, and edited
  /// ones restart if they were running.
  Future<void> syncConfig({
    required String sessionId,
    required String sessionName,
    required List<SshTunnel> tunnels,
  }) async {
    final bucket = _sessions[sessionId];
    if (bucket == null) return;
    bucket.sessionName = sessionName;

    final before = {
      for (final rt in bucket.tunnels) rt.config.id: rt.config,
    };
    final restart = <String>[];
    for (final t in tunnels) {
      final old = before[t.id];
      if (old != null && old.toSpec() != t.toSpec()) restart.add(t.id);
    }

    _reconcile(bucket, tunnels);
    notifyListeners();

    if (bucket.client == null) return;
    for (final rt in List<TunnelRuntime>.from(bucket.tunnels)) {
      final changed = restart.contains(rt.config.id);
      if (changed && rt.isUp) {
        await stop(sessionId, rt.config.id, userInitiated: false);
        await start(sessionId, rt.config.id);
      } else if (!before.containsKey(rt.config.id) && rt.config.autoStart) {
        await start(sessionId, rt.config.id);
      }
    }
  }

  /// Adds/updates/removes runtimes so they mirror [tunnels], preserving live
  /// state for ids that survive.
  void _reconcile(_SessionTunnels bucket, List<SshTunnel> tunnels) {
    final keep = tunnels.map((t) => t.id).toSet();
    for (final rt in List<TunnelRuntime>.from(bucket.tunnels)) {
      if (!keep.contains(rt.config.id)) {
        _teardown(rt);
        bucket.tunnels.remove(rt);
      }
    }
    for (final t in tunnels) {
      final existing = find(bucket.sessionId, t.id);
      if (existing == null) {
        bucket.tunnels.add(TunnelRuntime(t));
      } else {
        existing.config = t;
        // The edit may have changed the inactivity timeout.
        if (existing.isUp) _armIdleTimer(bucket, existing);
      }
    }
  }

  /// The SSH connection dropped: everything stops, but tunnels that were up
  /// keep [TunnelRuntime.desired] so the reconnect restores them.
  void onSessionLost(String sessionId) {
    final bucket = _sessions[sessionId];
    if (bucket == null) return;
    bucket.client = null;
    for (final rt in bucket.tunnels) {
      if (rt.isUp || rt.isBusy) {
        _teardown(rt);
        rt.state = TunnelState.stopped;
        rt.error = null;
        rt.errorDetail = null;
      }
    }
    notifyListeners();
  }

  /// The session is gone for good (tab closed / app shutting down).
  void removeSession(String sessionId) {
    final bucket = _sessions.remove(sessionId);
    if (bucket == null) return;
    for (final rt in bucket.tunnels) {
      _teardown(rt);
    }
    notifyListeners();
  }

  void renameSession(String sessionId, String name) {
    final bucket = _sessions[sessionId];
    if (bucket == null || bucket.sessionName == name) return;
    bucket.sessionName = name;
    notifyListeners();
  }

  // ---- start / stop --------------------------------------------------------

  Future<void> start(String sessionId, String tunnelId) async {
    final bucket = _sessions[sessionId];
    final rt = find(sessionId, tunnelId);
    if (bucket == null || rt == null) return;
    // Re-entrancy guard: a reconnect and the on-resume sweep can both land here.
    if (rt.isUp || rt.isBusy) return;

    rt.desired = true;

    final client = bucket.client;
    if (client == null || client.isClosed) {
      _fail(rt, tr('La sesión SSH no está conectada. El túnel se abrirá al reconectar.'));
      return;
    }

    final invalid = rt.config.validate();
    if (invalid != null) {
      _fail(rt, invalid);
      return;
    }

    rt.state = TunnelState.starting;
    rt.error = null;
    rt.errorDetail = null;
    notifyListeners();

    try {
      switch (rt.config.kind) {
        case TunnelKind.local:
          await _startLocal(bucket, rt, client);
        case TunnelKind.dynamicSocks:
          await _startDynamic(bucket, rt, client);
        case TunnelKind.remote:
          await _startRemote(bucket, rt, client);
      }
    } catch (e) {
      _teardown(rt);
      _fail(rt, _humanError(e, rt.config), detail: '$e');
      bucket.log?.call(tr('No se pudo abrir el túnel {0}: {1}', [rt.config.toSpec(), rt.error]));
      return;
    }

    rt.state = TunnelState.active;
    rt.startedAt = DateTime.now();
    rt.stoppedForIdle = false;
    _armIdleTimer(bucket, rt);
    notifyListeners();
    bucket.log?.call(tr('Túnel activo: {0}', [rt.config.describe(boundPort: rt.boundPort)]));
  }

  Future<void> stop(String sessionId, String tunnelId,
      {bool userInitiated = true}) async {
    final rt = find(sessionId, tunnelId);
    if (rt == null) return;
    if (userInitiated) rt.desired = false;
    _teardown(rt);
    rt.state = TunnelState.stopped;
    rt.stoppedForIdle = false;
    rt.error = null;
    rt.errorDetail = null;
    notifyListeners();
  }

  Future<void> restart(String sessionId, String tunnelId) async {
    await stop(sessionId, tunnelId, userInitiated: false);
    await start(sessionId, tunnelId);
  }

  Future<void> stopAll(String sessionId) async {
    final bucket = _sessions[sessionId];
    if (bucket == null) return;
    for (final rt in bucket.tunnels) {
      _teardown(rt);
      rt.desired = false;
      rt.state = TunnelState.stopped;
    }
    notifyListeners();
  }

  // ---- per-kind startup ----------------------------------------------------

  /// `ssh -L`: we own the listening socket; each accepted connection opens its
  /// own SSH channel.
  Future<void> _startLocal(
      _SessionTunnels bucket, TunnelRuntime rt, SSHClient client) async {
    final server = await ServerSocket.bind(
      rt.config.exposeToLan
          ? InternetAddress.anyIPv4
          : InternetAddress.loopbackIPv4,
      rt.config.listenPort,
    );
    rt._server = server;
    rt.boundPort = server.port;

    rt._acceptSub = server.listen(
      (socket) => _acceptLocal(bucket, rt, socket),
      onError: (Object e) {
        _teardown(rt);
        _fail(rt, _humanError(e, rt.config), detail: '$e');
      },
      cancelOnError: true,
    );
  }

  Future<void> _acceptLocal(
      _SessionTunnels bucket, TunnelRuntime rt, Socket socket) async {
    final client = bucket.client;
    if (client == null || client.isClosed) {
      socket.destroy();
      return;
    }
    SSHForwardChannel channel;
    try {
      channel = await client.forwardLocal(rt.config.destHost, rt.config.destPort);
    } catch (e) {
      // One rejected connection must not take the tunnel down: the service on
      // the far side may simply be down right now.
      socket.destroy();
      rt.error = _humanError(e, rt.config);
      rt.errorDetail = '$e';
      _notifySoon();
      return;
    }
    _bridge(rt, socket, channel);
  }

  /// `ssh -D`: dartssh2 implements the whole SOCKS5 server, including its own
  /// bind, handshake timeouts and connection cap.
  Future<void> _startDynamic(
      _SessionTunnels bucket, TunnelRuntime rt, SSHClient client) async {
    final forward = await client.forwardDynamic(
      bindHost: rt.config.exposeToLan ? '0.0.0.0' : '127.0.0.1',
      bindPort: rt.config.listenPort,
    );
    rt._dynamic = forward;
    rt.boundPort = forward.port;
  }

  /// `ssh -R`: the server listens and hands us a channel per inbound
  /// connection, which we splice to a socket on this device.
  Future<void> _startRemote(
      _SessionTunnels bucket, TunnelRuntime rt, SSHClient client) async {
    final forward = await client.forwardRemote(
      host: '',
      port: rt.config.listenPort,
    );
    if (forward == null) {
      throw _TunnelRejected(rt.config.listenPort);
    }
    rt._remote = forward;
    rt.boundPort = forward.port;

    // `connections` is single-subscription — listen exactly once per forward.
    rt._remoteSub = forward.connections.listen(
      (channel) => _acceptRemote(rt, channel),
      onError: (Object e) {
        rt.error = _humanError(e, rt.config);
        rt.errorDetail = '$e';
        _notifySoon();
      },
    );
  }

  Future<void> _acceptRemote(TunnelRuntime rt, SSHForwardChannel channel) async {
    Socket socket;
    try {
      socket = await Socket.connect(
        rt.config.destHost,
        rt.config.destPort,
        timeout: const Duration(seconds: 10),
      );
    } catch (e) {
      channel.destroy();
      rt.error = tr('No se pudo conectar con {0}:{1} en este dispositivo. ¿Está el servicio levantado?', [rt.config.destHost, rt.config.destPort]);
      rt.errorDetail = '$e';
      _notifySoon();
      return;
    }
    _bridge(rt, socket, channel);
  }

  // ---- idle shutdown -------------------------------------------------------

  /// Starts (or restarts) the inactivity countdown for a tunnel.
  ///
  /// The clock only runs while the tunnel has **no open connections**, so a
  /// database client or a long download is never cut mid-flight: every new
  /// connection cancels the timer and closing the last one starts it again.
  /// Disabled for SOCKS, where we can't see the connections.
  void _armIdleTimer(_SessionTunnels bucket, TunnelRuntime rt) {
    rt._idleTimer?.cancel();
    rt._idleTimer = null;
    rt.idleDeadline = null;

    final minutes = rt.config.idleTimeoutMinutes;
    if (minutes <= 0) return;
    if (rt.config.kind == TunnelKind.dynamicSocks) return;
    if (!rt.isUp || rt.liveConnections > 0) return;

    final delay = Duration(minutes: minutes);
    rt.idleDeadline = DateTime.now().add(delay);
    rt._idleTimer = Timer(delay, () {
      // Re-check: a connection may have arrived while the timer was pending.
      if (!rt.isUp || rt.liveConnections > 0) {
        _armIdleTimer(bucket, rt);
        return;
      }
      _teardown(rt);
      rt.state = TunnelState.stopped;
      rt.stoppedForIdle = true;
      // Keep `desired` so a reconnect (or the next autoStart) brings it back —
      // this is a hygiene measure, not the user cancelling the tunnel.
      notifyListeners();
      bucket.log?.call(
          tr('Túnel cerrado por inactividad ({0} min): {1}', [minutes, rt.config.toSpec()]));
    });
  }

  /// Called whenever a tunnel's connection count changes.
  void _onConnectionCountChanged(TunnelRuntime rt) {
    final bucket = _bucketOf(rt);
    if (bucket == null) return;
    if (rt.liveConnections > 0) {
      rt._idleTimer?.cancel();
      rt._idleTimer = null;
      rt.idleDeadline = null;
    } else {
      _armIdleTimer(bucket, rt);
    }
  }

  _SessionTunnels? _bucketOf(TunnelRuntime rt) {
    for (final bucket in _sessions.values) {
      if (bucket.tunnels.contains(rt)) return bucket;
    }
    return null;
  }

  // ---- plumbing ------------------------------------------------------------

  /// Splices a device socket and an SSH channel in both directions.
  ///
  /// Written by hand rather than with `pipe()` so that: errors on either side
  /// are handled instead of escaping as unhandled async errors, bytes can be
  /// counted for the UI, the pair is torn down exactly once, and the reader is
  /// paused while the writer flushes (backpressure — otherwise a fast download
  /// buffers the whole file in RAM).
  void _bridge(TunnelRuntime rt, Socket socket, SSHForwardChannel channel) {
    final bridge = _Bridge(socket, channel);
    rt._bridges.add(bridge);
    rt.liveConnections++;
    rt.totalConnections++;
    _onConnectionCountChanged(rt);
    notifyListeners();

    // Hard teardown: only on error or when both directions are finished.
    void abort() {
      if (bridge.closed) return;
      bridge.closed = true;
      rt._bridges.remove(bridge);
      rt.liveConnections = rt.liveConnections > 0 ? rt.liveConnections - 1 : 0;
      _onConnectionCountChanged(rt);
      bridge.socketSub?.cancel();
      bridge.channelSub?.cancel();
      try {
        socket.destroy();
      } catch (_) {}
      try {
        channel.destroy();
      } catch (_) {}
      _notifySoon();
    }

    // EOF from one side must *not* destroy the other: the reply may still be
    // in flight. Half-close it instead (which flushes) and wait for its own
    // EOF — this is what `ssh` does, and skipping it silently truncated the
    // last response of every connection.
    void onSocketDone() {
      bridge.socketDone = true;
      if (bridge.channelDone) {
        abort();
        return;
      }
      channel.close().catchError((_) {});
    }

    void onChannelDone() {
      bridge.channelDone = true;
      if (bridge.socketDone) {
        abort();
        return;
      }
      // Socket.close() is a half-close: it flushes and shuts the write side
      // while still reading.
      socket.close().catchError((_) => socket);
    }

    socket.setOption(SocketOption.tcpNoDelay, true);

    bridge.socketSub = socket.listen(
      (data) {
        rt.bytesUp += data.length;
        try {
          channel.sink.add(data);
        } catch (_) {
          abort();
        }
        _notifySoon();
      },
      onError: (_) => abort(),
      onDone: onSocketDone,
      cancelOnError: true,
    );

    bridge.channelSub = channel.stream.listen(
      (data) {
        rt.bytesDown += data.length;
        try {
          socket.add(data);
        } catch (_) {
          abort();
          return;
        }
        // Backpressure: stop reading from the tunnel until the device socket
        // has drained.
        final sub = bridge.channelSub;
        if (sub != null) {
          sub.pause();
          socket.flush().then(
            (_) {
              if (!bridge.closed) sub.resume();
            },
            onError: (_) => abort(),
          );
        }
        _notifySoon();
      },
      onError: (_) => abort(),
      onDone: onChannelDone,
      cancelOnError: true,
    );
  }

  /// Releases every resource a tunnel holds. Order matters: stop accepting
  /// first, then kill the connections already in flight — closing a
  /// `ServerSocket` does not touch sockets it already handed out.
  void _teardown(TunnelRuntime rt) {
    rt._idleTimer?.cancel();
    rt._idleTimer = null;
    rt.idleDeadline = null;
    rt._acceptSub?.cancel();
    rt._acceptSub = null;
    final server = rt._server;
    rt._server = null;
    server?.close().then((_) {}, onError: (_) {});

    rt._remoteSub?.cancel();
    rt._remoteSub = null;
    rt._remote?.close(); // synchronous; also sends cancel-tcpip-forward
    rt._remote = null;

    final dyn = rt._dynamic;
    rt._dynamic = null;
    dyn?.close().catchError((_) {});

    for (final bridge in List<_Bridge>.from(rt._bridges)) {
      bridge.closed = true;
      bridge.socketSub?.cancel();
      bridge.channelSub?.cancel();
      try {
        bridge.socket.destroy();
      } catch (_) {}
      try {
        bridge.channel.destroy();
      } catch (_) {}
    }
    rt._bridges.clear();
    rt.liveConnections = 0;
    rt.boundPort = null;
    rt.startedAt = null;
  }

  void _fail(TunnelRuntime rt, String message, {String? detail}) {
    rt.state = TunnelState.failed;
    rt.error = message;
    rt.errorDetail = detail;
    notifyListeners();
  }

  /// Turns socket/SSH errors into something a person can act on. The raw text
  /// is kept in `errorDetail` for debugging.
  String _humanError(Object e, SshTunnel tunnel) {
    if (e is _TunnelRejected) {
      return tr('El servidor rechazó abrir el puerto {0}. Suele faltar `GatewayPorts yes` en su sshd_config, o el puerto ya está en uso allí.', [e.port]);
    }
    if (e is SocketException) {
      final code = e.osError?.errorCode;
      final text =
          '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
      // The "shared flag" wording is what Dart reports when *this same app*
      // already holds the port — i.e. two tunnels configured on the same port.
      if (code == 98 ||
          code == 48 ||
          text.contains('address already in use') ||
          text.contains('shared flag')) {
        return tr('El puerto {0} ya está ocupado en este dispositivo. Elige otro.', [tunnel.listenPort]);
      }
      if (code == 13 || code == 1 || text.contains('permission denied')) {
        return tr('Android no permite abrir el puerto {0}. Usa uno mayor que 1024.', [tunnel.listenPort]);
      }
      if (code == 99 || text.contains('cannot assign requested address')) {
        return tr('No se pudo enlazar la dirección local. Prueba sin exponer el túnel a la red.');
      }
      return tr('No se pudo abrir el puerto {0}: {1}', [tunnel.listenPort, e.osError?.message ?? e.message]);
    }
    final text = '$e';
    if (text.contains('SSHChannelOpenError') ||
        text.toLowerCase().contains('administratively prohibited') ||
        text.toLowerCase().contains('connect failed')) {
      return tr('El servidor no dejó conectar con {0}:{1}. ¿Está el servicio levantado y permitido el forwarding?', [tunnel.destHost, tunnel.destPort]);
    }
    if (text.contains('SSHStateError') || text.contains('closed')) {
      return tr('La sesión SSH se cerró. El túnel volverá al reconectar.');
    }
    return text;
  }

  // ---- notification throttle ----------------------------------------------

  /// Byte counters change thousands of times per second; coalesce those into
  /// at most one rebuild every 500 ms. State transitions still notify directly.
  void _notifySoon() {
    if (_disposed || _throttle != null) return;
    _throttle = Timer(const Duration(milliseconds: 500), () {
      _throttle = null;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _throttle?.cancel();
    for (final bucket in _sessions.values) {
      for (final rt in bucket.tunnels) {
        _teardown(rt);
      }
    }
    _sessions.clear();
    super.dispose();
  }
}

/// The server answered SSH_MSG_REQUEST_FAILURE to a remote-forward request.
class _TunnelRejected implements Exception {
  final int port;
  const _TunnelRejected(this.port);
  @override
  String toString() => tr('El servidor rechazó el puerto remoto {0}', [port]);
}
