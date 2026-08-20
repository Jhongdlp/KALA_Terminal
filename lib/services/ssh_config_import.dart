import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';

import '../models/connection_profile.dart';

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

  const SshConfigHost({
    required this.alias,
    required this.hostName,
    this.user,
    this.port = 22,
    this.identityFile,
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
}

/// Reads hosts out of an OpenSSH client config.
///
/// Anyone who already uses SSH from a laptop has this file, and retyping thirty
/// hosts into a phone form is exactly the kind of work that stops someone from
/// trying the app at all.
///
/// Deliberately partial: `Host` / `HostName` / `User` / `Port` / `IdentityFile`
/// and nothing else. ProxyJump, Match blocks and Include are *not* supported and
/// a profile that needs them would be quietly wrong — so hosts carrying them are
/// dropped rather than imported half-configured.
class SshConfigImport {
  SshConfigImport._();

  /// Directives whose presence means this app can't honour the entry.
  static const Set<String> _unsupported = {
    'proxyjump',
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
      }
    }
    flush();
    return out;
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
