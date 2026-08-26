import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';

import '../models/connection_profile.dart';
import '../models/jump_chain.dart';

/// A host block read out of an OpenSSH `config` file, ready to become a
/// [ConnectionProfile].
class SshConfigHost {
  final String alias;
  final String hostName;
  final String? user;
  final int port;

  /// Path named by `IdentityFile`, kept only to *tell* the user which key the
  /// entry expects. The key itself is never read from disk here.
  final String? identityFile;

  /// Alias named by `ProxyJump`, once it has been checked against the rest of
  /// the file. Always another host in this same config — see [SshConfigImport].
  final String? proxyJump;

  const SshConfigHost({
    required this.alias,
    required this.hostName,
    this.user,
    this.port = 22,
    this.identityFile,
    this.proxyJump,
  });

  ConnectionProfile toProfile() => ConnectionProfile(
        id: const Uuid().v4(),
        name: alias,
        host: hostName,
        port: port,
        username: user ?? '',
        // Nothing here can supply a secret: an imported host authenticates with
        // the device key or with a password the user adds afterwards.
        useDeviceKey: identityFile != null,
      );

  SshConfigHost _withJump(String? jump) => SshConfigHost(
        alias: alias,
        hostName: hostName,
        user: user,
        port: port,
        identityFile: identityFile,
        proxyJump: jump,
      );
}

/// Reads hosts out of an OpenSSH client config.
///
/// Anyone who already uses SSH from a laptop has this file, and retyping thirty
/// hosts into a phone form is exactly the kind of work that stops someone from
/// trying the app at all.
///
/// Deliberately partial: `Host` / `HostName` / `User` / `Port` /
/// `IdentityFile` / `ProxyJump` and nothing else. ProxyCommand, Match blocks
/// and Include are *not* supported and a profile that needs them would be
/// quietly wrong — so hosts carrying them are dropped rather than imported
/// half-configured.
///
/// `ProxyJump` is honoured only in the one shape this app can reproduce
/// faithfully: **a single alias defined in the same file**. A jump spec that
/// names a host directly (`user@bastion.example.com`), or chains several hops
/// with commas, drops the entry instead of importing a machine whose route we
/// would be guessing at. Same rule for a chain that loops or that is deeper
/// than [JumpChain.maxHops].
class SshConfigImport {
  SshConfigImport._();

  /// Directives whose presence means this app can't honour the entry.
  static const Set<String> _unsupported = {
    'proxycommand',
    'match',
    'include',
  };

