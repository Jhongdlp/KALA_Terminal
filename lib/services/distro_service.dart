import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// Manages a self-contained Linux userland (Alpine) that runs on Android via
/// `proot` — no root required. This is what gives the local terminal a real
/// package manager (`apk`, plus a Termux-style `pkg` wrapper) and a normal
/// `/usr` filesystem, instead of Android's bare `/system/bin/sh`.
///
/// Layout under the app's support dir (`<support>/distro`):
///   bin/proot            the proot loader (exec'd directly by flutter_pty)
///   bin/libtalloc.so.2   proot's only non-system shared lib
///   rootfs/              the extracted Alpine root filesystem
///   tmp/                 PROOT_TMP_DIR scratch (proot extracts its loader here)
///
/// proot itself is exec'd from the app data dir, which Android only permits for
/// apps targeting SDK <= 28 — see the targetSdk pin in android/app/build.gradle.kts.
class DistroService {
  DistroService._();

  // Bump when the bundled rootfs/proot changes so installs re-provision.
  static const int _version = 6;

  // Termux's proot (built for Android's untrusted_app sandbox) + its loader and
  // the two shared libs it needs. proot needs the loader at runtime via
  // PROOT_LOADER, and libtalloc/libandroid-shmem found via LD_LIBRARY_PATH.
  static const String _prootAsset = 'assets/distro/proot';
  static const String _loaderAsset = 'assets/distro/loader';
  static const Map<String, String> _libAssets = {
    'assets/distro/libtalloc.so.2': 'libtalloc.so.2',
    'assets/distro/libandroid-shmem.so': 'libandroid-shmem.so',
  };
  static const String _rootfsAsset = 'assets/distro/alpine-minirootfs.tar.gz';

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
  static Future<String> rootfsDir() async => '${(await _base()).path}/rootfs';
  static Future<String> tmpDir() async => '${(await _base()).path}/tmp';
  static Future<String> _prootPath() async => '${await binDir()}/proot';
  static Future<File> _stamp() async =>
      File('${(await _base()).path}/.installed');

  /// Whether the distro has been provisioned at the current [_version].
  static Future<bool> isInstalled() async {
    if (!Platform.isAndroid) return false;
    final stamp = await _stamp();
    if (!await stamp.exists()) return false;
    final v = int.tryParse((await stamp.readAsString()).trim());
    return v == _version && await File(await _prootPath()).exists();
  }

  /// Provision the userland: copy proot, extract the rootfs, wire DNS and the
  /// `pkg` shim. [log] receives human-readable progress lines (already CR/LF
  /// terminated) so the caller can stream them to the terminal. Throws on
  /// failure; callers should fall back to the system shell.
  static Future<void> install({void Function(String)? log}) async {
    void emit(String m) => log?.call('$m\r\n');

    final base = await _base();
    final bin = Directory(await binDir());
    final rootfs = Directory(await rootfsDir());
    final tmp = Directory(await tmpDir());

    emit('Preparando entorno Linux (Alpine)...');
    await bin.create(recursive: true);
    await tmp.create(recursive: true);
    if (await rootfs.exists()) await rootfs.delete(recursive: true);
    await rootfs.create(recursive: true);

    // 1) proot + its loader + shared libs.
    emit('Copiando proot...');
    final prootFile = await _copyAsset(_prootAsset, await _prootPath());
    await _chmod('0755', prootFile.path);
    final loaderFile = await _copyAsset(_loaderAsset, '${bin.path}/loader');
    await _chmod('0755', loaderFile.path);
    for (final entry in _libAssets.entries) {
      await _copyAsset(entry.key, '${bin.path}/${entry.value}');
    }

    // 2) Extract the rootfs using Android's own tar (preserves symlinks/perms).
    emit('Extrayendo sistema de archivos...');
    final tarPath = '${base.path}/rootfs.tar.gz';
    final tarFile = await _copyAsset(_rootfsAsset, tarPath);
    final res = await Process.run(
        '/system/bin/tar', ['xzf', tarPath, '-C', rootfs.path]);
    await tarFile.delete();
    if (res.exitCode != 0) {
      throw Exception('tar falló (${res.exitCode}): ${res.stderr}');
    }

    // 3) DNS so the package manager can reach the network.
    emit('Configurando red...');
    await File('${rootfs.path}/etc/resolv.conf')
        .writeAsString('nameserver 8.8.8.8\nnameserver 1.1.1.1\n');

    // 4) A Termux-style `pkg` wrapper around apk, plus a friendlier motd.
    emit('Instalando comandos (pkg)...');
    final localBin = Directory('${rootfs.path}/usr/local/bin');
    await localBin.create(recursive: true);
    final pkg = File('${localBin.path}/pkg');
    await pkg.writeAsString(_pkgWrapper);
    await _chmod('0755', pkg.path);

    // Branded MOTD: written with real ANSI/UTF-8 bytes to /etc/motd, then
    // `cat`-ed from /etc/profile on every interactive login shell. Writing the
    // raw bytes (rather than echo-ing escapes from shell) keeps the colour
    // codes intact and sidesteps shell-quoting headaches.
    await File('${rootfs.path}/etc/motd').writeAsString(_motd);
    await File('${rootfs.path}/etc/profile').writeAsString(
      '\n# KALA welcome banner (only on interactive terminals)\n'
      '[ -t 1 ] && cat /etc/motd 2>/dev/null\n',
      mode: FileMode.append,
    );

    // 5) Pre-fetch the package index so `pkg install <x>` works immediately,
    //    without the user having to run `pkg update` first. Non-fatal: if the
    //    device is offline the user can refresh it later.
    emit('Actualizando índice de paquetes...');
    final upd = await _runInGuest('apk update');
    if (upd.exitCode != 0) {
      emit('(sin red ahora; usa "pkg update" más tarde)');
    }

    final stamp = await _stamp();
    await stamp.writeAsString('$_version');
    emit('Listo.');
  }

