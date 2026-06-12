import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:uuid/uuid.dart';
import '../models/connection_profile.dart';
import '../services/background_service.dart';
import '../services/distro_service.dart';
import '../services/secure_store.dart';

enum ConnectionStatus { disconnected, connecting, local, remote }

class TerminalSession {
  final String id;
  String name;
  final Terminal terminal;
  ConnectionStatus connectionStatus;
  ConnectionProfile? activeProfile;
  SSHClient? sshClient;
  SSHSession? sshSession;
  Pty? localPty;
  String currentPath;
  List<FileSystemEntityInfo> files;
  bool isLoadingFiles;
  // Whether the underlying shell (local PTY or SSH) has actually been spawned.
  // The initial local session is created lazily: the object exists so the UI's
  // active-session delegates work, but proot/Alpine isn't booted until the user
  // first opens the terminal or explorer tab. See [ensureActiveSessionStarted].
  bool started;
  List<ServerSocket> forwardServers;
  // Batched, frame-coalesced writers that feed PTY/SSH bytes into [terminal].
  // One per byte stream (local PTY, or SSH stdout/stderr). See [_TerminalWriter].
  final List<_TerminalWriter> _outputWriters = [];

  TerminalSession({
    required this.id,
    required this.name,
    required this.terminal,
    required this.connectionStatus,
    this.activeProfile,
    this.sshClient,
    this.sshSession,
    this.localPty,
    required this.currentPath,
    List<FileSystemEntityInfo>? files,
    this.isLoadingFiles = false,
    this.started = false,
    List<ServerSocket>? forwardServers,
  })  : files = files ?? [],
        forwardServers = forwardServers ?? [];
}

class AppState extends ChangeNotifier {
  // Navigation State
  int _activeTabIndex = 0;
  int get activeTabIndex => _activeTabIndex;

  void setActiveTabIndex(int index) {
    _activeTabIndex = index;
    // Boot the deferred local shell the first time the user actually needs it —
    // i.e. when they land on the terminal (1) or explorer (2) tab. The app opens
    // on the connections tab, so this keeps proot/Alpine off the startup path.
    if (index == 1 || index == 2) ensureActiveSessionStarted();
    notifyListeners();
  }

  // Connection Profiles State
  List<ConnectionProfile> _profiles = [];
  List<ConnectionProfile> get profiles => _profiles;

  // Multiple Sessions State
  final List<TerminalSession> _sessions = [];
  List<TerminalSession> get sessions => _sessions;

  int _activeSessionIndex = -1;
  int get activeSessionIndex => _activeSessionIndex;

  TerminalSession? get activeSession => (_sessions.isNotEmpty && _activeSessionIndex >= 0 && _activeSessionIndex < _sessions.length)
      ? _sessions[_activeSessionIndex]
      : null;

  // Delegates for active session to maintain compatibility with other views.
  // The fallback is a shared singleton so the getter never allocates a fresh
  // 10k-line Terminal on every access when there is (transiently) no session.
  static final Terminal _fallbackTerminal = Terminal(maxLines: 10000);
  Terminal get terminal => activeSession?.terminal ?? _fallbackTerminal;
  ConnectionStatus get connectionStatus => activeSession?.connectionStatus ?? ConnectionStatus.disconnected;
  ConnectionProfile? get activeProfile => activeSession?.activeProfile;
  bool get isTerminalInitialized => activeSession != null;
  String get currentPath => activeSession?.currentPath ?? '';
  // const fallback so the getter returns a stable reference (a fresh `[]` each
  // call would defeat the explorer's Selector equality check).
  List<FileSystemEntityInfo> get files =>
      activeSession?.files ?? const <FileSystemEntityInfo>[];
  bool get isLoadingFiles => activeSession?.isLoadingFiles ?? false;

  // Editor State (Global but tracks client used to load the file)
  String? _editingFilePath;
  String? get editingFilePath => _editingFilePath;
  String _editingFileContent = '';
  String get editingFileContent => _editingFileContent;
  bool _isFileDirty = false;
  bool get isFileDirty => _isFileDirty;
  bool _isEditingFileRemote = false;
  bool get isEditingFileRemote => _isEditingFileRemote;
  SSHClient? _editingSshClient;

  // ---- Markdown viewer -----------------------------------------------------
  // When the open file is markdown the editor tab can render a formatted
  // preview instead of the raw code editor. [_isMarkdownPreview] tracks which
  // mode is showing; [_markdownScale] is a persisted zoom multiplier driven by
  // the +/- buttons in the preview header.
  static const String _kMarkdownScale = 'settings_markdown_scale';
  static const double minMarkdownScale = 0.6;
  static const double maxMarkdownScale = 3.0;

  static const Set<String> _markdownExtensions = {
    '.md', '.markdown', '.mdown', '.mkd', '.mkdn', '.mdwn'
  };

  /// Whether [path] should be treated as a markdown document (by extension).
  static bool isMarkdownPath(String path) {
    final lower = path.toLowerCase();
    return _markdownExtensions.any((ext) => lower.endsWith(ext));
  }

