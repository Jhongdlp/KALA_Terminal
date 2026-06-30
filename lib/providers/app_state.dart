import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:uuid/uuid.dart';
import '../models/connection_profile.dart';
import '../theme/app_theme.dart';
import '../services/background_service.dart';
import '../services/distro_service.dart';
import '../services/secure_store.dart';

enum ConnectionStatus { disconnected, connecting, local, remote }

/// Type filter applied by the explorer's filter button.
enum FileTypeFilter { all, folders, filesOnly }

class TerminalSession {
  final String id;
  String name;
  final Terminal terminal;
  ConnectionStatus connectionStatus;
  ConnectionProfile? activeProfile;
  SSHClient? sshClient;
  SSHSession? sshSession;
  Pty? localPty;
  // Which Linux distro this local session's proot guest runs. Each terminal can
  // run a different distro (see [AppState.createNewSession]); SSH sessions
  // ignore it. Read by [_initLocalSession] when the shell boots.
  String distroId;
  String currentPath;
  // Stack of previously visited directories for this session's explorer, used
  // by [AppState.navigateBack]. Pushed in [AppState.changeDirectory] and
  // [AppState.navigateUp] right before the path changes.
  List<String> pathHistory = [];
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
    this.distroId = DistroService.defaultDistroId,
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

  // Whether the terminal is in fullscreen mode. Lives here (not in TerminalTab)
  // so the shell's top navigation bar can hide itself while it's on.
  bool _terminalFullscreen = false;
  bool get terminalFullscreen => _terminalFullscreen;

  void setTerminalFullscreen(bool value) {
    if (_terminalFullscreen == value) return;
    _terminalFullscreen = value;
    notifyListeners();
  }

