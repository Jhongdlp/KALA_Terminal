import 'package:uuid/uuid.dart';

/// The three kinds of SSH port forwarding, mirroring OpenSSH's flags.
enum TunnelKind {
  /// `ssh -L` — a port on the phone is forwarded to `destHost:destPort` as
  /// resolved *from the server*. Brings a remote service to the device.
  local,

  /// `ssh -D` — a SOCKS5 proxy on the phone; every CONNECT goes out through
  /// the server. Turns the server into a proxy.
  dynamicSocks,

  /// `ssh -R` — a port on the *server* is forwarded back to
  /// `destHost:destPort` as resolved from the phone. Publishes something
  /// running on the device.
  remote,
}

extension TunnelKindInfo on TunnelKind {
  /// The OpenSSH flag, used both for display and for [SshTunnel.parseSpec].
  String get flag => switch (this) {
        TunnelKind.local => '-L',
        TunnelKind.dynamicSocks => '-D',
        TunnelKind.remote => '-R',
      };

  String get title => switch (this) {
        TunnelKind.local => 'LOCAL',
        TunnelKind.dynamicSocks => 'SOCKS',
        TunnelKind.remote => 'REMOTO',
      };

  /// One-line explanation shown in the tunnel editor.
  String get blurb => switch (this) {
        TunnelKind.local =>
          'Trae un servicio del servidor a este teléfono. Abres localhost:PUERTO '
              'aquí y llegas a un servicio que sólo existe allí.',
        TunnelKind.dynamicSocks =>
          'Convierte el servidor en un proxy SOCKS5. Las apps que apunten a '
              'localhost:PUERTO saldrán a internet desde el servidor.',
        TunnelKind.remote =>
          'Publica algo de este teléfono en el servidor. Quien entre al puerto '
              'del servidor llega a un servicio que corre aquí.',
      };

  /// Whether this kind opens the listening socket on the device (vs. on the
  /// server). Decides which security warnings and port limits apply.
  bool get listensOnDevice => this != TunnelKind.remote;

  /// Whether a destination host/port is meaningful (SOCKS picks it per
  /// connection, so it has none).
  bool get hasDestination => this != TunnelKind.dynamicSocks;
}

/// A single port-forward declared on a [ConnectionProfile].
///
/// This is pure configuration — the live state of a tunnel (bound port, byte
/// counters, errors) lives in `TunnelRuntime` in `services/tunnel_manager.dart`,
/// keyed by [id].
class SshTunnel {
  /// Stable across edits: the runtime is keyed by it, so editing a tunnel's
  /// ports doesn't lose its live state.
  final String id;

  /// Optional human name ("Grafana", "Postgres"). Falls back to [toSpec].
  final String label;

  final TunnelKind kind;

  /// Port that gets opened: on the device for [TunnelKind.local] and
  /// [TunnelKind.dynamicSocks], on the server for [TunnelKind.remote] (where 0
  /// means "let the server pick one").
  final int listenPort;

  /// Destination of the forwarded traffic. Resolved from the server for
  /// [TunnelKind.local], from the device for [TunnelKind.remote], unused for
  /// SOCKS.
  final String destHost;
  final int destPort;

  /// Start this tunnel automatically when the profile connects.
  final bool autoStart;

  /// Bind to 0.0.0.0 instead of loopback, making the tunnel reachable by any
  /// device on the same wifi. Off by default — see the warnings in the editor.
  /// Only meaningful when [TunnelKindInfo.listensOnDevice].
  final bool exposeToLan;

  SshTunnel({
    String? id,
    this.label = '',
    required this.kind,
    required this.listenPort,
    this.destHost = 'localhost',
    this.destPort = 0,
    this.autoStart = true,
    this.exposeToLan = false,
  }) : id = id ?? const Uuid().v4();