  bool get isEditingFileMarkdown =>
      _editingFilePath != null && isMarkdownPath(_editingFilePath!);

  bool _isMarkdownPreview = false;
  bool get isMarkdownPreview => _isMarkdownPreview;

  // ---- PDF viewer ----------------------------------------------------------
  // PDFs open in an embedded read-only viewer (pdfrx) on the editor tab instead
  // of the code editor. The raw bytes are held in memory because SFTP-loaded
  // files have no local path to hand to the viewer, and reading them once keeps
  // the local/remote paths uniform.
  static bool isPdfPath(String path) => path.toLowerCase().endsWith('.pdf');

  Uint8List? _viewingPdfBytes;
  Uint8List? get viewingPdfBytes => _viewingPdfBytes;
  bool get isViewingPdf =>
      _editingFilePath != null && _viewingPdfBytes != null;

  double _markdownScale = 1.0;
  double get markdownScale => _markdownScale;

  void setMarkdownPreview(bool preview) {
    if (_isMarkdownPreview == preview) return;
    _isMarkdownPreview = preview;
    notifyListeners();
  }

  void toggleMarkdownPreview() => setMarkdownPreview(!_isMarkdownPreview);

  Future<void> setMarkdownScale(double scale) async {
    final clamped = scale.clamp(minMarkdownScale, maxMarkdownScale);
    if (clamped == _markdownScale) return;
    _markdownScale = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kMarkdownScale, clamped);
  }

  void bumpMarkdownScale(double delta) =>
      setMarkdownScale(_markdownScale + delta);

  // ---- Settings State ------------------------------------------------------
  // Persisted user preferences. Keep every configurable option here so the
  // settings screen has a single source of truth.
  static const String _kThemeMode = 'settings_theme_mode';
  static const String _kTerminalFontSize = 'settings_terminal_font_size';
  static const String _kActiveDistro = 'active_distro';

  static const double minTerminalFontSize = 7;
  static const double maxTerminalFontSize = 26;

  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  double _terminalFontSize = 13;
  double get terminalFontSize => _terminalFontSize;

  // ---- Linux distro selector ----------------------------------------------
  // The local Android terminal runs inside a proot'd Linux userland. Alpine is
  // bundled (instant); Ubuntu/Debian are downloaded on demand. [_activeDistroId]
  // is which one the local shell launches into; the maps track per-distro UI
  // state (installed? currently downloading? at what %?).
  String _activeDistroId = DistroService.defaultDistroId;
  String get activeDistroId => _activeDistroId;
  Distro get activeDistro => DistroService.byId(_activeDistroId);

  List<Distro> get distroCatalog => DistroService.catalog;

  final Map<String, bool> _distroInstalled = {};
  final Map<String, double> _distroProgress = {}; // 0..1 while downloading
  final Map<String, String> _distroStatus = {}; // current phase text
  final Set<String> _distroBusy = {}; // installing/deleting in flight

  bool isDistroInstalled(String id) => _distroInstalled[id] ?? false;
  bool isDistroBusy(String id) => _distroBusy.contains(id);
  double? distroProgress(String id) => _distroProgress[id];
  String? distroStatus(String id) => _distroStatus[id];

  // ---- Command history (smart command bar) --------------------------------
  // Persisted, most-recent-first, de-duplicated list of commands the user has
  // run through the command bar. Drives the bar's autosuggestion (ghost text)
  // and suggestion dropdown. Capped so prefs stay small.
  static const String _kCommandHistory = 'command_history';
  static const int _maxCommandHistory = 300;

  List<String> _commandHistory = [];
  List<String> get commandHistory => _commandHistory;

  AppState() {
    _loadSettings();
    _loadProfiles();
    _loadCommandHistory();
    // Create the default local session as a lightweight placeholder only. The
    // heavy part (booting proot/Alpine via flutter_pty) is deferred until the
    // user first opens the terminal/explorer tab, so the app reaches the
    // connections screen without paying for the shell up front.
    createNewSession(lazy: true);
    // Keep the process alive in the background (Termux-style) so shells survive
    // when the app is minimized. No-op on platforms other than Android. Deferred
    // to the first frame so the native MethodChannel handler is registered.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      BackgroundService.start();
    });
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();

    final modeIndex = prefs.getInt(_kThemeMode);
    if (modeIndex != null &&
        modeIndex >= 0 &&
        modeIndex < ThemeMode.values.length) {
      _themeMode = ThemeMode.values[modeIndex];
    }

    final fontSize = prefs.getDouble(_kTerminalFontSize);
    if (fontSize != null) {
      _terminalFontSize =
          fontSize.clamp(minTerminalFontSize, maxTerminalFontSize);
    }

    final mdScale = prefs.getDouble(_kMarkdownScale);
    if (mdScale != null) {
      _markdownScale = mdScale.clamp(minMarkdownScale, maxMarkdownScale);
    }

    final distroId = prefs.getString(_kActiveDistro);
    if (distroId != null && DistroService.byId(distroId).id == distroId) {
      _activeDistroId = distroId;
    }

    notifyListeners();
    refreshDistroStatus();
  }

  /// Recompute which distros are installed on disk (drives the Settings list).
  Future<void> refreshDistroStatus() async {
    for (final d in DistroService.catalog) {
      _distroInstalled[d.id] = await DistroService.isInstalled(d);
    }
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kThemeMode, mode.index);
  }

  Future<void> setTerminalFontSize(double size) async {
    final clamped = size.clamp(minTerminalFontSize, maxTerminalFontSize);
    if (clamped == _terminalFontSize) return;
    _terminalFontSize = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kTerminalFontSize, clamped);
  }

  void bumpTerminalFontSize(double delta) =>
      setTerminalFontSize(_terminalFontSize + delta);

  // ---- Distro actions ------------------------------------------------------

  /// Download + provision [id] (Ubuntu/Debian). Reports progress through
  /// [distroProgress]/[isDistroBusy] so the Settings list can show a bar. Throws
  /// on failure so the UI can surface it; the partial install is left removed.
  Future<void> downloadDistro(String id) async {
    if (_distroBusy.contains(id)) return;
    final distro = DistroService.byId(id);
    _distroBusy.add(id);
    _distroProgress[id] = 0;
    _distroStatus[id] = 'Iniciando…';
    notifyListeners();
    try {
      await DistroService.install(
        distro,
        onStatus: (s) {
          _distroStatus[id] = s;
          notifyListeners();
        },
        onProgress: (p) {
          _distroProgress[id] = p;
          notifyListeners();
        },
      );
      _distroInstalled[id] = true;
    } catch (e) {
      // Leave nothing half-installed behind.
      await DistroService.remove(distro);
      _distroInstalled[id] = false;
      rethrow;
    } finally {
      _distroBusy.remove(id);
      _distroProgress.remove(id);
      _distroStatus.remove(id);
      notifyListeners();
    }
  }

  /// Delete [id]'s rootfs to free space. Refuses to delete the active distro.
  Future<void> deleteDistro(String id) async {
    if (id == _activeDistroId || _distroBusy.contains(id)) return;
    _distroBusy.add(id);
    notifyListeners();
    try {
      await DistroService.remove(DistroService.byId(id));
      _distroInstalled[id] = false;
    } finally {
      _distroBusy.remove(id);
      notifyListeners();
    }
  }

  /// Make [id] the distro the local terminal launches into. Persists the choice
  /// and restarts every local (non-SSH) session in place so they pick it up.
  Future<void> setActiveDistro(String id) async {
    if (id == _activeDistroId) return;
    if (!(_distroInstalled[id] ?? false)) return; // must be installed first
    _activeDistroId = id;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kActiveDistro, id);

    // Restart already-running local shells so the new userland takes effect
    // immediately. Sessions that were never started (lazy) will pick up the new
    // active distro when they first boot, so leave them untouched.
    for (final session in _sessions) {
      if (session.started &&
          session.activeProfile == null &&
          session.connectionStatus != ConnectionStatus.remote) {
        session.localPty?.kill();
        session.terminal
            .write('\r\n\x1B[2mCambiando a ${activeDistro.name}…\x1B[0m\r\n');
        _initLocalSession(session);
      }
    }
  }

  // Create a new terminal session.
  //
  // When [lazy] is true the session object is created and made active but its
  // shell is NOT spawned — used for the initial local session so app startup
  // doesn't boot proot/Alpine. The shell starts on the first
  // [ensureActiveSessionStarted] call (when the terminal/explorer tab opens).
  // [lazy] is ignored for profile (SSH) sessions, which the user opens
  // intentionally and expects to connect right away.
  void createNewSession({ConnectionProfile? profile, bool lazy = false}) {
    final String id = const Uuid().v4();
    final Terminal terminal = Terminal(maxLines: 10000);

    String name;
    if (profile != null) {
      name = profile.name;
    } else {
      int localCount = _sessions.where((s) => s.activeProfile == null).length;
      name = 'Local ${localCount + 1}';
    }

    final session = TerminalSession(
      id: id,
      name: name,
      terminal: terminal,
      connectionStatus: ConnectionStatus.disconnected,
      activeProfile: profile,
      currentPath: '',
    );

    _sessions.add(session);
    _activeSessionIndex = _sessions.length - 1;
    notifyListeners();

    if (profile != null) {
      _connectSessionToSSH(session, profile);
    } else if (!lazy) {
      _initLocalSession(session);
    }
  }

  /// Boots the active session's local shell if it hasn't been started yet.
  /// No-op for sessions that are already running or are SSH profiles (those
  /// connect on creation). This is the lazy-init entry point for the default
  /// local session, called when the user first opens the terminal/explorer tab.
  void ensureActiveSessionStarted() {
    final session = activeSession;
    if (session == null || session.started || session.activeProfile != null) {
      return;
    }
    _initLocalSession(session);
  }

  // Initialize a local PTY session
  Future<void> _initLocalSession(TerminalSession session) async {
    try {
      // Mark started up front so a concurrent ensureActiveSessionStarted (e.g.
      // tapping terminal then explorer quickly) can't spawn a second shell.
      session.started = true;
      _disposeWriters(session);
      session.connectionStatus = ConnectionStatus.local;

      session.terminal.write('Iniciando terminal local...\r\n');

      // What we ultimately hand to flutter_pty.
      String executable;
      List<String> arguments = const [];
      String workingDir = Directory.current.path;
      final environment = <String, String>{
        'TERM': 'xterm-256color',
        'LANG': 'en_US.UTF-8',
      };

      if (Platform.isAndroid) {
        // On Android the "local terminal" is a full Linux userland (the active
        // distro) running under proot — that's what gives a real package
        // manager and a normal filesystem instead of the bare system shell.
        final distro = activeDistro;
        try {
          if (!await DistroService.isInstalled(distro)) {
            session.terminal.write(
                '\r\nPrimer arranque: instalando entorno Linux (${distro.name})...\r\n');
            await DistroService.install(distro, log: session.terminal.write);
            _distroInstalled[distro.id] = true;
          }
          final launch = await DistroService.launch(distro);
          executable = launch.executable;
          arguments = launch.arguments;
          workingDir = launch.workingDirectory;
          environment.addAll(launch.environment);
        } catch (e) {
          // Provisioning/launch failed — fall back to Android's system shell so
          // the user still has *a* terminal, and surface why.
          session.terminal.write(
              '\r\nNo se pudo iniciar el entorno Linux ($e).\r\n'
              'Usando el shell del sistema como respaldo.\r\n\r\n');
          executable = '/system/bin/sh';
          environment['PATH'] =
              '/system/bin:/system/xbin:/vendor/bin:/product/bin';
          try {
            final docsDir = await getApplicationDocumentsDirectory();
            workingDir = docsDir.path;
            environment['HOME'] = docsDir.path;
            environment['TMPDIR'] = docsDir.path;
          } catch (_) {}
        }
      } else {
        // Desktop (Linux/Windows): spawn the host shell directly.
        if (Platform.isWindows) {
          executable = 'cmd.exe';
        } else if (File('/bin/bash').existsSync()) {
          executable = '/bin/bash';
        } else {
          executable = '/bin/sh';
        }
        try {
          final docsDir = await getApplicationDocumentsDirectory();
          workingDir = docsDir.path;
          environment['HOME'] = docsDir.path;
          environment['TMPDIR'] = docsDir.path;
        } catch (_) {}
      }

      session.localPty = Pty.start(
        executable,
        arguments: arguments,
        workingDirectory: workingDir,
        environment: environment,
      );

      final writer = _TerminalWriter(session.terminal);
      session._outputWriters.add(writer);
      session.localPty!.output.listen(writer.add);

      session.terminal.onOutput = (data) {
        session.localPty!.write(utf8.encode(_applyCtrlModifier(data)));
      };

      // Keep the PTY's window size in sync with the rendered terminal so
      // programs (vim, claude, etc.) wrap lines at the real column count.
      // xterm reports (cols, rows); flutter_pty expects (rows, cols).
      session.terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        session.localPty?.resize(height, width);
      };
      session.localPty!.resize(
          session.terminal.viewHeight, session.terminal.viewWidth);

      session.currentPath = workingDir;
      if (activeSession == session) {
        _loadFiles();
      } else {
        _loadFilesForSession(session);
      }

      notifyListeners();
    } catch (e) {
      session.terminal.write('\r\nError al iniciar terminal local: $e\r\n\r\n');
      if (Platform.isAndroid) {
        session.terminal.write('⚠️ NOTA SOBRE ANDROID:\r\n');
        session.terminal.write('Por motivos de seguridad (SELinux), Android bloquea la creación de\r\n');
        session.terminal.write('terminales locales (acceso a /dev/ptmx o /system/bin/sh) en aplicaciones estándar.\r\n');
        session.terminal.write('Usa la pestaña de "Conexiones" para iniciar sesión en un servidor remoto por SSH.\r\n');
      } else if (Platform.isLinux) {
        session.terminal.write('⚠️ NOTA SOBRE LINUX:\r\n');
        session.terminal.write('Verifica que tu usuario tenga permisos para acceder a /dev/ptmx y /dev/pts/,\r\n');
        session.terminal.write('y que el ejecutable de shell (/bin/bash o /bin/sh) sea accesible y ejecutable.\r\n');
      }
      notifyListeners();
    }
  }

  // Load Connection Profiles. Metadata comes from shared_preferences; secrets
  // (password/privateKey) come from secure storage and are merged back in.
  // Profiles persisted by an older build still carry plaintext secrets inside
  // the prefs JSON — those are migrated to secure storage on first load.
  Future<void> _loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final profilesJson = prefs.getStringList('ssh_profiles') ?? [];

    var needsMigration = false;

    // Resolve every profile concurrently. Each profile does two Keystore reads
    // (password + private key); on Android those are slow, so reading them in
    // parallel — across profiles and across the two keys — instead of awaiting
    // one at a time keeps the connections tab from stalling at startup.
    final loaded = await Future.wait(profilesJson.map((raw) async {
      final base = ConnectionProfile.fromJson(raw);

      // Legacy entries embed the secrets directly in the prefs JSON.
      final hasLegacySecret =
          (base.password != null && base.password!.isNotEmpty) ||
              (base.privateKey != null && base.privateKey!.isNotEmpty);
      if (hasLegacySecret) {
        await SecureStore.instance.writeSecrets(
          base.id,
          password: base.password,
          privateKey: base.privateKey,
        );
        needsMigration = true;
      }

      final secrets = await Future.wait([
        SecureStore.instance.readPassword(base.id),
        SecureStore.instance.readPrivateKey(base.id),
      ]);
      return base.copyWith(
        password: secrets[0] ?? base.password,
        privateKey: secrets[1] ?? base.privateKey,
      );
    }));

    _profiles = loaded;

    // Rewrite prefs without secrets if we migrated any (or just to strip them).
    if (needsMigration) {
      await prefs.setStringList(
          'ssh_profiles', _profiles.map((p) => p.toJsonPublic()).toList());
    }
    notifyListeners();
  }

  Future<void> _persistProfiles(SharedPreferences prefs) async {
    await prefs.setStringList(
        'ssh_profiles', _profiles.map((p) => p.toJsonPublic()).toList());
  }

  Future<void> saveProfile(ConnectionProfile profile) async {
    final index = _profiles.indexWhere((p) => p.id == profile.id);
    if (index >= 0) {
      _profiles[index] = profile;
    } else {
      _profiles.add(profile);
    }
    await SecureStore.instance.writeSecrets(
      profile.id,
      password: profile.password,
      privateKey: profile.privateKey,
    );
    final prefs = await SharedPreferences.getInstance();
    await _persistProfiles(prefs);
    notifyListeners();
  }

  Future<void> deleteProfile(String id) async {
    _profiles.removeWhere((p) => p.id == id);
    await SecureStore.instance.deleteSecrets(id);
    final prefs = await SharedPreferences.getInstance();
    await _persistProfiles(prefs);
    notifyListeners();
  }

  // Connect a session to a remote SSH server
  Future<void> _connectSessionToSSH(TerminalSession session, ConnectionProfile profile) async {
    _disposeWriters(session);
    session.connectionStatus = ConnectionStatus.connecting;
    notifyListeners();

    session.terminal.write('\r\nConectando a ${profile.name} (${profile.host}:${profile.port})...\r\n');

    try {
      final socket = await SSHSocket.connect(profile.host, profile.port, timeout: const Duration(seconds: 15));
      
      session.sshClient = SSHClient(
        socket,
        username: profile.username,
        onPasswordRequest: () => profile.password ?? '',
      );

      session.terminal.write('Autenticado correctamente. Abriendo terminal shell...\r\n');

      session.sshSession = await session.sshClient!.shell(
        pty: SSHPtyConfig(
          width: session.terminal.viewWidth,
          height: session.terminal.viewHeight,
        ),
      );

      // Forward later size changes to the remote PTY. xterm and
      // resizeTerminal both use (width=cols, height=rows) order.
      session.terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        session.sshSession?.resizeTerminal(width, height, pixelWidth, pixelHeight);
      };

      session.connectionStatus = ConnectionStatus.remote;

      await _setupForwards(session, profile);

      // Separate batched writers for stdout/stderr: each keeps its own UTF-8
      // decoder so a multi-byte glyph split across packets is reassembled
      // instead of mangled, and bursts are coalesced into one write per frame.
      final stdoutWriter = _TerminalWriter(session.terminal);
      final stderrWriter = _TerminalWriter(session.terminal);
      session._outputWriters.addAll([stdoutWriter, stderrWriter]);
      session.sshSession!.stdout.listen(stdoutWriter.add);
      session.sshSession!.stderr.listen(stderrWriter.add);

      session.terminal.onOutput = (data) {
        session.sshSession!.write(utf8.encode(_applyCtrlModifier(data)));
      };

      session.currentPath = '.';
      if (activeSession == session) {
        await _loadFiles();
      } else {
        await _loadFilesForSession(session);
      }

      notifyListeners();
    } catch (e) {
      session.connectionStatus = ConnectionStatus.disconnected;
      session.terminal.write('\r\nError de conexión: $e\r\n');
      notifyListeners();
    }
  }

  // Sets up the local port-forwards (`ssh -L`) declared on the profile.
  Future<void> _setupForwards(
      TerminalSession session, ConnectionProfile profile) async {
    for (final fwd in profile.forwards) {
      try {
        final server = await ServerSocket.bind(
            InternetAddress.loopbackIPv4, fwd.bindPort);
        session.forwardServers.add(server);
        server.listen((socket) async {
          try {
            final forward =
                await session.sshClient!.forwardLocal(fwd.remoteHost, fwd.remotePort);
            forward.stream.cast<List<int>>().pipe(socket);
            socket.cast<List<int>>().pipe(forward.sink);
          } catch (_) {
            socket.destroy();
          }
        });
        session.terminal.write(
            'Túnel activo: localhost:${fwd.bindPort} → ${fwd.remoteHost}:${fwd.remotePort}\r\n');
      } catch (e) {
        session.terminal.write(
            'No se pudo abrir el túnel en el puerto ${fwd.bindPort}: $e\r\n');
      }
    }
  }

  // Connect to Remote SSH (API exposed to ConnectionsTab)
  Future<void> connectToSSH(ConnectionProfile profile) async {
    createNewSession(profile: profile);
    _activeTabIndex = 1; // Switch to terminal tab
    notifyListeners();
  }

  // Switch to an open session
  void switchSession(int index) {
    if (index < 0 || index >= _sessions.length) return;
    _activeSessionIndex = index;
    // Switching sessions happens from the terminal UI, so a deferred local
    // session being switched to should boot now (it also kicks off _loadFiles).
    ensureActiveSessionStarted();
    notifyListeners();
    _loadFiles();
  }

  // Close an open session
  void closeSession(int index) {
    if (index < 0 || index >= _sessions.length) return;
    final session = _sessions[index];
    _cleanupSession(session);
    _sessions.removeAt(index);

    if (_sessions.isEmpty) {
      _activeSessionIndex = -1;
      createNewSession(); // Ensure there is always at least one session
    } else {
      if (_activeSessionIndex >= _sessions.length) {
        _activeSessionIndex = _sessions.length - 1;
      }
      notifyListeners();
      _loadFiles();
    }
  }

  // Rename an open session
  void renameSession(int index, String newName) {
    if (index < 0 || index >= _sessions.length) return;
    if (newName.trim().isNotEmpty) {
      _sessions[index].name = newName.trim();
      notifyListeners();
    }
  }

  // Disconnect active session (reverts to local shell)
  void disconnect() {
    final session = activeSession;
    if (session == null) return;
    
    _cleanupSession(session);
    int localCount = _sessions.where((s) => s.activeProfile == null).length;
    session.name = 'Local ${localCount + 1}';
    _initLocalSession(session);
  }

  // Flush and tear down a session's batched output writers (cancels their
  // pending flush timers so no work is scheduled after teardown).
  void _disposeWriters(TerminalSession session) {
    for (final writer in session._outputWriters) {
      writer.dispose();
    }
    session._outputWriters.clear();
  }

  void _cleanupSession(TerminalSession session) {
    _disposeWriters(session);
    for (final server in session.forwardServers) {
      server.close();
    }
    session.forwardServers.clear();
    session.sshSession?.close();
    session.sshClient?.close();
    session.localPty?.kill();
    session.sshSession = null;
    session.sshClient = null;
    session.localPty = null;
    session.connectionStatus = ConnectionStatus.disconnected;
    session.activeProfile = null;
  }

  // ---- Sticky CTRL modifier ------------------------------------------------
  // The smart-keyboard CTRL key is a "sticky" modifier (Termux-style): tapping
  // it arms the modifier, then the next character typed — from the system
  // keyboard or a quick key — is folded into its control code (Ctrl+C == 0x03)
  // and the modifier disarms.

  bool _ctrlArmed = false;
  bool get ctrlArmed => _ctrlArmed;

  void toggleCtrl() {
    _ctrlArmed = !_ctrlArmed;
    notifyListeners();
  }

  /// If CTRL is armed, fold the first character of [data] into its control code
  /// and disarm; otherwise return [data] unchanged. Control codes are the low
  /// 5 bits of the ASCII letter (`'c' & 0x1f == 0x03`).
  String _applyCtrlModifier(String data) {
    if (!_ctrlArmed || data.isEmpty) return data;
    _ctrlArmed = false;
    notifyListeners();
    final ctrl = String.fromCharCode(data.codeUnitAt(0) & 0x1f);
    return ctrl + data.substring(1);
  }

  // ---- Command history / smart command bar ---------------------------------
  Future<void> _loadCommandHistory() async {
    final prefs = await SharedPreferences.getInstance();
    _commandHistory = prefs.getStringList(_kCommandHistory) ?? [];
    notifyListeners();
  }

  /// Sends a full command line to the active session's shell (local PTY or SSH)
  /// followed by a carriage return, and records it in the persisted history.
  /// This is the entry point used by the smart command bar; unlike
  /// [sendTerminalInput] it never folds the sticky CTRL modifier into the text.
  void submitCommand(String command) {
    final session = activeSession;
    if (session == null) return;

    final bytes = utf8.encode('$command\r');
    if (session.connectionStatus == ConnectionStatus.remote &&
        session.sshSession != null) {
      session.sshSession!.write(bytes);
    } else if (session.localPty != null) {
      session.localPty!.write(bytes);
    }

    final trimmed = command.trim();
    if (trimmed.isNotEmpty) _recordCommand(trimmed);
  }

  /// Moves [command] to the front of the history (de-duplicating), caps the
  /// list and persists it. Does not notify: the command bar recomputes its
  /// suggestions from the in-memory list on the next keystroke, and we don't
  /// want to rebuild the terminal on every command.
  void _recordCommand(String command) {
    _commandHistory.remove(command);
    _commandHistory.insert(0, command);
    if (_commandHistory.length > _maxCommandHistory) {
      _commandHistory.removeRange(_maxCommandHistory, _commandHistory.length);
    }
    SharedPreferences.getInstance().then(
        (prefs) => prefs.setStringList(_kCommandHistory, _commandHistory));
  }

  // Send input directly to terminal
  void sendTerminalInput(String text) {
    final session = activeSession;
    if (session == null) return;
    final out = _applyCtrlModifier(text);
    if (session.connectionStatus == ConnectionStatus.remote && session.sshSession != null) {
      session.sshSession!.write(utf8.encode(out));
    } else if (session.connectionStatus == ConnectionStatus.local && session.localPty != null) {
      session.localPty!.write(utf8.encode(out));
    }
  }

  // File Explorer Operations
  Future<void> changeDirectory(String newPath) async {
    final session = activeSession;
    if (session == null) return;
    session.currentPath = newPath;
    await _loadFiles();
  }

  Future<void> navigateUp() async {
    final session = activeSession;
    if (session == null) return;
    
    if (session.connectionStatus == ConnectionStatus.remote) {
      if (session.currentPath == '.' || session.currentPath == '/') return;
      final parts = session.currentPath.split('/');
      parts.removeLast();
      session.currentPath = parts.isEmpty ? '/' : parts.join('/');
      if (session.currentPath.isEmpty) session.currentPath = '/';
    } else {
      final dir = Directory(session.currentPath);
      final parent = dir.parent;
      if (parent.path != session.currentPath) {
        session.currentPath = parent.path;
      }
    }
    await _loadFiles();
  }

  Future<void> _loadFiles() async {
    final session = activeSession;
    if (session == null) return;
    await _loadFilesForSession(session);
    notifyListeners();
  }

  Future<void> _loadFilesForSession(TerminalSession session) async {
    session.isLoadingFiles = true;
    // Surface the loading state right away so the explorer can show its spinner
    // while the listing (especially a slow SFTP `listdir`) is in flight. Only
    // the active session drives the explorer, so don't rebuild for the others.
    if (activeSession == session) notifyListeners();
    // Build into a fresh list and assign it at the end, so consumers that
    // compare by reference (the explorer's Selector) detect the change.
    final loaded = <FileSystemEntityInfo>[];

    try {
      if (session.connectionStatus == ConnectionStatus.remote && session.sshClient != null) {
        final sftp = await session.sshClient!.sftp();
        final list = await sftp.listdir(session.currentPath);

        for (final item in list) {
          if (item.filename == '.' || item.filename == '..') continue;

          final isDir = item.attr.isDirectory;
          loaded.add(FileSystemEntityInfo(
            name: item.filename,
            path: '${session.currentPath}/${item.filename}'.replaceAll('//', '/'),
            isDirectory: isDir,
            size: item.attr.size ?? 0,
            modified: DateTime.fromMillisecondsSinceEpoch((item.attr.modifyTime ?? 0) * 1000),
          ));
        }
      } else {
        // Local Filesystem
        final dir = Directory(session.currentPath);
        if (await dir.exists()) {
          final list = dir.listSync();
          for (final entity in list) {
            final stat = entity.statSync();
            final name = entity.path.split(Platform.pathSeparator).last;
            loaded.add(FileSystemEntityInfo(
              name: name,
              path: entity.path,
              isDirectory: entity is Directory,
              size: stat.size,
              modified: stat.modified,
            ));
          }
        }
      }

      loaded.sort((a, b) {
        if (a.isDirectory && !b.isDirectory) return -1;
        if (!a.isDirectory && b.isDirectory) return 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    } catch (e) {
      // Don't pollute the terminal with explorer errors (e.g. navigating up
      // into directories Android won't let the app read). The file list just
      // stays empty; surface it only to the debug log.
      debugPrint('Error al cargar archivos: $e');
    } finally {
      session.files = loaded;
      session.isLoadingFiles = false;
    }
  }

  // Text Editor Operations
  Future<void> openFile(FileSystemEntityInfo file) async {
    if (file.isDirectory) return;

    final session = activeSession;
    if (session == null) return;

    final isRemote = (session.connectionStatus == ConnectionStatus.remote);
    final sshClient = session.sshClient;
    session.isLoadingFiles = true;
    notifyListeners();

    try {
      // Read the content *before* updating _editingFilePath so the editor only
      // rebuilds (and initializes its controller) once the content is ready.
      // Otherwise the editor inits with empty content and never refreshes.
      if (isPdfPath(file.path)) {
        // PDFs are read as raw bytes and handed to the embedded viewer; there
        // is no text content or editing involved.
        final Uint8List bytes;
        if (isRemote && sshClient != null) {
          final sftp = await sshClient.sftp();
          final fileStream =
              await sftp.open(file.path, mode: SftpFileOpenMode.read);
          bytes = await fileStream.readBytes();
        } else {
          bytes = await File(file.path).readAsBytes();
        }
        _viewingPdfBytes = bytes;
        _editingFileContent = '';
        _isMarkdownPreview = false;
      } else {
        final String content;
        if (isRemote && sshClient != null) {
          final sftp = await sshClient.sftp();
          final fileStream =
              await sftp.open(file.path, mode: SftpFileOpenMode.read);
          final bytes = await fileStream.readBytes();
          content = utf8.decode(bytes, allowMalformed: true);
        } else {
          final localFile = File(file.path);
          content = await localFile.readAsString();
        }
        _viewingPdfBytes = null;
        _editingFileContent = content;
        // Markdown files open in the formatted preview by default; everything
        // else goes straight to the raw code editor.
        _isMarkdownPreview = isMarkdownPath(file.path);
      }

      _editingFilePath = file.path;
      _isEditingFileRemote = isRemote;
      _editingSshClient = sshClient;
      _isFileDirty = false;

      _activeTabIndex = 3; // Navigate to Editor Tab
    } catch (e) {
      session.terminal.write('Error al abrir archivo: $e\r\n');
    } finally {
      session.isLoadingFiles = false;
      notifyListeners();
    }
  }

  void updateFileContent(String content) {
    if (_editingFileContent == content) return;
    _editingFileContent = content;
    // The editor's own controller drives the CodeEditor surface; the only
    // observed state here is the dirty flag (save button + nav dot). Notify
    // only on the false→true transition so we don't rebuild every tab on each
    // keystroke once the file is already marked dirty.
    if (!_isFileDirty) {
      _isFileDirty = true;
      notifyListeners();
    }
  }

  Future<void> saveCurrentFile() async {
    if (_editingFilePath == null) return;
    
    final session = activeSession;
    if (session != null) {
      session.isLoadingFiles = true;
      notifyListeners();
    }

    try {
      final bytes = utf8.encode(_editingFileContent);
      if (_isEditingFileRemote && _editingSshClient != null) {
        final sftp = await _editingSshClient!.sftp();
        final fileStream = await sftp.open(
          _editingFilePath!,
          mode: SftpFileOpenMode.write | SftpFileOpenMode.create | SftpFileOpenMode.truncate,
        );
        await fileStream.write(Stream.value(bytes));
      } else {
        final localFile = File(_editingFilePath!);
        await localFile.writeAsBytes(bytes);
      }
      _isFileDirty = false;
      if (session != null) {
        session.terminal.write('Archivo guardado: ${_editingFilePath!.split("/").last}\r\n');
      }
    } catch (e) {
      if (session != null) {
        session.terminal.write('Error al guardar archivo: $e\r\n');
      }
    } finally {
      if (session != null) {
        session.isLoadingFiles = false;
        notifyListeners();
      }
    }
  }

  void closeFile() {
    _editingFilePath = null;
    _editingFileContent = '';
    _viewingPdfBytes = null;
    _isFileDirty = false;
    _editingSshClient = null;
    _activeTabIndex = 2; // Go back to files tab
    notifyListeners();
  }

  @override
  void dispose() {
    for (final session in _sessions) {
      _cleanupSession(session);
    }
    super.dispose();
  }
}

/// Coalesces a stream of raw output bytes into a small number of
/// [Terminal.write] calls.
///
/// Two wins over decoding+writing each chunk straight from the stream:
///  * A single persistent [Utf8Decoder] spans chunk boundaries, so a multi-byte
///    glyph split across two packets (common over SSH) is decoded correctly
///    instead of turning into replacement characters.
///  * Bursts of tiny packets (logs, `ls -R`, builds) are buffered and flushed
///    at most once per frame, collapsing many parse/repaint cycles into one.
class _TerminalWriter {
  final Terminal terminal;
  final StringBuffer _buffer = StringBuffer();
  late final Sink<List<int>> _decoder;
  Timer? _flushTimer;
  bool _disposed = false;

  _TerminalWriter(this.terminal) {
    _decoder = utf8.decoder.startChunkedConversion(_StringBufferSink(_buffer));
  }

  void add(List<int> data) {
    if (_disposed) return;
    _decoder.add(data);
    // Debounce to the next frame interval; cheap no-op if one is already armed.
    _flushTimer ??= Timer(const Duration(milliseconds: 16), _flush);
  }

  void _flush() {
    _flushTimer = null;
    if (_buffer.isEmpty) return;
    final text = _buffer.toString();
    _buffer.clear();
    terminal.write(text);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    _flush(); // Drain anything already decoded so no output is lost.
  }
}

/// Minimal [Sink] that appends decoded strings into a [StringBuffer].
class _StringBufferSink implements Sink<String> {
  final StringBuffer _buffer;
  _StringBufferSink(this._buffer);

  @override
  void add(String data) => _buffer.write(data);

  @override
  void close() {}
}

class FileSystemEntityInfo {
  final String name;
  final String path;
  final bool isDirectory;
  final int size;
  final DateTime modified;

  FileSystemEntityInfo({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.modified,
  });
}
