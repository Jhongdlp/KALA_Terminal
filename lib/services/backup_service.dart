import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import 'secure_store.dart';

/// Everything the app knows about a user, in one file.
///
/// Until now a reinstall meant reconfiguring by hand: profiles, groups, prompt
/// snippets, quick-key layers, accent palette, terminal theme, trusted host
/// keys. All of it lives in `shared_preferences`, which Android will happily
/// wipe with the app, so "my phone died" and "I bought a new phone" both cost
/// an evening.
///
/// The file is plain JSON on purpose: it is meant to be readable, diffable and
/// editable, and to survive this app being uninstalled.
class BackupService {
  BackupService._();

  /// Bumped only on a breaking change to the envelope. [restore] refuses a
  /// version it doesn't understand rather than half-applying it.
  static const int formatVersion = 1;

  /// Keys copied verbatim. Everything the user *chose* is in here.
  static const List<String> _explicitKeys = [
    'ssh_profiles',
    'connection_groups',
    'profile_favorites',
    'profile_last_used',
    'prompt_snippets',
    'explorer_bookmarks',
    'known_hosts',
    'app_language',
  ];

  /// Plus every `settings_*` key, minus the ones below.
  static const String _settingsPrefix = 'settings_';

  /// Settings that describe *this device*, not this user's preferences.
  ///
  /// Window geometry and pane splits belong to the screen they were set on, and
  /// restoring `app_lock_enabled` onto a device with no enrolled biometric
  /// would turn a restore into a lockout.
  static const Set<String> _deviceLocalKeys = {
    'settings_app_lock_enabled',
    'settings_split_side',
    'settings_split_editor_terminal',
    'settings_explorer_pane_open',
    'settings_git_pane_open',
  };

  static bool _isBackedUp(String key) =>
      !_deviceLocalKeys.contains(key) &&
      (_explicitKeys.contains(key) || key.startsWith(_settingsPrefix));

  // ---- Export ---------------------------------------------------------------

  /// Builds the backup envelope.
  ///
  /// [includeSecrets] pulls passwords and private keys out of secure storage
  /// and into the file. It defaults to off everywhere it is called from: the
  /// result is a plaintext file holding every credential the user owns, which
  /// is the right trade-off only when they know they're making it.
  static Future<Map<String, dynamic>> build({
    required bool includeSecrets,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final data = <String, dynamic>{};

    for (final key in prefs.getKeys()) {
      if (!_isBackedUp(key)) continue;
      final value = prefs.get(key);
      if (value == null) continue;
      // Typed so restore can put each value back with the right setter —
      // shared_preferences has no generic `set`.
      data[key] = {
        'type': switch (value) {
          bool _ => 'bool',
          int _ => 'int',
          double _ => 'double',
          String _ => 'string',
          List<String> _ => 'stringList',
          _ => 'unsupported',
        },
        'value': value is List<String> ? value : value,
      };
    }
    data.removeWhere((_, v) => (v as Map)['type'] == 'unsupported');

    final envelope = <String, dynamic>{
      'kammel_backup': formatVersion,
      'createdAt': DateTime.now().toIso8601String(),
      'includesSecrets': includeSecrets,
      'prefs': data,
    };

    if (includeSecrets) {
      envelope['secrets'] = await _collectSecrets(prefs);
    }
    return envelope;
  }

  /// Reads every profile's password/private key out of secure storage, keyed by
  /// profile id.
  static Future<Map<String, dynamic>> _collectSecrets(
      SharedPreferences prefs) async {
    final out = <String, dynamic>{};
    for (final raw in prefs.getStringList('ssh_profiles') ?? const <String>[]) {
      String? id;
      try {
        id = (json.decode(raw) as Map<String, dynamic>)['id'] as String?;
      } catch (_) {
        continue;
      }
      if (id == null || id.isEmpty) continue;
      final password = await SecureStore.instance.readPassword(id);
      final privateKey = await SecureStore.instance.readPrivateKey(id);
      if (password == null && privateKey == null) continue;
      out[id] = {
        'password': ?password,
        'privateKey': ?privateKey,
      };
    }
    return out;
  }

  /// Writes the backup where the user can actually find it: the shared
  /// `Download/KAMMEL` folder on Android (same destination the SFTP downloader
  /// uses), the app documents directory elsewhere. Returns the file.
  static Future<File> writeToDisk(Map<String, dynamic> envelope) async {
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final name = 'kammel-backup-$stamp.json';

    String dir;
    if (Platform.isAndroid &&
        await Directory('/storage/emulated/0/Download').exists()) {
      dir = '/storage/emulated/0/Download/KAMMEL';
    } else {
      dir = (await getApplicationDocumentsDirectory()).path;
    }
    await Directory(dir).create(recursive: true);

    final file = File('$dir/$name');
    await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(envelope));
    return file;
  }

