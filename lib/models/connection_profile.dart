import 'dart:convert';

import 'ssh_tunnel.dart';

/// Legacy shape of a local port-forward (`ssh -L bindPort:remoteHost:remotePort`)
/// as persisted by app versions before [SshTunnel] existed.
///
/// Kept only so old profiles keep working: [ConnectionProfile.fromMap] migrates
/// these into [SshTunnel]s, and [ConnectionProfile.toMap] keeps writing them so
/// downgrading the app doesn't silently lose the user's tunnels.
class PortForward {
  final int bindPort;
  final String remoteHost;
  final int remotePort;

  PortForward({
    required this.bindPort,
    required this.remoteHost,
    required this.remotePort,
  });

  Map<String, dynamic> toMap() => {
        'bindPort': bindPort,
        'remoteHost': remoteHost,
        'remotePort': remotePort,
      };

  factory PortForward.fromMap(Map<String, dynamic> map) => PortForward(
        bindPort: map['bindPort'] ?? 0,
        remoteHost: map['remoteHost'] ?? 'localhost',
        remotePort: map['remotePort'] ?? 0,
      );

  /// Parses a single `-L` argument value. Accepts both
  /// `bindPort:remoteHost:remotePort` and
  /// `bindAddress:bindPort:remoteHost:remotePort` (the bind address is ignored,
  /// we always bind to localhost on the device).
  static PortForward? parseSpec(String spec) {
    final parts = spec.split(':');
    List<String> p;
    if (parts.length == 3) {
      p = parts;
    } else if (parts.length == 4) {
      p = parts.sublist(1); // drop bind address
    } else {
      return null;
    }
    final bindPort = int.tryParse(p[0]);
    final remotePort = int.tryParse(p[2]);
    if (bindPort == null || remotePort == null || p[1].isEmpty) return null;
    return PortForward(
      bindPort: bindPort,
      remoteHost: p[1],
      remotePort: remotePort,
    );
  }

  /// Renders this forward back as an `-L` spec for display.
  String toSpec() => '$bindPort:$remoteHost:$remotePort';
}

class ConnectionProfile {
  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final String? password;
  final String? privateKey;
  final bool isLocal;
  final String? groupId;

  /// Port forwards (`-L`/`-D`/`-R`) declared on this profile. Started by
  /// `TunnelManager` when a session using this profile connects.
  final List<SshTunnel> tunnels;

  /// Wrap the remote shell in `tmux new-session -A` so the session (and any
  /// agent running inside) survives network drops; reconnecting re-attaches.
  final bool useTmux;

  /// Authenticate with the phone's own ed25519 key (see DeviceKey) in addition
  /// to any per-profile key/password. Requires the device public key in the
  /// server's `authorized_keys`.
  final bool useDeviceKey;

  /// Signal color for this machine, as `#RRGGBB` (see `AppColors.parseHex`), or
  /// null for none. It is *identity*, not decoration: every surface that shows
  /// which host a session belongs to paints this stripe, so four black-on-black
  /// terminals stop being indistinguishable.
  final String? colorHex;

  /// Marks the machine as production. Beyond the badge, it is what gives a
  /// profile a tint when the user never picked one (see `profileTint`).
  final bool isProduction;

  /// Id of the profile to tunnel through to reach this one — OpenSSH's
  /// `ProxyJump` / `ssh -J`. Null connects directly.
  ///
  /// A *reference*, not a copy of the bastion's host/user/key: the jump host is
  /// a machine the user already has a profile for, with its own credentials and
  /// its own pinned host key, and inlining that into every profile behind it
  /// means editing ten profiles the day the bastion moves. Resolution, cycle
  /// detection and depth limits live in `JumpChain`.
  final String? jumpProfileId;

  ConnectionProfile({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    this.password,
    this.privateKey,
    this.isLocal = false,
    this.groupId,
    this.tunnels = const [],
    this.useTmux = false,
    this.useDeviceKey = false,
    this.colorHex,
    this.isProduction = false,
    this.jumpProfileId,
  });