  /// Run a one-off command inside the guest non-interactively (used during
  /// provisioning, e.g. `apk update`). Shares proot's binary/binds/env with the
  /// interactive [launch] path.
  static Future<ProcessResult> _runInGuest(String command) async {
    final rootfs = await rootfsDir();
    return Process.run(
      await _prootPath(),
      [
        ..._prootBaseArgs(rootfs),
        '/usr/bin/env', '-i', ..._guestEnv,
        '/bin/sh', '-c', command,
      ],
      environment: await _prootEnv(),
      workingDirectory: rootfs,
    );
  }

  /// Everything flutter_pty needs to spawn an interactive shell *inside* the
  /// distro: the proot executable, its arguments, and the host-side environment
  /// (LD_LIBRARY_PATH for libtalloc, PROOT_TMP_DIR for the loader).
  static Future<ProotLaunch> launch({String shell = '/bin/sh'}) async {
    final rootfs = await rootfsDir();
    return ProotLaunch(
      executable: await _prootPath(),
      arguments: [
        ..._prootBaseArgs(rootfs),
        '/usr/bin/env', '-i', ..._guestEnv,
        'PS1=\\w \\\$ ',
        shell, '-l', // login shell: sources /etc/profile (welcome banner)
      ],
      environment: await _prootEnv(),
      workingDirectory: rootfs,
    );
  }

  // Base proot args shared by the interactive shell and one-off commands:
  // fake root, bind the kernel virtual filesystems, start in /root.
  static List<String> _prootBaseArgs(String rootfs) => [
        '--kill-on-exit',
        '-r', rootfs,
        '-0',
        '-b', '/dev',
        '-b', '/proc',
        '-b', '/sys',
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
  // Letting proot install its seccomp filter, like Termux's proot-distro, fixes it.
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

  static Future<void> _chmod(String mode, String path) async {
    final res = await Process.run('/system/bin/chmod', [mode, path]);
    if (res.exitCode != 0) {
      throw Exception('chmod $mode $path falló: ${res.stderr}');
    }
  }

  static const String _pkgWrapper = '''#!/bin/sh
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

  // The KALA "message of the day": an ANSI-Shadow logo in the app's azure
  // brand colour (256-colour 33 ≈ #007AFF), a tagline, and an aligned
  // quick-start. \x1B is a literal ESC byte; \x1B[38;5;33m = azure, [1m = bold,
  // [2m = dim, [0m = reset. Box/block glyphs render via the bundled CascadiaCode.
  static const String _motd = '\n'
      '   \x1B[38;5;33m██╗  ██╗ █████╗ ██╗      █████╗ \x1B[0m\n'
      '   \x1B[38;5;33m██║ ██╔╝██╔══██╗██║     ██╔══██╗\x1B[0m\n'
      '   \x1B[38;5;33m█████╔╝ ███████║██║     ███████║\x1B[0m\n'
      '   \x1B[38;5;33m██╔═██╗ ██╔══██║██║     ██╔══██║\x1B[0m\n'
      '   \x1B[38;5;33m██║  ██╗██║  ██║███████╗██║  ██║\x1B[0m\n'
      '   \x1B[38;5;33m╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝\x1B[0m\n'
      '\n'
      '   \x1B[2mTu terminal Linux de bolsillo · Alpine + proot\x1B[0m\n'
      '   \x1B[2m──────────────────────────────────────────\x1B[0m\n'
      '\n'
      '   \x1B[38;5;33m▸\x1B[0m \x1B[1mpkg install\x1B[0m \x1B[2m<paquete>\x1B[0m  —  python3, git, nano…\n'
      '   \x1B[38;5;33m▸\x1B[0m \x1B[1mpkg search\x1B[0m \x1B[2m<texto>\x1B[0m  —  buscar paquetes\n'
      '   \x1B[38;5;33m▸\x1B[0m \x1B[1mpkg upgrade\x1B[0m  —  actualizar todo\n'
      '   \x1B[38;5;33m▸\x1B[0m \x1B[1mclear\x1B[0m  —  limpiar la pantalla\n'
      '\n'
      '   \x1B[2mroot · ~  ·  escribe «pkg» para ver todos los comandos\x1B[0m\n'
      '\n';
}

/// Immutable description of how to spawn the distro shell via flutter_pty.
class ProotLaunch {
  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
  final String workingDirectory;

  const ProotLaunch({
    required this.executable,
    required this.arguments,
    required this.environment,
    required this.workingDirectory,
  });
}
