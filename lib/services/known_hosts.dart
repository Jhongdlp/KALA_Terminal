import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Outcome of checking a server's key against what we have stored.
enum HostKeyVerdict {
  /// Never seen this host before — ask the user (trust on first use).
  unknown,

  /// Same key as last time. Connect silently.
  match,

  /// A *different* key than the one pinned. Either the server was rebuilt or
  /// someone is impersonating it. Never silent.
  mismatch,
}

/// What the user is being asked to decide about a server's identity.
class HostKeyChallenge {
  final String profileName;
  final String host;
  final int port;
  final String keyType;
  final String fingerprint;
  final HostKeyVerdict verdict;

  /// The fingerprint we had pinned, when [verdict] is
  /// [HostKeyVerdict.mismatch].
  final String? previousFingerprint;
  final DateTime? previousAddedAt;

  const HostKeyChallenge({
    required this.profileName,
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprint,
    required this.verdict,
    this.previousFingerprint,
    this.previousAddedAt,
  });
}

class KnownHost {
  final String host;
  final int port;
  final String keyType;
  final String fingerprint;
  final DateTime addedAt;

  KnownHost({
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprint,
    required this.addedAt,
  });

  String get id => '$host:$port';

  Map<String, dynamic> toMap() => {
        'host': host,
        'port': port,
        'keyType': keyType,
        'fingerprint': fingerprint,
        'addedAt': addedAt.toIso8601String(),
      };

  factory KnownHost.fromMap(Map<String, dynamic> map) => KnownHost(
        host: map['host'] ?? '',
        port: map['port'] ?? 22,
        keyType: map['keyType'] ?? '',
        fingerprint: map['fingerprint'] ?? '',
        addedAt:
            DateTime.tryParse(map['addedAt'] ?? '') ?? DateTime.now(),
      );
}

/// The app's `~/.ssh/known_hosts`: which key each server presented the first
/// time we talked to it.
///
/// Without this, dartssh2 accepts *any* host key (its `onVerifyHostKey` default
/// is "true"), so anyone able to intercept the connection could impersonate the
/// server and collect the password — and, with tunnels, everything sent through
/// them. Pinning turns that into a loud, blocking warning.
class KnownHosts {
  KnownHosts._();
  static final KnownHosts instance = KnownHosts._();

  static const String _prefsKey = 'known_hosts';

  Map<String, KnownHost>? _cache;

  /// OpenSSH-style fingerprint of a host key blob: `SHA256:<base64 sin padding>`.
  /// Same string `ssh-keyscan`/`ssh-keygen -l` prints, so it can be compared by
  /// eye against the server.
  static String fingerprintOf(Uint8List hostkeyBlob) {
    final digest = sha256.convert(hostkeyBlob).bytes;
    final b64 = base64.encode(digest).replaceAll('=', '');
    return 'SHA256:$b64';
  }

  Future<Map<String, KnownHost>> _load() async {
    if (_cache != null) return _cache!;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefsKey) ?? const [];
    final map = <String, KnownHost>{};
    for (final entry in raw) {
      try {
        final host = KnownHost.fromMap(
            Map<String, dynamic>.from(json.decode(entry)));
        map[host.id] = host;
      } catch (_) {
        // Ignore a corrupt entry rather than losing the whole file.
      }
    }
    _cache = map;
    return map;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _prefsKey,
      (_cache ?? {}).values.map((h) => json.encode(h.toMap())).toList(),
    );
  }

  Future<List<KnownHost>> entries() async {
    final map = await _load();
    final list = map.values.toList()
      ..sort((a, b) => a.host.compareTo(b.host));
    return list;
  }

  Future<KnownHost?> lookup(String host, int port) async =>
      (await _load())['$host:$port'];

  Future<HostKeyVerdict> check(
      String host, int port, String fingerprint) async {
    final known = (await _load())['$host:$port'];
    if (known == null) return HostKeyVerdict.unknown;
    return known.fingerprint == fingerprint
        ? HostKeyVerdict.match
        : HostKeyVerdict.mismatch;
  }

  /// Pins (or re-pins) a host's key.
  Future<void> trust(
      String host, int port, String keyType, String fingerprint) async {
    final map = await _load();
    map['$host:$port'] = KnownHost(
      host: host,
      port: port,
      keyType: keyType,
      fingerprint: fingerprint,
      addedAt: DateTime.now(),
    );
    await _persist();
  }

  Future<void> forget(String host, int port) async {
    final map = await _load();
    map.remove('$host:$port');
    await _persist();
  }

  Future<void> forgetAll() async {
    (await _load()).clear();
    await _persist();
  }
}