  // ---- Import ---------------------------------------------------------------

  /// Outcome of a restore, for the confirmation the UI shows afterwards.
  ///
  /// [restarted] is always true today — every restore needs the app state
  /// rebuilt — but it is reported rather than assumed so the caller doesn't
  /// have to know that.
  static ({int keys, int secrets, String? error}) _result(
          int keys, int secrets, String? error) =>
      (keys: keys, secrets: secrets, error: error);

  /// Lets the user pick a backup file and applies it.
  ///
  /// Restores are **merges**: a key present in the file replaces the current
  /// one, a key that isn't stays as it is. That makes "import my prompts from
  /// the old phone" safe on a device that is already set up, and it is also why
  /// the caller must reload [AppState] afterwards.
  static Future<({int keys, int secrets, String? error})> pickAndRestore() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) {
      return _result(0, 0, null); // Cancelled — not an error.
    }

    final file = picked.files.first;
    String text;
    try {
      final bytes = file.bytes;
      text = bytes != null
          ? utf8.decode(bytes)
          : await File(file.path!).readAsString();
    } catch (e) {
      return _result(0, 0, tr('No se pudo leer el archivo: {0}', [e]));
    }

    Map<String, dynamic> envelope;
    try {
      envelope = json.decode(text) as Map<String, dynamic>;
    } catch (_) {
      return _result(0, 0, tr('Ese archivo no es una copia de KAMMEL.'));
    }

    return restore(envelope);
  }

  /// Applies an already-parsed envelope. Split out from [pickAndRestore] so it
  /// is testable without a file picker.
  static Future<({int keys, int secrets, String? error})> restore(
      Map<String, dynamic> envelope) async {
    final version = envelope['kammel_backup'];
    if (version is! int) {
      return _result(0, 0, tr('Ese archivo no es una copia de KAMMEL.'));
    }
    if (version > formatVersion) {
      return _result(
          0,
          0,
          tr('La copia se hizo con una versión más nueva de la app (formato {0}). Actualiza KAMMEL e inténtalo de nuevo.',
              [version]));
    }

    final prefsData = envelope['prefs'];
    if (prefsData is! Map) {
      return _result(0, 0, tr('La copia está incompleta o dañada.'));
    }

    final prefs = await SharedPreferences.getInstance();
    var restored = 0;
    for (final entry in prefsData.entries) {
      final key = '${entry.key}';
      if (!_isBackedUp(key)) continue; // Never let a file write arbitrary keys.
      final payload = entry.value;
      if (payload is! Map) continue;
      final value = payload['value'];
      final ok = switch (payload['type']) {
        'bool' when value is bool => await prefs.setBool(key, value),
        'int' when value is int => await prefs.setInt(key, value),
        'double' when value is num =>
          await prefs.setDouble(key, value.toDouble()),
        'string' when value is String => await prefs.setString(key, value),
        'stringList' when value is List => await prefs.setStringList(
            key, value.map((e) => '$e').toList()),
        _ => false,
      };
      if (ok) restored++;
    }

    var secrets = 0;
    final secretsData = envelope['secrets'];
    if (secretsData is Map) {
      for (final entry in secretsData.entries) {
        final payload = entry.value;
        if (payload is! Map) continue;
        await SecureStore.instance.writeSecrets(
          '${entry.key}',
          password: payload['password'] as String?,
          privateKey: payload['privateKey'] as String?,
        );
        secrets++;
      }
    }

    return _result(restored, secrets, null);
  }
}