  static List<SshConfigHost> parse(String text) {
    final out = <SshConfigHost>[];

    // Accumulator for the block being read.
    List<String> aliases = const [];
    String? hostName;
    String? user;
    int port = 22;
    String? identityFile;
    String? proxyJump;
    var poisoned = false;

    void flush() {
      if (aliases.isEmpty || poisoned) return;
      for (final alias in aliases) {
        // `Host *` is defaults for everything, not a machine.
        if (alias.contains('*') || alias.contains('?')) continue;
        out.add(SshConfigHost(
          alias: alias,
          hostName: hostName ?? alias,
          user: user,
          port: port,
          identityFile: identityFile,
          proxyJump: proxyJump,
        ));
      }
    }

    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      // `Key value` or `Key=value`, case-insensitive keyword.
      final match = RegExp(r'^(\S+)\s*[=\s]\s*(.+)$').firstMatch(line);
      if (match == null) continue;
      final key = match.group(1)!.toLowerCase();
      final value = match.group(2)!.trim();

      if (key == 'host') {
        flush();
        aliases = value.split(RegExp(r'\s+')).where((a) => a.isNotEmpty).toList();
        hostName = null;
        user = null;
        port = 22;
        identityFile = null;
        proxyJump = null;
        poisoned = false;
        continue;
      }
      if (_unsupported.contains(key)) {
        poisoned = true;
        continue;
      }
      switch (key) {
        case 'hostname':
          hostName = value;
        case 'user':
          user = value;
        case 'port':
          port = int.tryParse(value) ?? 22;
        case 'identityfile':
          identityFile = value;
        case 'proxyjump':
          proxyJump = value;
      }
    }
    flush();
    return _resolveJumps(out);
  }

  /// Keeps only the `ProxyJump` links this app can honour, and drops the hosts
  /// whose route we would otherwise be inventing.
  ///
  /// The alternative — importing the machine without its jump — is worse than
  /// not importing it: the profile looks right, sits in the list, and fails
  /// every time because the host was never reachable directly.
  static List<SshConfigHost> _resolveJumps(List<SshConfigHost> hosts) {
    if (hosts.every((h) => h.proxyJump == null)) return hosts;

    final byAlias = {for (final h in hosts) h.alias: h};
    final resolved = <String, String?>{}; // alias -> jump alias or null
    final dropped = <String>{};

    for (final host in hosts) {
      final raw = host.proxyJump?.trim();
      if (raw == null || raw.isEmpty) {
        resolved[host.alias] = null;
        continue;
      }
      // `ProxyJump none` is OpenSSH's way of cancelling an inherited one.
      if (raw.toLowerCase() == 'none') {
        resolved[host.alias] = null;
        continue;
      }
      // A comma chains hops; a user@host:port spec names a machine that has no
      // block here. Both are honest configurations we cannot reproduce.
      if (raw.contains(',') ||
          raw.contains('@') ||
          raw.contains(':') ||
          RegExp(r'\s').hasMatch(raw) ||
          !byAlias.containsKey(raw) ||
          raw == host.alias) {
        dropped.add(host.alias);
        continue;
      }
      resolved[host.alias] = raw;
    }

    // Walk each chain: anything that loops, runs into a dropped host, or goes
    // deeper than the app allows takes its whole branch with it. Repeated to a
    // fixed point because dropping a host invalidates everything behind it, and
    // that host may already have been checked earlier in this same sweep.
    var changed = true;
    while (changed) {
      changed = false;
      for (final host in hosts) {
        if (dropped.contains(host.alias)) continue;
        final seen = <String>{host.alias};
        var cursor = resolved[host.alias];
        var depth = 0;
        while (cursor != null) {
          depth++;
          if (dropped.contains(cursor) ||
              !seen.add(cursor) ||
              depth > JumpChain.maxHops) {
            dropped.add(host.alias);
            changed = true;
            break;
          }
          cursor = resolved[cursor];
        }
      }
    }

    return hosts
        .where((h) => !dropped.contains(h.alias))
        .map((h) => h._withJump(resolved[h.alias]))
        .toList();
  }

  /// Turns the chosen [aliases] into profiles with their jump chains wired up.
  ///
  /// A jump host is pulled in even when it was not ticked: importing a machine
  /// without the bastion it needs would produce a profile that cannot connect,
  /// and asking the user to notice the dependency themselves is how that
  /// happens. The caller gets the full list back, so it can say how many were
  /// actually created.
  static List<ConnectionProfile> toProfiles(
      List<SshConfigHost> hosts, Set<String> aliases) {
    final byAlias = {for (final h in hosts) h.alias: h};

    // Transitive closure of the selection over ProxyJump.
    final needed = <String>{};
    void pull(String alias) {
      if (!needed.add(alias)) return;
      final jump = byAlias[alias]?.proxyJump;
      if (jump != null) pull(jump);
    }

    for (final alias in aliases) {
      if (byAlias.containsKey(alias)) pull(alias);
    }

    // Ids first, so a chain can be wired in one pass whatever the file order.
    final profiles = <String, ConnectionProfile>{
      for (final alias in needed)
        if (byAlias[alias] != null) alias: byAlias[alias]!.toProfile(),
    };

    return [
      for (final entry in profiles.entries)
        () {
          final jump = byAlias[entry.key]?.proxyJump;
          final hop = jump == null ? null : profiles[jump];
          return hop == null
              ? entry.value
              : entry.value.copyWith(jumpProfileId: hop.id);
        }(),
    ];
  }

  /// The user's own config, when there is one to read without a picker. On
  /// Android there is no `~/.ssh`, so this returns null and the caller falls
  /// back to [pickAndParse].
  static Future<List<SshConfigHost>?> readDefault() async {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    final file = File('$home/.ssh/config');
    if (!await file.exists()) return null;
    try {
      return parse(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  /// Lets the user pick a config file. Returns null when they cancelled.
  static Future<List<SshConfigHost>?> pickAndParse() async {
    final picked = await FilePicker.platform.pickFiles(withData: true);
    if (picked == null || picked.files.isEmpty) return null;
    final file = picked.files.first;
    try {
      final text = file.bytes != null
          ? String.fromCharCodes(file.bytes!)
          : await File(file.path!).readAsString();
      return parse(text);
    } catch (_) {
      return const [];
    }
  }
}