  SshTunnel copyWith({
    String? label,
    TunnelKind? kind,
    int? listenPort,
    String? destHost,
    int? destPort,
    bool? autoStart,
    bool? exposeToLan,
  }) {
    return SshTunnel(
      id: id,
      label: label ?? this.label,
      kind: kind ?? this.kind,
      listenPort: listenPort ?? this.listenPort,
      destHost: destHost ?? this.destHost,
      destPort: destPort ?? this.destPort,
      autoStart: autoStart ?? this.autoStart,
      exposeToLan: exposeToLan ?? this.exposeToLan,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'label': label,
        'kind': kind.name,
        'listenPort': listenPort,
        'destHost': destHost,
        'destPort': destPort,
        'autoStart': autoStart,
        'exposeToLan': exposeToLan,
      };

  factory SshTunnel.fromMap(Map<String, dynamic> map) {
    return SshTunnel(
      id: map['id'] as String?,
      label: map['label'] ?? '',
      kind: TunnelKind.values.firstWhere(
        (k) => k.name == map['kind'],
        orElse: () => TunnelKind.local,
      ),
      listenPort: map['listenPort'] ?? 0,
      destHost: map['destHost'] ?? 'localhost',
      destPort: map['destPort'] ?? 0,
      autoStart: map['autoStart'] ?? true,
      exposeToLan: map['exposeToLan'] ?? false,
    );
  }

  /// The equivalent OpenSSH argument, e.g. `-L 8080:127.0.0.1:8080`. Shown live
  /// in the editor so anyone who already knows `ssh` recognizes what they built.
  String toSpec() {
    final bind = exposeToLan && kind.listensOnDevice ? '*:' : '';
    return switch (kind) {
      TunnelKind.local => '-L $bind$listenPort:$destHost:$destPort',
      TunnelKind.dynamicSocks => '-D $bind$listenPort',
      TunnelKind.remote => '-R $listenPort:$destHost:$destPort',
    };
  }

  /// Short "from → to" line for list rows.
  String describe({int? boundPort}) {
    final port = boundPort ?? listenPort;
    final iface = exposeToLan && kind.listensOnDevice ? '0.0.0.0' : 'localhost';
    return switch (kind) {
      TunnelKind.local => '$iface:$port  →  $destHost:$destPort',
      TunnelKind.dynamicSocks => 'proxy SOCKS5 en $iface:$port',
      TunnelKind.remote => 'servidor:$port  →  $destHost:$destPort',
    };
  }

  /// Parses an OpenSSH-style spec. Accepts the flag form (`-L 8080:host:80`,
  /// `-D 1080`, `-R 8080:localhost:3000`, and the glued `-L8080:host:80`) as
  /// well as a bare `-L` spec without the flag, which is what the old tunnel
  /// field in the profile sheet accepted.
  static SshTunnel? parseSpec(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;

    var kind = TunnelKind.local;
    var explicitFlag = false;
    for (final k in TunnelKind.values) {
      if (text == k.flag) return null; // flag with no value
      if (text.startsWith('${k.flag} ') || text.startsWith(k.flag)) {
        kind = k;
        explicitFlag = true;
        text = text.substring(k.flag.length).trim();
        break;
      }
    }
    if (text.isEmpty) return null;

    if (kind == TunnelKind.dynamicSocks) {
      final parts = text.split(':');
      // Both `1080` and `localhost:1080` are valid -D values.
      final port = int.tryParse(parts.last);
      if (port == null) return null;
      return SshTunnel(
        kind: TunnelKind.dynamicSocks,
        listenPort: port,
        destPort: 0,
        exposeToLan: parts.length > 1 && _isWildcardBind(parts.first),
      );
    }

    final parts = text.split(':');
    List<String> p;
    var wildcard = false;
    if (parts.length == 3) {
      p = parts;
    } else if (parts.length == 4) {
      // Leading bind address: we only keep whether it asks for all interfaces.
      wildcard = _isWildcardBind(parts.first);
      p = parts.sublist(1);
    } else {
      return null;
    }

    final listenPort = int.tryParse(p[0]);
    final destPort = int.tryParse(p[2]);
    if (listenPort == null || destPort == null || p[1].isEmpty) return null;

    return SshTunnel(
      kind: explicitFlag ? kind : TunnelKind.local,
      listenPort: listenPort,
      destHost: p[1],
      destPort: destPort,
      exposeToLan: wildcard && kind.listensOnDevice,
    );
  }

  static bool _isWildcardBind(String bind) =>
      bind == '*' || bind == '0.0.0.0' || bind == '::' || bind.isEmpty;

  /// Returns a user-facing reason why this tunnel can't work, or null if it's
  /// valid. Checked before touching the network so the user gets a real message
  /// instead of an errno.
  String? validate() {
    if (kind == TunnelKind.remote) {
      // 0 = "let the server choose a port", which OpenSSH also allows.
      if (listenPort < 0 || listenPort > 65535) {
        return 'El puerto remoto debe estar entre 1 y 65535 (o 0 para que lo '
            'elija el servidor).';
      }
    } else {
      if (listenPort < 1 || listenPort > 65535) {
        return 'El puerto debe estar entre 1 y 65535.';
      }
      if (listenPort < 1024) {
        return 'Android no permite abrir puertos por debajo de 1024. Usa uno '
            'más alto, por ejemplo 1080, 3000 u 8080.';
      }
    }

    if (kind.hasDestination) {
      if (destHost.trim().isEmpty) {
        return 'Falta el host de destino.';
      }
      if (destPort < 1 || destPort > 65535) {
        return 'El puerto de destino debe estar entre 1 y 65535.';
      }
    }
    return null;
  }

  /// True when a local tunnel plausibly points at something a browser can open.
  bool get looksLikeHttp =>
      kind == TunnelKind.local &&
      const {80, 443, 3000, 5000, 8000, 8006, 8080, 8081, 8096, 8123, 9000, 9090}
          .contains(destPort);
}
