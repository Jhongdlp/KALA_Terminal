import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// Owner/repo whose GitHub Releases host the distributed APKs. The "latest"
/// release endpoint is public (no token required) for public repositories.
const String _kRepo = 'Jhongdlp/TerminalAI';

/// Metadata about a release that is newer than the installed build.
class AppUpdate {
  /// Human-facing version name, e.g. "1.0.1" (the release tag without a leading
  /// "v").
  final String version;

  /// Direct download URL of the `.apk` asset attached to the release.
  final String apkUrl;

  /// Release notes (the GitHub release body), shown in the update dialog.
  final String notes;

  const AppUpdate({
    required this.version,
    required this.apkUrl,
    required this.notes,
  });
}

/// Checks GitHub Releases for a newer APK and installs it via the system
/// package installer. The whole flow is best-effort: any network/parse error
/// resolves to "no update" so the app never blocks on the check.
class UpdateService {
  /// Returns an [AppUpdate] when the latest GitHub release is newer than the
  /// running build, or `null` when up to date or on any failure.
  static Future<AppUpdate?> checkForUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final current = info.version; // versionName, e.g. "1.0.0"

      final resp = await http
          .get(
            Uri.parse('https://api.github.com/repos/$_kRepo/releases/latest'),
            headers: {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;

      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      // Drafts/prereleases are not returned by /releases/latest, so no need to
      // filter them here.
      final tag = (json['tag_name'] as String?)?.trim() ?? '';
      final latest = tag.startsWith('v') ? tag.substring(1) : tag;
      if (latest.isEmpty || !_isNewer(latest, current)) return null;

      // Pick the first asset whose name ends in .apk.
      final assets = (json['assets'] as List?) ?? const [];
      final apk = assets.cast<Map<String, dynamic>>().firstWhere(
            (a) => (a['name'] as String? ?? '').toLowerCase().endsWith('.apk'),
            orElse: () => const {},
          );
      final apkUrl = apk['browser_download_url'] as String?;
      if (apkUrl == null) return null;

      return AppUpdate(
        version: latest,
        apkUrl: apkUrl,
        notes: (json['body'] as String? ?? '').trim(),
      );
    } catch (_) {
      // Offline, rate-limited, malformed payload — treat as "no update".
      return null;
    }
  }

  /// Downloads [update]'s APK to app storage, reporting progress in [0,1] via
  /// [onProgress], then opens it with the system installer. Returns the
  /// [OpenResult.type] message on failure, or `null` on success.
  static Future<String?> downloadAndInstall(
    AppUpdate update, {
    void Function(double progress)? onProgress,
  }) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(update.apkUrl));
      final resp = await client.send(req);
      if (resp.statusCode != 200) {
        return 'Descarga fallida (HTTP ${resp.statusCode})';
      }

      final dir = await getApplicationSupportDirectory();
      // Overwrite any previous download so storage doesn't accumulate APKs.
      final file = File('${dir.path}/update-${update.version}.apk');
      final sink = file.openWrite();

      final total = resp.contentLength ?? 0;
      var received = 0;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.flush();
      await sink.close();

      // open_filex bundles its own FileProvider, so it hands the installer a
      // content:// URI — required even on targetSdk 28. The system shows the
      // "Install?" dialog; the user confirms.
      final result = await OpenFilex.open(
        file.path,
        type: 'application/vnd.android.package-archive',
      );
      if (result.type != ResultType.done) return result.message;
      return null;
    } catch (e) {
      return 'Error al actualizar: $e';
    } finally {
      client.close();
    }
  }

  /// Semantic-ish comparison: returns true when [a] is a strictly higher
  /// version than [b]. Compares dot-separated numeric components left to right
  /// ("1.0.10" > "1.0.9"); non-numeric parts are treated as 0.
  static bool _isNewer(String a, String b) {
    final pa = a.split('.');
    final pb = b.split('.');
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final na = i < pa.length ? (int.tryParse(pa[i]) ?? 0) : 0;
      final nb = i < pb.length ? (int.tryParse(pb[i]) ?? 0) : 0;
      if (na != nb) return na > nb;
    }
    return false;
  }
}
