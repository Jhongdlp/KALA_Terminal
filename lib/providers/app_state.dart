import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:uuid/uuid.dart';
import 'package:open_filex/open_filex.dart';
import '../models/connection_profile.dart';
import '../models/prompt_snippet.dart';
import '../models/terminal_shortcut.dart';
import '../theme/app_theme.dart';
import '../services/background_service.dart';
import '../services/device_key.dart';
import '../services/server_controller.dart';
import '../services/notification_service.dart';
import '../services/secure_store.dart';

enum ConnectionStatus { disconnected, connecting, remote }

/// Type filter applied by the explorer's filter button.
enum FileTypeFilter { all, folders, filesOnly }

/// Lifecycle of a file download. [done] and [error] are terminal states that
/// stay on screen (as the explorer's result bar) until the user dismisses them.
enum DownloadPhase { idle, scanning, transferring, done, error }

/// One unit of work in a download plan: a directory to create, or a file to
/// stream from [srcPath] (remote or local) to [destPath] on the device.
class _DownloadItem {
  _DownloadItem({
    required this.srcPath,
    required this.destPath,
    required this.name,
    required this.isDirectory,
    this.size = 0,
  });

  final String srcPath;
  final String destPath;
  final String name;
  final bool isDirectory;
  final int size;
}

class TerminalSession {
  final String id;
  String name;
  final Terminal terminal;
  ConnectionStatus connectionStatus;
  ConnectionProfile? activeProfile;
  SSHClient? sshClient;
  SSHSession? sshSession;
  SftpClient? sftpClient;
  String currentPath;
  // Actual working directory of the interactive shell, tracked out-of-band from
  // the file explorer's [currentPath]. Updated whenever the remote shell emits
  // an OSC 7 sequence (`ESC ] 7 ; file://host/path ST`); the git panel prefers
  // this over the explorer path so "cambios" reflects where the terminal is.
  // Null until the shell reports it at least once (see [_seedCwdReporting]).
  String? terminalCwd;
  // Stack of previously visited directories for this session's explorer, used
  // by [AppState.navigateBack]. Pushed in [AppState.changeDirectory] and
  // [AppState.navigateUp] right before the path changes.
  List<String> pathHistory = [];
  List<FileSystemEntityInfo> files;
  bool isLoadingFiles;
  // Whether the underlying shell (local PTY or SSH) has actually been spawned.
  // Whether the SSH shell has actually been spawned (set once the connection
  // is established). SSH sessions connect on creation, so this is effectively
  // always true for a live session; kept for the explorer's bookkeeping.
  bool started;
  List<ServerSocket> forwardServers;
  // Set when this session rang the bell (or emitted an OSC notification)
  // while it wasn't the visible one; rendered as an accent dot in the session
  // selector and cleared when the user switches to it.
  bool hasPendingAlert = false;
  // Last window title the remote program set (OSC 0/2). Many TUI agents put
  // their name here; used to pick the agent badge on alert notifications.
  String? lastTitle;
  // Last time an agent alert fired for this session — debounce window so a
  // burst of BELs collapses into a single notification.
  DateTime? lastAlertAt;
  // ---- Background agent-watch state (see [_evaluateAgentActivity]) ----
  // Signature (hash) of the normalized visible tail of the terminal the last
  // time it was inspected while backgrounded. Spinner glyphs, counters and
  // whitespace are stripped before hashing so idle redraw loops (Claude Code's
  // "✻ Thinking… (10s · esc to interrupt)") don't count as new output.
  int? watchSignature;
  // True once an autodetect alert fired for the current idle period; reset
  // whenever the (normalized) screen content actually changes again, so a
  // static prompt can never re-notify.
  bool watchAlertFired = false;
  // True while a reconnect attempt is in flight, so the banner button and the
  // on-resume sweep can't double-connect the same session.
  bool reconnecting = false;
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
    required this.currentPath,
    List<FileSystemEntityInfo>? files,
    this.isLoadingFiles = false,
    this.started = false,
    List<ServerSocket>? forwardServers,
  })  : files = files ?? [],
        forwardServers = forwardServers ?? [];
}

