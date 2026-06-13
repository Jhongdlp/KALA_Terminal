import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// Package manager a distro ships with. Drives the Termux-style `pkg` wrapper.
enum PackageManager { apk, apt }

/// Where a distro's root filesystem tarball comes from: either bundled inside
/// the APK (instant, offline) or fetched over the network on demand.
class DistroSource {
  /// Asset path for a bundled tarball (e.g. Alpine). Null for remote distros.
  final String? asset;

  /// Download URL for a remote tarball (e.g. Ubuntu/Debian). Null for bundled.
  final String? url;

  /// Compression of the tarball: 'gz' or 'xz'. Picks the `/system/bin/tar`
  /// flag used to extract it.
  final String compression;

  /// Leading path components to strip on extraction. proot-distro tarballs wrap
  /// the rootfs in a top-level dir (e.g. `ubuntu-noble-aarch64/`), so they need
  /// 1; Alpine's minirootfs sits at the archive root, so it needs 0.
  final int stripComponents;

  const DistroSource.bundled(String this.asset,
      {this.compression = 'gz', this.stripComponents = 0})
      : url = null;
  const DistroSource.remote(String this.url,
      {this.compression = 'xz', this.stripComponents = 1})
      : asset = null;

  bool get isBundled => asset != null;
}

/// Immutable descriptor of a selectable Linux distribution.
class Distro {
  final String id; // 'alpine' | 'ubuntu' | 'debian'
  final String name; // 'Ubuntu 24.04'
  final String description; // 'Compatible y familiar (glibc · apt)'
  final DistroSource source;
  final PackageManager pm;
  final int approxSizeMb; // download/extracted footprint, for the UI
  final String? iconAsset; // monochrome SVG logo for status glyphs, if any

  const Distro({
    required this.id,
    required this.name,
    required this.description,
    required this.source,
    required this.pm,
    required this.approxSizeMb,
    this.iconAsset,
  });
}

/// Manages one or more self-contained Linux userlands that run on Android via
/// `proot` — no root required. This is what gives the local terminal a real
/// package manager and a normal `/usr` filesystem instead of Android's bare
/// `/system/bin/sh`.
///
/// Alpine ships bundled in the APK (instant, offline). Ubuntu/Debian are
/// downloaded on demand from Settings. Each distro lives in its own folder so
/// switching between them doesn't destroy the others.
///
/// Layout under the app's support dir (`<support>/distro`):
///   bin/proot              the proot loader (exec'd directly by flutter_pty)
///   bin/loader             PROOT_LOADER
///   bin/libtalloc.so.2     proot's non-system shared libs (via LD_LIBRARY_PATH)
///   bin/libandroid-shmem.so
///   bin/.proot_version     stamp: which proot revision is provisioned
///   tmp/                   PROOT_TMP_DIR scratch (shared)
///   distros/`<id>`/rootfs    the extracted root filesystem of distro `<id>`
///   distros/`<id>`/.installed  stamp: which provisioning revision is installed
///
/// proot itself is exec'd from the app data dir, which Android only permits for
/// apps targeting SDK <= 28 — see the targetSdk pin in android/app/build.gradle.kts.
class DistroService {
  DistroService._();

  // Bump when the bundled proot/loader/libs change so they re-provision.
  static const int _prootVersion = 1;

  // Bump when per-distro provisioning (pkg wrapper, motd, dns) changes so
  // installs re-provision on next launch.
  static const int _version = 8;

  // -------------------------------------------------------------------------
  // Catalog
  //
  // IMPORTANT: Android's tar (toybox) only decompresses gzip natively — it has
  // no xz/zstd/bzip2 and no external `xz` binary. So:
  //   - .tar.gz sources extract straight through `tar xzf` (fast).
  //   - .tar.xz sources are decompressed in a Dart isolate (archive's
  //     XZDecoder, see _extract) to a plain .tar first, then `tar xf`. That's
  //     CPU-heavy (~minutes for a big rootfs), so prefer gzip sources.
  //
  // Ubuntu → official `ubuntu-base` cloud rootfs (.tar.gz, ~30 MB, extracts at
  //   the archive root → stripComponents 0). HTTP 200 verified.
  // Debian → proot-distro aarch64 rootfs (.tar.xz, ~43 MB, wrapped in a top dir
  //   → stripComponents 1). No official Debian .tar.gz exists, so it pays the
  //   xz-decompress cost. proot-distro pins each codename to its last release.
  // -------------------------------------------------------------------------
  static const String _alpineAsset = 'assets/distro/alpine-minirootfs.tar.gz';

