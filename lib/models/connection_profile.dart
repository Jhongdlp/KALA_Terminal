import 'dart:convert';

/// A local port-forward, equivalent to `ssh -L bindPort:remoteHost:remotePort`.
/// Connections to `localhost:bindPort` on the device are tunneled through the
/// SSH connection to `remoteHost:remotePort` (as seen from the server).
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
  final List<PortForward> forwards;

  ConnectionProfile({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    this.password,
    this.privateKey,
    this.isLocal = false,
    this.forwards = const [],
  });

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
      'forwards': forwards.map((f) => f.toMap()).toList(),
    };
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
      forwards: (map['forwards'] as List?)
              ?.map((e) => PortForward.fromMap(Map<String, dynamic>.from(e)))
              .toList() ??
          const [],
    );
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
    final forwards = <PortForward>[];

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

      if (t == '-L' || t.startsWith('-L')) {
        final v = takeValue('-L');
        if (v != null) {
          final pf = PortForward.parseSpec(v);
          if (pf != null) forwards.add(pf);
        }
        continue;
      }
      if (t == '-p' || t.startsWith('-p')) {
        final v = takeValue('-p');
        if (v != null) port = int.tryParse(v);
        continue;
      }
      // Skip other value-taking flags so their argument isn't read as host.
      if (t == '-i' || t == '-o' || t == '-D' || t == '-R' || t == '-J') {
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
      forwards: forwards,
    );
  }
}

class ParsedSshCommand {
  final String host;
  final String? username;
  final int? port;
  final List<PortForward> forwards;

  ParsedSshCommand({
    required this.host,
    this.username,
    this.port,
    this.forwards = const [],
  });
}