  /// tmux session name used when [useTmux] is on: a slug of the profile name
  /// (single-quote-safe, since it's interpolated into the remote command),
  /// prefixed so it's recognizable in `tmux ls`.
  String get tmuxSessionName {
    var slug = name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    if (slug.isEmpty) slug = id.length >= 8 ? id.substring(0, 8) : id;
    return 'kammel-$slug';
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'host': host,
      'port': port,
      'username': username,
      'password': password,
      'privateKey': privateKey,
      'isLocal': isLocal,
      'groupId': groupId,
      'tunnels': tunnels.map((t) => t.toMap()).toList(),
      // Legacy mirror of the local tunnels, so an older build (or a downgrade)
      // still finds its `-L` forwards where it expects them.
      'forwards': tunnels
          .where((t) => t.kind == TunnelKind.local)
          .map((t) => PortForward(
                bindPort: t.listenPort,
                remoteHost: t.destHost,
                remotePort: t.destPort,
              ).toMap())
          .toList(),
      'useTmux': useTmux,
      'useDeviceKey': useDeviceKey,
      'colorHex': colorHex,
      'isProduction': isProduction,
      'jumpProfileId': jumpProfileId,
    };
  }

  /// Same as [toMap] but without secrets ([password]/[privateKey]). Used to
  /// persist profile metadata to plain shared_preferences while the secrets are
  /// kept in secure storage.
  Map<String, dynamic> toMapPublic() {
    final map = toMap();
    map.remove('password');
    map.remove('privateKey');
    return map;
  }

  String toJsonPublic() => json.encode(toMapPublic());

  /// [clearGroupId] is what moves a profile *out* of every group: a null
  /// `groupId` argument can only ever mean "keep what it had", so without an
  /// explicit flag there is no way to express "ungrouped". [clearColor] and
  /// [clearJump] are the same trick for the signal color and the jump host.
  ConnectionProfile copyWith({
    String? name,
    String? host,
    int? port,
    String? username,
    String? password,
    String? privateKey,
    List<SshTunnel>? tunnels,
    String? groupId,
    bool clearGroupId = false,
    bool? useTmux,
    bool? useDeviceKey,
    String? colorHex,
    bool clearColor = false,
    bool? isProduction,
    String? jumpProfileId,
    bool clearJump = false,
  }) {
    return ConnectionProfile(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      password: password ?? this.password,
      privateKey: privateKey ?? this.privateKey,
      isLocal: isLocal,
      groupId: clearGroupId ? null : (groupId ?? this.groupId),
      tunnels: tunnels ?? this.tunnels,
      useTmux: useTmux ?? this.useTmux,
      useDeviceKey: useDeviceKey ?? this.useDeviceKey,
      colorHex: clearColor ? null : (colorHex ?? this.colorHex),
      isProduction: isProduction ?? this.isProduction,
      jumpProfileId:
          clearJump ? null : (jumpProfileId ?? this.jumpProfileId),
    );
  }

  factory ConnectionProfile.fromMap(Map<String, dynamic> map) {
    return ConnectionProfile(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      host: map['host'] ?? '',
      port: map['port'] ?? 22,
      username: map['username'] ?? '',
      password: map['password'],
      privateKey: map['privateKey'],
      isLocal: map['isLocal'] ?? false,
      groupId: map['groupId'],
      tunnels: _tunnelsFromMap(map),
      useTmux: map['useTmux'] ?? false,
      useDeviceKey: map['useDeviceKey'] ?? false,
      colorHex: (map['colorHex'] as String?)?.trim().isEmpty ?? true
          ? null
          : (map['colorHex'] as String).trim(),
      isProduction: map['isProduction'] ?? false,
      jumpProfileId: (map['jumpProfileId'] as String?)?.trim().isEmpty ?? true
          ? null
          : (map['jumpProfileId'] as String).trim(),
    );
  }

  /// Reads the tunnel list, falling back to the pre-[SshTunnel] `forwards` key
  /// so profiles saved by older builds keep their `-L` tunnels.
  static List<SshTunnel> _tunnelsFromMap(Map<String, dynamic> map) {
    final raw = map['tunnels'] as List?;
    if (raw != null) {
      return raw
          .map((e) => SshTunnel.fromMap(Map<String, dynamic>.from(e)))
          .toList();
    }
    final legacy = map['forwards'] as List?;
    if (legacy == null) return const [];
    return legacy
        .map((e) => PortForward.fromMap(Map<String, dynamic>.from(e)))
        .map((f) => SshTunnel(
              kind: TunnelKind.local,
              listenPort: f.bindPort,
              destHost: f.remoteHost,
              destPort: f.remotePort,
            ))
        .toList();
  }

  String toJson() => json.encode(toMap());

  factory ConnectionProfile.fromJson(String source) =>
      ConnectionProfile.fromMap(json.decode(source));

  /// Result of parsing a raw `ssh ...` command line. Any field that could not
  /// be parsed is left null so the caller can keep an existing value.
  static ParsedSshCommand? parseCommand(String input) {
    var cmd = input.trim();
    if (cmd.isEmpty) return null;
    // Tolerate a leading "ssh".
    if (cmd == 'ssh') return null;
    final tokens = cmd.split(RegExp(r'\s+'));
    if (tokens.isNotEmpty && tokens.first == 'ssh') {
      tokens.removeAt(0);
    }

    String? host;
    String? username;
    int? port;
    final tunnels = <SshTunnel>[];

    for (var i = 0; i < tokens.length; i++) {
      final t = tokens[i];
      if (t.isEmpty) continue;

      // Flags that take a value (either "-L val" or "-Lval").
      String? takeValue(String flag) {
        if (t == flag) {
          if (i + 1 < tokens.length) return tokens[++i];
          return null;
        }
        if (t.startsWith(flag)) return t.substring(flag.length);
        return null;
      }

      // Tunnel flags: the value is parsed by SshTunnel so `-L`, `-D` and `-R`
      // all land in the profile's tunnel list.
      var matchedTunnelFlag = false;
      for (final kind in TunnelKind.values) {
        if (!t.startsWith(kind.flag)) continue;
        matchedTunnelFlag = true;
        final v = takeValue(kind.flag);
        if (v != null) {
          final tunnel = SshTunnel.parseSpec('${kind.flag} $v');
          if (tunnel != null) tunnels.add(tunnel);
        }
        break;
      }
      if (matchedTunnelFlag) continue;

      if (t == '-p' || t.startsWith('-p')) {
        final v = takeValue('-p');
        if (v != null) port = int.tryParse(v);
        continue;
      }
      // Skip other value-taking flags so their argument isn't read as host.
      if (t == '-i' || t == '-o' || t == '-J') {
        i++; // consume the following value
        continue;
      }
      if (t.startsWith('-')) continue; // unknown flag, ignore

      // First non-flag token is the destination (user@host).
      if (host == null) {
        if (t.contains('@')) {
          final at = t.split('@');
          username = at[0];
          host = at.sublist(1).join('@');
        } else {
          host = t;
        }
      }
    }

    if (host == null || host.isEmpty) return null;
    return ParsedSshCommand(
      host: host,
      username: username,
      port: port,
      tunnels: tunnels,
    );
  }
}

class ParsedSshCommand {
  final String host;
  final String? username;
  final int? port;
  final List<SshTunnel> tunnels;

  ParsedSshCommand({
    required this.host,
    this.username,
    this.port,
    this.tunnels = const [],
  });
}