  static const List<Distro> catalog = [
    Distro(
      id: 'alpine',
      name: 'Alpine',
      description: 'Ligero y rápido (musl · apk)',
      source: DistroSource.bundled(_alpineAsset),
      pm: PackageManager.apk,
      approxSizeMb: 9,
      iconAsset: 'assets/distro/icons/alpinelinux.svg',
    ),
    Distro(
      id: 'ubuntu',
      name: 'Ubuntu 24.04',
      description: 'Compatible y familiar (glibc · apt)',
      source: DistroSource.remote(
        'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.4-base-arm64.tar.gz',
        compression: 'gz',
        stripComponents: 0,
      ),
      pm: PackageManager.apt,
      approxSizeMb: 30,
      iconAsset: 'assets/distro/icons/ubuntu.svg',
    ),
    Distro(
      id: 'debian',
      name: 'Debian 12',
      description: 'Estable (glibc · apt)',
      source: DistroSource.remote(
        'https://github.com/termux/proot-distro/releases/download/v4.17.3/debian-bookworm-aarch64-pd-v4.17.3.tar.xz',
      ),
      pm: PackageManager.apt,
      approxSizeMb: 43,
      iconAsset: 'assets/distro/icons/debian.svg',
    ),
  ];

  static const String defaultDistroId = 'alpine';

  /// Look a distro up by id, falling back to Alpine for unknown ids.
  static Distro byId(String? id) => catalog.firstWhere(
        (d) => d.id == id,
        orElse: () => catalog.first,
      );

  // Termux's proot (built for Android's untrusted_app sandbox) + its loader and
  // the two shared libs it needs.
  static const String _prootAsset = 'assets/distro/proot';
  static const String _loaderAsset = 'assets/distro/loader';
  static const Map<String, String> _libAssets = {
    'assets/distro/libtalloc.so.2': 'libtalloc.so.2',
    'assets/distro/libandroid-shmem.so': 'libandroid-shmem.so',
  };

  static Directory? _baseCache;

  /// `<support>/distro`. Created on demand.
  static Future<Directory> _base() async {
    if (_baseCache != null) return _baseCache!;
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/distro');
    _baseCache = dir;
    return dir;
  }

  static Future<String> binDir() async => '${(await _base()).path}/bin';
  static Future<String> tmpDir() async => '${(await _base()).path}/tmp';
  static Future<String> _prootPath() async => '${await binDir()}/proot';