  /// Handle the system back gesture/button: step back one level inside the app
  /// instead of letting Android close the activity. Returns true when the
  /// event was consumed; false means we're already at the root (connections
  /// tab) and the caller decides whether to exit.
  bool handleBackNavigation() {
    // Editor with an open file → close it (lands on the files tab).
    if (_activeTabIndex == 3 && _editingFilePath != null) {
      closeFile();
      return true;
    }
    // Explorer with an active selection → just drop the selection.
    if (_activeTabIndex == 2 && _selectedPaths.isNotEmpty) {
      clearSelection();
      return true;
    }
    // Explorer: step back in history if we have history.
    if (_activeTabIndex == 2 && canNavigateBack) {
      navigateBack();
      return true;
    }
    // Explorer, opt-in: step up one folder until we reach the root, then fall
    // through to the normal tab/exit behaviour.
    if (_activeTabIndex == 2 && _backGestureNavigatesFolders && canNavigateUp) {
      navigateUp();
      return true;
    }
    // Any other tab → back to the connections (home) tab.
    if (_activeTabIndex != 0) {
      setActiveTabIndex(0);
      return true;
    }
    return false;
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
  bool get canNavigateBack =>
      activeSession?.pathHistory.isNotEmpty ?? false;
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

  // ---- Markdown / SVG preview ----------------------------------------------
  // When the open file is markdown (or SVG) the editor tab can render a
  // formatted preview instead of the raw code editor. [_isPreviewMode] tracks
  // which mode is showing; [_markdownScale] is a persisted zoom multiplier
  // driven by the +/- buttons in the markdown preview header (SVG zooms via
  // pinch/drag in its own viewer instead).
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

  bool _isPreviewMode = false;
  bool get isPreviewMode => _isPreviewMode;

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

  // ---- Image viewer ----------------------------------------------------------
  // Images open in an embedded viewer on the editor tab. Raster formats
  // (PNG/JPG/…) are read as raw bytes — same scheme as the PDF viewer so local
  // and SFTP files share one path — and are view-only. SVG is text: it loads
  // through the normal editor path and toggles between a rendered preview and
  // the raw code editor, exactly like markdown.
  static const Set<String> _imageExtensions = {
    '.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.svg'
  };

  /// Whether [path] should open in the image viewer (by extension).
  static bool isImagePath(String path) {
    final lower = path.toLowerCase();
    return _imageExtensions.any((ext) => lower.endsWith(ext));
  }

  /// SVGs are images but also editable text — they open in preview mode with
  /// an "Editar" toggle instead of the bytes-only viewer.
  static bool isSvgPath(String path) => path.toLowerCase().endsWith('.svg');

  bool get isEditingFileSvg =>
      _editingFilePath != null && isSvgPath(_editingFilePath!);

  Uint8List? _viewingImageBytes;
  Uint8List? get viewingImageBytes => _viewingImageBytes;
  bool get isViewingImage =>
      _editingFilePath != null && _viewingImageBytes != null;

  // ---- Video / audio player --------------------------------------------------
  // Video and audio open in an embedded media_kit player on the editor tab.
  // Local files are played directly from their path; SFTP files have no local
  // path, so they are downloaded to a temp file first (cleaned up on close or
  // when another file is opened).
  static const Set<String> _videoExtensions = {
    '.mp4', '.mkv', '.mov', '.avi', '.webm', '.m4v', '.flv', '.3gp', '.wmv'
  };
  static const Set<String> _audioExtensions = {
    '.mp3', '.wav', '.ogg', '.m4a', '.flac', '.aac', '.opus', '.wma'
  };

  /// Whether [path] should open in the video player (by extension).
  static bool isVideoPath(String path) {
    final lower = path.toLowerCase();
    return _videoExtensions.any((ext) => lower.endsWith(ext));
  }

  /// Whether [path] should open in the audio player (by extension).
  static bool isAudioPath(String path) {
    final lower = path.toLowerCase();
    return _audioExtensions.any((ext) => lower.endsWith(ext));
  }

  String? _viewingMediaPath;
  String? get viewingMediaPath => _viewingMediaPath;
  // Local copy of a remote media file downloaded for playback; deleted once
  // it's no longer needed.
  File? _tempMediaFile;
  bool get isViewingVideo =>
      _editingFilePath != null &&
      _viewingMediaPath != null &&
      isVideoPath(_editingFilePath!);
  bool get isViewingAudio =>
      _editingFilePath != null &&
      _viewingMediaPath != null &&
      isAudioPath(_editingFilePath!);

  void _disposeTempMediaFile() {
    final temp = _tempMediaFile;
    _tempMediaFile = null;
    if (temp != null) {
      temp.delete().catchError((_) => temp);
    }
  }

  double _markdownScale = 1.0;
  double get markdownScale => _markdownScale;

  void setPreviewMode(bool preview) {
    if (_isPreviewMode == preview) return;
    _isPreviewMode = preview;
    notifyListeners();
  }

  void togglePreviewMode() => setPreviewMode(!_isPreviewMode);

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
  // Persisted as the enum index. Old builds stored a ThemeMode index here
  // (system=0/light=1/dark=2); those line up 1:1 with the first three
  // AppThemeChoice values, so existing preferences migrate transparently.
  static const String _kThemeMode = 'settings_theme_mode';
  static const String _kTerminalFontSize = 'settings_terminal_font_size';
  static const String _kEditorFontSize = 'settings_editor_font_size';
  static const String _kActiveDistro = 'active_distro';
  static const String _kTerminalScheme = 'settings_terminal_scheme';
  static const String _kIconScale = 'settings_icon_scale';
  static const String _kBackGestureFolders = 'settings_back_gesture_folders';

  static const double minTerminalFontSize = 7;
  static const double maxTerminalFontSize = 26;

  static const double minEditorFontSize = 8;
  static const double maxEditorFontSize = 30;

  AppThemeChoice _themeChoice = AppThemeChoice.system;
  AppThemeChoice get themeChoice => _themeChoice;

  AppIconScale _iconScale = AppIconScale.small;
  AppIconScale get iconScale => _iconScale;
  double get uiIconFactor => switch (_iconScale) {
        AppIconScale.small => 1.0,
        AppIconScale.medium => 1.25,
        AppIconScale.large => 1.5,
      };

  double _terminalFontSize = 13;
  double get terminalFontSize => _terminalFontSize;

  // Code editor font size, adjusted by the +/- buttons in the editor header.
  double _editorFontSize = 13;
  double get editorFontSize => _editorFontSize;

  // Terminal color scheme id ('auto' follows the app theme; otherwise one of
  // AppTerminalTheme.schemes). The terminal view resolves it via
  // AppTerminalTheme.byId.
  String _terminalScheme = 'auto';
  String get terminalScheme => _terminalScheme;

  // When true, the system back gesture/button steps up one folder in the file
  // explorer (instead of jumping straight back to the connections tab). Off by
  // default because deep trees would need many back presses to leave the tab.
  bool _backGestureNavigatesFolders = false;
  bool get backGestureNavigatesFolders => _backGestureNavigatesFolders;

  /// Whether the active session's explorer can still step up a level (i.e. it
  /// isn't already at the filesystem root). Used by back navigation.
  bool get canNavigateUp {
    final session = activeSession;
    if (session == null) return false;
    if (session.connectionStatus == ConnectionStatus.remote) {
      return session.currentPath != '.' && session.currentPath != '/';
    }
    final dir = Directory(session.currentPath);
    return dir.parent.path != session.currentPath;
  }

  // ---- Linux distro selector ----------------------------------------------
  // The local Android terminal runs inside a proot'd Linux userland. Alpine is
  // bundled (instant); Ubuntu/Debian are downloaded on demand. Each terminal
  // session carries its own [TerminalSession.distroId], so different tabs can
  // run different distros at once. [_defaultDistroId] is just the one a *new*
  // local terminal starts with — it tracks the last distro the user opened.
  // The maps track per-distro UI state (installed? downloading? at what %?).
  String _defaultDistroId = DistroService.defaultDistroId;
  String get defaultDistroId => _defaultDistroId;
  Distro get defaultDistro => DistroService.byId(_defaultDistroId);

  List<Distro> get distroCatalog => DistroService.catalog;

  final Map<String, bool> _distroInstalled = {};
  final Map<String, double> _distroProgress = {}; // 0..1 while downloading
  final Map<String, String> _distroStatus = {}; // current phase text
  final Set<String> _distroBusy = {}; // installing/deleting in flight

  bool isDistroInstalled(String id) => _distroInstalled[id] ?? false;
  bool isDistroBusy(String id) => _distroBusy.contains(id);
  double? distroProgress(String id) => _distroProgress[id];
  String? distroStatus(String id) => _distroStatus[id];

  AppState() {
    _loadSettings();
    _loadProfiles();
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
        modeIndex < AppThemeChoice.values.length) {
      _themeChoice = AppThemeChoice.values[modeIndex];
    }

    final fontSize = prefs.getDouble(_kTerminalFontSize);
    if (fontSize != null) {
      _terminalFontSize =
          fontSize.clamp(minTerminalFontSize, maxTerminalFontSize);
    }

    final editorFontSize = prefs.getDouble(_kEditorFontSize);
    if (editorFontSize != null) {
      _editorFontSize =
          editorFontSize.clamp(minEditorFontSize, maxEditorFontSize);
    }

    final mdScale = prefs.getDouble(_kMarkdownScale);
    if (mdScale != null) {
      _markdownScale = mdScale.clamp(minMarkdownScale, maxMarkdownScale);
    }

    final distroId = prefs.getString(_kActiveDistro);
    if (distroId != null && DistroService.byId(distroId).id == distroId) {
      _defaultDistroId = distroId;
      // The initial local session is created (lazily) in the constructor before
      // this runs, so it was stamped with the fallback default. Re-point any
      // not-yet-booted local session at the persisted choice so the first
      // terminal opens into the distro the user last used.
      for (final s in _sessions) {
        if (!s.started && s.activeProfile == null) s.distroId = _defaultDistroId;
      }
    }

    final scheme = prefs.getString(_kTerminalScheme);
    if (scheme != null &&
        (scheme == 'auto' || AppTerminalTheme.schemes.containsKey(scheme))) {
      _terminalScheme = scheme;
    }

    final iconScaleIdx = prefs.getInt(_kIconScale);
    if (iconScaleIdx != null &&
        iconScaleIdx >= 0 &&
        iconScaleIdx < AppIconScale.values.length) {
      _iconScale = AppIconScale.values[iconScaleIdx];
    }

    _backGestureNavigatesFolders =
        prefs.getBool(_kBackGestureFolders) ?? false;

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

  Future<void> setIconScale(AppIconScale scale) async {
    if (_iconScale == scale) return;
    _iconScale = scale;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kIconScale, scale.index);
  }