// WidgetsBindingObserver: AppState tracks the app's foreground/background
// state itself (see [didChangeAppLifecycleState]) to decide whether an agent
// alert becomes a system notification and to reconnect dropped sessions on
// resume.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  // Navigation State
  int _activeTabIndex = 0;
  int get activeTabIndex => _activeTabIndex;

  void setActiveTabIndex(int index) {
    _activeTabIndex = index;
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
      if (isLoadingFiles) return true;
      navigateBack();
      return true;
    }
    // Explorer, opt-in: step up one folder until we reach the root, then fall
    // through to the normal tab/exit behaviour.
    if (_activeTabIndex == 2 && _backGestureNavigatesFolders && canNavigateUp) {
      if (isLoadingFiles) return true;
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

  // Per-session idle timers: armed when the (normalized) screen content
  // changes while backgrounded, fire after [_agentIdleDelay] of no further
  // meaningful change — the "the agent stopped writing" signal.
  final Map<String, Timer> _sessionAlertTimers = {};
  // Per-session throttle timers so a flood of output chunks costs at most one
  // buffer inspection every [_agentCheckThrottle].
  final Map<String, Timer> _sessionCheckTimers = {};

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

  /// Whether [path] is an Office document or unsupported binary format to open externally.
  static bool isOfficeOrExternalDocumentPath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.docx') ||
        lower.endsWith('.doc') ||
        lower.endsWith('.xlsx') ||
        lower.endsWith('.xls') ||
        lower.endsWith('.pptx') ||
        lower.endsWith('.ppt') ||
        lower.endsWith('.odt') ||
        lower.endsWith('.ods') ||
        lower.endsWith('.odp') ||
        lower.endsWith('.rtf') ||
        lower.endsWith('.epub') ||
        lower.endsWith('.zip') ||
        lower.endsWith('.tar') ||
        lower.endsWith('.gz') ||
        lower.endsWith('.rar') ||
        lower.endsWith('.7z') ||
        lower.endsWith('.apk');
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
  static const String _kTerminalScheme = 'settings_terminal_scheme';
  static const String _kIconScale = 'settings_icon_scale';
  static const String _kBackGestureFolders = 'settings_back_gesture_folders';
  static const String _kSyncTerminalPath = 'settings_sync_terminal_path';
  static const String _kAppLockEnabled = 'settings_app_lock_enabled';
  static const String _kAgentAlerts = 'settings_agent_alerts';
  static const String _kAccentColorHex = 'settings_accent_color_hex';
  static const String _kMonoFontChoice = 'settings_mono_font_choice';
  static const String _kShortcutLayout = 'settings_shortcut_layout';
  static const String _kCustomShortcuts = 'settings_custom_shortcuts_json';
  static const String _kShortcutKeyHeight = 'settings_shortcut_key_height';
  static const String _kShortcutKeyWidth = 'settings_shortcut_key_width';

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

  bool _syncTerminalPath = true;
  bool get syncTerminalPath => _syncTerminalPath;

  // When true (default), a session that rings the bell or emits an OSC 9/777
  // notification while the app is backgrounded posts a system notification —
  // how TUI agents (Claude Code, aider, …) signal that they need input.
  bool _agentAlertsEnabled = true;
  bool get agentAlertsEnabled => _agentAlertsEnabled;

  String _accentColorHex = 'auto';
  String get accentColorHex => _accentColorHex;

  String _monoFontChoice = 'cascadia';
  String get monoFontChoice => _monoFontChoice;

  TerminalShortcutLayout _shortcutLayout = TerminalShortcutLayout.classic;
  TerminalShortcutLayout get shortcutLayout => _shortcutLayout;

  int _shortcutPageIndex = 0;
  int get shortcutPageIndex => _shortcutPageIndex;

  List<TerminalShortcut> _customShortcuts = [];
  List<TerminalShortcut> get customShortcuts => _customShortcuts;

  double _shortcutKeyHeight = 28.0;
  double get shortcutKeyHeight => _shortcutKeyHeight;

  double _shortcutKeyWidth = 36.0;
  double get shortcutKeyWidth => _shortcutKeyWidth;

  String get monoFontFamily => AppText.resolveMonoFontFamily(_monoFontChoice);

  Future<void> setAgentAlertsEnabled(bool value) async {
    if (_agentAlertsEnabled == value) return;
    _agentAlertsEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAgentAlerts, value);
  }

  // ---- App lock --------------------------------------------------------
  // When enabled, a biometric/device-credential gate is shown before the app
  // shell on cold start (see LockGate in main.dart). The unlock uses the phone's
  // biometric with a fallback to its screen-lock credential; no KALA-specific
  // secret is stored.
  bool _appLockEnabled = false;
  bool get appLockEnabled => _appLockEnabled;

  // Runtime unlock flag for the current process. Starts false so the gate
  // appears on launch; flipped by [markUnlocked] after a successful auth.
  bool _unlocked = false;

  // Becomes true once _loadSettings has run, so the gate can avoid flashing the
  // app shell before it knows whether the lock is enabled.
  bool _settingsLoaded = false;
  bool get settingsLoaded => _settingsLoaded;

  /// True while the app should stay behind the lock screen: settings are known,
  /// the lock is on, and the user hasn't authenticated yet this session.
  bool get requiresUnlock =>
      _settingsLoaded && _appLockEnabled && !_unlocked;

  /// Records a successful authentication for the rest of this process run.
  void markUnlocked() {
    if (_unlocked) return;
    _unlocked = true;
    notifyListeners();
  }

  Future<void> setAppLockEnabled(bool value) async {
    if (_appLockEnabled == value) return;
    _appLockEnabled = value;
    // Enabling from settings means the user is already inside the app; don't
    // relock the current session — the gate only guards the next cold start.
    if (value) _unlocked = true;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAppLockEnabled, value);
  }

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

  AppState() {
    _loadSettings();
    _loadProfiles();
    WidgetsBinding.instance.addObserver(this);
    // A cold start triggered by tapping an agent-alert notification carries a
    // session id; with no sessions alive after a process death there's nothing
    // to jump to, but consuming it clears the native side either way.
    _consumePendingNotificationTap();
    // No session exists until the user connects to an SSH profile: the app
    // opens on the connections tab. The background service that keeps SSH
    // sessions alive while minimized is started on the first connection
    // (see [_connectSessionToSSH]).
  }

  // ---- App lifecycle & agent alerts ----------------------------------------
  // Whether the app is currently visible (resumed). Starts true: the process
  // begins in the foreground.
  bool _appInForeground = true;

  // Ids of the sessions that were live when the app last went to background.
  // On resume, only these are auto-reconnected if now disconnected: a session
  // the user deliberately ended (`exit`) before backgrounding stays down.
  Set<String> _liveWhenPaused = const {};

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _appInForeground) return;
    _appInForeground = foreground;
    if (foreground) {
      _onAppResumed();
    } else {
      _liveWhenPaused = _sessions
          .where((s) => s.connectionStatus == ConnectionStatus.remote)
          .map((s) => s.id)
          .toSet();
      // Seed each session's watch state with what's on screen right now, so a
      // prompt that was already visible when the user left doesn't fire an
      // alert by itself — only output produced *after* backgrounding counts.
      for (final session in _sessions) {
        session.watchSignature = _screenSignature(session);
        session.watchAlertFired = false;
      }
    }
  }

  void _onAppResumed() {
    // The user is back: pending idle timers would alert about things they are
    // already looking at.
    for (final t in _sessionAlertTimers.values) {
      t.cancel();
    }
    _sessionAlertTimers.clear();
    for (final t in _sessionCheckTimers.values) {
      t.cancel();
    }
    _sessionCheckTimers.clear();
    // The user is looking at the app again: posted alerts are now noise.
    NotificationService.cancelAlerts();
    // If a notification tap resumed us, jump to that session.
    _consumePendingNotificationTap();
    // Looking at the active session acknowledges its pending alert.
    final active = activeSession;
    if (active != null && active.hasPendingAlert) {
      active.hasPendingAlert = false;
      notifyListeners();
    }
    // One reconnect attempt per session that dropped while backgrounded (never
    // a retry loop — further attempts are the user's, via the banner button).
    for (final session in List<TerminalSession>.of(_sessions)) {
      if (session.connectionStatus == ConnectionStatus.disconnected &&
          session.activeProfile != null &&
          _liveWhenPaused.contains(session.id)) {
        reconnectSession(session);
      }
    }
    _liveWhenPaused = const {};
  }

  /// Reads (and clears) the session id carried by an alert-notification tap;
  /// if that session is still open, makes it active and shows the terminal.
  Future<void> _consumePendingNotificationTap() async {
    final id = await NotificationService.consumePendingSession();
    if (id == null) return;
    final index = _sessions.indexWhere((s) => s.id == id);
    if (index < 0) return;
    switchSession(index);
    _activeTabIndex = 1;
    notifyListeners();
  }

  /// Minimum spacing between alerts of the same session: TUI agents often ring
  /// the bell several times in a burst.
  static const Duration _alertDebounce = Duration(seconds: 4);

  /// Known TUI agents, matched (in order) against the terminal title and the
  /// recent screen content to brand the alert notification. Purely cosmetic:
  /// everything works the same for an unknown agent (generic badge).
  static const List<({String marker, String id, String label})> _agentMarkers = [
    (marker: 'antigravity', id: 'antigravity', label: 'Antigravity'),
    (marker: 'agy', id: 'antigravity', label: 'Antigravity'),
    (marker: 'deepmind', id: 'antigravity', label: 'Antigravity'),
    (marker: 'claude', id: 'claude', label: 'Claude Code'),
    (marker: 'aider', id: 'aider', label: 'Aider'),
    // Before 'codex'/'gemini': their names could appear in opencode output.
    (marker: 'opencode', id: 'opencode', label: 'OpenCode'),
    (marker: 'codex', id: 'codex', label: 'Codex'),
    (marker: 'gemini', id: 'gemini', label: 'Gemini CLI'),
    (marker: 'copilot', id: 'copilot', label: 'Copilot CLI'),
    // 'cursor' alone would match ordinary terminal text ("cursor position"),
    // so only the CLI binary name counts.
    (marker: 'cursor-agent', id: 'cursor', label: 'Cursor'),
    (marker: 'qwen', id: 'qwen', label: 'Qwen Code'),
  ];

  /// Best guess at which agent is running in [session]: the window title
  /// (agents usually put their name there) wins; otherwise the most recent
  /// mention in the tail of the terminal buffer. Null → unknown/no agent.
  ({String id, String label})? _detectAgent(TerminalSession session) {
    final title = session.lastTitle?.toLowerCase() ?? '';
    for (final m in _agentMarkers) {
      if (title.contains(m.marker)) return (id: m.id, label: m.label);
    }
    final tail = _terminalTail(session, 60).toLowerCase();
    if (tail.isEmpty) return null;
    ({String id, String label})? best;
    var bestIdx = -1;
    for (final m in _agentMarkers) {
      final idx = tail.lastIndexOf(m.marker);
      if (idx > bestIdx) {
        bestIdx = idx;
        best = (id: m.id, label: m.label);
      }
    }
    return best;
  }

  /// Shared endpoint for every agent-attention signal (BEL, OSC 9, OSC 777 and
  /// the idle autodetector), wired per-session in [createNewSession]. Policy:
  ///  - app in background → system notification (tap reopens the session);
  ///  - app visible but the session isn't the active one → in-app badge;
  ///  - app visible and session active → nothing beyond the bell's haptic.
  void _onSessionAlert(TerminalSession session, {String? title, String? body}) {
    if (!_agentAlertsEnabled) return;
    final now = DateTime.now();
    final last = session.lastAlertAt;
    if (last != null && now.difference(last) < _alertDebounce) return;
    session.lastAlertAt = now;

    if (!_appInForeground) {
      final agent = _detectAgent(session);

      // An explicit signal (BEL/OSC) covers the current idle period too: mark
      // it consumed so the autodetector can't post a duplicate 3s later.
      session.watchAlertFired = true;
      session.watchSignature = _screenSignature(session);
      _sessionAlertTimers.remove(session.id)?.cancel();

      String finalTitle;
      if (title != null && title.isNotEmpty && title != session.name) {
        // Explicit OSC 777 title — the program knows best what to announce.
        finalTitle = agent != null ? '${agent.label} · $title' : title;
      } else {
        finalTitle = agent?.label ?? session.name;
      }
      String finalBody = body ?? '';
      if (finalBody.isEmpty) {
        finalBody = agent != null
            ? 'Espera tu respuesta'
            : 'El terminal pide tu atención';
      }

      NotificationService.showAlert(
        sessionId: session.id,
        title: finalTitle,
        body: finalBody,
        agent: agent?.id,
        sessionName: session.name,
      );
    } else if (!identical(session, activeSession)) {
      session.hasPendingAlert = true;
      notifyListeners();
    }
  }

  // ---- Background autodetector -------------------------------------------
  // Detects, without any cooperation from the program, the two moments worth
  // a notification while the app is backgrounded:
  //  - the agent stopped writing and is waiting for an answer (question/menu);
  //  - the agent stopped writing because it finished the task.
  //
  // It works on transitions, not on content alone: output must first *change*
  // (beyond spinner/counter redraw noise) and then stay still for
  // [_agentIdleDelay]. One alert per idle period ([watchAlertFired]), so a
  // static prompt on screen can never re-notify no matter how many redraws or
  // heartbeats the program emits.

  /// How long the normalized screen must stay unchanged before the agent
  /// counts as "stopped writing". LLM streams pause between tokens; 3s avoids
  /// firing inside those gaps.
  static const Duration _agentIdleDelay = Duration(seconds: 3);

  /// Inspection cadence while output is flowing: at most one buffer read per
  /// session per throttle window, regardless of how many chunks arrive.
  static const Duration _agentCheckThrottle = Duration(milliseconds: 300);

  /// Rows from the bottom of the buffer that feed detection — roughly one
  /// phone screen of a TUI agent.
  static const int _watchTailLines = 40;

  /// Everything that idle TUIs redraw without meaning anything new: spaces,
  /// digits (elapsed-time and token counters), braille and geometric spinner
  /// glyphs, progress-bar characters.
  static final RegExp _watchNoiseRegex = RegExp(
    r"[\s\d⠀-⣿✻✳✶✽✢·∙•●○◌◍◐◓◑◒◴◵◶◷⏳⌛|/\\*+~↑↓█▉▊▋▌▍▎▏░▒▓-]",
  );

  /// Status-line hints that mean the program is *still working* (streaming or
  /// running a tool), even though the visible text hasn't changed for a while
  /// — e.g. Claude Code's "(esc to interrupt)". Suppresses the idle alert; a
  /// real state change re-arms it.
  static final RegExp _busyMarkerRegex = RegExp(
    r'esc to interrupt|esc para interrumpir|esc to cancel|esc para cancelar|'
    r'ctrl\+c to|ctrl-c to|ctrl\+c para|press esc|thinking…|pensando…',
  );

  /// UI chrome lines of known agents that would pollute classification and
  /// snippets (Claude Code's "? for shortcuts" bar would read as a question).
  static final RegExp _chromeLineRegex = RegExp(
    r'\?\s*for shortcuts|for commands|for newline|@ for file|shift\+tab|'
    r'bypass permissions|auto-accept|plan mode|context left|/help|'
    r'tokens used|tokens remaining',
  );

  /// Last [lines] rows of the terminal (screen + tail of scrollback) as plain
  /// text, without serializing the whole 10k-line buffer.
  String _terminalTail(TerminalSession session, int lines) {
    try {
      final buffer = session.terminal.buffer;
      final height = buffer.height;
      final start = height > lines ? height - lines : 0;
      return buffer.getText(BufferRangeLine(
        CellOffset(0, start),
        CellOffset(buffer.viewWidth - 1, height - 1),
      ));
    } catch (_) {
      return '';
    }
  }

  /// Hash of the visible tail with redraw noise stripped: two screens with the
  /// same signature show the same *meaningful* content, even if a spinner or
  /// an elapsed-seconds counter differs.
  int _screenSignature(TerminalSession session) => _terminalTail(session, _watchTailLines)
      .replaceAll(_watchNoiseRegex, '')
      .hashCode;

  /// Entry point wired to every remote-output batch (see [_TerminalWriter]).
  void _onTerminalOutput(TerminalSession session) {
    if (!_agentAlertsEnabled || _appInForeground) return;
    if (_sessionCheckTimers.containsKey(session.id)) return;
    _sessionCheckTimers[session.id] = Timer(_agentCheckThrottle, () {
      _sessionCheckTimers.remove(session.id);
      _evaluateAgentActivity(session);
    });
  }

  void _evaluateAgentActivity(TerminalSession session) {
    if (!_agentAlertsEnabled || _appInForeground) return;
    final sig = _screenSignature(session);
    if (sig == session.watchSignature) {
      // Pure redraw (spinner frame, counter tick): not activity — whatever
      // idle timer is already running keeps counting.
      return;
    }
    session.watchSignature = sig;
    session.watchAlertFired = false;
    _sessionAlertTimers[session.id]?.cancel();
    _sessionAlertTimers[session.id] = Timer(_agentIdleDelay, () {
      _sessionAlertTimers.remove(session.id);
      _maybeFireIdleAlert(session);
    });
  }

  void _maybeFireIdleAlert(TerminalSession session) {
    if (!_agentAlertsEnabled || _appInForeground) return;
    if (session.watchAlertFired) return;
    // Output can land inside the throttle window after the last evaluation:
    // if the screen moved again, this wasn't real silence — restart the cycle.
    if (_screenSignature(session) != session.watchSignature) {
      _evaluateAgentActivity(session);
      return;
    }

    final lines = _terminalTail(session, _watchTailLines)
        .split('\n')
        .map((l) => l.trimRight())
        .toList();
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    final recent =
        lines.length > 14 ? lines.sublist(lines.length - 14) : lines;
    if (_busyMarkerRegex.hasMatch(recent.join('\n').toLowerCase())) {
      // Still streaming/running a tool with a static screen (long silent
      // step). Don't consume the idle period: when the busy hint disappears
      // the signature changes and the cycle restarts.
      return;
    }

    session.watchAlertFired = true;
    final isQuestion = _looksLikeQuestion(recent);
    final snippet = _alertSnippet(recent);
    final headline =
        isQuestion ? 'Espera tu respuesta' : 'Terminó de escribir';
    _onSessionAlert(
      session,
      body: snippet.isEmpty ? headline : '$headline\n$snippet',
    );
  }

  /// Whether the tail of the screen looks like an interactive prompt (the
  /// agent is waiting for the user) rather than a finished task.
  bool _looksLikeQuestion(List<String> recent) {
    final meaningful = recent
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !_chromeLineRegex.hasMatch(l.toLowerCase()))
        .toList();
    if (meaningful.isEmpty) return false;

    var numbered = 0;
    for (final line in meaningful) {
      final lower = line.toLowerCase();
      // Selection menus: "❯ 1. Yes", "› Option", numbered choices.
      if (line.startsWith('❯') || line.startsWith('›')) return true;
      if (RegExp(r'^\d+[.)]\s').hasMatch(line)) numbered++;
      // Question mark closing a sentence (box borders already trimmed).
      final stripped = line.replaceAll(RegExp(r'[│┃║╮╯┐┘\s]+$'), '');
      if (stripped.endsWith('?')) return true;
      if (lower.contains('¿')) return true;
      if (RegExp(r'\((?:y/n|yes/no|s/n|sí/no)\)|\[(?:y/n|y/N|Y/n|yes/no|s/n)\]',
              caseSensitive: false)
          .hasMatch(line)) {
        return true;
      }
      if (RegExp(r'\b(?:do you want|would you like|allow this|approve|confirm|'
              r'select an option|choose an option|press enter|enter a|'
              r'deseas|quieres|permitir|aprobar|confirmar|selecciona|elige|'
              r'escribe|ingresa|contraseña|password|passphrase)\b')
          .hasMatch(lower)) {
        return true;
      }
    }
    return numbered >= 2;
  }

  /// Short human-readable excerpt of what's on screen for the notification
  /// body: the last meaningful lines with TUI chrome and box borders removed.
  String _alertSnippet(List<String> recent) {
    final cleaned = <String>[];
    for (final raw in recent) {
      final line = raw
          .replaceAll(RegExp(r'[│┃║╭╮╰╯┌┐└┘├┤┬┴─━═╌╍]'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (line.isEmpty) continue;
      if (_chromeLineRegex.hasMatch(line.toLowerCase())) continue;
      cleaned.add(line);
    }
    if (cleaned.isEmpty) return '';
    final lastLines =
        cleaned.length > 3 ? cleaned.sublist(cleaned.length - 3) : cleaned;
    var snippet = lastLines.join('\n');
    if (snippet.length > 200) {
      snippet = '…${snippet.substring(snippet.length - 200)}';
    }
    return snippet;
  }

  // Ensures the Android foreground service (which keeps the process — and its
  // SSH shells — alive while the app is in the background) is running. Started
  // lazily on the first SSH connection so no persistent notification shows
  // while the user is only browsing the connections list. No-op off Android.
  bool _backgroundStarted = false;
  void _ensureBackgroundService() {
    if (_backgroundStarted) return;
    _backgroundStarted = true;
    BackgroundService.start();
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

    _syncTerminalPath =
        prefs.getBool(_kSyncTerminalPath) ?? true;

    _appLockEnabled = prefs.getBool(_kAppLockEnabled) ?? false;

    _agentAlertsEnabled = prefs.getBool(_kAgentAlerts) ?? true;

    _accentColorHex = prefs.getString(_kAccentColorHex) ?? 'auto';
    final shortcutLayoutIdx = prefs.getInt(_kShortcutLayout);
    if (shortcutLayoutIdx != null &&
        shortcutLayoutIdx >= 0 &&
        shortcutLayoutIdx < TerminalShortcutLayout.values.length) {
      _shortcutLayout = TerminalShortcutLayout.values[shortcutLayoutIdx];
    }
    _monoFontChoice = prefs.getString(_kMonoFontChoice) ?? 'cascadia';


    final customShortcutsJson = prefs.getString(_kCustomShortcuts);
    if (customShortcutsJson != null) {
      try {
        final decoded = json.decode(customShortcutsJson) as List<dynamic>;
        _customShortcuts = decoded
            .map((item) => TerminalShortcut.fromJson(item as Map<String, dynamic>))
            .toList();
        
        // Migration: If no system shortcuts exist in the loaded configuration, prepend them.
        final hasSystem = _customShortcuts.any((s) => s.value.startsWith('system:'));
        if (!hasSystem) {
          final systemShortcuts = [
            TerminalShortcut(label: 'ADJUNTAR', value: 'system:attach'),
            TerminalShortcut(label: 'PROMPTS', value: 'system:prompts'),
            TerminalShortcut(label: 'COMMIT', value: 'system:commit'),
            TerminalShortcut(label: 'ENLACES', value: 'system:links'),
            TerminalShortcut(label: 'AJUSTES', value: 'system:settings'),
          ];
          _customShortcuts.insertAll(0, systemShortcuts);
          _saveCustomShortcuts();
        }
      } catch (e) {
        _customShortcuts = getDefaultShortcuts();
      }
    } else {
      _customShortcuts = getDefaultShortcuts();
    }

    // One-time migration to append new default shortcuts (like Ctrl+Delete, Shift+Tab, and standard Antigravity/TUI keys)
    final migrated = prefs.getBool('settings_shortcuts_migrated_v3') ?? false;
    if (!migrated) {
      final defaults = getDefaultShortcuts();
      bool modified = false;
      for (final def in defaults) {
        if (!_customShortcuts.any((s) => s.value == def.value)) {
          _customShortcuts.add(def);
          modified = true;
        }
      }
      if (modified) {
        await prefs.setString(_kCustomShortcuts, json.encode(_customShortcuts.map((s) => s.toJson()).toList()));
      }
      await prefs.setBool('settings_shortcuts_migrated_v3', true);
    }

    // Migration v4: Reset default shortcuts to clean up unnecessary duplicates that are now standard in Row 1
    final migratedV4 = prefs.getBool('settings_shortcuts_migrated_v4') ?? false;
    if (!migratedV4) {
      _customShortcuts = getDefaultShortcuts();
      await prefs.setString(_kCustomShortcuts, json.encode(_customShortcuts.map((s) => s.toJson()).toList()));
      await prefs.setBool('settings_shortcuts_migrated_v4', true);
    }

    _shortcutKeyHeight = prefs.getDouble(_kShortcutKeyHeight) ?? 28.0;
    _shortcutKeyWidth = prefs.getDouble(_kShortcutKeyWidth) ?? 36.0;

    await _loadSnippets(prefs);

    _settingsLoaded = true;
    notifyListeners();
  }

  Future<void> setAccentColorHex(String value) async {
    if (_accentColorHex == value) return;
    _accentColorHex = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAccentColorHex, value);
  }

  Future<void> setMonoFontChoice(String value) async {
    if (_monoFontChoice == value) return;
    _monoFontChoice = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMonoFontChoice, value);
  }

  Future<void> setShortcutLayout(TerminalShortcutLayout layout) async {
    if (_shortcutLayout == layout) return;
    _shortcutLayout = layout;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kShortcutLayout, layout.index);
  }

  void setShortcutPageIndex(int val) {
    if (_shortcutPageIndex == val) return;
    _shortcutPageIndex = val;
    notifyListeners();
  }

  Future<void> setShortcutKeyHeight(double value) async {
    if (_shortcutKeyHeight == value) return;
    _shortcutKeyHeight = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kShortcutKeyHeight, value);
  }

  Future<void> setShortcutKeyWidth(double value) async {
    if (_shortcutKeyWidth == value) return;
    _shortcutKeyWidth = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kShortcutKeyWidth, value);
  }

  List<TerminalShortcut> getDefaultShortcuts() {
    return [
      TerminalShortcut(label: 'ADJUNTAR', value: 'system:attach'),
      TerminalShortcut(label: 'PROMPTS', value: 'system:prompts'),
      TerminalShortcut(label: 'COMMIT', value: 'system:commit'),
      TerminalShortcut(label: 'ENLACES', value: 'system:links'),
      TerminalShortcut(label: 'AJUSTES', value: 'system:settings'),
      TerminalShortcut(label: 'clear', value: 'clear\n'),
      TerminalShortcut(label: '^A', value: r'\x01'),
      TerminalShortcut(label: '^E', value: r'\x05'),
      TerminalShortcut(label: '^L', value: r'\x0c'),
      TerminalShortcut(label: '^K', value: r'\x0b'),
      TerminalShortcut(label: 'exit', value: 'exit\n'),
    ];
  }

  Future<void> _saveCustomShortcuts() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = json.encode(_customShortcuts.map((s) => s.toJson()).toList());
    await prefs.setString(_kCustomShortcuts, jsonStr);
    notifyListeners();
  }

  Future<void> setCustomShortcuts(List<TerminalShortcut> shortcuts) async {
    _customShortcuts = List.from(shortcuts);
    await _saveCustomShortcuts();
  }

  Future<void> addCustomShortcut(TerminalShortcut shortcut) async {
    _customShortcuts.add(shortcut);
    await _saveCustomShortcuts();
  }

  Future<void> updateCustomShortcut(int index, TerminalShortcut shortcut) async {
    if (index >= 0 && index < _customShortcuts.length) {
      _customShortcuts[index] = shortcut;
      await _saveCustomShortcuts();
    }
  }

  Future<void> deleteCustomShortcut(int index) async {
    if (index >= 0 && index < _customShortcuts.length) {
      _customShortcuts.removeAt(index);
      await _saveCustomShortcuts();
    }
  }

  Future<void> reorderCustomShortcuts(int oldIndex, int newIndex) async {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final item = _customShortcuts.removeAt(oldIndex);
    _customShortcuts.insert(newIndex, item);
    await _saveCustomShortcuts();
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

  Future<void> setSyncTerminalPath(bool value) async {
    if (_syncTerminalPath == value) return;
    _syncTerminalPath = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSyncTerminalPath, value);
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

  // Create a new terminal session for [profile] and connect it over SSH. The
  // session is made active immediately; the shell is opened asynchronously in
  // [_connectSessionToSSH].
  void createNewSession({
    required ConnectionProfile profile,
    String? initialCommand,
    String? sessionName,
  }) {
    final String id = const Uuid().v4();
    // `late` because the terminal's callbacks below capture the session that
    // owns them; they can only fire after [Terminal.write], i.e. well after
    // the assignment.
    late final TerminalSession session;
    final Terminal terminal = Terminal(
      maxLines: 10000,
      // Bell (BEL / \a) → haptic tick (no-op without a vibrator) + agent
      // alert: it's how most TUI agents signal they finished or need input.
      onBell: () {
        HapticFeedback.mediumImpact();
        _onSessionAlert(session);
      },
      // Explicit notification escapes, agent-agnostic:
      //   OSC 9   — `ESC ] 9 ; message BEL` (iTerm2/WezTerm style);
      //   OSC 777 — `ESC ] 777 ; notify ; title ; body BEL` (urxvt style).
      // Semicolons inside the payload arrive pre-split, hence the joins.
      onPrivateOSC: (ps, pt) {
        if (ps == '7' && pt.isNotEmpty) {
          // OSC 7 — the shell reporting its working directory as a file:// URI
          // (`ESC ] 7 ; file://host/path ST`). Keep the terminal's real cwd in
          // sync so the git panel can key off it instead of the explorer path.
          _updateTerminalCwd(session, pt.join(';'));
          return;
        }
        if (ps == '9' && pt.isNotEmpty) {
          _onSessionAlert(session, body: pt.join(';'));
        } else if (ps == '777' && pt.isNotEmpty && pt.first == 'notify') {
          _onSessionAlert(
            session,
            title: pt.length > 1 ? pt[1] : null,
            body: pt.length > 2 ? pt.sublist(2).join(';') : null,
          );
        }
      },
      onTitleChange: (title) => session.lastTitle = title,
    );

    session = TerminalSession(
      id: id,
      name: sessionName ?? profile.name,
      terminal: terminal,
      connectionStatus: ConnectionStatus.disconnected,
      activeProfile: profile,
      currentPath: '',
    );

    _sessions.add(session);
    _activeSessionIndex = _sessions.length - 1;
    notifyListeners();

    _connectSessionToSSH(session, profile, initialCommand: initialCommand);
  }

  /// Ask for the legacy storage permission (the app targets SDK 28, so the
  /// classic READ_EXTERNAL_STORAGE dialog still grants /sdcard access). Used by
  /// the file "adjuntar" picker and the SFTP → local downloader so they can read
  /// and write files under /storage/emulated/0. Best-effort: a denial just means
  /// those features fall back to app-private storage. No-op off Android.
  Future<void> _ensureStoragePermission() async {
    try {
      final status = await Permission.storage.status;
      if (!status.isGranted) await Permission.storage.request();
    } catch (_) {/* plugin unavailable (tests) or user denied — continue */}
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

  // ---- Prompt snippets ------------------------------------------------------
  // Reusable prompt templates for TUI agents, persisted as a JSON string list
  // (same pattern as `ssh_profiles`; no secrets → plain shared_preferences).
  static const String _kPromptSnippets = 'prompt_snippets';

  List<PromptSnippet> _snippets = [];
  List<PromptSnippet> get snippets => _snippets;

  Future<void> _loadSnippets(SharedPreferences prefs) async {
    final raw = prefs.getStringList(_kPromptSnippets);
    if (raw == null) {
      // First run: seed a few starter templates so the sheet isn't empty and
      // shows what the feature is for. Deleting them all is remembered (the
      // key then exists as an empty list).
      _snippets = [
        PromptSnippet(
          id: const Uuid().v4(),
          title: 'Tests y arreglos',
          text: 'Corre los tests del proyecto y arregla los fallos que '
              'encuentres. Muéstrame un resumen de lo que cambiaste.',
        ),
        PromptSnippet(
          id: const Uuid().v4(),
          title: 'Commit y push',
          text: 'Haz commit de los cambios pendientes con un mensaje '
              'descriptivo y haz push a la rama actual.',
        ),
        PromptSnippet(
          id: const Uuid().v4(),
          title: 'Explicar error',
          text: 'Explica el último error que apareció y propón cómo '
              'solucionarlo antes de tocar nada.',
        ),
      ];
      await _persistSnippets(prefs);
      return;
    }
    _snippets = raw.map(PromptSnippet.fromJson).toList();
  }

  Future<void> _persistSnippets(SharedPreferences prefs) async {
    await prefs.setStringList(
        _kPromptSnippets, _snippets.map((s) => s.toJson()).toList());
  }

  Future<void> saveSnippet(PromptSnippet snippet) async {
    final index = _snippets.indexWhere((s) => s.id == snippet.id);
    if (index >= 0) {
      _snippets[index] = snippet;
    } else {
      _snippets.add(snippet);
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await _persistSnippets(prefs);
  }

  Future<void> deleteSnippet(String id) async {
    _snippets.removeWhere((s) => s.id == id);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await _persistSnippets(prefs);
  }

  /// Inserts [text] into the active shell as if pasted, without a trailing
  /// newline — the user reviews and submits. Routed through [Terminal.paste]
  /// so bracketed-paste-aware TUIs (every modern agent) receive a multi-line
  /// prompt as one paste instead of N Enter presses.
  void insertPromptText(String text) {
    final session = activeSession;
    if (session == null || text.isEmpty) return;
    session.terminal.paste(text);
  }

  /// The session's SFTP channel, opening one on demand. Pass [fresh] to force a
  /// new channel: a cached client can belong to a connection that has since
  /// dropped, and every operation on it then hangs instead of failing.
  Future<SftpClient> _getSftpClient(TerminalSession session,
      {bool fresh = false}) async {
    final ssh = session.sshClient;
    if (ssh == null || ssh.isClosed) {
      session.sftpClient = null;
      throw Exception('El cliente SSH no está conectado');
    }
    if (!fresh && session.sftpClient != null) {
      return session.sftpClient!;
    }
    final sftp = await ssh.sftp().timeout(const Duration(seconds: 10));
    session.sftpClient = sftp;
    return sftp;
  }

  // Server console state (monitor + Docker). Owned here so the connection,
  // sudo mode, section and cached data survive tab switches; the ServerTab
  // listens to it directly (ListenableBuilder) so its refreshes don't trigger
  // app-wide rebuilds.
  ServerController? _server;
  ServerController get server =>
      _server ??= ServerController(openClient: openClient);

  /// Opens and authenticates a standalone [SSHClient] for [profile], without
  /// tying it to a terminal session. Non-fatal notices (missing device key,
  /// unparseable PEM) are reported through [onNotice]; auth/connect failures
  /// throw. Callers own the returned client and must close() it.
  Future<SSHClient> openClient(ConnectionProfile profile,
      {void Function(String msg)? onNotice}) async {
    final socket = await SSHSocket.connect(profile.host, profile.port,
        timeout: const Duration(seconds: 15));

    // Public-key auth: the phone's own device key (opt-in per profile) plus
    // any per-profile PEM. dartssh2 tries identities first and falls back to
    // the password automatically, so a profile can carry both. A PEM that
    // fails to parse is reported but doesn't block the connection attempt.
    final identities = <SSHKeyPair>[];
    if (profile.useDeviceKey) {
      final pem = await DeviceKey.privatePem();
      if (pem == null) {
        onNotice?.call(
            'Este perfil usa la llave del dispositivo pero aún no existe; '
            'génerala en Ajustes.');
      } else {
        identities.addAll(SSHKeyPair.fromPem(pem));
      }
    }
    final profilePem = profile.privateKey;
    if (profilePem != null && profilePem.trim().isNotEmpty) {
      try {
        // An encrypted PEM uses the profile password as its passphrase.
        identities.addAll(SSHKeyPair.fromPem(
            profilePem,
            (profile.password?.isNotEmpty ?? false)
                ? profile.password
                : null));
      } catch (e) {
        onNotice?.call('No se pudo leer la llave privada del perfil: $e');
      }
    }

    final client = SSHClient(
      socket,
      username: profile.username,
      identities: identities.isEmpty ? null : identities,
      onPasswordRequest: () => profile.password ?? '',
    );
    // Fail fast on bad credentials instead of on the first channel open.
    await client.authenticated;
    return client;
  }

  // Connect a session to a remote SSH server
  Future<void> _connectSessionToSSH(TerminalSession session, ConnectionProfile profile,
      {String? initialCommand}) async {
    _disposeWriters(session);
    // A reconnect reuses the session object: drop every leftover from the
    // previous connection first — bound forward ports (they'd fail to re-bind
    // in _setupForwards) and stale SFTP/SSH handles.
    for (final server in session.forwardServers) {
      server.close();
    }
    session.forwardServers.clear();
    session.sftpClient?.close();
    session.sftpClient = null;
    session.sshSession?.close();
    session.sshSession = null;
    session.sshClient?.close();
    session.sshClient = null;
    session.connectionStatus = ConnectionStatus.connecting;
    notifyListeners();

    session.terminal.write('\r\nConectando a ${profile.name} (${profile.host}:${profile.port})...\r\n');

    try {
      session.sshClient = await openClient(
        profile,
        onNotice: (msg) => session.terminal.write('$msg\r\n'),
      );

      session.terminal.write('Autenticado correctamente. Abriendo terminal shell...\r\n');

      final pty = SSHPtyConfig(
        width: session.terminal.viewWidth,
        height: session.terminal.viewHeight,
      );
      if (initialCommand != null) {
        // Dedicated-purpose session (e.g. a `docker exec` shell from the
        // Docker panel): run the given command instead of a login shell.
        session.sshSession =
            await session.sshClient!.execute(initialCommand, pty: pty);
      } else if (profile.useTmux) {
        // Persistent session: `tmux new -A` attaches to the named session if
        // it exists and creates it otherwise, so reconnecting after a network
        // drop re-attaches to whatever kept running on the server (e.g. an AI
        // agent mid-task). Falls back to a plain login shell — with a visible
        // notice — when the server has no tmux.
        session.sshSession = await session.sshClient!.execute(
          'command -v tmux >/dev/null 2>&1 '
          "&& exec tmux new-session -A -s '${profile.tmuxSessionName}' "
          '|| { echo "[KALA] tmux no está instalado en el servidor; abriendo shell normal."; '
              'exec "\${SHELL:-sh}" -l; }',
          pty: pty,
        );
      } else {
        session.sshSession = await session.sshClient!.shell(pty: pty);
      }

      // Forward later size changes to the remote PTY. xterm and
      // resizeTerminal both use (width=cols, height=rows) order.
      session.terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        session.sshSession?.resizeTerminal(width, height, pixelWidth, pixelHeight);
      };

      // Ask the remote shell to report its cwd via OSC 7 on every prompt, so the
      // git panel tracks where the terminal actually is (see [terminalCwd]).
      _seedCwdReporting(session);

      session.connectionStatus = ConnectionStatus.remote;
      session.started = true;
      // First live SSH session → keep the process alive while backgrounded.
      _ensureBackgroundService();

      await _setupForwards(session, profile);

      // Separate batched writers for stdout/stderr: each keeps its own UTF-8
      // decoder so a multi-byte glyph split across packets is reassembled
      // instead of mangled, and bursts are coalesced into one write per frame.
      final stdoutWriter = _TerminalWriter(
        session.terminal,
        isInForeground: () => _appInForeground,
        onTextWritten: (_) => _onTerminalOutput(session),
      );
      final stderrWriter = _TerminalWriter(
        session.terminal,
        isInForeground: () => _appInForeground,
        onTextWritten: (_) => _onTerminalOutput(session),
      );
      session._outputWriters.addAll([stdoutWriter, stderrWriter]);
      session.sshSession!.stdout.listen(stdoutWriter.add);
      session.sshSession!.stderr.listen(stderrWriter.add);

      session.terminal.onOutput = (data) {
        final out = _applyModifiers(data);
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
        final sftp = await _getSftpClient(session);
        session.currentPath = await sftp.absolute('.').timeout(const Duration(seconds: 5));
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

  /// Re-establishes a dropped SSH session in place, reusing its profile. With
  /// tmux enabled on the profile this re-attaches to the still-running remote
  /// session. No-op while the session is live or a reconnect is in flight.
  /// Called by the "Reconectar" banner and by the on-resume sweep.
  Future<void> reconnectSession(TerminalSession session) async {
    final profile = session.activeProfile;
    if (profile == null) return;
    if (session.connectionStatus != ConnectionStatus.disconnected) return;
    if (session.reconnecting) return;
    session.reconnecting = true;
    notifyListeners();
    try {
      await _connectSessionToSSH(session, profile);
    } finally {
      session.reconnecting = false;
      notifyListeners();
    }
  }

  // Connect to Remote SSH (API exposed to ConnectionsTab)
  Future<void> connectToSSH(ConnectionProfile profile,
      {String? initialCommand, String? sessionName}) async {
    createNewSession(
      profile: profile,
      initialCommand: initialCommand,
      sessionName: sessionName,
    );
    _activeTabIndex = 1; // Switch to terminal tab
    notifyListeners();
  }

  // Switch to an open session
  void switchSession(int index) {
    if (index < 0 || index >= _sessions.length) return;
    _activeSessionIndex = index;
    // Looking at the session acknowledges its pending agent alert.
    _sessions[index].hasPendingAlert = false;
    // The explorer's selection/search belong to the previous session's listing.
    _selectedPaths = const {};
    _fileSearchQuery = '';
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
      // No SSH sessions left: drop back to the connections tab. A new session
      // is created only when the user connects to a profile again.
      _activeSessionIndex = -1;
      _activeTabIndex = 0;
      notifyListeners();
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

  // Disconnect the active session: tear down its SSH connection, close its tab,
  // and return to the connections list.
  void disconnect() {
    if (_activeSessionIndex < 0) return;
    closeSession(_activeSessionIndex);
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
    _sessionAlertTimers.remove(session.id)?.cancel();
    _sessionCheckTimers.remove(session.id)?.cancel();
    _disposeWriters(session);
    for (final server in session.forwardServers) {
      server.close();
    }
    session.forwardServers.clear();
    session.sftpClient?.close();
    session.sshSession?.close();
    session.sshClient?.close();
    session.sftpClient = null;
    session.sshSession = null;
    session.sshClient = null;
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

  // SHIFT is a sticky modifier just like CTRL: it arms, then reshapes the next
  // key sent — from a quick key or a hardware keyboard — into its shifted
  // sequence and disarms. Its main use is TUI agents (Claude Code, etc.) where
  // Shift+Tab (`\x1b[Z`) cycles the mode (plan → accept → normal).
  bool _shiftArmed = false;
  bool get shiftArmed => _shiftArmed;

  void toggleShift() {
    _shiftArmed = !_shiftArmed;
    notifyListeners();
  }

  /// If SHIFT is armed, rewrite [data] to its shifted form and disarm:
  ///   - Tab (`\t`)            → `\x1b[Z`      (CSI Z / back-tab)
  ///   - arrows `\x1b[A…D`     → `\x1b[1;2A…D` (shift-modified cursor keys)
  ///   - a lone lowercase a-z  → its uppercase letter
  /// Anything else passes through unchanged.
  String _applyShiftModifier(String data) {
    if (!_shiftArmed || data.isEmpty) return data;
    _shiftArmed = false;
    notifyListeners();
    if (data == '\t') return '\x1b[Z';
    final arrow = RegExp(r'^\x1b\[([A-D])$');
    final m = arrow.firstMatch(data);
    if (m != null) return '\x1b[1;2${m.group(1)}';
    if (data.length == 1) {
      final c = data.codeUnitAt(0);
      if (c >= 0x61 && c <= 0x7a) return String.fromCharCode(c - 0x20);
    }
    return data;
  }

  /// If CTRL is armed, fold the first character of [data] into its control code
  /// and disarm; otherwise return [data] unchanged. Control codes are the low
  /// 5 bits of the ASCII letter (`'c' & 0x1f == 0x03`).
  String _applyCtrlModifier(String data) {
    if (!_ctrlArmed || data.isEmpty) return data;
    _ctrlArmed = false;
    notifyListeners();
    if (data == '\x1b[3~') return '\x1b[3;5~'; // Ctrl + Delete
    final ctrl = String.fromCharCode(data.codeUnitAt(0) & 0x1f);
    return ctrl + data.substring(1);
  }

  /// Apply every armed modifier to [data] before it reaches the shell. SHIFT is
  /// applied first so a shifted key (e.g. Tab → `\x1b[Z`) is what CTRL then sees.
  String _applyModifiers(String data) => _applyCtrlModifier(_applyShiftModifier(data));


  // Send input directly to terminal
  void sendTerminalInput(String text) {
    final session = activeSession;
    if (session == null) return;
    final out = _applyModifiers(text);
    if (session.connectionStatus == ConnectionStatus.remote && session.sshSession != null) {
      session.sshSession!.write(utf8.encode(out));
    }
  }

  /// Write [text] straight to the active shell, bypassing the CTRL/SHIFT
  /// modifiers and adding no newline. Used when inserting a chunk of literal
  /// text (e.g. an attached file's path) that must not be reshaped or executed.
  void _typeLiteral(TerminalSession session, String text) {
    final bytes = utf8.encode(text);
    if (session.connectionStatus == ConnectionStatus.remote &&
        session.sshSession != null) {
      session.sshSession!.write(bytes);
    }
  }

  /// Strip a filename down to shell/agent-safe characters: spaces and anything
  /// outside `[A-Za-z0-9._-]` become `_`. Keeps the resulting path unquoted so a
  /// TUI agent (Claude Code) sees a clean path with no wrapping quotes to parse.
  String _sanitizeFilename(String name) {
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return safe.isEmpty ? 'archivo' : safe;
  }

  /// Format [path] for insertion into the prompt. If it's already free of shell
  /// metacharacters it goes in bare (cleanest for agents like Claude Code);
  /// otherwise it's single-quoted so a plain shell still receives it intact.
  String _formatPathForInput(String path) {
    if (RegExp(r'^[A-Za-z0-9@%+=:,./_-]+$').hasMatch(path)) return path;
    return "'${path.replaceAll("'", "'\\''")}'";
  }

  /// Attach a file for a TUI agent: let the user pick any document/image or PDF,
  /// put it somewhere the **agent process can actually read**, and insert its
  /// path into the prompt without executing — the user wraps it in their message
  /// (e.g. `describe esta imagen /tmp/attachments/foto.png`).
  ///
  /// This is the whole point over SSH: the picked file lives on the phone, but
  /// Claude Code runs on the server, so the file is uploaded to
  /// `/tmp/attachments/` on the server via SFTP and that server-side path is
  /// inserted — the remote agent reads the real bytes, not a phone path it can't
  /// see. Requires a live SSH session.
  ///
  /// Returns `(ok, message)` for the caller to surface; `ok == false` with an
  /// empty message means the user cancelled the picker.
  Future<({bool ok, String message})> attachFile() async {
    final session = activeSession;
    if (session == null) return (ok: false, message: 'No hay sesión activa');

    final picked = await FilePicker.platform.pickFiles(type: FileType.any);
    final src = picked?.files.single.path;
    if (src == null) return (ok: false, message: '');
    final rawName = src.split('/').last;
    final name = _sanitizeFilename(rawName);

    // The agent (Claude Code, etc.) runs on the server, so the picked phone file
    // is uploaded to `/tmp/attachments/` over SFTP and that server-side path is
    // inserted — the remote agent reads the real bytes, not a phone path.
    if (session.connectionStatus != ConnectionStatus.remote ||
        session.sshClient == null) {
      return (ok: false, message: 'Adjuntar requiere una sesión SSH activa');
    }
    final String shellPath;
    try {
      final sftp = await session.sshClient!.sftp();
      try {
        await sftp.mkdir('/tmp/attachments');
      } catch (_) {
        // Already exists — ignore.
      }
      shellPath = '/tmp/attachments/$name';
      final bytes = await File(src).readAsBytes();
      final f = await sftp.open(shellPath,
          mode: SftpFileOpenMode.write |
              SftpFileOpenMode.create |
              SftpFileOpenMode.truncate);
      await f.write(Stream.value(bytes));
      await f.close();
    } catch (e) {
      return (ok: false, message: 'No se pudo adjuntar: $e');
    }

    // Leading + trailing space keep the path separate from whatever the user
    // types around it. The path itself is bare when safe, quoted when not.
    _typeLiteral(session, ' ${_formatPathForInput(shellPath)} ');
    return (ok: true, message: 'Adjuntado: $name');
  }

  // File Explorer Operations
  Future<void> changeDirectory(String newPath) async {
    final session = activeSession;
    if (session == null || session.isLoadingFiles) return;
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
    if (session == null || session.isLoadingFiles) return;

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
    if (session == null || session.isLoadingFiles || session.pathHistory.isEmpty) return;
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

  bool _showHidden = true;
  bool get showHidden => _showHidden;

  List<FileSystemEntityInfo> _clipboard = const [];
  bool _clipboardIsMove = false;
  SSHClient? _clipboardSshClient;
  int get clipboardCount => _clipboard.length;
  bool get clipboardIsMove => _clipboardIsMove;

  // ---- Download state -------------------------------------------------------
  // A download runs in two phases: first the selection is walked (over SFTP or
  // the local filesystem) to build the full list of files to copy, then those
  // files are streamed to disk. Both phases publish progress here so the
  // explorer can show a real bar (bytes, not just "item 1 of 2"), and the
  // terminal result — success or the per-file failures — stays in
  // [_downloadPhase] until the user dismisses it, so a download that finished
  // while the user was on another tab is still visible when they come back.
  DownloadPhase _downloadPhase = DownloadPhase.idle;
  DownloadPhase get downloadPhase => _downloadPhase;
  bool get isDownloading =>
      _downloadPhase == DownloadPhase.scanning ||
      _downloadPhase == DownloadPhase.transferring;

  int _downloadFilesDone = 0;
  int _downloadFilesTotal = 0;
  int get downloadFilesDone => _downloadFilesDone;
  int get downloadFilesTotal => _downloadFilesTotal;

  int _downloadBytesDone = 0;
  int _downloadBytesTotal = 0;
  int get downloadBytesDone => _downloadBytesDone;
  int get downloadBytesTotal => _downloadBytesTotal;

  String _downloadCurrentName = '';
  String get downloadCurrentName => _downloadCurrentName;

  String _downloadDestDir = '';
  String get downloadDestDir => _downloadDestDir;

  String _downloadError = '';
  String get downloadError => _downloadError;

  List<String> _downloadFailures = const [];
  List<String> get downloadFailures => _downloadFailures;

  bool _downloadCancelled = false;

  /// Fraction of the transfer that is done, or null while the size of the job
  /// is still unknown (scanning) — the bar shows an indeterminate spinner then.
  double? get downloadProgress {
    if (_downloadPhase == DownloadPhase.scanning) return null;
    if (_downloadBytesTotal > 0) {
      return (_downloadBytesDone / _downloadBytesTotal).clamp(0.0, 1.0);
    }
    if (_downloadFilesTotal > 0) {
      return (_downloadFilesDone / _downloadFilesTotal).clamp(0.0, 1.0);
    }
    return null;
  }

  /// Ask the in-flight download to stop. It finishes the chunk it is on, drops
  /// the partial file and settles into [DownloadPhase.done] with whatever it
  /// had already written.
  void cancelDownload() {
    if (!isDownloading) return;
    _downloadCancelled = true;
    notifyListeners();
  }

  /// Clear the finished/failed result bar.
  void dismissDownloadStatus() {
    if (isDownloading) return;
    if (_downloadPhase == DownloadPhase.idle) return;
    _downloadPhase = DownloadPhase.idle;
    _downloadFailures = const [];
    _downloadError = '';
    notifyListeners();
  }

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

  void setShowHidden(bool value) {
    if (_showHidden == value) return;
    _showHidden = value;
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
    try {
      final sftp = session.connectionStatus == ConnectionStatus.remote
          ? await _getSftpClient(session)
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
      session.sftpClient = null;
    } finally {
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

    TerminalSession? srcSession;
    if (srcClient != null) {
      srcSession = _sessions.firstWhere(
        (s) => s.sshClient == srcClient,
        orElse: () => session,
      );
    }

    session.isLoadingFiles = true;
    notifyListeners();
    try {
      final srcSftp = srcSession != null ? await _getSftpClient(srcSession) : null;
      final destSftp = destClient != null ? await _getSftpClient(session) : null;

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
      session.sftpClient = null;
      if (srcSession != null) srcSession.sftpClient = null;
    } finally {
      if (isMove) {
        _clipboard = const [];
        _clipboardSshClient = null;
      }
      await _loadFiles();
    }
  }

  Future<void> pasteImageBytes(Uint8List imageBytes, {String ext = 'png'}) async {
    final session = activeSession;
    if (session == null) return;

    final now = DateTime.now();
    final timestamp = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    final fileName = 'pasted_image_$timestamp.$ext';

    session.isLoadingFiles = true;
    notifyListeners();

    try {
      if (session.connectionStatus == ConnectionStatus.remote) {
        final sftp = await _getSftpClient(session);
        final remoteFilePath = '${session.currentPath}/$fileName'.replaceAll('//', '/');
        final fileStream = await sftp.open(
          remoteFilePath,
          mode: SftpFileOpenMode.write | SftpFileOpenMode.create | SftpFileOpenMode.truncate,
        ).timeout(const Duration(seconds: 10));
        await fileStream.write(Stream.value(imageBytes)).timeout(const Duration(seconds: 30));
        await fileStream.close();
      } else {
        final localFilePath = '${session.currentPath}/$fileName'.replaceAll('//', '/');
        await File(localFilePath).writeAsBytes(imageBytes);
      }

      session.terminal.write('\r\n✓ Imagen guardada como: $fileName\r\n');
      sendTerminalInput(fileName);
    } catch (e) {
      session.terminal.write('\r\n⚠️ Error al guardar imagen pegada: $e\r\n');
      session.sftpClient = null;
    } finally {
      session.isLoadingFiles = false;
      notifyListeners();
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
        final isDir = entity.statSync().type == FileSystemEntityType.directory;
        await _copyEntry(
            srcSftp,
            entity.path,
            isDir,
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

  /// Download the selected remote (SFTP) or local entries into a local folder.
  /// Pass [destDir] to save into the folder the user picked; when null it falls
  /// back to the public Downloads folder.
  ///
  /// The selection is first walked to build the complete file list (so the
  /// progress bar knows the real byte total up front), then each file is
  /// *streamed* to a `.part` file and renamed into place, so an interrupted
  /// download never leaves a truncated file that looks complete. A file that
  /// fails (permissions, a broken symlink, a vanished file) is recorded in
  /// [downloadFailures] and the rest of the batch keeps going — one bad file no
  /// longer aborts the whole download half-way through.
  Future<void> downloadSelection({String? destDir}) async {
    final session = activeSession;
    final entries = _selectedEntries;
    if (session == null || entries.isEmpty || isDownloading) return;

    final isRemote = session.connectionStatus == ConnectionStatus.remote;
    if (isRemote && (session.sshClient == null || session.sshClient!.isClosed)) {
      _finishDownloadWithError('La sesión SSH no está conectada.');
      return;
    }

    _selectedPaths = const {};
    _downloadCancelled = false;
    _downloadFailures = const [];
    _downloadError = '';
    _downloadFilesDone = 0;
    _downloadFilesTotal = 0;
    _downloadBytesDone = 0;
    _downloadBytesTotal = 0;
    _downloadCurrentName = '';
    _downloadDestDir = '';
    _downloadPhase = DownloadPhase.scanning;
    notifyListeners();

    try {
      if (Platform.isAndroid) await _ensureStoragePermission();

      // Destination: the folder the user picked, or — as a fallback — the
      // public Downloads/KALA on Android, ~/Downloads/KALA elsewhere.
      final String finalDir;
      if (destDir != null && destDir.isNotEmpty) {
        finalDir = destDir;
      } else if (Platform.isAndroid) {
        finalDir = '/storage/emulated/0/Download/KALA';
      } else {
        final base = await getApplicationDocumentsDirectory();
        finalDir = '${base.path}/Downloads/KALA';
      }
      _downloadDestDir = finalDir;

      try {
        await Directory(finalDir).create(recursive: true);
        // create() succeeds on a read-only path on some Android volumes; only a
        // real write proves the folder is usable, and failing here (instead of
        // on the first file) keeps the error understandable.
        final probe = File('$finalDir/.kala_write_test');
        await probe.writeAsBytes(const [0]);
        await probe.delete();
      } catch (e) {
        throw Exception(
            'No se puede escribir en $finalDir. Concede el permiso de '
            'almacenamiento o elige otra carpeta.');
      }

      // A cached SFTP client can belong to a connection that has since dropped;
      // ask for a fresh one so a stale handle can't hang the download.
      final sftp = isRemote ? await _getSftpClient(session, fresh: true) : null;

      // ---- Phase 1: plan ----------------------------------------------------
      final plan = <_DownloadItem>[];
      for (final entry in entries) {
        if (_downloadCancelled) break;
        _downloadCurrentName = entry.name;
        notifyListeners();
        final dest = _childPath(finalDir, entry.name, Platform.pathSeparator);
        if (sftp != null) {
          await _planRemote(sftp, entry.path, dest, plan);
        } else {
          await _planLocal(entry.path, dest, plan);
        }
      }

      _downloadFilesTotal = plan.where((i) => !i.isDirectory).length;
      _downloadBytesTotal =
          plan.fold<int>(0, (sum, i) => sum + (i.isDirectory ? 0 : i.size));
      _downloadPhase = DownloadPhase.transferring;
      notifyListeners();

      // ---- Phase 2: transfer ------------------------------------------------
      var settledBytes = 0;
      for (final item in plan) {
        if (_downloadCancelled) break;

        if (item.isDirectory) {
          try {
            await Directory(item.destPath).create(recursive: true);
          } catch (e) {
            _recordDownloadFailure(item.srcPath, e);
          }
          continue;
        }

        _downloadCurrentName = item.name;
        notifyListeners();
        try {
          await _downloadFile(sftp, item, onBytes: (n) {
            _downloadBytesDone = settledBytes + n;
            _notifyDownloadProgress();
          });
          _downloadFilesDone++;
        } catch (e) {
          _recordDownloadFailure(item.srcPath, e);
        }
        // Whether it landed or failed, this file is settled: charge its full
        // size so the bar keeps advancing monotonically.
        settledBytes += item.size;
        _downloadBytesDone = settledBytes;
        notifyListeners();
      }

      _downloadCurrentName = '';
      _downloadPhase = DownloadPhase.done;

      final ok = _downloadFilesDone;
      final failed = _downloadFailures.length;
      if (_downloadCancelled) {
        session.terminal.write(
            'Descarga cancelada — $ok archivo(s) guardado(s) en $finalDir\r\n');
      } else if (failed > 0) {
        session.terminal.write('✓ $ok archivo(s) → $finalDir '
            '($failed con errores)\r\n');
      } else {
        session.terminal.write('✓ $ok archivo(s) → $finalDir\r\n');
      }
      notifyListeners();
    } catch (e) {
      // The SFTP channel may be the thing that broke; drop it so the next
      // operation opens a fresh one.
      session.sftpClient = null;
      session.terminal.write('Error al descargar: ${_briefError(e)}\r\n');
      _finishDownloadWithError(_briefError(e));
    }
  }

  void _finishDownloadWithError(String message) {
    _downloadPhase = DownloadPhase.error;
    _downloadError = message;
    _downloadCurrentName = '';
    notifyListeners();
  }

  void _recordDownloadFailure(String path, Object error) {
    _downloadFailures = [
      ..._downloadFailures,
      '${path.split('/').last}: ${_briefError(error)}',
    ];
  }

  static String _briefError(Object error) {
    var msg = error.toString();
    if (msg.startsWith('Exception: ')) msg = msg.substring(11);
    return msg.length > 160 ? '${msg.substring(0, 157)}…' : msg;
  }

  // Progress ticks arrive per 32KB chunk; rebuilding the explorer that often
  // would starve the transfer itself, so throttle the UI to ~10fps.
  DateTime _lastDownloadTick = DateTime.fromMillisecondsSinceEpoch(0);
  void _notifyDownloadProgress() {
    final now = DateTime.now();
    if (now.difference(_lastDownloadTick) < const Duration(milliseconds: 100)) {
      return;
    }
    _lastDownloadTick = now;
    notifyListeners();
  }

  static const Duration _sftpOpTimeout = Duration(seconds: 20);
  // Idle timeout *between* chunks — a big file may legitimately take minutes,
  // but a silent server for this long means the connection is gone.
  static const Duration _sftpStallTimeout = Duration(seconds: 45);

  // Walk a remote entry, appending the directories to create and the files to
  // fetch. `stat` (which follows symlinks) decides the type: the `listdir`
  // attributes report a symlinked directory as a plain link, and treating that
  // as a file used to blow up the whole download.
  Future<void> _planRemote(
      SftpClient sftp, String srcPath, String destPath, List<_DownloadItem> out,
      {int depth = 0}) async {
    if (_downloadCancelled || depth > 32) return;
    final name = srcPath.split('/').last;

    SftpFileAttrs attrs;
    try {
      attrs = await sftp.stat(srcPath).timeout(_sftpOpTimeout);
    } catch (e) {
      _recordDownloadFailure(srcPath, e);
      return;
    }

    if (attrs.isDirectory) {
      out.add(_DownloadItem(
          srcPath: srcPath, destPath: destPath, name: name, isDirectory: true));
      final List<SftpName> items;
      try {
        items = await sftp.listdir(srcPath).timeout(_sftpOpTimeout);
      } catch (e) {
        _recordDownloadFailure(srcPath, e);
        return;
      }
      for (final item in items) {
        if (item.filename == '.' || item.filename == '..') continue;
        await _planRemote(
          sftp,
          _childPath(srcPath, item.filename, '/'),
          _childPath(destPath, item.filename, Platform.pathSeparator),
          out,
          depth: depth + 1,
        );
      }
      return;
    }

    // Sockets, pipes and devices aren't downloadable; skip them silently rather
    // than failing the batch on them.
    if (attrs.type != null && !attrs.isFile) return;

    out.add(_DownloadItem(
      srcPath: srcPath,
      destPath: destPath,
      name: name,
      isDirectory: false,
      size: attrs.size ?? 0,
    ));
    _downloadFilesTotal = out.where((i) => !i.isDirectory).length;
    _notifyDownloadProgress();
  }

  Future<void> _planLocal(
      String srcPath, String destPath, List<_DownloadItem> out,
      {int depth = 0}) async {
    if (_downloadCancelled || depth > 32) return;
    final name = srcPath.split(Platform.pathSeparator).last;

    final FileSystemEntityType type;
    try {
      type = await FileSystemEntity.type(srcPath); // follows symlinks
    } catch (e) {
      _recordDownloadFailure(srcPath, e);
      return;
    }

    if (type == FileSystemEntityType.directory) {
      out.add(_DownloadItem(
          srcPath: srcPath, destPath: destPath, name: name, isDirectory: true));
      try {
        for (final entity in Directory(srcPath).listSync(followLinks: false)) {
          final child = entity.path.split(Platform.pathSeparator).last;
          await _planLocal(
            entity.path,
            _childPath(destPath, child, Platform.pathSeparator),
            out,
            depth: depth + 1,
          );
        }
      } catch (e) {
        _recordDownloadFailure(srcPath, e);
      }
      return;
    }

    if (type != FileSystemEntityType.file) return;

    var size = 0;
    try {
      size = await File(srcPath).length();
    } catch (_) {/* unreadable size — still try to copy it */}
    out.add(_DownloadItem(
      srcPath: srcPath,
      destPath: destPath,
      name: name,
      isDirectory: false,
      size: size,
    ));
    _downloadFilesTotal = out.where((i) => !i.isDirectory).length;
    _notifyDownloadProgress();
  }

  // Stream one file to disk. Writes to `<dest>.part` and renames on success, so
  // a cancelled or broken transfer can never be mistaken for a complete file.
  Future<void> _downloadFile(SftpClient? sftp, _DownloadItem item,
      {required void Function(int bytesRead) onBytes}) async {
    final dest = File(item.destPath);
    await dest.parent.create(recursive: true);

    // A directory sitting where the file must go would make rename() fail.
    if (await Directory(item.destPath).exists()) {
      await Directory(item.destPath).delete(recursive: true);
    }

    final part = File('${item.destPath}.part');
    final sink = part.openWrite();
    var written = 0;
    var completed = false;
    try {
      final Stream<List<int>> source;
      SftpFile? handle;
      if (sftp != null) {
        handle = await sftp
            .open(item.srcPath, mode: SftpFileOpenMode.read)
            .timeout(_sftpOpTimeout);
        source = handle.read();
      } else {
        source = File(item.srcPath).openRead();
      }

      try {
        await for (final chunk in source.timeout(_sftpStallTimeout)) {
          if (_downloadCancelled) break;
          sink.add(chunk);
          written += chunk.length;
          onBytes(written);
        }
        completed = !_downloadCancelled;
      } finally {
        await handle?.close();
      }
      await sink.flush();
    } finally {
      // close() rethrows whatever the sink swallowed, so it goes first — but the
      // .part file must never outlive a failed or cancelled transfer either way.
      try {
        await sink.close();
      } finally {
        if (!completed) await _deleteQuietly(part);
      }
    }

    await part.rename(item.destPath);
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {/* best effort */}
  }

  /// Send a `cd` into the active SSH session's shell and jump to the terminal
  /// tab. [path] is the remote path the file explorer is showing.
  Future<void> openTerminalAt(String path) async {
    final session = activeSession;
    if (session == null || path.isEmpty) return;
    if (session.connectionStatus != ConnectionStatus.remote ||
        session.sshSession == null) {
      return;
    }

    // Single-quote for the shell; embedded single quotes become '\''.
    final escaped = path.replaceAll("'", "'\\''");
    session.sshSession!.write(utf8.encode("cd '$escaped'\r"));
    _activeTabIndex = 1;
    notifyListeners();
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
      if (!_syncTerminalPath) return;
      if (session.terminal.isUsingAltBuffer) return;
      if (_detectAgent(session) != null) return;
      if (session.connectionStatus != ConnectionStatus.remote ||
          session.sshSession == null) {
        return;
      }

      final escaped = session.currentPath.replaceAll("'", "'\\''");
      // Add a space to avoid clogging shell history (common ignorespace setting)
      session.sshSession!.write(utf8.encode(" cd '$escaped'\r"));
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

    try {
      if (session.connectionStatus == ConnectionStatus.remote && session.sshClient != null) {
        final sftp = await _getSftpClient(session);
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
                  isDirectory: stat.type == FileSystemEntityType.directory,
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
      session.sftpClient = null;
    } finally {
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

    SftpFile? fileStream;
    try {
      // Drop any temp copy from a previously open remote media file before
      // loading the next one.
      _disposeTempMediaFile();

      if (isOfficeOrExternalDocumentPath(file.path)) {
        final String localPath;
        if (isRemote && sshClient != null) {
          final sftp = await _getSftpClient(session);
          fileStream =
              await sftp.open(file.path, mode: SftpFileOpenMode.read).timeout(const Duration(seconds: 5));
          final bytes = await fileStream.readBytes().timeout(const Duration(seconds: 15));
          final tempDir = await getTemporaryDirectory();
          final tempFile = File('${tempDir.path}/${file.name}');
          await tempFile.writeAsBytes(bytes);
          localPath = tempFile.path;
          _tempMediaFile = tempFile;
        } else {
          localPath = file.path;
        }

        final result = await OpenFilex.open(localPath);
        if (result.type != ResultType.done) {
          session.terminal.write('No se pudo abrir el documento: ${result.message}\r\n');
        }

        session.isLoadingFiles = false;
        notifyListeners();
        return;
      }

      // Read the content *before* updating _editingFilePath so the editor only
      // rebuilds (and initializes its controller) once the content is ready.
      // Otherwise the editor inits with empty content and never refreshes.
      if (isVideoPath(file.path) || isAudioPath(file.path)) {
        // Video/audio play through media_kit, which needs a local file path.
        // Local files are played in place; remote files are downloaded to a
        // temp file first.
        if (isRemote && sshClient != null) {
          final sftp = await _getSftpClient(session);
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
          final sftp = await _getSftpClient(session);
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
          final sftp = await _getSftpClient(session);
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
      session.sftpClient = null;
    } finally {
      if (fileStream != null) {
        fileStream.close();
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

    SftpFile? fileStream;
    try {
      final bytes = utf8.encode(_editingFileContent);
      if (_isEditingFileRemote && _editingSshClient != null) {
        final editSession = _sessions.firstWhere(
          (s) => s.sshClient == _editingSshClient,
          orElse: () => session ?? activeSession!,
        );
        final sftp = await _getSftpClient(editSession);
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
        session.sftpClient = null;
      }
      if (_isEditingFileRemote && _editingSshClient != null) {
        final editSession = _sessions.firstWhere(
          (s) => s.sshClient == _editingSshClient,
          orElse: () => session ?? activeSession!,
        );
        editSession.sftpClient = null;
      }
    } finally {
      if (fileStream != null) {
        fileStream.close();
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

  // --- TERMINAL CWD TRACKING (OSC 7) ---

  /// Parses an OSC 7 payload (`file://host/path`, possibly percent-encoded) and
  /// stores the decoded path as the session's live working directory.
  void _updateTerminalCwd(TerminalSession session, String payload) {
    var value = payload.trim();
    if (value.isEmpty) return;
    if (value.startsWith('file://')) {
      value = value.substring('file://'.length);
      // Strip the authority (hostname) up to the first slash: file://host/path.
      final slash = value.indexOf('/');
      value = slash >= 0 ? value.substring(slash) : '/';
    }
    try {
      value = Uri.decodeFull(value);
    } catch (_) {
      // Leave the raw value if it isn't valid percent-encoding.
    }
    if (value.isEmpty) return;
    if (session.terminalCwd == value) return;
    session.terminalCwd = value;
  }

  /// Installs a `PROMPT_COMMAND` that emits OSC 7 on every prompt, so we can
  /// track the shell's real cwd without polling. Best-effort: harmless on
  /// shells that ignore `PROMPT_COMMAND` (they just fall back to the explorer
  /// path). Sent with a small delay so it lands after the login shell is ready,
  /// and with a leading space so it's kept out of history when `HISTCONTROL`
  /// includes `ignorespace`.
  void _seedCwdReporting(TerminalSession session) {
    Future.delayed(const Duration(milliseconds: 900), () {
      if (session.connectionStatus != ConnectionStatus.remote) return;
      const cmd =
          " PROMPT_COMMAND='printf \"\\033]7;file://\$HOSTNAME\$PWD\\033\\134\"'"
          "\${PROMPT_COMMAND:+;\$PROMPT_COMMAND}\r";
      try {
        session.sshSession?.write(utf8.encode(cmd));
      } catch (e) {
        debugPrint('Error seeding cwd reporting: $e');
      }
    });
  }

  /// The directory git operations should run in for [session]: the terminal's
  /// tracked cwd when known, otherwise the file explorer's path.
  String _workingDirFor(TerminalSession session) {
    final cwd = session.terminalCwd;
    if (cwd != null && cwd.isNotEmpty) return cwd;
    return session.currentPath;
  }

  // --- GIT STATUS WORKFLOW ---

  Future<List<GitChangedFile>> getGitStatus() async {
    final session = activeSession;
    if (session == null) return [];

    final currentDir = _workingDirFor(session);
    String output = '';

    if (session.connectionStatus == ConnectionStatus.remote) {
      if (session.sshClient == null) return [];
      try {
        final run = await session.sshClient!.execute('cd "$currentDir" && git status --porcelain');
        final bytes = await run.stdout.cast<List<int>>().transform(utf8.decoder).join();
        output = bytes;
      } catch (e) {
        debugPrint('Error running remote git status: $e');
      }
    } else {
      try {
        final res = await Process.run('git', ['status', '--porcelain'], workingDirectory: currentDir);
        output = res.stdout as String;
      } catch (e) {
        debugPrint('Error running local git status: $e');
      }
    }

    final List<GitChangedFile> files = [];
    final lines = const LineSplitter().convert(output);
    for (final line in lines) {
      if (line.length < 4) continue;
      final status = line.substring(0, 2).trim();
      final relative = line.substring(3).trim();
      final sanitizedRelative = relative.replaceAll('"', '');
      final absPath = currentDir.endsWith('/') 
          ? '$currentDir$sanitizedRelative' 
          : '$currentDir/$sanitizedRelative';
      
      files.add(GitChangedFile(
        status: status,
        relativePath: sanitizedRelative,
        absolutePath: absPath,
      ));
    }
    return files;
  }

  void navigateToGitFile(GitChangedFile file) async {
    final lastSlash = file.absolutePath.lastIndexOf('/');
    final parentDir = lastSlash > 0 ? file.absolutePath.substring(0, lastSlash) : '/';
    
    await changeDirectory(parentDir);

    if (file.status != 'D') {
      final fileName = file.relativePath.contains('/')
          ? file.relativePath.substring(file.relativePath.lastIndexOf('/') + 1)
          : file.relativePath;
          
      final fileEntity = FileSystemEntityInfo(
        name: fileName,
        path: file.absolutePath,
        isDirectory: false,
        size: 0,
        modified: DateTime.now(),
      );
      await openFile(fileEntity);
    } else {
      setActiveTabIndex(2);
    }
  }

  Future<String> getGitRoot() async {
    final session = activeSession;
    if (session == null) return '';

    final currentDir = _workingDirFor(session);
    if (session.connectionStatus == ConnectionStatus.remote) {
      if (session.sshClient == null) return currentDir;
      try {
        final run = await session.sshClient!.execute('cd "$currentDir" && git rev-parse --show-toplevel');
        final bytes = await run.stdout.cast<List<int>>().transform(utf8.decoder).join();
        final path = bytes.trim();
        if (path.isNotEmpty && !path.startsWith('fatal')) {
          return path;
        }
      } catch (e) {
        debugPrint('Error finding remote git root: $e');
      }
    } else {
      try {
        final res = await Process.run('git', ['rev-parse', '--show-toplevel'], workingDirectory: currentDir);
        if (res.exitCode == 0) {
          final path = (res.stdout as String).trim();
          if (path.isNotEmpty) {
            return path;
          }
        }
      } catch (e) {
        debugPrint('Error finding local git root: $e');
      }
    }
    return currentDir;
  }

  Future<List<FileSystemEntityInfo>> listDirectoriesOf(String path) async {
    final session = activeSession;
    if (session == null) return [];

    final List<FileSystemEntityInfo> dirs = [];
    try {
      if (session.connectionStatus == ConnectionStatus.remote && session.sshClient != null) {
        final sftp = await _getSftpClient(session);
        final list = await sftp.listdir(path).timeout(const Duration(seconds: 5));
        for (final item in list) {
          if (item.filename == '.' || item.filename == '..') continue;
          if (item.filename.startsWith('.')) continue; // ignore hidden files
          if (item.attr.isDirectory) {
            dirs.add(FileSystemEntityInfo(
              name: item.filename,
              path: '$path/${item.filename}'.replaceAll('//', '/'),
              isDirectory: true,
              size: item.attr.size ?? 0,
              modified: DateTime.fromMillisecondsSinceEpoch((item.attr.modifyTime ?? 0) * 1000),
            ));
          }
        }
      } else {
        final dir = Directory(path);
        if (await dir.exists()) {
          await for (final entity in dir.list(followLinks: false)) {
            if (entity is Directory) {
              final name = entity.path.split(Platform.pathSeparator).last;
              if (name.startsWith('.')) continue;
              final stat = await entity.stat();
              dirs.add(FileSystemEntityInfo(
                name: name,
                path: entity.path,
                isDirectory: true,
                size: stat.size,
                modified: stat.modified,
              ));
            }
          }
        }
      }
      dirs.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } catch (e) {
      debugPrint('Error listing directories of $path: $e');
    }
    return dirs;
  }

  /// Like [listDirectoriesOf] but also returns files, so the git panel's tree
  /// can show file leaves. Directories come first, then files, each sorted by
  /// name. Hidden entries (dotfiles) are skipped, matching the folder listing.
  Future<List<FileSystemEntityInfo>> listTreeEntries(String path) async {
    final session = activeSession;
    if (session == null) return [];

    final List<FileSystemEntityInfo> dirs = [];
    final List<FileSystemEntityInfo> files = [];
    try {
      if (session.connectionStatus == ConnectionStatus.remote && session.sshClient != null) {
        final sftp = await _getSftpClient(session);
        final list = await sftp.listdir(path).timeout(const Duration(seconds: 5));
        for (final item in list) {
          if (item.filename == '.' || item.filename == '..') continue;
          if (item.filename.startsWith('.')) continue;
          final entry = FileSystemEntityInfo(
            name: item.filename,
            path: '$path/${item.filename}'.replaceAll('//', '/'),
            isDirectory: item.attr.isDirectory,
            size: item.attr.size ?? 0,
            modified: DateTime.fromMillisecondsSinceEpoch((item.attr.modifyTime ?? 0) * 1000),
          );
          (item.attr.isDirectory ? dirs : files).add(entry);
        }
      } else {
        final dir = Directory(path);
        if (await dir.exists()) {
          await for (final entity in dir.list(followLinks: false)) {
            final name = entity.path.split(Platform.pathSeparator).last;
            if (name.startsWith('.')) continue;
            final isDir = entity is Directory;
            final stat = await entity.stat();
            (isDir ? dirs : files).add(FileSystemEntityInfo(
              name: name,
              path: entity.path,
              isDirectory: isDir,
              size: stat.size,
              modified: stat.modified,
            ));
          }
        }
      }
      dirs.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      files.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } catch (e) {
      debugPrint('Error listing tree entries of $path: $e');
    }
    return [...dirs, ...files];
  }

  /// Sends [prompt] straight to the AI agent running in the active terminal
  /// (pastes it, then submits with Enter). Returns `null` on success or a
  /// human-readable error when there's no live agent to receive it — no active
  /// session, a dropped connection, or no full-screen agent TUI on screen
  /// (which also covers the "agent exited / out of tokens" case, since a
  /// crashed agent drops back to the shell and leaves the alt-screen).
  String? sendAgentPrompt(String prompt) {
    final session = activeSession;
    if (session == null) return 'No hay una sesión activa.';
    if (session.connectionStatus != ConnectionStatus.remote) {
      return 'No hay una conexión activa.';
    }
    if (!session.terminal.isUsingAltBuffer) {
      return 'No hay un agente de IA abierto en la terminal. Ábrelo (p. ej. claude) y vuelve a intentarlo.';
    }
    session.terminal.paste(prompt);
    // Give the agent a beat to ingest the bracketed paste before submitting.
    Future.delayed(const Duration(milliseconds: 120), () {
      if (session.connectionStatus == ConnectionStatus.remote) {
        sendTerminalInput('\r');
      }
    });
    return null;
  }

  Future<String?> commitChanges(String message) async {
    final session = activeSession;
    if (session == null) return 'Sin sesión activa';
    if (message.trim().isEmpty) return 'El mensaje de commit no puede estar vacío';

    final currentDir = _workingDirFor(session);
    try {
      if (session.connectionStatus == ConnectionStatus.remote) {
        if (session.sshClient == null) return 'Desconectado';
        final escapedMsg = message.replaceAll('"', '\\"');
        final run = await session.sshClient!.execute('cd "$currentDir" && git add . && git commit -m "$escapedMsg"');
        final errBytes = await run.stderr.cast<List<int>>().transform(utf8.decoder).join();
        final outBytes = await run.stdout.cast<List<int>>().transform(utf8.decoder).join();
        if (errBytes.isNotEmpty && !outBytes.contains('changed') && !outBytes.contains('insertion')) {
          return errBytes;
        }
      } else {
        final addRes = await Process.run('git', ['add', '.'], workingDirectory: currentDir);
        if (addRes.exitCode != 0) return addRes.stderr as String;

        final commitRes = await Process.run('git', ['commit', '-m', message], workingDirectory: currentDir);
        if (commitRes.exitCode != 0) return commitRes.stderr as String;
      }
      await _loadFilesForSession(session);
      notifyListeners();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _server?.dispose();
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
  final bool Function() isInForeground;
  final void Function(String text) onTextWritten;
  final StringBuffer _buffer = StringBuffer();
  late final Sink<List<int>> _decoder;
  Timer? _flushTimer;
  bool _disposed = false;

  _TerminalWriter(this.terminal, {
    required this.isInForeground,
    required this.onTextWritten,
  }) {
    _decoder = utf8.decoder.startChunkedConversion(_StringBufferSink(_buffer));
  }

  void add(List<int> data) {
    if (_disposed) return;
    _decoder.add(data);
    
    if (!isInForeground()) {
      _flush();
    } else {
      // Debounce to the next frame interval; cheap no-op if one is already armed.
      // Increased to 30ms to prevent UI stuttering during high-speed prints.
      _flushTimer ??= Timer(const Duration(milliseconds: 30), _flush);
    }
  }

  void _flush() {
    _flushTimer = null;
    if (_buffer.isEmpty) return;
    final text = _buffer.toString();
    _buffer.clear();
    terminal.write(text);
    onTextWritten(text);
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

class GitChangedFile {
  final String status;
  final String relativePath;
  final String absolutePath;

  GitChangedFile({
    required this.status,
    required this.relativePath,
    required this.absolutePath,
  });
}
