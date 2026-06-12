import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:uuid/uuid.dart';
import '../models/connection_profile.dart';

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
  List<ServerSocket> forwardServers;

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

  // Delegates for active session to maintain compatibility with other views
  Terminal get terminal => activeSession?.terminal ?? Terminal(maxLines: 10000);
  ConnectionStatus get connectionStatus => activeSession?.connectionStatus ?? ConnectionStatus.disconnected;
  ConnectionProfile? get activeProfile => activeSession?.activeProfile;
  bool get isTerminalInitialized => activeSession != null;
  String get currentPath => activeSession?.currentPath ?? '';
  List<FileSystemEntityInfo> get files => activeSession?.files ?? [];
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

  // ---- Settings State ------------------------------------------------------
  // Persisted user preferences. Keep every configurable option here so the
  // settings screen has a single source of truth.
  static const String _kThemeMode = 'settings_theme_mode';
  static const String _kTerminalFontSize = 'settings_terminal_font_size';

  static const double minTerminalFontSize = 7;
  static const double maxTerminalFontSize = 26;

  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  double _terminalFontSize = 13;
  double get terminalFontSize => _terminalFontSize;

  AppState() {
    _loadSettings();
    _loadProfiles();
    createNewSession(); // Start a local terminal by default
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

  // Create a new terminal session
  void createNewSession({ConnectionProfile? profile}) {
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
    } else {
      _initLocalSession(session);
    }
  }

  // Initialize a local PTY session
  void _initLocalSession(TerminalSession session) {
    try {
      session.connectionStatus = ConnectionStatus.local;
      
      session.terminal.write('Iniciando terminal local...\r\n');

      String shell = '/bin/sh';
      if (Platform.isWindows) {
        shell = 'cmd.exe';
      } else if (Platform.isAndroid) {
        shell = '/system/bin/sh';
      } else if (File('/bin/bash').existsSync()) {
        shell = '/bin/bash';
      } else if (File('/bin/sh').existsSync()) {
        shell = '/bin/sh';
      }
      
      session.localPty = Pty.start(
        shell,
        environment: {
          'TERM': 'xterm-256color',
          'LANG': 'en_US.UTF-8',
        },
      );

      session.localPty!.output.listen((data) {
        session.terminal.write(utf8.decode(data, allowMalformed: true));
      });

      session.terminal.onOutput = (data) {
        session.localPty!.write(utf8.encode(data));
      };

      // Keep the PTY's window size in sync with the rendered terminal so
      // programs (vim, claude, etc.) wrap lines at the real column count.
      // xterm reports (cols, rows); flutter_pty expects (rows, cols).
      session.terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        session.localPty?.resize(height, width);
      };
      session.localPty!.resize(
          session.terminal.viewHeight, session.terminal.viewWidth);

      getApplicationDocumentsDirectory().then((dir) {
        session.currentPath = dir.path;
        if (activeSession == session) {
          _loadFiles();
        } else {
          _loadFilesForSession(session);
        }
      });

      notifyListeners();
    } catch (e) {
      session.terminal.write('Error al iniciar terminal local: $e\r\n');
      notifyListeners();
    }
  }

  // Load Connection Profiles from Local Storage
  Future<void> _loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final profilesJson = prefs.getStringList('ssh_profiles') ?? [];
    _profiles = profilesJson.map((json) => ConnectionProfile.fromJson(json)).toList();
    notifyListeners();
  }

  Future<void> saveProfile(ConnectionProfile profile) async {
    final index = _profiles.indexWhere((p) => p.id == profile.id);
    if (index >= 0) {
      _profiles[index] = profile;
    } else {
      _profiles.add(profile);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('ssh_profiles', _profiles.map((p) => p.toJson()).toList());
    notifyListeners();
  }

  Future<void> deleteProfile(String id) async {
    _profiles.removeWhere((p) => p.id == id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('ssh_profiles', _profiles.map((p) => p.toJson()).toList());
    notifyListeners();
  }

  // Connect a session to a remote SSH server
  Future<void> _connectSessionToSSH(TerminalSession session, ConnectionProfile profile) async {
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

      session.sshSession!.stdout.listen((data) {
        session.terminal.write(utf8.decode(data, allowMalformed: true));
      });
      session.sshSession!.stderr.listen((data) {
        session.terminal.write(utf8.decode(data, allowMalformed: true));
      });

      session.terminal.onOutput = (data) {
        session.sshSession!.write(utf8.encode(data));
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

  void _cleanupSession(TerminalSession session) {
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

  // Send input directly to terminal
  void sendTerminalInput(String text) {
    final session = activeSession;
    if (session == null) return;
    if (session.connectionStatus == ConnectionStatus.remote && session.sshSession != null) {
      session.sshSession!.write(utf8.encode(text));
    } else if (session.connectionStatus == ConnectionStatus.local && session.localPty != null) {
      session.localPty!.write(utf8.encode(text));
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
    session.files.clear();

    try {
      if (session.connectionStatus == ConnectionStatus.remote && session.sshClient != null) {
        final sftp = await session.sshClient!.sftp();
        final list = await sftp.listdir(session.currentPath);
        
        for (final item in list) {
          if (item.filename == '.' || item.filename == '..') continue;
          
          final isDir = item.attr.isDirectory;
          session.files.add(FileSystemEntityInfo(
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
            session.files.add(FileSystemEntityInfo(
              name: name,
              path: entity.path,
              isDirectory: entity is Directory,
              size: stat.size,
              modified: stat.modified,
            ));
          }
        }
      }
      
      session.files.sort((a, b) {
        if (a.isDirectory && !b.isDirectory) return -1;
        if (!a.isDirectory && b.isDirectory) return 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    } catch (e) {
      session.terminal.write('Error al cargar archivos: $e\r\n');
    } finally {
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
      final String content;
      if (isRemote && sshClient != null) {
        final sftp = await sshClient.sftp();
        final fileStream = await sftp.open(file.path, mode: SftpFileOpenMode.read);
        final bytes = await fileStream.readBytes();
        content = utf8.decode(bytes, allowMalformed: true);
      } else {
        final localFile = File(file.path);
        content = await localFile.readAsString();
      }

      _editingFileContent = content;
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
    if (_editingFileContent != content) {
      _editingFileContent = content;
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