  Future<void> setBackGestureNavigatesFolders(bool value) async {
    if (_backGestureNavigatesFolders == value) return;
    _backGestureNavigatesFolders = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBackGestureFolders, value);
  }

  Future<void> setThemeChoice(AppThemeChoice choice) async {
    if (_themeChoice == choice) return;
    _themeChoice = choice;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kThemeMode, choice.index);
  }

  /// [persist] false skips the prefs write — used by the pinch-zoom gesture,
  /// which calls this on every move and persists once on gesture end.
  Future<void> setTerminalFontSize(double size, {bool persist = true}) async {
    final clamped = size.clamp(minTerminalFontSize, maxTerminalFontSize);
    if (clamped != _terminalFontSize) {
      _terminalFontSize = clamped;
      notifyListeners();
    }
    if (!persist) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kTerminalFontSize, clamped);
  }

  Future<void> setTerminalScheme(String id) async {
    if (_terminalScheme == id) return;
    _terminalScheme = id;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTerminalScheme, id);
  }

  void bumpTerminalFontSize(double delta) =>
      setTerminalFontSize(_terminalFontSize + delta);

  Future<void> setEditorFontSize(double size) async {
    final clamped = size.clamp(minEditorFontSize, maxEditorFontSize);
    if (clamped == _editorFontSize) return;
    _editorFontSize = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kEditorFontSize, clamped);
  }

  void bumpEditorFontSize(double delta) =>
      setEditorFontSize(_editorFontSize + delta);

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

  /// True while at least one running local terminal is using distro [id], so the
  /// Settings UI can keep its rootfs from being deleted out from under a session.
  bool isDistroInUse(String id) => _sessions.any((s) =>
      s.started &&
      s.connectionStatus == ConnectionStatus.local &&
      s.distroId == id);

  /// Delete [id]'s rootfs to free space. Refuses while a running terminal still
  /// uses it. Rethrows on failure so the UI can surface it; the installed flag
  /// is recomputed from disk either way (the removal is best-effort: see
  /// [DistroService.remove], which fixes up unwritable proot dirs first).
  Future<void> deleteDistro(String id) async {
    if (_distroBusy.contains(id) || isDistroInUse(id)) return;
    _distroBusy.add(id);
    notifyListeners();
    try {
      await DistroService.remove(DistroService.byId(id));
    } finally {
      _distroInstalled[id] = await DistroService.isInstalled(DistroService.byId(id));
      _distroBusy.remove(id);
      notifyListeners();
    }
  }

  /// Remember [id] as the distro a *new* local terminal should start with (the
  /// last one the user opened). Persisted; does not touch running sessions.
  Future<void> _rememberDefaultDistro(String id) async {
    if (id == _defaultDistroId) return;
    _defaultDistroId = id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kActiveDistro, id);
  }

  // Create a new terminal session.
  //
  // When [lazy] is true the session object is created and made active but its
  // shell is NOT spawned — used for the initial local session so app startup
  // doesn't boot proot/Alpine. The shell starts on the first
  // [ensureActiveSessionStarted] call (when the terminal/explorer tab opens).
  // [lazy] is ignored for profile (SSH) sessions, which the user opens
  // intentionally and expects to connect right away.
  //
  // [distroId] picks which Linux userland a local terminal boots into; it
  // defaults to [_defaultDistroId] (the last one opened) and, when given
  // explicitly, becomes the new default. Ignored for SSH sessions.
  void createNewSession(
      {ConnectionProfile? profile, bool lazy = false, String? distroId}) {
    final String id = const Uuid().v4();
    // Bell (BEL / \a) → haptic tick, like Termux's vibrate-on-bell. No-op on
    // devices without a vibrator.
    final Terminal terminal = Terminal(
      maxLines: 10000,
      onBell: HapticFeedback.mediumImpact,
    );

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
      distroId: distroId ?? _defaultDistroId,
      currentPath: '',
    );

    _sessions.add(session);
    _activeSessionIndex = _sessions.length - 1;
    notifyListeners();

    if (profile != null) {
      _connectSessionToSSH(session, profile);
    } else {
      // Opening a local terminal with an explicit distro makes it the default
      // for the next one (and survives restarts).
      if (distroId != null) _rememberDefaultDistro(distroId);
      if (!lazy) _initLocalSession(session);
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
      // Where the file explorer should land for this session, when it differs
      // from the PTY's working directory (the proot guest's home).
      String? explorerDir;
      final environment = <String, String>{
        'TERM': 'xterm-256color',
        'LANG': 'en_US.UTF-8',
      };

      if (Platform.isAndroid) {
        // On Android the "local terminal" is a full Linux userland (this
        // session's distro) running under proot — that's what gives a real
        // package manager and a normal filesystem instead of the bare system
        // shell. Each session can run a different distro.
        final distro = DistroService.byId(session.distroId);
        try {
          if (!await DistroService.isInstalled(distro)) {
            session.terminal.write(
                '\r\nPrimer arranque: instalando entorno Linux (${distro.name})...\r\n');
            await DistroService.install(distro, log: session.terminal.write);
            _distroInstalled[distro.id] = true;
          }
          // Like Termux: with the storage permission granted, the distro can
          // bind /storage/emulated/0 and show Downloads/DCIM/... in ~.
          await _ensureStoragePermission();
          final launch = await DistroService.launch(distro);
          executable = launch.executable;
          arguments = launch.arguments;
          workingDir = launch.workingDirectory;
          explorerDir = launch.homeDirectory;
          environment.addAll(launch.environment);
          // Bridge for the guest's `open <archivo>` command (idempotent).
          _startOpenRequestWatcher();
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
        final out = _applyCtrlModifier(data);
        session.localPty!.write(utf8.encode(out));
      };

      // Keep the PTY's window size in sync with the rendered terminal so
      // programs (vim, claude, etc.) wrap lines at the real column count.
      // xterm reports (cols, rows); flutter_pty expects (rows, cols).
      session.terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        session.localPty?.resize(height, width);
      };
      session.localPty!.resize(
          session.terminal.viewHeight, session.terminal.viewWidth);

      session.currentPath = explorerDir ?? workingDir;
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

  /// Ask for the legacy storage permission (the app targets SDK 28, so the
  /// classic READ/WRITE_EXTERNAL_STORAGE dialog still grants full /sdcard
  /// access, same mechanism Termux uses). Best-effort: a denial just means the
  /// guest home has no phone-storage links until it's granted from Ajustes.
  Future<void> _ensureStoragePermission() async {
    try {
      final status = await Permission.storage.status;
      if (!status.isGranted) await Permission.storage.request();
    } catch (_) {/* plugin unavailable (tests) or user denied — continue */}
  }

  // ---- `open` command bridge (guest terminal → editor) ---------------------
  // The guest-side `open` script (see DistroService) drops one request file
  // per invocation into the shared spool dir; watching it from here turns
  // `open foo.py` typed in the local shell into the editor opening foo.py.
  StreamSubscription<FileSystemEvent>? _openRequestSub;
  Timer? _openRequestPoll;
  bool _openWatcherStarted = false;
  final Set<String> _openRequestsInFlight = {};

  Future<void> _startOpenRequestWatcher() async {
    if (_openWatcherStarted) return;
    _openWatcherStarted = true;
    try {
      final dir = Directory(await DistroService.openSpoolDir());
      // Discard requests left over from a previous run instead of replaying
      // them as surprise editor tabs.
      for (final e in dir.listSync()) {
        if (e is File) {
          try {
            e.deleteSync();
          } catch (_) {}
        }
      }
      void startPolling() {
        _openRequestPoll ??=
            Timer.periodic(const Duration(seconds: 2), (_) {
          try {
            for (final e in dir.listSync()) {
              if (e is File) _processOpenRequest(e);
            }
          } catch (_) {}
        });
      }

      try {
        _openRequestSub = dir.watch(events: FileSystemEvent.create).listen(
          (event) {
            if (!event.isDirectory) _processOpenRequest(File(event.path));
          },
          onError: (_) => startPolling(),
        );
      } catch (_) {
        // inotify unavailable on this kernel/filesystem — poll instead.
        startPolling();
      }
    } catch (e) {
      debugPrint('open-watcher: $e');
    }
  }

  Future<void> _processOpenRequest(File request) async {
    if (!_openRequestsInFlight.add(request.path)) return;
    try {
      // The create event can fire before the script finishes writing; the
      // request always ends in a newline, so retry briefly until it does.
      String raw = '';
      for (var attempt = 0; attempt < 5 && !raw.endsWith('\n'); attempt++) {
        if (attempt > 0) {
          await Future.delayed(const Duration(milliseconds: 60));
        }
        try {
          raw = await request.readAsString();
        } catch (_) {}
      }
      try {
        await request.delete();
      } catch (_) {}

      final lines = raw.trim().split('\n');
      if (lines.length < 2) return;
      final hostPath = await DistroService.guestPathToHost(
          lines[0].trim(), lines[1].trim());
      final f = File(hostPath);
      if (!await f.exists()) return;
      final stat = await f.stat();
      await openFile(
        FileSystemEntityInfo(
          name: hostPath.split('/').last,
          path: hostPath,
          isDirectory: false,
          size: stat.size,
          modified: stat.modified,
        ),
        forceLocal: true,
      );
    } finally {
      _openRequestsInFlight.remove(request.path);
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
        final out = _applyCtrlModifier(data);
        session.sshSession!.write(utf8.encode(out));
      };

      // Listen for connection loss
      session.sshClient!.done.then((_) {
        if (session.connectionStatus == ConnectionStatus.remote) {
          session.connectionStatus = ConnectionStatus.disconnected;
          session.terminal.write('\r\nConexión cerrada por el servidor.\r\n');
          notifyListeners();
        }
      }).catchError((e) {
        if (session.connectionStatus == ConnectionStatus.remote) {
          session.connectionStatus = ConnectionStatus.disconnected;
          session.terminal.write('\r\nError de conexión: $e\r\n');
          notifyListeners();
        }
      });

      try {
        final sftp = await session.sshClient!.sftp().timeout(const Duration(seconds: 5));
        try {
          session.currentPath = await sftp.absolute('.').timeout(const Duration(seconds: 5));
        } finally {
          sftp.close();
        }
      } catch (_) {
        session.currentPath = '.';
      }

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
    // The explorer's selection/search belong to the previous session's listing.
    _selectedPaths = const {};
    _fileSearchQuery = '';
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
    if (session.currentPath != newPath) {
      // Selection and search are per-directory state; keep them only when the
      // path is unchanged (the refresh button re-enters the same directory).
      _selectedPaths = const {};
      _fileSearchQuery = '';
      session.pathHistory.add(session.currentPath);
    }
    session.currentPath = newPath;
    await _loadFiles();
  }

  Future<void> navigateUp() async {
    final session = activeSession;
    if (session == null) return;

    final previousPath = session.currentPath;
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
    if (session.currentPath != previousPath) {
      session.pathHistory.add(previousPath);
    }
    _selectedPaths = const {};
    _fileSearchQuery = '';
    await _loadFiles();
  }

  /// Returns to the directory visited right before the current one (the
  /// inverse of [changeDirectory]/[navigateUp]), like a browser "back" button.
  Future<void> navigateBack() async {
    final session = activeSession;
    if (session == null || session.pathHistory.isEmpty) return;
    session.currentPath = session.pathHistory.removeLast();
    _selectedPaths = const {};
    _fileSearchQuery = '';
    await _loadFiles();
  }

  // ---- Explorer: selection, clipboard & filters -----------------------------
  // Multi-select (entered by long-pressing a row) plus a copy/move clipboard
  // and the search/type filters. The selection set is replaced — never mutated
  // in place — on every change so the explorer's `context.select` reference
  // check picks it up. The clipboard pins the SSH client it was captured from
  // (null = local), same idea as [_editingSshClient], so pasting keeps working
  // across session switches and even across local↔remote boundaries.

  Set<String> _selectedPaths = const {};
  Set<String> get selectedPaths => _selectedPaths;

  String _fileSearchQuery = '';
  String get fileSearchQuery => _fileSearchQuery;

  FileTypeFilter _fileTypeFilter = FileTypeFilter.all;
  FileTypeFilter get fileTypeFilter => _fileTypeFilter;

  List<FileSystemEntityInfo> _clipboard = const [];
  bool _clipboardIsMove = false;
  SSHClient? _clipboardSshClient;
  int get clipboardCount => _clipboard.length;
  bool get clipboardIsMove => _clipboardIsMove;

  // ---- Download state -------------------------------------------------------
  // Progress of an in-flight SSH → local download. [_downloadCurrent] and
  // [_downloadTotal] count top-level entries so the bar ticks once per item.
  // [_downloadCurrentName] is the entry name shown in the progress bar.
  bool _isDownloading = false;
  bool get isDownloading => _isDownloading;
  int _downloadCurrent = 0;
  int _downloadTotal = 0;
  int get downloadCurrent => _downloadCurrent;
  int get downloadTotal => _downloadTotal;
  String _downloadCurrentName = '';
  String get downloadCurrentName => _downloadCurrentName;

  void setFileSearchQuery(String query) {
    if (_fileSearchQuery == query) return;
    _fileSearchQuery = query;
    notifyListeners();
  }

  void setFileTypeFilter(FileTypeFilter filter) {
    if (_fileTypeFilter == filter) return;
    _fileTypeFilter = filter;
    notifyListeners();
  }

  void toggleSelected(String path) {
    final next = Set<String>.from(_selectedPaths);
    if (!next.remove(path)) next.add(path);
    _selectedPaths = next;
    notifyListeners();
  }

  void selectPaths(Iterable<String> paths) {
    _selectedPaths = {..._selectedPaths, ...paths};
    notifyListeners();
  }

  void clearSelection() {
    if (_selectedPaths.isEmpty) return;
    _selectedPaths = const {};
    notifyListeners();
  }

  List<FileSystemEntityInfo> get _selectedEntries =>
      files.where((f) => _selectedPaths.contains(f.path)).toList();

  /// Snapshot the current selection into the clipboard for a later paste.
  /// [move] decides whether pasting copies or moves the entries.
  void copySelectionToClipboard({required bool move}) {
    final session = activeSession;
    final entries = _selectedEntries;
    if (session == null || entries.isEmpty) return;
    _clipboard = entries;
    _clipboardIsMove = move;
    _clipboardSshClient = session.connectionStatus == ConnectionStatus.remote
        ? session.sshClient
        : null;
    _selectedPaths = const {};
    notifyListeners();
  }

  void clearClipboard() {
    if (_clipboard.isEmpty) return;
    _clipboard = const [];
    _clipboardSshClient = null;
    notifyListeners();
  }

  Future<void> deleteSelection() async {
    final session = activeSession;
    final entries = _selectedEntries;
    if (session == null || entries.isEmpty) return;
    _selectedPaths = const {};
    session.isLoadingFiles = true;
    notifyListeners();
    SftpClient? sftp;
    try {
      sftp = session.connectionStatus == ConnectionStatus.remote
          ? await session.sshClient!.sftp().timeout(const Duration(seconds: 5))
          : null;
      for (final entry in entries) {
        if (sftp != null) {
          await _deleteRemote(sftp, entry.path, entry.isDirectory);
        } else if (entry.isDirectory) {
          await Directory(entry.path).delete(recursive: true);
        } else {
          await File(entry.path).delete();
        }
      }
    } catch (e) {
      session.terminal.write('Error al eliminar: $e\r\n');
    } finally {
      if (sftp != null) {
        sftp.close();
      }
      await _loadFiles();
    }
  }

  // SFTP has no recursive delete: walk the tree depth-first.
  Future<void> _deleteRemote(
      SftpClient sftp, String path, bool isDirectory) async {
    if (!isDirectory) {
      await sftp.remove(path);
      return;
    }
    for (final item in await sftp.listdir(path)) {
      if (item.filename == '.' || item.filename == '..') continue;
      await _deleteRemote(sftp, '$path/${item.filename}'.replaceAll('//', '/'),
          item.attr.isDirectory);
    }
    await sftp.rmdir(path);
  }

  /// Paste the clipboard into the active session's current directory. Handles
  /// every source/destination combination (local↔local, remote↔remote, and
  /// local↔remote up/downloads). Move uses a rename fast path when source and
  /// destination share a filesystem, falling back to copy + delete.
  Future<void> pasteClipboard() async {
    final session = activeSession;
    final entries = _clipboard;
    if (session == null || entries.isEmpty) return;
    final isMove = _clipboardIsMove;
    final srcClient = _clipboardSshClient;
    final destRemote = session.connectionStatus == ConnectionStatus.remote;
    final destClient = destRemote ? session.sshClient : null;
    final sameFs = identical(srcClient, destClient);
    final sep = destRemote ? '/' : Platform.pathSeparator;

    session.isLoadingFiles = true;
    notifyListeners();
    SftpClient? srcSftp;
    SftpClient? destSftp;
    try {
      srcSftp = srcClient != null ? await srcClient.sftp().timeout(const Duration(seconds: 5)) : null;
      destSftp = destClient != null ? await destClient.sftp().timeout(const Duration(seconds: 5)) : null;

      for (final entry in entries) {
        final destPath = _childPath(session.currentPath, entry.name, sep);
        if (sameFs && destPath == entry.path) continue; // pasted in place
        if (entry.isDirectory &&
            sameFs &&
            (session.currentPath == entry.path ||
                session.currentPath.startsWith('${entry.path}$sep'))) {
          session.terminal.write(
              'No se puede pegar "${entry.name}" dentro de sí misma.\r\n');
          continue;
        }

        if (isMove && sameFs) {
          try {
            if (srcSftp != null) {
              await srcSftp.rename(entry.path, destPath);
            } else if (entry.isDirectory) {
              await Directory(entry.path).rename(destPath);
            } else {
              await File(entry.path).rename(destPath);
            }
            continue;
          } catch (_) {
            // rename can fail across mount points — fall back to copy+delete.
          }
        }

        await _copyEntry(
            srcSftp, entry.path, entry.isDirectory, destSftp, destPath);
        if (isMove) {
          if (srcSftp != null) {
            await _deleteRemote(srcSftp, entry.path, entry.isDirectory);
          } else if (entry.isDirectory) {
            await Directory(entry.path).delete(recursive: true);
          } else {
            await File(entry.path).delete();
          }
        }
      }
    } catch (e) {
      session.terminal.write('Error al pegar: $e\r\n');
    } finally {
      if (srcSftp != null) {
        srcSftp.close();
      }
      if (destSftp != null) {
        destSftp.close();
      }
      if (isMove) {
        _clipboard = const [];
        _clipboardSshClient = null;
      }
      await _loadFiles();
    }
  }

  static String _childPath(String dir, String name, String sep) =>
      dir.endsWith(sep) ? '$dir$name' : '$dir$sep$name';

  // Recursive copy between any combination of local and SFTP endpoints. File
  // contents go through memory (same approach as the editor), which is fine
  // for the sizes this explorer deals with.
  Future<void> _copyEntry(SftpClient? srcSftp, String srcPath, bool isDirectory,
      SftpClient? destSftp, String destPath) async {
    if (!isDirectory) {
      final Uint8List bytes;
      if (srcSftp != null) {
        final f = await srcSftp.open(srcPath, mode: SftpFileOpenMode.read);
        bytes = await f.readBytes();
        await f.close();
      } else {
        bytes = await File(srcPath).readAsBytes();
      }
      if (destSftp != null) {
        final f = await destSftp.open(destPath,
            mode: SftpFileOpenMode.write |
                SftpFileOpenMode.create |
                SftpFileOpenMode.truncate);
        await f.write(Stream.value(bytes));
        await f.close();
      } else {
        await File(destPath).writeAsBytes(bytes);
      }
      return;
    }

    if (destSftp != null) {
      try {
        await destSftp.mkdir(destPath);
      } catch (_) {
        // Directory may already exist.
      }
    } else {
      await Directory(destPath).create(recursive: true);
    }
    final destSep = destSftp != null ? '/' : Platform.pathSeparator;
    if (srcSftp != null) {
      for (final item in await srcSftp.listdir(srcPath)) {
        if (item.filename == '.' || item.filename == '..') continue;
        await _copyEntry(
            srcSftp,
            '$srcPath/${item.filename}'.replaceAll('//', '/'),
            item.attr.isDirectory,
            destSftp,
            _childPath(destPath, item.filename, destSep));
      }
    } else {
      for (final entity in Directory(srcPath).listSync()) {
        await _copyEntry(
            srcSftp,
            entity.path,
            entity is Directory,
            destSftp,
            _childPath(destPath,
                entity.path.split(Platform.pathSeparator).last, destSep));
      }
    }
  }

  /// Best-effort storage permission request, exposed so the UI can ensure
  /// access before opening the local folder picker (which needs to list
  /// `/storage/emulated/0` on Android). No-op off Android.
  Future<void> ensureStoragePermission() => _ensureStoragePermission();

  /// Download the selected remote or local entries to a local folder. Pass [destDir]
  /// to save to a specific directory the user chose; when null, falls back to the
  /// public Downloads folder. Progress is surfaced through [isDownloading],
  /// [downloadCurrent], [downloadTotal], and [downloadCurrentName] so the
  /// explorer can show a bar.
  Future<void> downloadSelection({String? destDir}) async {
    final session = activeSession;
    final entries = _selectedEntries;
    if (session == null || entries.isEmpty) {
      return;
    }

    // Verify remote dependencies if remote
    if (session.connectionStatus == ConnectionStatus.remote && session.sshClient == null) {
      return;
    }

    _selectedPaths = const {};
    _isDownloading = true;
    _downloadCurrent = 0;
    _downloadTotal = entries.length;
    _downloadCurrentName = '';
    notifyListeners();

    SftpClient? sftp;
    try {
      if (Platform.isAndroid) await _ensureStoragePermission();

      // Destination: the folder the user picked, or — as a fallback — the
      // public Downloads/KALA on Android, ~/Downloads/KALA elsewhere.
      final String finalDir;
      if (destDir != null) {
        finalDir = destDir;
      } else if (Platform.isAndroid) {
        finalDir = '/storage/emulated/0/Download/KALA';
      } else {
        final base = await getApplicationDocumentsDirectory();
        finalDir = '${base.path}/Downloads/KALA';
      }
      await Directory(finalDir).create(recursive: true);

      if (session.connectionStatus == ConnectionStatus.remote) {
        sftp = await session.sshClient!.sftp().timeout(const Duration(seconds: 5));
        for (final entry in entries) {
          _downloadCurrentName = entry.name;
          notifyListeners();
          await _downloadEntry(
              sftp, entry.path, entry.isDirectory, '$finalDir/${entry.name}');
          _downloadCurrent++;
          notifyListeners();
        }
      } else {
        // Local download (export files/folders from Alpine sandbox to shared storage)
        for (final entry in entries) {
          _downloadCurrentName = entry.name;
          notifyListeners();
          await _downloadEntryLocal(
              entry.path, entry.isDirectory, '$finalDir/${entry.name}');
          _downloadCurrent++;
          notifyListeners();
        }
      }

      session.terminal
          .write('✓ ${entries.length} elemento(s) descargado(s) → $finalDir\r\n');
    } catch (e) {
      activeSession?.terminal.write('Error al descargar: $e\r\n');
    } finally {
      if (sftp != null) {
        sftp.close();
      }
      _isDownloading = false;
      notifyListeners();
    }
  }

  // Recursively copy a local file or directory.
  Future<void> _downloadEntryLocal(String srcPath, bool isDirectory, String destPath) async {
    if (!isDirectory) {
      final srcFile = File(srcPath);
      if (await srcFile.exists()) {
        await srcFile.copy(destPath);
      }
      return;
    }
    await Directory(destPath).create(recursive: true);
    final srcDir = Directory(srcPath);
    if (await srcDir.exists()) {
      await for (final entity in srcDir.list(recursive: false)) {
        final name = entity.path.split('/').last;
        final isDir = entity is Directory;
        await _downloadEntryLocal(entity.path, isDir, '$destPath/$name');
      }
    }
  }

  // Recursively download a remote entry (file or directory) via SFTP.
  Future<void> _downloadEntry(SftpClient sftp, String remotePath,
      bool isDirectory, String localPath) async {
    if (!isDirectory) {
      final f = await sftp.open(remotePath, mode: SftpFileOpenMode.read);
      final bytes = await f.readBytes();
      await f.close();
      await File(localPath).writeAsBytes(bytes);
      return;
    }
    await Directory(localPath).create(recursive: true);
    for (final item in await sftp.listdir(remotePath)) {
      if (item.filename == '.' || item.filename == '..') continue;
      await _downloadEntry(
          sftp,
          '$remotePath/${item.filename}'.replaceAll('//', '/'),
          item.attr.isDirectory,
          '$localPath/${item.filename}');
    }
  }

  /// Send a `cd` into the active session's shell and jump to the terminal tab.
  ///
  /// [path] is always a **host** path (what the file explorer stores). For
  /// local sessions on Android the shell runs inside proot, so the host path
  /// must be translated to the equivalent guest path before being sent.
  Future<void> openTerminalAt(String path) async {
    final session = activeSession;
    if (session == null || path.isEmpty) return;

    String guestPath = path;
    if (Platform.isAndroid &&
        session.connectionStatus == ConnectionStatus.local) {
      guestPath = await _hostToGuestPath(path, session.distroId);
    }

    // Single-quote for the shell; embedded single quotes become '\''.
    final escaped = guestPath.replaceAll("'", "'\\''");
    final bytes = utf8.encode("cd '$escaped'\r");
    if (session.connectionStatus == ConnectionStatus.remote &&
        session.sshSession != null) {
      session.sshSession!.write(bytes);
    } else if (session.localPty != null) {
      session.localPty!.write(bytes);
    } else {
      return;
    }
    _activeTabIndex = 1;
    notifyListeners();
  }

  /// Convert a host-side path to the equivalent path inside the proot guest.
  ///
  /// proot maps three zones:
  ///   - `<rootfs>/…`        → `/…`          (the distro filesystem)
  ///   - `<sharedDir>/…`     → `/shared/…`   (cross-distro share folder)
  ///   - `/storage/…` or `/sdcard/…` → same  (bind-mounted at identical path)
  ///
  /// Anything outside those zones is returned unchanged; the shell will report
  /// "no such directory" rather than silently navigating to the wrong place.
  Future<String> _hostToGuestPath(String hostPath, String distroId) async {
    // Phone storage is bind-mounted at the same absolute path inside proot.
    if (hostPath.startsWith('/storage/') || hostPath.startsWith('/sdcard')) {
      return hostPath;
    }
    // Shared folder.
    final shared = await DistroService.sharedDir();
    if (hostPath == shared) return '/shared';
    if (hostPath.startsWith('$shared/')) {
      return '/shared${hostPath.substring(shared.length)}';
    }
    // This session's distro rootfs — the most common case.
    final rootfs = await DistroService.rootfsDir(DistroService.byId(distroId));
    if (hostPath == rootfs) return '/';
    if (hostPath.startsWith('$rootfs/')) {
      return hostPath.substring(rootfs.length); // keeps the leading '/'
    }
    return hostPath;
  }

  Future<void> _loadFiles() async {
    final session = activeSession;
    if (session == null) return;
    await _loadFilesForSession(session);
    notifyListeners();
    _syncTerminalDirectory(session);
  }

  Future<void> _syncTerminalDirectory(TerminalSession session) async {
    try {
      if (session.terminal.isUsingAltBuffer) return;

      String guestPath = session.currentPath;
      if (Platform.isAndroid &&
          session.connectionStatus == ConnectionStatus.local) {
        guestPath = await _hostToGuestPath(session.currentPath, session.distroId);
      }

      final escaped = guestPath.replaceAll("'", "'\\''");
      // Add a space to avoid clogging shell history (common ignorespace setting)
      final bytes = utf8.encode(" cd '$escaped'\r");
      if (session.connectionStatus == ConnectionStatus.remote &&
          session.sshSession != null) {
        session.sshSession!.write(bytes);
      } else if (session.connectionStatus == ConnectionStatus.local &&
          session.localPty != null) {
        session.localPty!.write(bytes);
      }
    } catch (e) {
      debugPrint('Error al sincronizar directorio con terminal: $e');
    }
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
    bool hasError = false;

    SftpClient? sftp;
    try {
      if (session.connectionStatus == ConnectionStatus.remote && session.sshClient != null) {
        sftp = await session.sshClient!.sftp().timeout(const Duration(seconds: 5));
        final list = await sftp.listdir(session.currentPath).timeout(const Duration(seconds: 5));

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
          try {
            await for (final entity in dir.list(followLinks: false)) {
              try {
                final stat = await entity.stat();
                final name = entity.path.split(Platform.pathSeparator).last;
                loaded.add(FileSystemEntityInfo(
                  name: name,
                  path: entity.path,
                  isDirectory: entity is Directory,
                  size: stat.size,
                  modified: stat.modified,
                ));
              } catch (e) {
                // Ignore individual file errors (e.g. broken symlink or permission error on single file)
                debugPrint('Error al obtener info de archivo local: $e');
              }
            }
          } catch (e) {
            debugPrint('Error al listar directorio local: $e');
            rethrow;
          }
        }
      }

      loaded.sort((a, b) {
        if (a.isDirectory && !b.isDirectory) return -1;
        if (!a.isDirectory && b.isDirectory) return 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    } catch (e) {
      hasError = true;
      debugPrint('Error al cargar archivos: $e');
      session.terminal.write('⚠️ Error al cargar archivos: $e\r\n');
    } finally {
      if (sftp != null) {
        sftp.close();
      }
      if (!hasError) {
        session.files = loaded;
      }
      session.isLoadingFiles = false;
    }
  }

  // Text Editor Operations
  //
  // [forceLocal] reads via dart:io even if the active session is an SSH one —
  // used by the guest `open` command, whose paths are always host-local.
  Future<void> openFile(FileSystemEntityInfo file,
      {bool forceLocal = false}) async {
    if (file.isDirectory) return;

    final session = activeSession;
    if (session == null) return;

    final isRemote = !forceLocal &&
        (session.connectionStatus == ConnectionStatus.remote);
    final sshClient = forceLocal ? null : session.sshClient;
    session.isLoadingFiles = true;
    notifyListeners();

    SftpClient? sftp;
    SftpFile? fileStream;
    try {
      // Drop any temp copy from a previously open remote media file before
      // loading the next one.
      _disposeTempMediaFile();

      // Read the content *before* updating _editingFilePath so the editor only
      // rebuilds (and initializes its controller) once the content is ready.
      // Otherwise the editor inits with empty content and never refreshes.
      if (isVideoPath(file.path) || isAudioPath(file.path)) {
        // Video/audio play through media_kit, which needs a local file path.
        // Local files are played in place; remote files are downloaded to a
        // temp file first.
        if (isRemote && sshClient != null) {
          sftp = await sshClient.sftp().timeout(const Duration(seconds: 5));
          fileStream =
              await sftp.open(file.path, mode: SftpFileOpenMode.read).timeout(const Duration(seconds: 5));
          final bytes = await fileStream.readBytes().timeout(const Duration(seconds: 15));
          final tempDir = await getTemporaryDirectory();
          final tempFile = File('${tempDir.path}/${file.name}');
          await tempFile.writeAsBytes(bytes);
          _viewingMediaPath = tempFile.path;
          _tempMediaFile = tempFile;
        } else {
          _viewingMediaPath = file.path;
        }
        _viewingPdfBytes = null;
        _viewingImageBytes = null;
        _editingFileContent = '';
        _isPreviewMode = false;
      } else if (isPdfPath(file.path) ||
          (isImagePath(file.path) && !isSvgPath(file.path))) {
        // PDFs and raster images are read as raw bytes and handed to the
        // embedded viewer; there is no text content or editing involved. SVG
        // is excluded: being text, it goes through the editor path below so
        // it can be edited, with a rendered preview as the default mode.
        final Uint8List bytes;
        if (isRemote && sshClient != null) {
          sftp = await sshClient.sftp().timeout(const Duration(seconds: 5));
          fileStream =
              await sftp.open(file.path, mode: SftpFileOpenMode.read).timeout(const Duration(seconds: 5));
          bytes = await fileStream.readBytes().timeout(const Duration(seconds: 15));
        } else {
          bytes = await File(file.path).readAsBytes();
        }
        final isPdf = isPdfPath(file.path);
        _viewingPdfBytes = isPdf ? bytes : null;
        _viewingImageBytes = isPdf ? null : bytes;
        _viewingMediaPath = null;
        _editingFileContent = '';
        _isPreviewMode = false;
      } else {
        final String content;
        if (isRemote && sshClient != null) {
          sftp = await sshClient.sftp().timeout(const Duration(seconds: 5));
          fileStream =
              await sftp.open(file.path, mode: SftpFileOpenMode.read).timeout(const Duration(seconds: 5));
          final bytes = await fileStream.readBytes().timeout(const Duration(seconds: 15));
          content = utf8.decode(bytes, allowMalformed: true);
        } else {
          final localFile = File(file.path);
          content = await localFile.readAsString();
        }
        _viewingPdfBytes = null;
        _viewingImageBytes = null;
        _viewingMediaPath = null;
        _editingFileContent = content;
        // Markdown and SVG files open in their formatted preview by default;
        // everything else goes straight to the raw code editor.
        _isPreviewMode = isMarkdownPath(file.path) || isSvgPath(file.path);
      }

      _editingFilePath = file.path;
      _isEditingFileRemote = isRemote;
      _editingSshClient = sshClient;
      _isFileDirty = false;

      _activeTabIndex = 3; // Navigate to Editor Tab
    } catch (e) {
      session.terminal.write('Error al abrir archivo: $e\r\n');
    } finally {
      if (fileStream != null) {
        fileStream.close();
      }
      if (sftp != null) {
        sftp.close();
      }
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

    SftpClient? sftp;
    SftpFile? fileStream;
    try {
      final bytes = utf8.encode(_editingFileContent);
      if (_isEditingFileRemote && _editingSshClient != null) {
        sftp = await _editingSshClient!.sftp().timeout(const Duration(seconds: 5));
        fileStream = await sftp.open(
          _editingFilePath!,
          mode: SftpFileOpenMode.write | SftpFileOpenMode.create | SftpFileOpenMode.truncate,
        ).timeout(const Duration(seconds: 5));
        await fileStream.write(Stream.value(bytes)).timeout(const Duration(seconds: 15));
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
      if (fileStream != null) {
        fileStream.close();
      }
      if (sftp != null) {
        sftp.close();
      }
      if (session != null) {
        session.isLoadingFiles = false;
        notifyListeners();
      }
    }
  }

  void closeFile() {
    _disposeTempMediaFile();
    _editingFilePath = null;
    _editingFileContent = '';
    _viewingPdfBytes = null;
    _viewingImageBytes = null;
    _viewingMediaPath = null;
    _isFileDirty = false;
    _editingSshClient = null;
    _activeTabIndex = 2; // Go back to files tab
    notifyListeners();
  }

  @override
  void dispose() {
    _openRequestSub?.cancel();
    _openRequestPoll?.cancel();
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