  /// A single host directory bind-mounted into every distro at `/shared`. It
  /// lives outside any distro's rootfs, so files there are visible from all of
  /// them and survive deleting/switching a distro. Created on demand.
  static Future<String> sharedDir() async {
    final dir = Directory('${(await _base()).path}/shared');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  /// `<support>/distro/distros/<id>`.
  static Future<String> _distroDir(Distro d) async =>
      '${(await _base()).path}/distros/${d.id}';
  static Future<String> rootfsDir(Distro d) async =>
      '${await _distroDir(d)}/rootfs';
  static Future<File> _stamp(Distro d) async =>
      File('${await _distroDir(d)}/.installed');
  static Future<File> _prootStamp() async =>
      File('${await binDir()}/.proot_version');

  /// Whether [d] has been provisioned at the current [_version].
  static Future<bool> isInstalled(Distro d) async {
    if (!Platform.isAndroid) return false;
    final stamp = await _stamp(d);
    if (!await stamp.exists()) return false;
    final v = int.tryParse((await stamp.readAsString()).trim());
    // The stamp is only written after a fully successful install, so its
    // presence at the current version is enough — but double-check the rootfs
    // wasn't manually deleted.
    return v == _version && Directory(await rootfsDir(d)).existsSync();
  }

  /// Total bytes on disk used by [d]'s installed rootfs (0 if not installed).
  static Future<int> installedSize(Distro d) async {
    final dir = Directory(await rootfsDir(d));
    if (!await dir.exists()) return 0;
    var total = 0;
    try {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) total += await e.length();
      }
    } catch (_) {}
    return total;
  }

  /// Remove [d]'s installed rootfs to free space. Refuses bundled distros that
  /// are not installed; safe to call on anything.
  static Future<void> remove(Distro d) async {
    final dir = Directory(await _distroDir(d));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// Provision the shared proot binary + loader + libs. Idempotent and
  /// versioned: a no-op once the current [_prootVersion] is in place.
  static Future<void> ensureProot({void Function(String)? log}) async {
    final stamp = await _prootStamp();
    if (await stamp.exists() &&
        (int.tryParse((await stamp.readAsString()).trim()) == _prootVersion) &&
        await File(await _prootPath()).exists()) {
      return;
    }

    void emit(String m) => log?.call('$m\r\n');
    final bin = Directory(await binDir());
    final tmp = Directory(await tmpDir());
    await bin.create(recursive: true);
    await tmp.create(recursive: true);

    emit('Copiando proot...');
    final prootFile = await _copyAsset(_prootAsset, await _prootPath());
    await _chmod('0755', prootFile.path);
    final loaderFile = await _copyAsset(_loaderAsset, '${bin.path}/loader');
    await _chmod('0755', loaderFile.path);
    for (final entry in _libAssets.entries) {
      await _copyAsset(entry.key, '${bin.path}/${entry.value}');
    }
    await stamp.writeAsString('$_prootVersion');
  }

  /// Provision [d]: ensure proot, obtain the rootfs tarball (copy the bundled
  /// asset or download it with progress), extract it, wire DNS and the `pkg`
  /// wrapper, then refresh the package index. [log] receives human-readable
  /// progress lines (already CR/LF terminated, for the terminal); [onStatus]
  /// receives the same phases as plain text (for a settings UI); [onProgress]
  /// reports download fraction in 0..1 (only for remote distros). Throws on
  /// failure.
  static Future<void> install(
    Distro d, {
    void Function(String)? log,
    void Function(String)? onStatus,
    void Function(double)? onProgress,
  }) async {
    void emit(String m) {
      log?.call('$m\r\n');
      onStatus?.call(m);
    }

    await ensureProot(log: log);

    final distroDir = Directory(await _distroDir(d));
    final rootfs = Directory(await rootfsDir(d));

    emit('Preparando entorno Linux (${d.name})...');
    await distroDir.create(recursive: true);
    if (await rootfs.exists()) await rootfs.delete(recursive: true);
    await rootfs.create(recursive: true);

    // 1) Obtain the rootfs tarball.
    final tarPath = '${distroDir.path}/rootfs.tar';
    final tarFile = File(tarPath);
    if (d.source.isBundled) {
      emit('Copiando sistema de archivos...');
      await _copyAsset(d.source.asset!, tarPath);
    } else {
      emit('Descargando ${d.name} (~${d.approxSizeMb} MB)...');
      await _download(d.source.url!, tarPath, onProgress: onProgress);
    }

    // 2) Decompress (if needed) and extract.
    //
    // Android's tar only knows gzip, so an .xz tarball is first turned into a
    // plain .tar in a background isolate (CPU-heavy, but off the UI thread).
    // gzip goes straight through `tar xzf`.
    String extractPath = tarPath;
    String tarFlags = 'xzf';
    if (d.source.compression == 'xz') {
      emit('Descomprimiendo ${d.name} (puede tardar 1-3 min)...');
      final plainTar = '$tarPath.plain';
      await _xzToTar(tarPath, plainTar);
      await tarFile.delete();
      extractPath = plainTar;
      tarFlags = 'xf'; // already uncompressed
    }

    emit('Extrayendo sistema de archivos...');
    final res = await Process.run('/system/bin/tar', [
      tarFlags, extractPath,
      '-C', rootfs.path,
      if (d.source.stripComponents > 0)
        '--strip-components=${d.source.stripComponents}',
      // Skip /dev: it holds char/block device nodes (console, null, tty…) that
      // an unprivileged Android app can't mknod — tar would otherwise abort with
      // "permission denied". proot binds the host's /dev anyway (-b /dev), so the
      // guest's own /dev is never used.
      '--exclude=*/dev/*',
      '--exclude=dev/*',
    ]);
    await File(extractPath).delete();
    // The /dev exclusion above removes the only entries an app can't create, but
    // some tar builds still return non-zero on harmless warnings. Treat the
    // extraction as successful as long as a real rootfs landed (e.g. /bin and
    // /etc exist); only fail hard when it clearly didn't.
    final looksValid = Directory('${rootfs.path}/etc').existsSync() &&
        (Directory('${rootfs.path}/bin').existsSync() ||
            Directory('${rootfs.path}/usr/bin').existsSync());
    if (res.exitCode != 0 && !looksValid) {
      throw Exception('tar falló (${res.exitCode}): ${res.stderr}');
    }
    // Guarantee proot's bind mount points exist even though /dev was skipped.
    // `shared` is the cross-distro folder bound at /shared (see _prootBaseArgs);
    // a /root/shared symlink makes it discoverable from the default home dir.
    for (final mp in const ['dev', 'proc', 'sys', 'shared']) {
      await Directory('${rootfs.path}/$mp').create(recursive: true);
    }
    try {
      final link = Link('${rootfs.path}/root/shared');
      if (!await link.exists()) await link.create('/shared');
    } catch (_) {/* non-fatal cosmetic shortcut */}

    // 3) DNS so the package manager can reach the network.
    emit('Configurando red...');
    await File('${rootfs.path}/etc/resolv.conf')
        .writeAsString('nameserver 8.8.8.8\nnameserver 1.1.1.1\n');

    // 4) A Termux-style `pkg` wrapper around the distro's package manager,
    //    plus a friendlier branded motd.
    emit('Instalando comandos (pkg)...');
    final localBin = Directory('${rootfs.path}/usr/local/bin');
    await localBin.create(recursive: true);
    final pkg = File('${localBin.path}/pkg');
    await pkg.writeAsString(_pkgWrapper(d.pm));
    await _chmod('0755', pkg.path);

    // Branded MOTD: real ANSI/UTF-8 bytes to /etc/motd. The welcome banner and
    // the colored prompt are wired by _provisionShellExperience (a /etc/profile.d
    // drop-in for POSIX shells + a fish config), which also runs on every launch
    // so existing installs pick up tweaks without reinstalling.
    await File('${rootfs.path}/etc/motd').writeAsString(_motd(d));
    await _provisionShellExperience(rootfs.path);

    // 5) Pre-fetch the package index so `pkg install <x>` works immediately.
    //    Non-fatal: if the device is offline the user can refresh it later.
    emit('Actualizando índice de paquetes...');
    final updateCmd = d.pm == PackageManager.apt
        ? 'DEBIAN_FRONTEND=noninteractive apt-get update'
        : 'apk update';
    final upd = await _runInGuest(d, updateCmd);
    if (upd.exitCode != 0) {
      emit('(sin red ahora; usa "pkg update" más tarde)');
    }

    // 6) fish: gives the Termux-style colored prompt with inline gray
    //    autosuggestions ("ghost text") and syntax highlighting out of the box,
    //    and becomes the preferred interactive shell (see _bestShell). Needs the
    //    network, so it's non-fatal: without it the colored /etc/profile.d
    //    prompt on the base shell still applies, and `pkg install fish` later
    //    finishes the job (the fish config is already in place).
    emit('Instalando shell mejorado (fish)...');
    final fishCmd = d.pm == PackageManager.apt
        ? 'DEBIAN_FRONTEND=noninteractive apt-get install -y fish'
        : 'apk add fish';
    final fish = await _runInGuest(d, fishCmd);
    if (fish.exitCode != 0) {
      emit('(fish no se instaló; tendrás prompt con color en el shell básico)');
    }

    await (await _stamp(d)).writeAsString('$_version');
    emit('Listo.');
  }

  /// Decompress an .xz tarball at [xzPath] into a plain .tar at [tarPath] in a
  /// background isolate (CPU-heavy XZ decode, kept off the UI thread).
  ///
  /// This MUST be its own static method: `Isolate.run` ships the closure to the
  /// new isolate, and a closure captures its whole enclosing *context*, not just
  /// the variables it names. Inlined in [install] the closure dragged along
  /// install's other locals (the `log`/`onStatus` callbacks, which close over
  /// the Pty/TerminalSession/AppState) and the send failed with "object is
  /// unsendable". Here the only locals in scope are the two String paths, so the
  /// capture is sendable.
  static Future<void> _xzToTar(String xzPath, String tarPath) async {
    await Isolate.run(() {
      final xz = File(xzPath).readAsBytesSync();
      final raw = XZDecoder().decodeBytes(xz);
      File(tarPath).writeAsBytesSync(raw);
    });
  }

  /// Run a one-off command inside [d]'s guest non-interactively (used during
  /// provisioning, e.g. the package-index refresh).
  static Future<ProcessResult> _runInGuest(Distro d, String command) async {
    final rootfs = await rootfsDir(d);
    return Process.run(
      await _prootPath(),
      [
        ..._prootBaseArgs(d, rootfs, await sharedDir()),
        '/usr/bin/env', '-i', ..._guestEnv,
        '/bin/sh', '-c', command,
      ],
      environment: await _prootEnv(),
      workingDirectory: rootfs,
    );
  }

  /// Everything flutter_pty needs to spawn an interactive shell inside [d].
  ///
  /// When [shell] is null the best available interactive shell is picked: fish
  /// if installed (colored prompt + inline gray autosuggestions), then bash,
  /// then `/bin/sh`. The shell matters for Tab completion — Ubuntu/Debian's
  /// `/bin/sh` is dash, which has no line editing or completion at all, whereas
  /// their `/bin/bash` does; Alpine has no bash but its BusyBox `/bin/sh` (ash)
  /// already completes.
  static Future<ProotLaunch> launch(Distro d, {String? shell}) async {
    final rootfs = await rootfsDir(d);
    final resolvedShell = shell ?? _bestShell(rootfs);
    // Termux-style phone storage: bind /storage/emulated/0 into the guest and
    // surface it as links in ~ — done at every launch (not install) so an
    // already-installed distro picks it up the first time the permission is
    // granted.
    final storage = sharedStoragePath();
    if (storage != null) await _linkStorageIntoHome(rootfs, storage);
    // `open <archivo>` (termux-open style) — also provisioned per launch so
    // existing installs get it without reinstalling the rootfs.
    await _provisionOpenCommand(rootfs);
    // Colored prompt + fish config — likewise refreshed per launch so prompt
    // tweaks ship without a reinstall. The prompt itself comes from these files
    // (/etc/profile.d for ash/bash, the fish config for fish), so no PS1 is
    // passed in the env below.
    await _provisionShellExperience(rootfs);
    return ProotLaunch(
      executable: await _prootPath(),
      arguments: [
        ..._prootBaseArgs(d, rootfs, await sharedDir()),
        if (storage != null) ...[
          // Same-path bind keeps the ~ symlink targets valid in the guest;
          // /sdcard is the familiar Android alias.
          '-b', storage,
          '-b', '$storage:/sdcard',
        ],
        '/usr/bin/env', '-i', ..._guestEnv,
        'KALA_DISTRO=${d.id}',
        resolvedShell, '-l', // login shell: sources /etc/profile (prompt + banner)
      ],
      environment: await _prootEnv(),
      workingDirectory: rootfs,
      homeDirectory: '$rootfs/root',
    );
  }

  // ---- `open` command (terminal → app editor) -------------------------------
  //
  // The guest-side `open` script drops one request file per invocation into
  // /shared/.kala/open (the /shared bind is visible from the host). AppState
  // watches the host side of that folder and opens the file in the editor.
  // Each request file holds two lines: the distro id and the absolute guest
  // path, which [guestPathToHost] maps back to a host path.

  /// Host directory where guest `open` requests land. Created on demand.
  static Future<String> openSpoolDir() async {
    final dir = Directory('${await sharedDir()}/.kala/open');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  /// Map an absolute path as seen inside [distroId]'s guest to the host path
  /// the app can read (rootfs-relative, /shared, or phone storage).
  static Future<String> guestPathToHost(String distroId, String guestPath) async {
    if (guestPath == '/shared' || guestPath.startsWith('/shared/')) {
      return '${await sharedDir()}${guestPath.substring('/shared'.length)}';
    }
    if (guestPath == '/sdcard' || guestPath.startsWith('/sdcard/')) {
      return '/storage/emulated/0${guestPath.substring('/sdcard'.length)}';
    }
    if (guestPath.startsWith('/storage/')) return guestPath;
    return '${await rootfsDir(byId(distroId))}$guestPath';
  }

  static Future<void> _provisionOpenCommand(String rootfs) async {
    try {
      final localBin = Directory('$rootfs/usr/local/bin');
      await localBin.create(recursive: true);
      final f = File('${localBin.path}/open');
      await f.writeAsString(_openScript);
      await _chmod('0755', f.path);
    } catch (_) {/* non-fatal: the shell still works without `open` */}
  }

  // ---- Colored prompt + fish config -----------------------------------------

  /// Write KALA's shell experience into [rootfs]. Idempotent and called on every
  /// launch, so existing installs pick up prompt tweaks without reinstalling:
  ///   * /etc/profile.d/kala.sh — the welcome banner plus a colored, Termux-style
  ///     prompt for POSIX shells (BusyBox ash and bash). Alpine/Debian's
  ///     /etc/profile sources /etc/profile.d/*.sh on every login shell.
  ///   * /etc/fish/config.fish — the same banner with a colored fish_prompt.
  ///     fish's inline gray autosuggestions are on by default (we only pin the
  ///     color); it ignores PS1/profile, hence its own config file.
  static Future<void> _provisionShellExperience(String rootfs) async {
    const esc = '\x1B'; // real ESC byte, so we don't rely on the shell decoding \033
    try {
      final profileD = Directory('$rootfs/etc/profile.d');
      await profileD.create(recursive: true);
      // user@host in green, path (\w, with ~ for home) in blue — Termux's
      // default look. \[ \] mark the zero-width color codes so line editing
      // counts the prompt width correctly; \$ is $ for users, # for root.
      final ps1 = "PS1='\\[$esc[1;32m\\]\\u@\\h\\[$esc[0m\\]:"
          "\\[$esc[1;34m\\]\\w\\[$esc[0m\\]\\\$ '";
      await File('${profileD.path}/kala.sh').writeAsString(
        '# KALA shell experience (auto-generated).\n'
        '[ -t 1 ] && [ -r /etc/motd ] && cat /etc/motd 2>/dev/null\n'
        '$ps1\n'
        'export PS1\n',
      );
    } catch (_) {/* non-fatal: the shell still works with its default prompt */}
    try {
      final fishDir = Directory('$rootfs/etc/fish');
      await fishDir.create(recursive: true);
      await File('${fishDir.path}/config.fish').writeAsString(_fishConfig);
    } catch (_) {/* non-fatal: only matters once fish is installed */}
  }

  static const String _fishConfig = '''# KALA fish config (auto-generated).
if status is-login
    test -r /etc/motd; and cat /etc/motd 2>/dev/null
end

# Show the full path (with ~ for home) instead of truncating it, Termux-style.
set -g fish_prompt_pwd_dir_length 0
# Inline autosuggestions ("ghost text") are on by default; pin them to gray.
set -g fish_color_autosuggestion 6c6c6c

function fish_prompt
    set_color green
    echo -n (whoami)'@'\$hostname
    set_color normal
    echo -n ':'
    set_color blue
    echo -n (prompt_pwd)
    set_color normal
    echo -n ' \$ '
end
''';

  static const String _openScript = '''#!/bin/sh
# KALA: abre un archivo en el editor de la app (estilo termux-open).
if [ -z "\$1" ]; then
  echo "uso: open <archivo>"
  exit 1
fi
case "\$1" in
  /*) abs="\$1" ;;
  *)  abs="\$(pwd)/\$1" ;;
esac
if [ ! -e "\$abs" ]; then
  echo "open: no existe: \$abs"
  exit 1
fi
mkdir -p /shared/.kala/open
printf '%s\\n%s\\n' "\${KALA_DISTRO:-alpine}" "\$abs" > "/shared/.kala/open/req-\$\$-\$(date +%s)"
''';

  /// Host path of the device's shared storage, or null when it isn't readable
  /// yet (storage permission not granted, or not on Android).
  static String? sharedStoragePath() {
    if (!Platform.isAndroid) return null;
    for (final p in const ['/storage/emulated/0', '/sdcard']) {
      try {
        Directory(p).listSync();
        return p;
      } catch (_) {/* not readable → try next / give up */}
    }
    return null;
  }

  // Symlinks in the guest home pointing at the phone's real folders, so `ls ~`
  // shows Downloads/DCIM/... like Termux. Targets are absolute host paths,
  // valid both inside the guest (same-path bind in [launch]) and for the
  // host-side file explorer. Best-effort and idempotent.
  static Future<void> _linkStorageIntoHome(String rootfs, String storage) async {
    final home = Directory('$rootfs/root');
    await home.create(recursive: true);
    final links = <String, String>{
      'sdcard': storage,
      'Downloads': '$storage/Download',
      'Documents': '$storage/Documents',
      'DCIM': '$storage/DCIM',
      'Pictures': '$storage/Pictures',
      'Music': '$storage/Music',
      'Movies': '$storage/Movies',
    };
    for (final e in links.entries) {
      if (e.key != 'sdcard' && !Directory(e.value).existsSync()) continue;
      try {
        final link = Link('${home.path}/${e.key}');
        if (!await link.exists()) await link.create(e.value);
      } catch (_) {/* non-fatal cosmetic shortcut */}
    }
  }

  /// Pick the interactive shell with the best experience available in [rootfs]:
  /// fish (colored prompt + inline gray autosuggestions), then bash, then the
  /// base `/bin/sh`. fish is installed during provisioning when the network is
  /// reachable; otherwise this falls through to bash/ash with the colored
  /// /etc/profile.d prompt.
  static String _bestShell(String rootfs) {
    for (final candidate in const [
      '/usr/bin/fish',
      '/bin/fish',
      '/bin/bash',
      '/usr/bin/bash',
    ]) {
      if (File('$rootfs$candidate').existsSync()) return candidate;
    }
    return '/bin/sh';
  }

  // Base proot args shared by the interactive shell and one-off commands:
  // fake root, bind the kernel virtual filesystems + the cross-distro /shared
  // folder, start in /root. apt-based distros also get --link2symlink so dpkg's
  // hardlinks survive on Android's filesystem.
  static List<String> _prootBaseArgs(Distro d, String rootfs, String shared) => [
        '--kill-on-exit',
        if (d.pm == PackageManager.apt) '--link2symlink',
        '-r', rootfs,
        '-0',
        '-b', '/dev',
        '-b', '/proc',
        '-b', '/sys',
        '-b', '$shared:/shared',
        '-w', '/root',
      ];

  // Clean guest environment passed via `env -i`.
  static const List<String> _guestEnv = [
    'HOME=/root',
    'TERM=xterm-256color',
    'LANG=C.UTF-8',
    'PATH=/usr/local/bin:/usr/local/sbin:/bin:/usr/bin:/sbin:/usr/sbin',
  ];

  // Host-side env proot itself needs. We deliberately do NOT set
  // PROOT_NO_SECCOMP: proot's seccomp acceleration (SECCOMP_RET_TRACE) is
  // required here — in pure-ptrace mode on this kernel (Android 16 / 6.12)
  // proot's emulated chdir/fchdir leak ENOSYS ("Function not implemented").
  static Future<Map<String, String>> _prootEnv() async {
    final bin = await binDir();
    return {
      'PROOT_TMP_DIR': await tmpDir(),
      'PROOT_LOADER': '$bin/loader',
      'LD_LIBRARY_PATH': bin,
    };
  }

  static Future<File> _copyAsset(String asset, String destPath) async {
    final data = await rootBundle.load(asset);
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final file = File(destPath);
    await file.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Stream [url] to [destPath], reporting completion fraction via [onProgress]
  /// when the server sends a Content-Length. Follows redirects (GitHub release
  /// assets redirect to a CDN). Throws on a non-200 final response.
  static Future<void> _download(
    String url,
    String destPath, {
    void Function(double)? onProgress,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close(); // follows redirects by default
      if (response.statusCode != 200) {
        throw Exception('Descarga falló (HTTP ${response.statusCode})');
      }
      final total = response.contentLength;
      final sink = File(destPath).openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          received += chunk.length;
          sink.add(chunk);
          if (total > 0) onProgress?.call(received / total);
        }
      } finally {
        await sink.close();
      }
    } finally {
      client.close();
    }
  }

  static Future<void> _chmod(String mode, String path) async {
    final res = await Process.run('/system/bin/chmod', [mode, path]);
    if (res.exitCode != 0) {
      throw Exception('chmod $mode $path falló: ${res.stderr}');
    }
  }

  // A Termux-style `pkg` command, mapped onto the distro's package manager.
  static String _pkgWrapper(PackageManager pm) =>
      pm == PackageManager.apt ? _pkgWrapperApt : _pkgWrapperApk;

  static const String _pkgWrapperApk = '''#!/bin/sh
# Termux-style package command, mapped onto Alpine's apk.
cmd="\$1"; shift 2>/dev/null
case "\$cmd" in
  install|add|i)      exec apk add "\$@" ;;
  uninstall|remove|rm|del) exec apk del "\$@" ;;
  update|up)          exec apk update "\$@" ;;
  upgrade)            exec apk upgrade "\$@" ;;
  search|find|s)      exec apk search "\$@" ;;
  list)               exec apk list "\$@" ;;
  info|show)          exec apk info "\$@" ;;
  ""|help|-h|--help)
    echo "pkg: gestor de paquetes (envuelve apk)"
    echo "  pkg install <paquete>     instalar"
    echo "  pkg uninstall <paquete>   desinstalar"
    echo "  pkg update                actualizar indices"
    echo "  pkg upgrade               actualizar paquetes"
    echo "  pkg search <texto>        buscar"
    ;;
  *) exec apk "\$cmd" "\$@" ;;
esac
''';

  static const String _pkgWrapperApt = '''#!/bin/sh
# Termux-style package command, mapped onto Debian/Ubuntu's apt.
export DEBIAN_FRONTEND=noninteractive
cmd="\$1"; shift 2>/dev/null
case "\$cmd" in
  install|add|i)      exec apt-get install -y "\$@" ;;
  uninstall|remove|rm|del) exec apt-get remove -y "\$@" ;;
  update|up)          exec apt-get update "\$@" ;;
  upgrade)            exec apt-get upgrade -y "\$@" ;;
  search|find|s)      exec apt-cache search "\$@" ;;
  list)               exec dpkg -l "\$@" ;;
  info|show)          exec apt-cache show "\$@" ;;
  ""|help|-h|--help)
    echo "pkg: gestor de paquetes (envuelve apt)"
    echo "  pkg install <paquete>     instalar"
    echo "  pkg uninstall <paquete>   desinstalar"
    echo "  pkg update                actualizar indices"
    echo "  pkg upgrade               actualizar paquetes"
    echo "  pkg search <texto>        buscar"
    ;;
  *) exec apt-get "\$cmd" "\$@" ;;
esac
''';

  // The KALA "message of the day": an ANSI-Shadow logo in the app's azure
  // brand colour (256-colour 33 ≈ #007AFF), a tagline naming the active distro,
  // and an aligned quick-start. \x1B is a literal ESC byte.
  static String _motd(Distro d) => '\n'
      '   \x1B[38;5;33m██╗  ██╗ █████╗ ██╗      █████╗ \x1B[0m\n'
      '   \x1B[38;5;33m██║ ██╔╝██╔══██╗██║     ██╔══██╗\x1B[0m\n'
      '   \x1B[38;5;33m█████╔╝ ███████║██║     ███████║\x1B[0m\n'
      '   \x1B[38;5;33m██╔═██╗ ██╔══██║██║     ██╔══██║\x1B[0m\n'
      '   \x1B[38;5;33m██║  ██╗██║  ██║███████╗██║  ██║\x1B[0m\n'
      '   \x1B[38;5;33m╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝\x1B[0m\n'
      '\n'
      '   \x1B[2mTu terminal Linux de bolsillo · ${d.name} + proot\x1B[0m\n'
      '   \x1B[2m──────────────────────────────────────────\x1B[0m\n'
      '\n'
      '   \x1B[38;5;33m▸\x1B[0m \x1B[1mpkg install\x1B[0m \x1B[2m<paquete>\x1B[0m  —  python3, git, nano…\n'
      '   \x1B[38;5;33m▸\x1B[0m \x1B[1mpkg search\x1B[0m \x1B[2m<texto>\x1B[0m  —  buscar paquetes\n'
      '   \x1B[38;5;33m▸\x1B[0m \x1B[1mpkg upgrade\x1B[0m  —  actualizar todo\n'
      '   \x1B[38;5;33m▸\x1B[0m \x1B[1mopen\x1B[0m \x1B[2m<archivo>\x1B[0m  —  abrir en el editor de KALA\n'
      '   \x1B[38;5;33m▸\x1B[0m \x1B[1mclear\x1B[0m  —  limpiar la pantalla\n'
      '\n'
      '   \x1B[2m~/Downloads · ~/DCIM · ~/sdcard  ·  almacenamiento del teléfono\x1B[0m\n'
      '   \x1B[2m/shared  ·  carpeta compartida entre todas las distros\x1B[0m\n'
      '   \x1B[2mroot · ~  ·  escribe «pkg» para ver todos los comandos\x1B[0m\n'
      '\n';
}

/// Immutable description of how to spawn the distro shell via flutter_pty.
class ProotLaunch {
  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
  final String workingDirectory;

  /// Host path of the guest's home (`<rootfs>/root`) — what the file explorer
  /// should open so it matches the terminal's `~`.
  final String homeDirectory;

  const ProotLaunch({
    required this.executable,
    required this.arguments,
    required this.environment,
    required this.workingDirectory,
    required this.homeDirectory,
  });
}
