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
import '../models/connection_error.dart';
import '../models/connection_group.dart';
import '../models/connection_profile.dart';
import '../models/jump_chain.dart';
import '../models/notification_prefs.dart';
import '../models/prompt_snippet.dart';
import '../models/terminal_shortcut.dart';
import '../models/terminal_key_layer.dart';
import '../models/touch_pad.dart';
import '../widgets/joystick_recognizer.dart';
import '../services/file_error.dart';
import '../theme/app_theme.dart';
import '../models/agent_activity.dart';
import '../models/agent_launcher.dart';
import '../services/agent_monitor.dart';
import '../services/agent_screen.dart';
import '../services/background_service.dart';
import '../services/device_key.dart';
import '../services/git_service.dart';
import '../services/known_hosts.dart';
import '../services/server_controller.dart';
import '../services/tunnel_manager.dart';
import '../services/notification_service.dart';
import '../services/secure_store.dart';
import '../l10n/l10n.dart';

enum ConnectionStatus { disconnected, connecting, remote }

/// Type filter applied by the explorer's filter button.
enum FileTypeFilter { all, folders, filesOnly }

/// How the explorer orders a directory listing.
///
/// Directories always come first whatever the key: mixing them into a
/// size-sorted list buries every folder among the files, and "go into a
/// folder" is the explorer's most common action by far.
enum FileSortKey { name, modified, size, extension }

/// Lifecycle of a file download. [done] and [error] are terminal states that
/// stay on screen (as the explorer's result bar) until the user dismisses them.
enum DownloadPhase { idle, scanning, transferring, done, error }

/// What a file operation did, in words the user can read.
///
/// These operations used to report by writing into the *terminal* buffer — a
/// screen the user is not looking at while they work in the explorer, so a
/// failed delete looked exactly like nothing happening. The result travels
/// back to the caller instead, and the view that started the operation is the
/// one that reports it.
///
/// [detail] keeps the original exception text for a "ver detalle" affordance:
/// the friendly sentence is for acting on, the raw one for debugging.
class FileOpResult {
  final bool ok;
  final String message;
  final String? detail;

  const FileOpResult._(this.ok, this.message, this.detail);

  const FileOpResult.ok(String message) : this._(true, message, null);

  /// [what] names the operation ("No se pudo eliminar"); the cause is appended
  /// from [describeFileError], so the user gets both the action and the reason
  /// in one line.
  factory FileOpResult.failed(String what, Object error) {
    return FileOpResult._(
        false, '$what: ${describeFileError(error)}', rawDetail(error));
  }

  /// Nothing to report — the operation was a no-op.
  bool get isSilent => message.isEmpty;
}

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
  // Set when this session rang the bell (or emitted an OSC notification)
  // while it wasn't the visible one; rendered as an accent dot in the session
  // selector and cleared when the user switches to it.
  bool hasPendingAlert = false;
  // Last window title the remote program set (OSC 0/2). Many TUI agents put
  // their name here; used to pick the agent badge on alert notifications.
  String? lastTitle;
  // ---- Sticky agent identity (see [AppState._noteAgentEvidence]) ----
  // Which agent this session is running, resolved once from the strongest
  // evidence seen so far and then *kept*. It deliberately does not follow
  // passing mentions in the output: talking to Claude Code about Qwen used to
  // re-brand the session as Qwen and change the notification's look mid-task.
  String? agentId;
  String? agentLabel;
  // Strength of the evidence behind [agentId] — see AppState._evidence*
  // constants. Weaker evidence can never overwrite stronger.
  int agentEvidence = 0;
  // Manual override from the notifications screen: wins over all detection.
  String? agentOverrideId;
  // Accumulates keystrokes sent to the shell up to the next Enter, so the
  // command the user actually launched can be used as identity evidence.
  String inputLine = '';
  // Last time an agent alert fired for this session — debounce window so a
  // burst of BELs collapses into a single notification.
  DateTime? lastAlertAt;
  // Whether that last alert was a question. A "finished" alert must not
  // swallow the question that follows it a second later, so the debounce lets
  // done → question through (see [AppState._onSessionAlert]).
  bool lastAlertWasQuestion = false;
  // ---- Background agent-watch state (see [_evaluateAgentActivity]) ----
  // Signature (hash) of the normalized visible tail of the terminal the last
  // time it was inspected while backgrounded. Spinner glyphs, counters and
  // whitespace are stripped before hashing so idle redraw loops (Claude Code's
  // "✻ Thinking… (10s · esc to interrupt)") don't count as new output.
  int? watchSignature;
  // Signature of the same tail *without* stripping anything. It moves on every
  // spinner frame, so `rawWatchSignature changed && watchSignature unchanged`
  // means "the agent is animating, i.e. still working" — the distinction the
  // detector is built on.
  int? rawWatchSignature;
  // When the meaningful (noise-stripped) content last actually changed. Used
  // by the [AppState._agentNoiseCap] safety valve so a TUI that redraws
  // forever can't postpone the idle alert indefinitely.
  DateTime? lastMeaningfulChangeAt;
  // True once an autodetect alert fired for the current idle period; reset
  // whenever the (normalized) screen content actually changes again, so a
  // static prompt can never re-notify.
  bool watchAlertFired = false;
  // Until when incoming output counts as a *redraw* of what was already on
  // screen rather than as new content. Backgrounding the app hides the soft
  // keyboard, which resizes the PTY, which makes the shell (or the agent)
  // repaint everything: without this window that repaint looks like a fresh
  // answer that then goes quiet — i.e. it notified the user for leaving the
  // terminal. Set on every PTY resize and whenever the watch state is seeded.
  DateTime? redrawGraceUntil;
  // True while a reconnect attempt is in flight, so the banner button and the
  // on-resume sweep can't double-connect the same session.
  bool reconnecting = false;
  // Why the last connection attempt failed (or why the live connection
  // dropped), classified for the UI. Cleared as soon as a connection succeeds,
  // so a banner can never show a stale reason. See [ConnectionError].
  ConnectionError? lastError;
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
  }) : files = files ?? [];
}

// WidgetsBindingObserver: AppState tracks the app's foreground/background
// state itself (see [didChangeAppLifecycleState]) to decide whether an agent
// alert becomes a system notification and to reconnect dropped sessions on
// resume.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  // Navigation State

  /// Tab indices that become side-by-side panes on the desktop shell
  /// (terminal, explorer, editor).
  static const Set<int> paneableTabs = {1, 2, 3};

  int _activeTabIndex = 0;
  int get activeTabIndex => _activeTabIndex;

  /// Desktop only: which workspace pane owns the focus ring and the pane-scoped
  /// shortcuts. Inert on the compact layout.
  ///
  /// Kept in sync by [_setTab], so every existing "go to tab N" call site keeps
  /// meaning what it always meant: `openFile()` jumping to the editor becomes
  /// "focus the editor pane" once the editor is already on screen, without any
  /// of those call sites knowing about panes.
  int _focusedPaneTab = 1;
  int get focusedPaneTab => _focusedPaneTab;

  /// Single writer for [_activeTabIndex]. Does not notify — callers that are
  /// mid-mutation batch their own `notifyListeners()`.
  void _setTab(int index) {
    _activeTabIndex = index;
    if (paneableTabs.contains(index)) _focusedPaneTab = index;
  }

  void setActiveTabIndex(int index) {
    _setTab(index);
    notifyListeners();
  }

  // ---- Desktop workspace ---------------------------------------------------
  // Only read by the desktop shell; inert on the compact layout, which shows
  // one screen at a time.

  /// Share of the workspace width given to the side column (explorer / git).
  double _splitSide = 0.24;
  double get splitSide => _splitSide;

  /// Share of the main column's height given to the editor, above the terminal.
  double _splitEditorTerminal = 0.55;
  double get splitEditorTerminal => _splitEditorTerminal;

  bool _explorerPaneOpen = true;
  bool get explorerPaneOpen => _explorerPaneOpen;

  bool _gitPaneOpen = false;
  bool get gitPaneOpen => _gitPaneOpen;

  Future<void> setSplitSide(double value) async {
    if (_splitSide == value) return;
    _splitSide = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kSplitSide, value);
  }

  Future<void> setSplitEditorTerminal(double value) async {
    if (_splitEditorTerminal == value) return;
    _splitEditorTerminal = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kSplitEditorTerminal, value);
  }

  Future<void> setExplorerPaneOpen(bool value) async {
    if (_explorerPaneOpen == value) return;
    _explorerPaneOpen = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kExplorerPaneOpen, value);
  }

  Future<void> setGitPaneOpen(bool value) async {
    if (_gitPaneOpen == value) return;
    _gitPaneOpen = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kGitPaneOpen, value);
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

  /// Port forwards (`-L`/`-D`/`-R`) for every session. Its own ChangeNotifier
  /// so the byte counters don't rebuild the whole app — the tunnels screen
  /// listens to it directly (same split as [server]).
  final TunnelManager tunnels = TunnelManager();

  /// Live agent activity per session, feeding the agents dashboard. Its own
  /// ChangeNotifier for the same reason as [tunnels]: the watch loop below
  /// re-reads a session's screen several times a second, and pushing that
  /// through [notifyListeners] would rebuild the whole app at that rate.
  final AgentMonitor agents = AgentMonitor();

  // Per-session idle timers: armed when the (normalized) screen content
  // changes while backgrounded, fire after [_agentIdleDelay] of no further
  // meaningful change — the "the agent stopped writing" signal.
  final Map<String, Timer> _sessionAlertTimers = {};
  // Per-session throttle timers so a flood of output chunks costs at most one
  // buffer inspection every [_agentCheckThrottle].
  final Map<String, Timer> _sessionCheckTimers = {};
  // Per-session trailing timers that coalesce PTY resizes — see [_scheduleResize].
  final Map<String, Timer> _sessionResizeTimers = {};

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
  static const String _kTerminalKeyboardAutocorrect = 'settings_terminal_keyboard_autocorrect';
  static const String _kAltScrollKeys = 'settings_alt_scroll_keys';
  static const String _kAppLockEnabled = 'settings_app_lock_enabled';
  static const String _kAgentAlerts = 'settings_agent_alerts';
  static const String _kAgentDashboard = 'settings_agent_dashboard';
  static const String _kAgentLaunchers = 'settings_agent_launchers';
  static const String _kNotificationPrefs = 'settings_notification_prefs';
  static const String _kAccentColorHex = 'settings_accent_color_hex';
  static const String _kCustomAccentColors = 'settings_custom_accent_colors';
  static const String _kMonoFontChoice = 'settings_mono_font_choice';
  static const String _kShortcutLayout = 'settings_shortcut_layout';
  static const String _kCustomShortcuts = 'settings_custom_shortcuts_json';
  static const String _kShortcutKeyHeight = 'settings_shortcut_key_height';
  static const String _kShortcutKeyWidth = 'settings_shortcut_key_width';
  static const String _kShortcutRows = 'settings_shortcut_rows';
  static const String _kShortcutLayers = 'settings_shortcut_layers';
  static const String _kShortcutLayer = 'settings_shortcut_active_layer';
  static const String _kDockLeft = 'settings_explorer_dock_left';
  static const String _kDockY = 'settings_explorer_dock_y';
  static const String _kTerminalGestureDeadzone = 'settings_terminal_gesture_deadzone';
  static const String _kPadEnabled = 'settings_pad_enabled';
  static const String _kPadHoldMs = 'settings_pad_hold_ms';
  static const String _kPadRadial = 'settings_pad_radial';
  static const String _kPadRadialMs = 'settings_pad_radial_ms';
  static const String _kPadSlots = 'settings_pad_slots';
  // Desktop workspace: splitter positions and which side panes are open.
  static const String _kSplitSide = 'settings_split_side';
  static const String _kSplitEditorTerminal = 'settings_split_editor_terminal';
  static const String _kExplorerPaneOpen = 'settings_explorer_pane_open';
  static const String _kGitPaneOpen = 'settings_git_pane_open';

  /// Accent used out of the box (and for installs that never picked one).
  static const String defaultAccentColorHex = 'red';

  /// How many colors the user can keep in the custom accent palette.
  static const int maxCustomAccentColors = 8;

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

  double _terminalGestureDeadzone = 60.0; // Default deadzone for gestures
  double get terminalGestureDeadzone => _terminalGestureDeadzone;

  // ---- Touch pad (hold-and-drag) ------------------------------------------
  // The terminal's pad: hold a beat and the finger becomes a d-pad (arrows,
  // i.e. shell history), hold a beat longer without pulling and it blooms into
  // the eight-slot radial. Everything about it is a setting because the
  // gesture shares its pixels with the scroll and the long press, and where
  // one hand draws the line between them is not where another does.
  bool _terminalPadEnabled = true;
  bool get terminalPadEnabled => _terminalPadEnabled;

  int _terminalPadHoldMs = JoystickGestureRecognizer.defaultHoldDelay.inMilliseconds;
  int get terminalPadHoldMs => _terminalPadHoldMs;
  Duration get terminalPadHoldDelay => Duration(milliseconds: _terminalPadHoldMs);

  bool _terminalPadRadialEnabled = true;
  bool get terminalPadRadialEnabled => _terminalPadRadialEnabled;

  /// How long the armed pad must sit inside the deadzone before the radial
  /// opens. Counted from the moment the pad arms — the arena is already ours
  /// by then, so this timing competes with nothing.
  int _terminalPadRadialMs = 420;
  int get terminalPadRadialMs => _terminalPadRadialMs;
  Duration get terminalPadRadialDelay =>
      Duration(milliseconds: _terminalPadRadialMs);

  static const int minPadRadialMs = 250;

  /// Ceiling matched to [JoystickGestureRecognizer.maxRadialDelay]. Past it the
  /// long press has already taken the pointer for a text selection, so a larger
  /// value would simply mean "the radial never opens" — a slider that promises
  /// 1200ms and silently does nothing above 440 is worse than a shorter one.
  static const int maxPadRadialMs = 440;

  TouchPadConfig _terminalPadConfig = TouchPadConfig.defaults;
  TouchPadConfig get terminalPadConfig => _terminalPadConfig;

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

  bool _terminalKeyboardAutocorrect = false;
  bool get terminalKeyboardAutocorrect => _terminalKeyboardAutocorrect;

  /// Whether a swipe inside a full-screen app that does **not** report the
  /// mouse wheel is translated into arrow keys.
  ///
  /// It is the only thing that makes `less`, `man` and `vim` scrollable with a
  /// thumb, and it is also how a swipe inside a TUI agent walks its prompt
  /// history instead of scrolling: the same two keys mean different things to
  /// a pager and to a text box, and nothing in the escape stream says which
  /// one is on screen. Applications that know they handle their own scrolling
  /// opt out with DEC mode 1007 and are obeyed regardless of this switch.
  bool _terminalAltScrollKeys = true;
  bool get terminalAltScrollKeys => _terminalAltScrollKeys;

  // Everything about agent notifications: which kinds fire, how loudly, when,
  // and how sensitive the autodetector is. See [NotificationPrefs].
  NotificationPrefs _notificationPrefs = const NotificationPrefs();
  NotificationPrefs get notificationPrefs => _notificationPrefs;

  /// Master switch, kept as a named getter because it gates the hot path in
  /// the detector.
  bool get agentAlertsEnabled => _notificationPrefs.enabled;

  /// Whether the agents dashboard tracks session activity.
  bool _agentDashboardEnabled = true;
  bool get agentDashboardEnabled => _agentDashboardEnabled;

  /// Whether the screen-watching loop runs at all.
  ///
  /// Two features read the same signal now, so the loop can't be gated on the
  /// notification switch alone: turning alerts off used to be the only way to
  /// stop it, and doing that would leave the dashboard frozen on whatever each
  /// session happened to be doing at the time.
  bool get _watchEnabled => agentAlertsEnabled || _agentDashboardEnabled;

  /// One-tap agent launchers, shown by the pad's `system:agents` action and
  /// editable in Personalizar → Agentes.
  ///
  /// Seeded from [kDefaultAgentLaunchers] on first run and then owned by the
  /// user: the defaults are a starting point, not a list the app keeps
  /// reconciling. A new agent appearing in the world is something the user
  /// adds, which is why the editor takes a free-form command and any of the
  /// bundled marks.
  List<AgentLauncher> _agentLaunchers = List.of(kDefaultAgentLaunchers);
  List<AgentLauncher> get agentLaunchers => List.unmodifiable(_agentLaunchers);

  /// What the launcher sheet actually draws.
  List<AgentLauncher> get enabledAgentLaunchers =>
      _agentLaunchers.where((l) => l.enabled).toList(growable: false);

  Future<void> _persistAgentLaunchers() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAgentLaunchers, AgentLauncher.encodeList(_agentLaunchers));
  }

  /// Inserts or updates by id, keeping the user's order.
  Future<void> saveAgentLauncher(AgentLauncher launcher) async {
    final index = _agentLaunchers.indexWhere((l) => l.id == launcher.id);
    if (index >= 0) {
      _agentLaunchers[index] = launcher;
    } else {
      _agentLaunchers.add(launcher);
    }
    notifyListeners();
    await _persistAgentLaunchers();
  }

  Future<void> deleteAgentLauncher(String id) async {
    _agentLaunchers.removeWhere((l) => l.id == id);
    notifyListeners();
    await _persistAgentLaunchers();
  }

  Future<void> reorderAgentLaunchers(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _agentLaunchers.length) return;
    // ReorderableListView reports the insertion point *before* the removal.
    final target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    final moved = _agentLaunchers.removeAt(oldIndex);
    _agentLaunchers.insert(target.clamp(0, _agentLaunchers.length), moved);
    notifyListeners();
    await _persistAgentLaunchers();
  }

  /// Puts the defaults back, for a list the user has emptied or broken.
  Future<void> restoreDefaultAgentLaunchers() async {
    _agentLaunchers = List.of(kDefaultAgentLaunchers);
    notifyListeners();
    await _persistAgentLaunchers();
  }

  /// Sends [launcher]'s command to the active session.
  ///
  /// Routed through [insertPromptText] (a bracketed paste) rather than as a
  /// burst of keystrokes, so a shell with autocomplete or a TUI already on
  /// screen receives it as one insertion. The Enter is separate and only sent
  /// when the launcher asks for it — a command the user means to finish by
  /// hand must not run itself.
  void runAgentLauncher(AgentLauncher launcher) {
    final session = activeSession;
    if (session == null) return;
    if (launcher.command.trim().isEmpty) return;
    insertPromptText(launcher.command);
    if (launcher.autoRun) sendTerminalInput('\r');
  }

  Future<void> setAgentDashboardEnabled(bool value) async {
    if (_agentDashboardEnabled == value) return;
    _agentDashboardEnabled = value;
    if (!value) agents.clear();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAgentDashboard, value);
  }

  /// Rolling diagnostics log of recent alert decisions, newest first. Capped so
  /// it can't grow unbounded; surfaced in the notifications screen.
  final List<AlertLogEntry> _alertLog = [];
  List<AlertLogEntry> get alertLog => List.unmodifiable(_alertLog);
  static const int _alertLogLimit = 30;

  void _logAlert(AlertLogEntry entry) {
    _alertLog.insert(0, entry);
    if (_alertLog.length > _alertLogLimit) _alertLog.removeLast();
  }

  String _accentColorHex = defaultAccentColorHex;
  String get accentColorHex => _accentColorHex;

  /// User-defined accent colors saved from the color picker, stored as
  /// `#RRGGBB` strings. Oldest first; capped at [maxCustomAccentColors].
  List<String> _customAccentColors = [];
  List<String> get customAccentColors => List.unmodifiable(_customAccentColors);

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

  /// How many rows the quick-keyboard grid gets. Columns are *derived* from
  /// this (see `TerminalQuickKeys`), which is what guarantees every key fits
  /// on screen: there is no horizontal scroll to hide the overflow in.
  ///
  /// One by default. Layers are what hold the key count now, so a second row
  /// only buys bigger keys — and it costs 33px of terminal on every screen,
  /// which is most of what the layered bar could have added over the old one.
  int _shortcutRows = 1;
  int get shortcutRows => _shortcutRows;

  /// Visible layers, in tab order. Persisted by id so reordering the enum
  /// can't scramble a user's setup.
  List<QuickKeyLayer> _shortcutLayers = List.of(kDefaultShortcutLayers);
  List<QuickKeyLayer> get shortcutLayers => List.unmodifiable(_shortcutLayers);

  /// The layer whose grid is on screen. Index into [shortcutLayers]; clamped
  /// on read because a layer can be hidden while it is the active one.
  ///
  /// Deliberately **not restored** from preferences on launch: the bar always
  /// opens on ACCIONES. Remembering the last layer meant an app reopened hours
  /// later came back on whatever page happened to be up when it was closed,
  /// which is never the page you want first. It is still persisted, because
  /// [setShortcutLayers] needs somewhere to keep the current layer across a
  /// reorder.
  int _shortcutLayerIndex = 0;
  int get shortcutLayerIndex {
    if (_shortcutLayers.isEmpty) return 0;
    return _shortcutLayerIndex.clamp(0, _shortcutLayers.length - 1);
  }

  QuickKeyLayer? get activeShortcutLayer =>
      _shortcutLayers.isEmpty ? null : _shortcutLayers[shortcutLayerIndex];

  /// Where the explorer's floating action dock rests. The user drags it with a
  /// long press; it always snaps back to one screen edge, so only the side and
  /// a vertical [Alignment] y (-1 top … 1 bottom) need storing.
  bool _explorerDockLeft = true;
  bool get explorerDockLeft => _explorerDockLeft;

  double _explorerDockY = 0;
  double get explorerDockY => _explorerDockY;

  Future<void> setExplorerDock(bool left, double y) async {
    final clamped = y.clamp(-1.0, 1.0);
    if (_explorerDockLeft == left && _explorerDockY == clamped) return;
    _explorerDockLeft = left;
    _explorerDockY = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDockLeft, left);
    await prefs.setDouble(_kDockY, clamped);
  }

  String get monoFontFamily => AppText.resolveMonoFontFamily(_monoFontChoice);

  Future<void> setAgentAlertsEnabled(bool value) =>
      updateNotificationPrefs(_notificationPrefs.copyWith(enabled: value));

  /// Persists a whole new notification configuration. Every control in the
  /// notifications screen funnels through here, so there is one place where
  /// the prefs are written and the native channels are kept in sync.
  Future<void> updateNotificationPrefs(NotificationPrefs value) async {
    _notificationPrefs = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kNotificationPrefs, value.encode());
    await NotificationService.configureChannels(
      intensities: {
        for (final kind in AlertKind.values)
          kind.name: value.intensityFor(kind).name,
      },
    );
  }

  /// Mutes or unmutes a single session, so one chatty server doesn't force the
  /// user to switch everything off.
  Future<void> setSessionMuted(String sessionId, bool muted) {
    final ids = Set<String>.from(_notificationPrefs.mutedSessionIds);
    if (muted) {
      ids.add(sessionId);
    } else {
      ids.remove(sessionId);
    }
    return updateNotificationPrefs(
        _notificationPrefs.copyWith(mutedSessionIds: ids));
  }

  /// Forces the agent identity of a session (or clears the override with
  /// null), for when detection picks the wrong one — or an agent we don't know.
  void setSessionAgentOverride(String sessionId, String? agentId) {
    final session = _sessions.where((s) => s.id == sessionId).firstOrNull;
    if (session == null) return;
    session.agentOverrideId = agentId;
    notifyListeners();
  }

  /// Posts one alert of each kind so the user can check on the device that
  /// they arrive, sound the way they expect, and are not being blocked by a
  /// system-level setting.
  Future<void> sendTestNotifications() async {
    final now = DateTime.now();
    for (final kind in AlertKind.values) {
      if (_notificationPrefs.intensityFor(kind) == AlertIntensity.off) continue;
      await NotificationService.showAlert(
        sessionId: 'test-${kind.name}',
        title: tr('Prueba · {0}', [kind.label]),
        body: kind.description,
        kind: kind.name,
        sessionName: tr('Notificación de prueba'),
      );
      _logAlert(AlertLogEntry(
        at: now,
        sessionName: tr('Prueba'),
        kind: kind,
        detail: tr('Notificación de prueba enviada.'),
      ));
    }
    notifyListeners();
  }

  // ---- App lock --------------------------------------------------------
  // When enabled, a biometric/device-credential gate is shown before the app
  // shell on cold start (see LockGate in main.dart). The unlock uses the phone's
  // biometric with a fallback to its screen-lock credential; no KAMMEL-specific
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
        _seedWatchState(session);
      }
    }
  }

  /// Points a session's watch state at whatever is on screen right now, so the
  /// content already there can't trigger an alert on its own — only output
  /// produced from this moment on counts as new.
  void _seedWatchState(TerminalSession session) {
    session.watchSignature = _screenSignature(session);
    session.rawWatchSignature = _rawScreenSignature(session);
    session.lastMeaningfulChangeAt = DateTime.now();
    session.watchAlertFired = false;
    // Going to (or coming back from) the background moves the soft keyboard
    // and resizes the PTY a moment later; the repaint that follows is this
    // same screen, not something new to announce.
    session.redrawGraceUntil = DateTime.now().add(_redrawGrace);
  }

  void _onAppResumed() {
    // The user is back: pending idle timers would alert about things they are
    // already looking at. The detector keeps running in the foreground (it
    // resolves to an in-app badge there), so the state is reseeded rather than
    // just torn down.
    for (final t in _sessionAlertTimers.values) {
      t.cancel();
    }
    _sessionAlertTimers.clear();
    for (final t in _sessionCheckTimers.values) {
      t.cancel();
    }
    _sessionCheckTimers.clear();
    for (final session in _sessions) {
      _seedWatchState(session);
    }
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
    _setTab(1);
    notifyListeners();
  }

  /// Minimum spacing between alerts of the same session: TUI agents often ring
  /// the bell several times in a burst.
  static const Duration _alertDebounce = Duration(seconds: 4);

  // ---- Agent identity ------------------------------------------------------
  // Which agent a session is running decides the notification's badge and
  // label. It is resolved from *ranked* evidence and then sticks: a stronger
  // signal replaces a weaker one, never the other way round. Guessing from
  // whatever name appeared last on screen (the previous approach) misidentified
  // the agent constantly, because agents print each other's names all the time.

  /// Screen text only — any name that shows up in the visible buffer. Weakest:
  /// used exclusively to name a session that has no identity at all yet.
  static const int _evidenceScreen = 1;

  /// The command the user typed to launch the agent. Strong: it says what was
  /// actually started, rather than what is being talked about.
  static const int _evidenceCommand = 2;

  /// The window title the program set for itself (OSC 0/2). Strongest — it is
  /// the running program declaring its own name.
  static const int _evidenceTitle = 3;

  /// Known TUI agents. [pattern] matches the window title or a banner on
  /// screen and is anchored to word boundaries — a bare `contains` made
  /// "legacy" match the old 'agy' marker and brand the session as Antigravity.
  /// [command] matches the launcher's program name (already basename'd and
  /// stripped of `sudo`/`npx`/env prefixes). Everything works the same for an
  /// unknown agent, just with a generic badge.
  static final List<({RegExp pattern, RegExp command, String id, String label})>
      _agentMarkers = [
    (
      pattern: RegExp(r'\b(antigravity|deepmind)\b'),
      command: RegExp(r'^(antigravity|agy)$'),
      id: 'antigravity',
      label: 'Antigravity'
    ),
    (
      pattern: RegExp(r'\bclaude(\s+code)?\b'),
      command: RegExp(r'^claude$'),
      id: 'claude',
      label: 'Claude Code'
    ),
    (
      pattern: RegExp(r'\baider\b'),
      command: RegExp(r'^aider$'),
      id: 'aider',
      label: 'Aider'
    ),
    // Before 'codex'/'gemini': their names could appear in opencode output.
    (
      pattern: RegExp(r'\bopencode\b'),
      command: RegExp(r'^opencode$'),
      id: 'opencode',
      label: 'OpenCode'
    ),
    (
      pattern: RegExp(r'\bcodex\b'),
      command: RegExp(r'^codex$'),
      id: 'codex',
      label: 'Codex'
    ),
    (
      pattern: RegExp(r'\bgemini\b'),
      command: RegExp(r'^gemini$'),
      id: 'gemini',
      label: 'Gemini CLI'
    ),
    (
      pattern: RegExp(r'\bcopilot\b'),
      command: RegExp(r'^copilot$'),
      id: 'copilot',
      label: 'Copilot CLI'
    ),
    // 'cursor' alone would match ordinary terminal text ("cursor position"),
    // so only the CLI binary name counts.
    (
      pattern: RegExp(r'\bcursor-agent\b'),
      command: RegExp(r'^cursor-agent$'),
      id: 'cursor',
      label: 'Cursor'
    ),
    (
      pattern: RegExp(r'\bqwen\b'),
      command: RegExp(r'^qwen$'),
      id: 'qwen',
      label: 'Qwen Code'
    ),
  ];

  /// Wrappers that precede the real program name on a command line, so
  /// `npx claude` and `sudo -E aider` still identify their agent.
  static final RegExp _launcherPrefixRegex = RegExp(
    r'^(sudo(\s+-\w+)*|env|command|nohup|npx|bunx|pnpm\s+dlx|yarn\s+dlx|uvx|'
    r'time|nice(\s+-n\s*-?\d+)?)\s+',
  );

  /// Shell assignments (`FOO=bar cmd`) that precede the program name.
  static final RegExp _envAssignRegex = RegExp(r'^\w+=\S*\s+');

  /// Records agent evidence of the given [strength] for [session], keeping the
  /// strongest seen. Same-strength evidence is allowed to update the identity
  /// (running a different agent in the same tab), except for
  /// [_evidenceScreen], which only ever names a still-unidentified session —
  /// otherwise a passing mention on screen could flip the badge again.
  void _noteAgentEvidence(
      TerminalSession session, String id, String label, int strength) {
    if (strength == _evidenceScreen && session.agentEvidence != 0) return;
    if (strength < session.agentEvidence) return;
    if (session.agentId == id && session.agentEvidence == strength) return;
    session.agentId = id;
    session.agentLabel = label;
    session.agentEvidence = strength;
  }

  /// Clears a session's agent identity — the agent exited, so the next one to
  /// run in this tab starts from scratch instead of inheriting the badge.
  void _clearAgentIdentity(TerminalSession session) {
    session.agentId = null;
    session.agentLabel = null;
    session.agentEvidence = 0;
  }

  /// Feeds a window title (OSC 0/2) into identity resolution.
  void _noteTitleEvidence(TerminalSession session, String title) {
    session.lastTitle = title;
    final lower = title.toLowerCase();
    for (final m in _agentMarkers) {
      if (m.pattern.hasMatch(lower)) {
        _noteAgentEvidence(session, m.id, m.label, _evidenceTitle);
        return;
      }
    }
  }

  /// Feeds the user's keystrokes into identity resolution: buffers them until
  /// Enter, then reads the completed line as a command. Typing `qwen` is the
  /// single most reliable signal that this tab now runs Qwen — far better than
  /// anything that can be inferred from the output.
  void _noteInputEvidence(TerminalSession session, String data) {
    for (final rune in data.runes) {
      if (rune == 0x0D || rune == 0x0A) {
        // Enter: the line has been submitted.
        _classifyCommandLine(session, session.inputLine);
        _recordCommand(session, session.inputLine);
        session.inputLine = '';
      } else if (rune == 0x03 || rune == 0x1B || rune == 0x15) {
        // Ctrl+C / ESC / Ctrl+U abandon the line being typed.
        session.inputLine = '';
      } else if (rune == 0x7F || rune == 0x08) {
        // Backspace / DEL.
        if (session.inputLine.isNotEmpty) {
          session.inputLine =
              session.inputLine.substring(0, session.inputLine.length - 1);
        }
      } else if (rune >= 0x20 && session.inputLine.length < 256) {
        session.inputLine += String.fromCharCode(rune);
      }
    }
  }

  /// Resolves a submitted command line to an agent (or to "the agent exited").
  void _classifyCommandLine(TerminalSession session, String rawLine) {
    var line = rawLine.trim().toLowerCase();
    if (line.isEmpty) return;
    // Only the first command of a pipeline/chain names the session.
    line = line.split(RegExp(r'[|;&]')).first.trim();
    while (true) {
      final stripped = line
          .replaceFirst(_envAssignRegex, '')
          .replaceFirst(_launcherPrefixRegex, '');
      if (stripped == line) break;
      line = stripped.trim();
    }
    if (line.isEmpty) return;
    var program = line.split(RegExp(r'\s+')).first;
    // Basename: /usr/local/bin/claude → claude.
    final slash = program.lastIndexOf('/');
    if (slash >= 0) program = program.substring(slash + 1);
    if (program == 'exit' || program == 'logout') {
      _clearAgentIdentity(session);
      return;
    }
    for (final m in _agentMarkers) {
      if (m.command.hasMatch(program)) {
        _noteAgentEvidence(session, m.id, m.label, _evidenceCommand);
        return;
      }
    }
  }

  /// Which agent is running in [session]. Returns the sticky identity resolved
  /// from title/command evidence; only when nothing is known does it fall back
  /// to scanning the screen, and that scan is deterministic (first marker in
  /// declaration order, not "whichever name appears lowest"), so repeated
  /// alerts for one session always look the same. Null → unknown/no agent.
  ({String id, String label})? _detectAgent(TerminalSession session) {
    final override = session.agentOverrideId;
    if (override != null) {
      if (override == 'none') return null;
      for (final m in _agentMarkers) {
        if (m.id == override) return (id: m.id, label: m.label);
      }
    }
    if (session.agentId == null) {
      final tail = _terminalTail(session, 60).toLowerCase();
      if (tail.isNotEmpty) {
        for (final m in _agentMarkers) {
          if (m.pattern.hasMatch(tail)) {
            _noteAgentEvidence(session, m.id, m.label, _evidenceScreen);
            break;
          }
        }
      }
    }
    final id = session.agentId;
    if (id == null) return null;
    return (id: id, label: session.agentLabel ?? id);
  }

  /// Shared endpoint for every agent-attention signal (BEL, OSC 9, OSC 777 and
  /// the idle autodetector), wired per-session in [createNewSession]. Policy,
  /// all of it overridable from the notifications screen:
  ///  - app in background → system notification (tap reopens the session);
  ///  - app visible but the session isn't the active one → in-app badge;
  ///  - app visible and session active → nothing beyond the bell's haptic.
  ///
  /// Every decision — sent or dropped — is recorded in [alertLog] with its
  /// reason, so a misfire can be diagnosed from the app instead of guessed at.
  void _onSessionAlert(TerminalSession session,
      {String? title, String? body, bool isQuestion = false, AlertKind? kind}) {
    final prefs = _notificationPrefs;
    final now = DateTime.now();
    final alertKind =
        kind ?? (isQuestion ? AlertKind.question : AlertKind.done);
    final agent = _detectAgent(session);

    void drop(String reason) {
      _logAlert(AlertLogEntry(
        at: now,
        sessionName: session.name,
        kind: alertKind,
        agentLabel: agent?.label,
        suppressedReason: reason,
        detail: body ?? title ?? '',
      ));
    }

    if (!prefs.enabled) return drop(tr('Avisos de agente desactivados'));
    if (prefs.isMuted(session.id)) return drop(tr('Sesión silenciada'));
    if (prefs.intensityFor(alertKind) == AlertIntensity.off) {
      return drop(tr('"{0}" está en NO AVISAR', [alertKind.label]));
    }
    if (prefs.isQuiet(now)) return drop(tr('Horario silencioso'));
    if (_appInForeground && prefs.when == AlertWhen.backgroundOnly) {
      return drop(tr('Configurado para avisar sólo en segundo plano'));
    }
    if (_appInForeground &&
        prefs.skipActiveSession &&
        identical(session, activeSession)) {
      return drop(tr('Es la sesión que estás viendo'));
    }

    final last = session.lastAlertAt;
    if (last != null && now.difference(last) < _alertDebounce) {
      // Within the debounce window, only an *upgrade* gets through: the agent
      // finishing and then immediately asking something is the common case,
      // and a flat debounce used to drop the question — the alert that
      // actually needed the user — while keeping the "finished" one.
      if (!(isQuestion && !session.lastAlertWasQuestion)) {
        return drop(tr('Repetido dentro de la ventana antirrebote'));
      }
    }
    session.lastAlertAt = now;
    session.lastAlertWasQuestion = isQuestion;

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
          ? tr('Espera tu respuesta')
          : tr('El terminal pide tu atención');
    }

    if (!_appInForeground) {
      // An explicit signal (BEL/OSC) covers the current idle period too: mark
      // it consumed so the autodetector can't post a duplicate seconds later.
      session.watchAlertFired = true;
      session.watchSignature = _screenSignature(session);
      session.rawWatchSignature = _rawScreenSignature(session);
      _sessionAlertTimers.remove(session.id)?.cancel();

      NotificationService.showAlert(
        sessionId: session.id,
        title: finalTitle,
        body: finalBody,
        agent: agent?.id,
        kind: alertKind.name,
        sessionName: session.name,
      );
    }
    // The badge is set either way: coming back to a marked tab is how the user
    // finds the session that needed them, whether or not a push was posted.
    if (!identical(session, activeSession)) {
      session.hasPendingAlert = true;
    }
    _logAlert(AlertLogEntry(
      at: now,
      sessionName: session.name,
      kind: alertKind,
      agentLabel: agent?.label,
      detail: finalBody,
    ));
    notifyListeners();
  }

  // ---- Agent activity autodetector ----------------------------------------
  // Detects, without any cooperation from the program, the two moments worth
  // a notification:
  //  - the agent stopped writing and is waiting for an answer (question/menu);
  //  - the agent stopped writing because it finished the task.
  //
  // It is a BUSY→IDLE state machine over two signatures of the visible tail:
  //
  //  - the *raw* signature changes whenever any pixel of text does — including
  //    a spinner frame or an elapsed-seconds counter;
  //  - the *semantic* signature has that redraw noise stripped, so it only
  //    changes when the agent actually said something new.
  //
  // Any output at all — noise included — means the program is alive and
  // working, so it pushes the idle deadline back. Only a change of the
  // semantic signature opens a *new* idle period (one alert per period, via
  // [TerminalSession.watchAlertFired]), so a static prompt can never re-notify
  // however many times it is redrawn.
  //
  // The previous version stripped the noise and then *ignored* unchanged
  // signatures without re-arming the timer, so a spinning agent looked exactly
  // like a silent one and got announced as "finished" mid-thought. Treating
  // noise as "busy" instead of "nothing happened" is the fix.

  /// How long the terminal must produce *no output whatsoever* before the
  /// agent counts as having stopped. LLM streams and tool calls pause for
  /// several seconds at a time, so the default is deliberately well above the
  /// old 3s; the notifications screen exposes it as a slider.
  Duration get _agentIdleDelay =>
      Duration(seconds: _notificationPrefs.idleDelaySeconds);

  /// Safety valve for TUIs that redraw forever (a clock in the status bar, a
  /// progress animation that never ends): once the *meaningful* content has
  /// been unchanged this long, stop treating incoming noise as work in
  /// progress. An explicit busy marker on screen still overrides this.
  static const Duration _agentNoiseCap = Duration(seconds: 90);

  /// Inspection cadence while output is flowing: at most one buffer read per
  /// session per throttle window, regardless of how many chunks arrive.
  static const Duration _agentCheckThrottle = Duration(milliseconds: 300);

  /// How long after a PTY resize (or after the app changes lifecycle state)
  /// screen changes are treated as a repaint of the same content. Long enough
  /// for a remote TUI to finish redrawing over a slow link, short enough that
  /// an agent answering right then is only ever delayed by one idle period.
  static const Duration _redrawGrace = Duration(seconds: 3);

  /// Rows from the bottom of the buffer that feed detection — roughly one
  /// phone screen of a TUI agent.
  static const int _watchTailLines = 40;

  /// Everything that idle TUIs redraw without meaning anything new: spaces,
  /// digits (elapsed-time and token counters), braille and geometric spinner
  /// glyphs, progress-bar characters.
  static final RegExp _watchNoiseRegex = RegExp(
    r"[\s\d⠀-⣿✻✳✶✽✢·∙•●○◌◍◐◓◑◒◴◵◶◷⏳⌛|/\\*+~↑↓█▉▊▋▌▍▎▏░▒▓-]",
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
  int _screenSignature(TerminalSession session) =>
      _signatureOf(_terminalTail(session, _watchTailLines));

  /// [_screenSignature] for an already-captured tail.
  int _signatureOf(String tail) =>
      tail.replaceAll(_watchNoiseRegex, '').hashCode;

  /// Hash of the visible tail *as-is*. Differs from [_screenSignature] exactly
  /// when the only thing that moved was redraw noise — which is how a spinning
  /// agent is told apart from a silent one.
  int _rawScreenSignature(TerminalSession session) =>
      _terminalTail(session, _watchTailLines).hashCode;

  /// Entry point wired to every remote-output batch (see [_TerminalWriter]).
  void _onTerminalOutput(TerminalSession session) {
    if (!_watchEnabled) return;
    if (_sessionCheckTimers.containsKey(session.id)) return;
    _sessionCheckTimers[session.id] = Timer(_agentCheckThrottle, () {
      _sessionCheckTimers.remove(session.id);
      _evaluateAgentActivity(session);
    });
  }

  /// Called shortly after output lands. Classifies what moved and (re)arms the
  /// idle deadline accordingly.
  void _evaluateAgentActivity(TerminalSession session) {
    if (!_watchEnabled) return;
    // Both signatures come from the same snapshot: reading the tail twice
    // rebuilt a ~3000-character string from the buffer for nothing, several
    // times a second for as long as output kept flowing.
    final tail = _terminalTail(session, _watchTailLines);
    final sig = _signatureOf(tail);
    session.rawWatchSignature = tail.hashCode;

    if (sig != session.watchSignature && _inRedrawGrace(session)) {
      // A resize just happened: the same screen laid out differently. Adopt it
      // as the baseline, but *don't* open a new idle period — the screen the
      // user walked away from doesn't earn an alert for being repainted. Real
      // output afterwards lands outside the window and alerts normally.
      session.watchSignature = sig;
      session.lastMeaningfulChangeAt = DateTime.now();
      session.watchAlertFired = true;
      _sessionAlertTimers.remove(session.id)?.cancel();
      return;
    }

    if (sig != session.watchSignature) {
      // Genuinely new content: a new idle period starts, so this session is
      // allowed to alert again once it goes quiet.
      if (session.watchAlertFired) {
        // The session went back to work, so whatever the posted notification
        // said ("terminó", "espera tu respuesta") is now stale — retract it
        // rather than leaving it lying in the shade.
        NotificationService.cancelAlert(session.id);
      }
      session.watchSignature = sig;
      session.watchAlertFired = false;
      session.lastMeaningfulChangeAt = DateTime.now();
      // Output is moving, so the dashboard says so. No classifier runs here on
      // purpose: movement is already proof of life, and putting the regexes of
      // [AgentScreen.read] on a path that fires every 300ms per session would
      // spend real CPU to learn what the signature just told us. The screen is
      // read properly once, when the session goes quiet.
      _noteActivity(session, AgentState.working);
      _armIdleTimer(session);
      return;
    }

    // Only redraw noise moved (a spinner frame, a counter tick) or nothing
    // visible did. That is still a sign of life, so it pushes the deadline
    // back — unless the meaningful content has been frozen for so long
    // ([_agentNoiseCap]) that this is a TUI animating forever rather than an
    // agent working, in which case the pending deadline is left to expire.
    if (!_noiseCapExceeded(session)) {
      _armIdleTimer(session);
    } else if (!_sessionAlertTimers.containsKey(session.id)) {
      _armIdleTimer(session);
    }
  }

  /// Whether we are inside the window where output is a repaint of what was
  /// already there (see [TerminalSession.redrawGraceUntil]).
  bool _inRedrawGrace(TerminalSession session) {
    final until = session.redrawGraceUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  /// Whether the meaningful screen content has been frozen past
  /// [_agentNoiseCap], i.e. incoming output should stop counting as progress.
  bool _noiseCapExceeded(TerminalSession session) {
    final last = session.lastMeaningfulChangeAt;
    if (last == null) return false;
    return DateTime.now().difference(last) > _agentNoiseCap;
  }

  /// Pushes a session's state to the dashboard, resolving the agent badge from
  /// the sticky identity the detector already keeps.
  ///
  /// [snippet] is omitted by callers that only know the connection changed, so
  /// a drop or a reconnect can't erase the question that is still on screen.
  void _noteActivity(TerminalSession session, AgentState state,
      {String? snippet, bool clearAgent = false}) {
    if (!_agentDashboardEnabled) return;
    agents.note(
      session.id,
      state,
      snippet: snippet,
      agentId: session.agentId,
      agentLabel: session.agentLabel,
      clearAgent: clearAgent,
    );
  }

  void _armIdleTimer(TerminalSession session) {
    _sessionAlertTimers[session.id]?.cancel();
    _sessionAlertTimers[session.id] = Timer(_agentIdleDelay, () {
      _sessionAlertTimers.remove(session.id);
      _maybeFireIdleAlert(session);
    });
  }

  void _maybeFireIdleAlert(TerminalSession session) {
    if (!_watchEnabled) return;
    if (session.watchAlertFired) return;
    // Output can land inside the throttle window after the last evaluation:
    // if the screen moved again, this wasn't real silence — restart the cycle.
    if (_rawScreenSignature(session) != session.rawWatchSignature) {
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

    // The screen is read **once**, here, and the reading is then used for two
    // independent decisions: what the dashboard says this session is doing, and
    // whether the phone should buzz. Those used to be the same tangle of early
    // returns, which is why states that make terrible notifications ("it's at a
    // shell prompt") were computed and thrown away rather than shown.
    final reading = AgentScreen.read(recent);
    final screenText = AgentScreen.snippet(recent);

    // Resolved before the prompt branch below can clear it: asking again
    // afterwards would re-detect the agent from its name still on screen.
    final agent = _detectAgent(session);

    switch (reading) {
      case ScreenReading.busy:
        _noteActivity(session, AgentState.working, snippet: screenText);
      case ScreenReading.shellPrompt:
        // The agent exited, so the badge goes with it — the same reasoning as
        // [_clearAgentIdentity] below, which the notification path applies to
        // the session itself.
        _noteActivity(session, AgentState.prompt,
            snippet: screenText, clearAgent: true);
      case ScreenReading.question:
        _noteActivity(session, AgentState.waiting, snippet: screenText);
      case ScreenReading.quiet:
        _noteActivity(session, AgentState.done, snippet: screenText);
    }

    // Everything below is the notification path, unchanged. It deliberately
    // re-asks the individual classifiers rather than deriving from [reading]:
    // the precedence [AgentScreen.read] applies is right for a dashboard that
    // must pick exactly one state, but the alert has always been allowed to
    // call a busy screen a question when the user turned [suppressWhileBusy]
    // off. This runs once per idle period, not on the 300ms path, so asking
    // twice costs nothing.
    if (!agentAlertsEnabled) return;

    if (_notificationPrefs.suppressWhileBusy && AgentScreen.looksBusy(recent)) {
      // A long silent step (a tool call, a slow model) with the status line
      // still saying so. Don't consume the idle period: keep watching, and
      // when the busy hint disappears the cycle completes normally.
      _armIdleTimer(session);
      return;
    }

    // From here on the decision is made for this idle period, whichever way it
    // goes: without this the same screen would be re-judged on every redraw.
    session.watchAlertFired = true;
    final isQuestion = AgentScreen.looksLikeQuestion(recent);
    final alertKind = isQuestion ? AlertKind.question : AlertKind.done;

    void drop(String reason) {
      _logAlert(AlertLogEntry(
        at: DateTime.now(),
        sessionName: session.name,
        kind: alertKind,
        agentLabel: agent?.label,
        suppressedReason: reason,
        detail: AgentScreen.snippet(recent),
      ));
    }

    // Nothing is running in the foreground: the screen ends at a shell prompt.
    // Whatever agent this tab used to run has exited, so its sticky identity
    // goes too — otherwise the next redraw of the same prompt would still be
    // announced under the agent's name and badge.
    if (AgentScreen.looksLikeShellPrompt(recent)) {
      _clearAgentIdentity(session);
      return drop(tr('El terminal está en el prompt, no hay nada esperándote'));
    }

    if (_notificationPrefs.requireAgent && agent == null) {
      return drop(tr('No se detectó ningún agente en esta sesión'));
    }

    final snippet =
        _notificationPrefs.includeSnippet ? AgentScreen.snippet(recent) : '';
    final headline =
        isQuestion ? tr('Espera tu respuesta') : tr('Terminó de escribir');
    _onSessionAlert(
      session,
      body: snippet.isEmpty ? headline : '$headline\n$snippet',
      isQuestion: isQuestion,
    );
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

    final deadzone = prefs.getDouble(_kTerminalGestureDeadzone);
    if (deadzone != null) {
      _terminalGestureDeadzone = deadzone;
    }

    _terminalPadEnabled = prefs.getBool(_kPadEnabled) ?? true;
    _terminalPadRadialEnabled = prefs.getBool(_kPadRadial) ?? true;
    final padHold = prefs.getInt(_kPadHoldMs);
    if (padHold != null) {
      _terminalPadHoldMs = padHold.clamp(JoystickGestureRecognizer.minHoldMs,
          JoystickGestureRecognizer.maxHoldMs);
    }
    final padRadialMs = prefs.getInt(_kPadRadialMs);
    if (padRadialMs != null) {
      _terminalPadRadialMs = padRadialMs.clamp(minPadRadialMs, maxPadRadialMs);
    }
    final padSlots = prefs.getString(_kPadSlots);
    if (padSlots != null) {
      _terminalPadConfig = TouchPadConfig.decode(padSlots);
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

    final sortKeyIdx = prefs.getInt(_kFileSortKey);
    if (sortKeyIdx != null &&
        sortKeyIdx >= 0 &&
        sortKeyIdx < FileSortKey.values.length) {
      _fileSortKey = FileSortKey.values[sortKeyIdx];
    }
    _fileSortAscending = prefs.getBool(_kFileSortAsc) ?? true;

    _textScale = (prefs.getDouble(_kTextScale) ?? 1.0)
        .clamp(minTextScale, maxTextScale);
    _onboardingSeen = prefs.getBool(_kOnboardingSeen) ?? false;
    _quickKeysVisible = prefs.getBool(_kQuickKeysVisible) ?? true;
    _commandHistoryEnabled = prefs.getBool(_kCommandHistoryEnabled) ?? true;
    _commandHistory = _commandHistoryEnabled
        ? (prefs.getStringList(_kCommandHistory) ?? [])
        : [];

    _backGestureNavigatesFolders =
        prefs.getBool(_kBackGestureFolders) ?? false;

    _syncTerminalPath =
        prefs.getBool(_kSyncTerminalPath) ?? true;

    _terminalKeyboardAutocorrect =
        prefs.getBool(_kTerminalKeyboardAutocorrect) ?? false;

    _terminalAltScrollKeys = prefs.getBool(_kAltScrollKeys) ?? true;

    _appLockEnabled = prefs.getBool(_kAppLockEnabled) ?? false;

    _agentDashboardEnabled = prefs.getBool(_kAgentDashboard) ?? true;

    // Absent (first run) seeds the defaults; present-but-empty is a list the
    // user deliberately emptied and is left empty.
    final rawLaunchers = prefs.getString(_kAgentLaunchers);
    if (rawLaunchers != null) {
      _agentLaunchers = AgentLauncher.decodeList(rawLaunchers);
      // Antigravity's binary is `agy`; the launcher shipped with the long name
      // and never ran. Only an entry still byte-identical to that default is
      // corrected — a command the user has edited is theirs, wrong or not.
      final wrong = _agentLaunchers
          .indexWhere((l) => l.id == 'antigravity' && l.command == 'antigravity');
      if (wrong >= 0) {
        _agentLaunchers[wrong] =
            _agentLaunchers[wrong].copyWith(command: 'agy');
        await prefs.setString(
            _kAgentLaunchers, AgentLauncher.encodeList(_agentLaunchers));
      }
    }

    // Notification config: the JSON blob wins; on first run after the update
    // there is none, so the legacy on/off boolean is carried over.
    final rawNotifPrefs = prefs.getString(_kNotificationPrefs);
    _notificationPrefs = rawNotifPrefs != null
        ? NotificationPrefs.decode(rawNotifPrefs)
        : NotificationPrefs.fromLegacy(prefs.getBool(_kAgentAlerts) ?? true);
    // Channels must exist before the first alert is posted, and their
    // importance can only be set at creation time.
    NotificationService.configureChannels(
      intensities: {
        for (final kind in AlertKind.values)
          kind.name: _notificationPrefs.intensityFor(kind).name,
      },
    );

    // Installs that never touched the setting adopt the current default (red);
    // an explicit choice — including 'auto' — is always respected.
    _accentColorHex =
        prefs.getString(_kAccentColorHex) ?? defaultAccentColorHex;
    _customAccentColors =
        prefs.getStringList(_kCustomAccentColors) ?? <String>[];
    final shortcutLayoutIdx = prefs.getInt(_kShortcutLayout);
    if (shortcutLayoutIdx != null &&
        shortcutLayoutIdx >= 0 &&
        shortcutLayoutIdx < TerminalShortcutLayout.values.length) {
      _shortcutLayout = TerminalShortcutLayout.values[shortcutLayoutIdx];
    } else {
      // Fresh install: arrows inline on the fixed row. Existing users keep
      // whatever they picked (`classic` had no arrows at all, and now reaches
      // them through the NAV layer instead).
      _shortcutLayout = TerminalShortcutLayout.inline;
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
            TerminalShortcut(label: 'AGENTES', value: 'system:agents'),
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

    // Migration v5: the layered keyboard ships ^A/^E/^K/^L (and the rest of
    // the control codes) as a built-in layer, so the copies that used to live
    // in the user's own row are now duplicates. Only entries still identical
    // to the old default are dropped — anything renamed or retyped is theirs.
    const supersededDefaults = {
      '^A': r'\x01',
      '^E': r'\x05',
      '^L': r'\x0c',
      '^K': r'\x0b',
    };
    final migratedV5 = prefs.getBool('settings_shortcuts_migrated_v5') ?? false;
    if (!migratedV5) {
      final before = _customShortcuts.length;
      _customShortcuts.removeWhere(
          (s) => supersededDefaults[s.label] == s.value);
      if (_customShortcuts.length != before) {
        await prefs.setString(_kCustomShortcuts,
            json.encode(_customShortcuts.map((s) => s.toJson()).toList()));
      }
      await prefs.setBool('settings_shortcuts_migrated_v5', true);
    }

    // Migration v7: `system:agents` opens the agent launcher. Added to existing
    // setups too — the whole point is that starting an agent stops being a
    // typed command line, and a user who never opens the shortcut manager is
    // exactly the one that helps most.
    final migratedV7 = prefs.getBool('settings_shortcuts_migrated_v7') ?? false;
    if (!migratedV7) {
      if (!_customShortcuts.any((s) => s.value == 'system:agents')) {
        _customShortcuts.insert(
            0, TerminalShortcut(label: 'AGENTES', value: 'system:agents'));
        await prefs.setString(_kCustomShortcuts,
            json.encode(_customShortcuts.map((s) => s.toJson()).toList()));
      }
      await prefs.setBool('settings_shortcuts_migrated_v7', true);
    }

    // Migration v8: `system:select` starts a text selection without a long
    // press. It is added to existing setups rather than only to fresh ones
    // because the problem it solves is one every install has: copying depends
    // on winning a gesture the touch pad also wants.
    final migratedV8 = prefs.getBool('settings_shortcuts_migrated_v8') ?? false;
    if (!migratedV8) {
      if (!_customShortcuts.any((s) => s.value == 'system:select')) {
        final entry =
            TerminalShortcut(label: 'SELECCIONAR', value: 'system:select');
        final after =
            _customShortcuts.indexWhere((s) => s.value == 'system:links');
        _customShortcuts.insert(after >= 0 ? after + 1 : 0, entry);
        await prefs.setString(_kCustomShortcuts,
            json.encode(_customShortcuts.map((s) => s.toJson()).toList()));
      }
      await prefs.setBool('settings_shortcuts_migrated_v8', true);
    }

    _shortcutKeyHeight = prefs.getDouble(_kShortcutKeyHeight) ?? 28.0;
    _shortcutKeyWidth = prefs.getDouble(_kShortcutKeyWidth) ?? 36.0;
    _shortcutRows = (prefs.getInt(_kShortcutRows) ?? 1).clamp(1, 3);

    final layerIds = prefs.getStringList(_kShortcutLayers);
    if (layerIds != null) {
      final restored = layerIds
          .map(QuickKeyLayerInfo.fromId)
          .whereType<QuickKeyLayer>()
          .toList();
      // An empty list would leave the bar with no grid at all; treat a corrupt
      // or fully-emptied setting as "everything visible".
      if (restored.isNotEmpty) _shortcutLayers = restored;
    }

    // Migration: ACCIONES leads the strip. Applied to existing setups too,
    // because the layer that starts the work was buried fourth for everyone
    // who already had the app — a default nobody chose is not a preference
    // worth preserving. Only the *position* moves; a user who hid the layer
    // keeps it hidden, and their order is otherwise untouched.
    final layersActionsFirst =
        prefs.getBool('settings_layers_actions_first') ?? false;
    if (!layersActionsFirst) {
      if (_shortcutLayers.remove(QuickKeyLayer.actions)) {
        _shortcutLayers.insert(0, QuickKeyLayer.actions);
        await prefs.setStringList(
            _kShortcutLayers, _shortcutLayers.map((l) => l.id).toList());
      }
      await prefs.setBool('settings_layers_actions_first', true);
    }

    // Always ACCIONES on launch — see [_shortcutLayerIndex].
    _shortcutLayerIndex = 0;

    _explorerDockLeft = prefs.getBool(_kDockLeft) ?? true;
    _explorerDockY = (prefs.getDouble(_kDockY) ?? 0).clamp(-1.0, 1.0);

    // Desktop workspace. Clamped on read: a fraction stored from a much wider
    // window must still leave both panes usable here.
    _splitSide = (prefs.getDouble(_kSplitSide) ?? 0.24).clamp(0.12, 0.5);
    _splitEditorTerminal =
        (prefs.getDouble(_kSplitEditorTerminal) ?? 0.55).clamp(0.15, 0.85);
    _explorerPaneOpen = prefs.getBool(_kExplorerPaneOpen) ?? true;
    _gitPaneOpen = prefs.getBool(_kGitPaneOpen) ?? false;

    await _loadSnippets(prefs);
    _loadExplorerBookmarks(prefs);

    _settingsLoaded = true;
    notifyListeners();
  }

  /// Re-reads everything from prefs and secure storage, as if the app had just
  /// started. Called after a backup restore: the file has already replaced the
  /// stored values, and this is what makes the running app show them without a
  /// relaunch.
  ///
  /// Live terminal sessions are deliberately untouched — a restore changes
  /// settings and saved profiles, not what is currently connected.
  Future<void> reloadFromDisk() async {
    await _loadSettings();
    await _loadProfiles();
    // The accent/theme are applied by the widget tree from these values, so a
    // single notify at the end is enough.
    notifyListeners();
  }

  Future<void> setAccentColorHex(String value) async {
    if (_accentColorHex == value) return;
    _accentColorHex = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAccentColorHex, value);
  }

  /// Saves [hex] (`#RRGGBB`) into the custom palette and selects it. When the
  /// palette is full the oldest entry is dropped, and re-saving an existing
  /// color just re-selects it.
  Future<void> addCustomAccentColor(String hex) async {
    final normalized = hex.trim().toUpperCase();
    if (!_customAccentColors.contains(normalized)) {
      _customAccentColors.add(normalized);
      if (_customAccentColors.length > maxCustomAccentColors) {
        _customAccentColors.removeAt(0);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kCustomAccentColors, _customAccentColors);
    }
    await setAccentColorHex(normalized);
    notifyListeners();
  }

  /// Removes [hex] from the custom palette, falling back to the default accent
  /// if the deleted color was the active one.
  Future<void> removeCustomAccentColor(String hex) async {
    final normalized = hex.trim().toUpperCase();
    if (!_customAccentColors.remove(normalized)) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kCustomAccentColors, _customAccentColors);
    if (_accentColorHex == normalized) {
      await setAccentColorHex(defaultAccentColorHex);
    }
    notifyListeners();
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

  Future<void> setShortcutRows(int value) async {
    final v = value.clamp(1, 3);
    if (_shortcutRows == v) return;
    _shortcutRows = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kShortcutRows, v);
  }

  /// Switches the visible layer. Not persisted through [setShortcutLayers] —
  /// it is written on its own so a swipe doesn't rewrite the layer list.
  void setShortcutLayerIndex(int index) {
    if (_shortcutLayers.isEmpty) return;
    final v = index.clamp(0, _shortcutLayers.length - 1);
    if (_shortcutLayerIndex == v) return;
    _shortcutLayerIndex = v;
    notifyListeners();
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setInt(_kShortcutLayer, v));
  }

  void showShortcutLayer(QuickKeyLayer layer) {
    final i = _shortcutLayers.indexOf(layer);
    if (i >= 0) setShortcutLayerIndex(i);
  }

  Future<void> setShortcutLayers(List<QuickKeyLayer> layers) async {
    // Keep the same layer on screen across a reorder: the index means nothing
    // to the user, the tab they were looking at does.
    final current = activeShortcutLayer;
    _shortcutLayers = List.of(layers);
    final moved = current == null ? -1 : _shortcutLayers.indexOf(current);
    _shortcutLayerIndex = moved >= 0 ? moved : 0;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _kShortcutLayers, _shortcutLayers.map((l) => l.id).toList());
    await prefs.setInt(_kShortcutLayer, _shortcutLayerIndex);
  }

  Future<void> toggleShortcutLayer(QuickKeyLayer layer, bool visible) async {
    final next = List.of(_shortcutLayers);
    if (visible) {
      if (next.contains(layer)) return;
      // Re-inserted where it sits in the canonical order, not appended, so a
      // toggle round-trip leaves the strip looking the way it started.
      final target = QuickKeyLayer.values.indexOf(layer);
      var at = next.length;
      for (var i = 0; i < next.length; i++) {
        if (QuickKeyLayer.values.indexOf(next[i]) > target) {
          at = i;
          break;
        }
      }
      next.insert(at, layer);
    } else {
      if (!next.contains(layer)) return;
      next.remove(layer);
    }
    await setShortcutLayers(next);
  }

  List<TerminalShortcut> getDefaultShortcuts() {
    return [
      TerminalShortcut(label: 'AGENTES', value: 'system:agents'),
      TerminalShortcut(label: 'ADJUNTAR', value: 'system:attach'),
      TerminalShortcut(label: 'PROMPTS', value: 'system:prompts'),
      TerminalShortcut(label: 'COMMIT', value: 'system:commit'),
      TerminalShortcut(label: 'ENLACES', value: 'system:links'),
      TerminalShortcut(label: 'SELECCIONAR', value: 'system:select'),
      TerminalShortcut(label: 'AJUSTES', value: 'system:settings'),
      // The control codes that used to be here are built into the CTRL layer
      // now (see `terminal_key_layer.dart`); this list is only what the user
      // owns and can edit.
      TerminalShortcut(label: 'clear', value: 'clear\n'),
      TerminalShortcut(label: 'exit', value: 'exit\n'),
    ];
  }

  /// The user's own keys — the MIS layer. `system:` entries are drawn on the
  /// ACCIONES layer instead, so they are filtered out here.
  List<TerminalShortcut> get myShortcuts => _customShortcuts
      .where((s) => s.enabled && !s.value.startsWith('system:'))
      .toList();

  /// Enabled `system:` shortcuts, in the user's order — the ACCIONES layer.
  /// `system:settings` is excluded: the gear lives on the tab strip, always
  /// reachable, so a copy in the grid would just be a second gear.
  List<TerminalShortcut> get actionShortcuts => _customShortcuts
      .where((s) =>
          s.enabled &&
          s.value.startsWith('system:') &&
          s.value != 'system:settings')
      .toList();

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

  Future<void> setTerminalKeyboardAutocorrect(bool value) async {
    if (_terminalKeyboardAutocorrect == value) return;
    _terminalKeyboardAutocorrect = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kTerminalKeyboardAutocorrect, value);
  }

  Future<void> setTerminalAltScrollKeys(bool value) async {
    if (_terminalAltScrollKeys == value) return;
    _terminalAltScrollKeys = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAltScrollKeys, value);
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
  Future<void> setTerminalGestureDeadzone(double deadzone) async {
    if (deadzone == _terminalGestureDeadzone) return;
    _terminalGestureDeadzone = deadzone;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kTerminalGestureDeadzone, deadzone);
  }

  Future<void> setTerminalPadEnabled(bool value) async {
    if (_terminalPadEnabled == value) return;
    _terminalPadEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPadEnabled, value);
  }

  Future<void> setTerminalPadHoldMs(int ms) async {
    final clamped = ms.clamp(
        JoystickGestureRecognizer.minHoldMs, JoystickGestureRecognizer.maxHoldMs);
    if (_terminalPadHoldMs == clamped) return;
    _terminalPadHoldMs = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kPadHoldMs, clamped);
  }

  Future<void> setTerminalPadRadialEnabled(bool value) async {
    if (_terminalPadRadialEnabled == value) return;
    _terminalPadRadialEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPadRadial, value);
  }

  Future<void> setTerminalPadRadialMs(int ms) async {
    final clamped = ms.clamp(minPadRadialMs, maxPadRadialMs);
    if (_terminalPadRadialMs == clamped) return;
    _terminalPadRadialMs = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kPadRadialMs, clamped);
  }

  /// Rebinds one slot (null empties it). The whole pad is persisted as one
  /// blob: eight entries are not worth eight prefs keys, and they are always
  /// read together.
  Future<void> setTerminalPadSlot(
      PadDirection direction, TerminalShortcut? shortcut) async {
    _terminalPadConfig = _terminalPadConfig.withSlot(direction, shortcut);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPadSlots, _terminalPadConfig.encode());
  }

  Future<void> resetTerminalPadSlots() async {
    _terminalPadConfig = TouchPadConfig.defaults;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPadSlots, _terminalPadConfig.encode());
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
    // Restored tabs come back without a connection (see [_restoreSessions]).
    bool connect = true,
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
        _onSessionAlert(session, kind: AlertKind.bell);
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
          _onSessionAlert(session, body: pt.join(';'), kind: AlertKind.bell);
        } else if (ps == '777' && pt.isNotEmpty && pt.first == 'notify') {
          _onSessionAlert(
            session,
            title: pt.length > 1 ? pt[1] : null,
            body: pt.length > 2 ? pt.sublist(2).join(';') : null,
            kind: AlertKind.bell,
          );
        }
      },
      onTitleChange: (title) => _noteTitleEvidence(session, title),
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
    _persistOpenSessions();
    notifyListeners();

    if (connect) {
      _connectSessionToSSH(session, profile, initialCommand: initialCommand);
    }
  }

  // ---- Session restore ------------------------------------------------------
  // Which sessions were open when the app was last used, so closing KAMMEL (or
  // Android killing it in the background) doesn't lose the set of servers being
  // worked on. Only the profile and the tab name are stored — a terminal buffer
  // is not something to persist, and the server's own state is what tmux is for.
  //
  // Restored sessions come back **disconnected**, with the "Reconectar" banner
  // ready. Reconnecting on launch by itself would open SSH connections (and
  // burn mobile data) without anyone asking for them.

  static const String _kOpenSessions = 'open_sessions';
  static const String _kRestoreSessions = 'settings_restore_sessions';

  bool _restoreSessionsEnabled = true;
  bool get restoreSessionsEnabled => _restoreSessionsEnabled;

  Future<void> setRestoreSessionsEnabled(bool value) async {
    if (_restoreSessionsEnabled == value) return;
    _restoreSessionsEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kRestoreSessions, value);
    if (!value) await prefs.remove(_kOpenSessions);
  }

  /// Snapshot of the open tabs. Fire-and-forget: it runs on every session
  /// open/close/rename and must never make those wait on disk.
  void _persistOpenSessions() {
    if (!_restoreSessionsEnabled) return;
    final entries = _sessions
        .where((s) => s.activeProfile != null)
        .map((s) => json.encode({
              'profileId': s.activeProfile!.id,
              'name': s.name,
            }))
        .toList();
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setStringList(_kOpenSessions, entries));
  }

  /// Recreates the tabs from the last run. Called once, right after profiles
  /// load — a session whose profile has since been deleted is dropped.
  Future<void> _restoreSessions(SharedPreferences prefs) async {
    // Read the switch straight from prefs: _loadSettings and _loadProfiles run
    // concurrently from the constructor, so the field may not be filled yet.
    _restoreSessionsEnabled = prefs.getBool(_kRestoreSessions) ?? true;
    if (!_restoreSessionsEnabled) return;
    if (_sessions.isNotEmpty) return; // Already connected to something.

    final raw = prefs.getStringList(_kOpenSessions) ?? const <String>[];
    for (final entry in raw) {
      try {
        final map = json.decode(entry) as Map<String, dynamic>;
        final profile =
            _profiles.where((p) => p.id == map['profileId']).firstOrNull;
        if (profile == null) continue;
        createNewSession(
          profile: profile,
          sessionName: map['name'] as String?,
          connect: false,
        );
      } catch (_) {
        // A malformed entry costs one tab, not the restore.
      }
    }
    if (_sessions.isNotEmpty) {
      _activeSessionIndex = 0;
      notifyListeners();
    }
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
    _loadConnectionOrganisation(prefs);
    await _restoreSessions(prefs);

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

    // Live sessions on this profile pick up tunnel changes immediately —
    // adding a tunnel shouldn't require reconnecting. Everything else on the
    // profile still only applies to the next connection.
    for (final session in _sessions) {
      if (session.activeProfile?.id != profile.id) continue;
      session.activeProfile = profile;
      await tunnels.syncConfig(
        sessionId: session.id,
        sessionName: session.name,
        tunnels: profile.tunnels,
      );
    }
  }

  /// Profiles that reach the internet through [id] as their jump host.
  ///
  /// Deleting a bastion is not a local edit: every machine behind it becomes
  /// unreachable. The confirmation says so, and [deleteProfile] unlinks them
  /// rather than leaving a dangling reference that only surfaces as a failed
  /// connection days later.
  List<ConnectionProfile> profilesJumpingThrough(String id) =>
      _profiles.where((p) => p.jumpProfileId == id).toList(growable: false);

  /// Deletes a profile and returns the ids of the profiles that were using it
  /// as their jump host — they are left connecting directly.
  ///
  /// The caller needs those ids because deletion is undoable: re-saving the
  /// profile alone would bring the bastion back with nothing pointing at it.
  Future<List<String>> deleteProfile(String id) async {
    final orphaned = profilesJumpingThrough(id).map((p) => p.id).toList();
    _profiles.removeWhere((p) => p.id == id);
    for (var i = 0; i < _profiles.length; i++) {
      if (_profiles[i].jumpProfileId == id) {
        _profiles[i] = _profiles[i].copyWith(clearJump: true);
      }
    }
    _favoriteProfiles.remove(id);
    _profileLastUsed.remove(id);
    await SecureStore.instance.deleteSecrets(id);
    final prefs = await SharedPreferences.getInstance();
    await _persistProfiles(prefs);
    notifyListeners();
    return orphaned;
  }

  /// Points [profileIds] back at [jumpId]. The undo half of [deleteProfile].
  Future<void> relinkJumpHost(List<String> profileIds, String jumpId) async {
    if (profileIds.isEmpty) return;
    var changed = false;
    for (var i = 0; i < _profiles.length; i++) {
      if (!profileIds.contains(_profiles[i].id)) continue;
      _profiles[i] = _profiles[i].copyWith(jumpProfileId: jumpId);
      changed = true;
    }
    if (!changed) return;
    final prefs = await SharedPreferences.getInstance();
    await _persistProfiles(prefs);
    notifyListeners();
  }

  // ---- Connection organisation ---------------------------------------------
  // Groups, favourites and "last used" are *about* profiles rather than part
  // of them: they change from the list (a swipe, a long press) far more often
  // than the profile itself, and rewriting the whole `ssh_profiles` blob — with
  // its secure-storage round trip per profile — on every connect would be
  // wasteful. They live in their own small prefs entries, keyed by profile id.

  static const String _kConnectionGroups = 'connection_groups';
  static const String _kProfileFavorites = 'profile_favorites';
  static const String _kProfileLastUsed = 'profile_last_used';

  List<ConnectionGroup> _groups = [];
  List<ConnectionGroup> get groups => List.unmodifiable(_groups);

  Set<String> _favoriteProfiles = {};
  Map<String, DateTime> _profileLastUsed = {};

  void _loadConnectionOrganisation(SharedPreferences prefs) {
    _groups = (prefs.getStringList(_kConnectionGroups) ?? [])
        .map((raw) {
          try {
            return ConnectionGroup.fromJson(raw);
          } catch (_) {
            return null;
          }
        })
        .whereType<ConnectionGroup>()
        .toList();

    _favoriteProfiles = (prefs.getStringList(_kProfileFavorites) ?? []).toSet();

    final rawUsed = prefs.getString(_kProfileLastUsed);
    if (rawUsed != null) {
      try {
        final decoded = json.decode(rawUsed) as Map<String, dynamic>;
        _profileLastUsed = {
          for (final entry in decoded.entries)
            if (DateTime.tryParse('${entry.value}') != null)
              entry.key: DateTime.parse('${entry.value}'),
        };
      } catch (_) {
        _profileLastUsed = {};
      }
    }
  }

  Future<void> _persistGroups() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _kConnectionGroups, _groups.map((g) => g.toJson()).toList());
  }

  /// Creates or renames a group.
  Future<void> saveGroup(ConnectionGroup group) async {
    final index = _groups.indexWhere((g) => g.id == group.id);
    if (index >= 0) {
      _groups[index] = group;
    } else {
      _groups.add(group);
    }
    notifyListeners();
    await _persistGroups();
  }

  /// Deletes a group. Its profiles are *not* deleted — they fall back to the
  /// ungrouped bucket, which is the only non-destructive reading of "remove
  /// this folder".
  Future<void> deleteGroup(String id) async {
    _groups.removeWhere((g) => g.id == id);
    final orphans = _profiles.where((p) => p.groupId == id).toList();
    for (var i = 0; i < _profiles.length; i++) {
      if (_profiles[i].groupId == id) {
        _profiles[i] = _profiles[i].copyWith(clearGroupId: true);
      }
    }
    notifyListeners();
    await _persistGroups();
    if (orphans.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await _persistProfiles(prefs);
    }
  }

  /// Moves [profileId] into [groupId] (null = ungrouped).
  Future<void> setProfileGroup(String profileId, String? groupId) async {
    final index = _profiles.indexWhere((p) => p.id == profileId);
    if (index < 0) return;
    _profiles[index] = _profiles[index]
        .copyWith(groupId: groupId, clearGroupId: groupId == null);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await _persistProfiles(prefs);
  }

  bool isFavoriteProfile(String id) => _favoriteProfiles.contains(id);

  Future<void> toggleFavoriteProfile(String id) async {
    if (!_favoriteProfiles.remove(id)) _favoriteProfiles.add(id);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kProfileFavorites, _favoriteProfiles.toList());
  }

  /// When [id] was last connected to, or null if never.
  DateTime? lastConnectedAt(String id) => _profileLastUsed[id];

  /// Profiles connected to at least once, most recent first. The connections
  /// screen shows the top few above the full list — on a phone that is the
  /// difference between one tap and a scroll through thirty servers.
  List<ConnectionProfile> recentProfiles({int limit = 3}) {
    final dated = _profiles
        .where((p) => _profileLastUsed.containsKey(p.id))
        .toList()
      ..sort((a, b) =>
          _profileLastUsed[b.id]!.compareTo(_profileLastUsed[a.id]!));
    return dated.take(limit).toList();
  }

  /// Stamps a successful connection. Fire-and-forget: it runs inside the
  /// connect path, where an await on a prefs write would delay the first byte.
  void _noteProfileConnected(ConnectionProfile profile) {
    _profileLastUsed[profile.id] = DateTime.now();
    SharedPreferences.getInstance().then((prefs) => prefs.setString(
        _kProfileLastUsed,
        json.encode({
          for (final e in _profileLastUsed.entries)
            e.key: e.value.toIso8601String(),
        })));
  }

  /// Copies [profile] under a new id and a "(copia)" name, keeping its secrets,
  /// tunnels and group. Returns the new profile so the caller can open it for
  /// editing straight away.
  Future<ConnectionProfile> duplicateProfile(ConnectionProfile profile) async {
    final copy = ConnectionProfile(
      id: const Uuid().v4(),
      name: tr('{0} (copia)', [profile.name]),
      host: profile.host,
      port: profile.port,
      username: profile.username,
      password: profile.password,
      privateKey: profile.privateKey,
      isLocal: profile.isLocal,
      groupId: profile.groupId,
      tunnels: profile.tunnels,
      useTmux: profile.useTmux,
      useDeviceKey: profile.useDeviceKey,
    );
    await saveProfile(copy);
    return copy;
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
          title: tr('Tests y arreglos'),
          text: tr('Corre los tests del proyecto y arregla los fallos que encuentres. Muéstrame un resumen de lo que cambiaste.'),
        ),
        PromptSnippet(
          id: const Uuid().v4(),
          title: tr('Commit y push'),
          text: tr('Haz commit de los cambios pendientes con un mensaje descriptivo y haz push a la rama actual.'),
        ),
        PromptSnippet(
          id: const Uuid().v4(),
          title: tr('Explicar error'),
          text: tr('Explica el último error que apareció y propón cómo solucionarlo antes de tocar nada.'),
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

  /// Answers the agent in [sessionId] **without switching to it** — the agents
  /// dashboard replying to a question from its card.
  ///
  /// Returns false when there is nothing to write to, so the caller can say so
  /// instead of silently swallowing a keystroke the user believes they sent.
  ///
  /// This is the first path in the app that types into a session the user is
  /// *not looking at*, which is why the caller is expected to put the screen
  /// snippet above the button and to confirm on a production profile. Here the
  /// care is mechanical:
  ///
  /// - It does **not** go through [sendTerminalInput]: that applies the sticky
  ///   CTRL modifier, and a modifier left armed in the terminal would silently
  ///   turn a "y" typed on another screen into a `^Y`.
  /// - [asPaste] routes through [Terminal.paste] so a bracketed-paste-aware TUI
  ///   (every modern agent) sees one insertion. Control sequences must never
  ///   take that path — wrapped in paste markers, an Esc is just text.
  /// - It still feeds [_noteInputEvidence], so a reply sent from the dashboard
  ///   keeps agent detection and command history as accurate as one typed into
  ///   the terminal.
  bool sendToSession(String sessionId, String text,
      {bool submit = false, bool asPaste = false}) {
    final session = _sessions.where((s) => s.id == sessionId).firstOrNull;
    if (session == null) return false;
    if (session.connectionStatus != ConnectionStatus.remote ||
        session.sshSession == null) {
      return false;
    }
    if (text.isEmpty && !submit) return false;

    if (text.isNotEmpty) {
      if (asPaste) {
        // paste() emits through Terminal.onOutput, which is already wired to
        // _noteInputEvidence and the SSH write in [createNewSession].
        session.terminal.paste(text);
      } else {
        _noteInputEvidence(session, text);
        session.sshSession!.write(utf8.encode(text));
      }
    }
    if (submit) {
      _noteInputEvidence(session, '\r');
      session.sshSession!.write(utf8.encode('\r'));
    }

    // Whatever the notification claimed this session wanted, it has now been
    // answered: leaving the badge and the posted alert behind would send the
    // user to a session that is no longer asking anything.
    session.hasPendingAlert = false;
    NotificationService.cancelAlert(session.id);
    notifyListeners();
    return true;
  }

  /// The session's SFTP channel, opening one on demand. Pass [fresh] to force a
  /// new channel: a cached client can belong to a connection that has since
  /// dropped, and every operation on it then hangs instead of failing.
  Future<SftpClient> _getSftpClient(TerminalSession session,
      {bool fresh = false}) async {
    final ssh = session.sshClient;
    if (ssh == null || ssh.isClosed) {
      session.sftpClient = null;
      throw Exception(tr('El cliente SSH no está conectado'));
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

  /// How long a single hop gets: the TCP connect to the first machine, and
  /// each `direct-tcpip` forward opened through the previous one. Per hop
  /// rather than for the whole chain, so a three-hop chain over a slow link
  /// isn't cut off halfway by a budget sized for one.
  static const Duration _kHopTimeout = Duration(seconds: 15);

  /// Opens and authenticates a standalone [SSHClient] for [profile], without
  /// tying it to a terminal session. Non-fatal notices (missing device key,
  /// unparseable PEM) are reported through [onNotice]; auth/connect failures
  /// throw. Callers own the returned client and must close() it.
  ///
  /// When the profile declares a jump host (see [JumpChain]) the chain is
  /// dialled first and the returned client runs **inside** a forward from the
  /// last hop. The hops are owned by the returned client: closing it — or the
  /// server closing it, or a hop dying under it — tears the whole chain down,
  /// so callers keep the one-client contract they always had.
  Future<SSHClient> openClient(ConnectionProfile profile,
      {void Function(String msg)? onNotice}) async {
    // Configuration errors (missing hop, cycle, too deep) are raised here,
    // before any socket exists, so nothing has to be unwound.
    final chain = JumpChain.resolve(profile, _profiles);

    final hops = <SSHClient>[];
    try {
      SSHSocket socket;
      if (chain.isEmpty) {
        socket = await SSHSocket.connect(profile.host, profile.port,
            timeout: _kHopTimeout);
      } else {
        SSHClient? previous;
        for (final hop in chain) {
          // Announced *before* dialling: a hop that is down burns the whole
          // timeout, and a silent terminal for 15 seconds looks like a hang.
          onNotice?.call(
              tr('Saltando por {0} ({1}:{2})…', [hop.name, hop.host, hop.port]));
          try {
            final hopSocket = previous == null
                ? await SSHSocket.connect(hop.host, hop.port,
                    timeout: _kHopTimeout)
                // A forward through an already-authenticated hop: this is the
                // `-J` chain proper. dartssh2's SSHForwardChannel *is* an
                // SSHSocket, so the next client speaks SSH over it unchanged.
                : await previous
                    .forwardLocal(hop.host, hop.port)
                    .timeout(_kHopTimeout);
            previous = await _authenticateClient(hop, hopSocket,
                onNotice: onNotice);
            hops.add(previous);
          } catch (e) {
            // Name the machine that actually refused. Three hosts were dialled;
            // "no se pudo conectar" would not say which one broke.
            if (e is JumpHopError) rethrow;
            throw JumpHopError(hop.name, e);
          }
        }
        // The last hop opening the channel to the destination. Wrapped like
        // the others: when a bastion is configured to forward nowhere, the raw
        // "channel open failed: administratively prohibited" names neither the
        // machine that refused nor what it refused to do.
        try {
          socket = await previous!
              .forwardLocal(profile.host, profile.port)
              .timeout(_kHopTimeout);
        } catch (e) {
          throw JumpHopError(chain.last.name, e);
        }
      }

      final client =
          await _authenticateClient(profile, socket, onNotice: onNotice);
      if (hops.isNotEmpty) _bindHopsTo(client, hops);
      return client;
    } catch (_) {
      // Unwind the chain in reverse: an outer hop closing first would tear
      // down the forward the inner one still lives in.
      for (final hop in hops.reversed) {
        hop.close();
      }
      rethrow;
    }
  }

  /// Ties the lifetime of [hops] to [client]: when the client is closed, dies,
  /// or its transport goes away, every hop behind it is closed too.
  ///
  /// This is what keeps the chain from leaking. It also covers the reverse
  /// direction for free: if a hop drops, the forward carrying [client] closes,
  /// [client] completes, and the rest of the chain is released here.
  void _bindHopsTo(SSHClient client, List<SSHClient> hops) {
    unawaited(client.done
        // The client's own failure is reported to whoever awaited it; here it
        // must not become an unhandled async error.
        .catchError((_) {})
        .whenComplete(() {
      for (final hop in hops.reversed) {
        try {
          hop.close();
        } catch (_) {
          // Already gone: closing is best-effort cleanup, never a failure.
        }
      }
    }));
  }

  /// Builds and authenticates a client for [profile] over an already-open
  /// [socket] — a plain TCP socket, or a forward through the previous hop.
  Future<SSHClient> _authenticateClient(
      ConnectionProfile profile, SSHSocket socket,
      {void Function(String msg)? onNotice}) async {
    // Public-key auth: the phone's own device key (opt-in per profile) plus
    // any per-profile PEM. dartssh2 tries identities first and falls back to
    // the password automatically, so a profile can carry both. A PEM that
    // fails to parse is reported but doesn't block the connection attempt.
    final identities = <SSHKeyPair>[];
    if (profile.useDeviceKey) {
      final pem = await DeviceKey.privatePem();
      if (pem == null) {
        onNotice?.call(
            tr('Este perfil usa la llave del dispositivo pero aún no existe; génerala en Ajustes.'));
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
        onNotice?.call(tr('No se pudo leer la llave privada del perfil: {0}', [e]));
      }
    }

    final client = SSHClient(
      socket,
      username: profile.username,
      identities: identities.isEmpty ? null : identities,
      onPasswordRequest: () => profile.password ?? '',
      // Host key pinning, per hop: each machine of the chain is checked and
      // pinned under its own host:port. Without this dartssh2 accepts any key,
      // so anyone able to intercept the connection could impersonate the server
      // and harvest the password (and everything sent through the tunnels).
      onVerifyHostkeyBlob: (type, blob) =>
          _verifyHostKey(profile, type, blob, onNotice: onNotice),
    );
    try {
      // Fail fast on bad credentials instead of on the first channel open.
      await client.authenticated;
    } catch (_) {
      // The socket is ours until authentication succeeds; a rejected password
      // would otherwise leave it (and, in a chain, the forward carrying it)
      // open until the server timed it out.
      client.close();
      rethrow;
    }
    return client;
  }


  /// Opens a throwaway connection with [profile] and closes it, reporting what
  /// happened in one sentence.
  ///
  /// This is the "Probar conexión" button in the profile form. Before it, the
  /// only way to find out a profile was wrong was to save it, connect, and read
  /// an exception in the terminal — after which the form (and everything just
  /// typed into it) was gone.
  ///
  /// Deliberately does *not* create a session, touch [_sessions], or stamp the
  /// profile as recently used: a test is not a connection.
  Future<({bool ok, String message})> testProfile(
      ConnectionProfile profile) async {
    // One budget per machine that has to be dialled. A fixed 20s would fail a
    // perfectly good two-hop chain over a slow link and blame the target.
    var hops = 0;
    try {
      hops = JumpChain.resolve(profile, _profiles).length;
    } on JumpChainError {
      // Leave it to openClient, which reports the broken link properly.
    }
    SSHClient? client;
    try {
      client = await openClient(profile, onNotice: (_) {})
          .timeout(Duration(seconds: 20 + 15 * hops));
      // Authentication is what we actually care about, and openClient only
      // returns once it succeeded.
      final banner = client.remoteVersion;
      return (
        ok: true,
        message: banner != null && banner.isNotEmpty
            ? tr('Conexión correcta · {0}', [banner])
            : tr('Conexión correcta.'),
      );
    } catch (e) {
      return (ok: false, message: ConnectionError.from(e).friendly.oneLine);
    } finally {
      client?.close();
    }
  }

  /// Asked by the UI layer to confirm an unknown or changed host key. Set in
  /// `main.dart`; when it's null (no UI available) an unrecognized key is
  /// refused rather than silently trusted.
  Future<bool> Function(HostKeyChallenge challenge)? hostKeyConfirm;

  /// Trust-on-first-use host key check, OpenSSH style:
  /// - known and unchanged → connect silently;
  /// - never seen → ask once and pin it;
  /// - changed → block by default and make the user look at both fingerprints.
  Future<bool> _verifyHostKey(
      ConnectionProfile profile, String keyType, Uint8List blob,
      {void Function(String msg)? onNotice}) async {
    final fingerprint = KnownHosts.fingerprintOf(blob);
    final verdict =
        await KnownHosts.instance.check(profile.host, profile.port, fingerprint);

    if (verdict == HostKeyVerdict.match) return true;

    final known = await KnownHosts.instance.lookup(profile.host, profile.port);
    final confirm = hostKeyConfirm;
    if (confirm == null) {
      onNotice?.call(tr('No se pudo verificar la identidad del servidor ({0}). Conexión cancelada.', [fingerprint]));
      return false;
    }

    final accepted = await confirm(HostKeyChallenge(
      profileName: profile.name,
      host: profile.host,
      port: profile.port,
      keyType: keyType,
      fingerprint: fingerprint,
      verdict: verdict,
      previousFingerprint: known?.fingerprint,
      previousAddedAt: known?.addedAt,
    ));

    if (!accepted) {
      onNotice?.call(verdict == HostKeyVerdict.mismatch
          ? tr('La identidad del servidor cambió y no fue aceptada. Conexión cancelada.')
          : tr('Identidad del servidor no aceptada. Conexión cancelada.'));
      return false;
    }

    await KnownHosts.instance
        .trust(profile.host, profile.port, keyType, fingerprint);
    onNotice?.call(tr('Identidad del servidor guardada: {0}', [fingerprint]));
    return true;
  }

  // Connect a session to a remote SSH server
  Future<void> _connectSessionToSSH(TerminalSession session, ConnectionProfile profile,
      {String? initialCommand}) async {
    _disposeWriters(session);
    // A reconnect reuses the session object: drop every leftover from the
    // previous connection first — bound tunnel ports (they'd fail to re-bind)
    // and stale SFTP/SSH handles. Tunnels that were up keep their "desired"
    // flag, so syncOnConnect brings exactly those back.
    tunnels.onSessionLost(session.id);
    session.sftpClient?.close();
    session.sftpClient = null;
    session.sshSession?.close();
    session.sshSession = null;
    session.sshClient?.close();
    session.sshClient = null;
    session.connectionStatus = ConnectionStatus.connecting;
    session.lastError = null;
    _noteActivity(session, AgentState.connecting);
    notifyListeners();

    session.terminal.write(
        '\r\n${tr('Conectando a {0} ({1}:{2})…', [
          profile.name,
          profile.host,
          profile.port
        ])}\r\n');
    final route = JumpChain.describe(profile, _profiles);
    if (route != null) {
      session.terminal.write('${tr('Ruta: {0} → {1}', [route, profile.name])}\r\n');
    }

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
          '|| { echo "[KAMMEL] tmux no está instalado en el servidor; abriendo shell normal."; '
              'exec "\${SHELL:-sh}" -l; }',
          pty: pty,
        );
      } else {
        session.sshSession = await session.sshClient!.shell(pty: pty);
      }

      // Forward later size changes to the remote PTY, coalesced. xterm and
      // resizeTerminal both use (width=cols, height=rows) order.
      session.terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        _scheduleResize(session, width, height, pixelWidth, pixelHeight);
      };

      // Ask the remote shell to report its cwd via OSC 7 on every prompt, so the
      // git panel tracks where the terminal actually is (see [terminalCwd]).
      _seedCwdReporting(session);

      session.connectionStatus = ConnectionStatus.remote;
      session.started = true;
      session.lastError = null;
      // A fresh shell is at its prompt. The watch loop takes over from here and
      // will say otherwise the moment anything is launched in it.
      _noteActivity(session, AgentState.prompt, snippet: '', clearAgent: true);
      _noteProfileConnected(profile);
      // First live SSH session → keep the process alive while backgrounded.
      _ensureBackgroundService();

      // Port forwards declared on the profile (-L / -D / -R). Failures are
      // reported per tunnel and never abort the connection.
      await tunnels.syncOnConnect(
        sessionId: session.id,
        sessionName: session.name,
        client: session.sshClient!,
        tunnels: profile.tunnels,
        log: (msg) => session.terminal.write('$msg\r\n'),
      );

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
        _noteInputEvidence(session, out);
        session.sshSession!.write(utf8.encode(out));
      };

      // Listen for connection loss
      session.sshClient!.done.then((_) {
        if (session.connectionStatus == ConnectionStatus.remote) {
          session.connectionStatus = ConnectionStatus.disconnected;
          tunnels.onSessionLost(session.id);
          _noteActivity(session, AgentState.disconnected);
          session.terminal.write(
              '\r\n${tr('Conexión cerrada por el servidor.')}\r\n');
          _onSessionAlert(session,
              body: tr('Se cerró la conexión con {0}.', [session.name]),
              kind: AlertKind.disconnect);
          notifyListeners();
        }
      }).catchError((e) {
        if (session.connectionStatus == ConnectionStatus.remote) {
          session.connectionStatus = ConnectionStatus.disconnected;
          tunnels.onSessionLost(session.id);
          _noteActivity(session, AgentState.disconnected);
          session.lastError = ConnectionError.from(e as Object);
          session.terminal.write(
              '\r\n${tr('Error de conexión: {0}', [session.lastError!.title])}\r\n');
          _onSessionAlert(session,
              body: tr('Se perdió la conexión con {0}.', [session.name]),
              kind: AlertKind.disconnect);
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
      final failure = ConnectionError.from(e);
      session.lastError = failure;
      _noteActivity(session, AgentState.disconnected);
      // The classified reason first (that's the actionable part), then the raw
      // text — it stays in the scrollback for a bug report.
      session.terminal.write(
          '\r\n${tr('Error de conexión: {0}', [failure.friendly.oneLine])}\r\n$e\r\n');
      notifyListeners();
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
    _setTab(1); // Switch to terminal tab
    notifyListeners();
  }

  // Switch to an open session
  void switchSession(int index) {
    if (index < 0 || index >= _sessions.length) return;
    _activeSessionIndex = index;
    // Looking at the session acknowledges its pending agent alert — in the app
    // and in the notification shade.
    _sessions[index].hasPendingAlert = false;
    NotificationService.cancelAlert(_sessions[index].id);
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
    _persistOpenSessions();

    if (_sessions.isEmpty) {
      // No SSH sessions left: drop back to the connections tab. A new session
      // is created only when the user connects to a profile again.
      _activeSessionIndex = -1;
      _setTab(0);
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
      tunnels.renameSession(_sessions[index].id, _sessions[index].name);
      _persistOpenSessions();
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

  /// Coalesce PTY resizes into one `window-change` per burst.
  ///
  /// Dragging a workspace splitter (or a window edge) walks the terminal
  /// through many cell grids in a few hundred milliseconds. Sent straight
  /// through, each step is an SSH packet and a full redraw, so a TUI like vim
  /// or htop reflows continuously while the drag is in flight. A trailing
  /// timer means the remote only ever sees the size the user settled on.
  void _scheduleResize(
    TerminalSession session,
    int width,
    int height,
    int pixelWidth,
    int pixelHeight,
  ) {
    _sessionResizeTimers[session.id]?.cancel();
    _sessionResizeTimers[session.id] =
        Timer(const Duration(milliseconds: 150), () {
      _sessionResizeTimers.remove(session.id);
      // Everything the remote repaints in response is old content in a new
      // shape — see [TerminalSession.redrawGraceUntil].
      session.redrawGraceUntil = DateTime.now().add(_redrawGrace);
      session.sshSession?.resizeTerminal(width, height, pixelWidth, pixelHeight);
    });
  }

  void _cleanupSession(TerminalSession session) {
    _sessionAlertTimers.remove(session.id)?.cancel();
    _sessionCheckTimers.remove(session.id)?.cancel();
    _sessionResizeTimers.remove(session.id)?.cancel();
    _disposeWriters(session);
    tunnels.removeSession(session.id);
    agents.removeSession(session.id);
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
    _noteInputEvidence(session, out);
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

  // ---- Attach upload progress ----------------------------------------------
  // The picked file is uploaded over SFTP *before* its path reaches the prompt,
  // and on a slow link that takes seconds with nothing on screen. These fields
  // let the ADJUNTAR key (and the paste-image path) show live progress instead
  // of looking frozen.
  bool _isAttaching = false;
  bool get isAttaching => _isAttaching;

  int _attachBytesDone = 0;
  int _attachBytesTotal = 0;

  String _attachName = '';
  String get attachName => _attachName;

  /// Upload progress in 0..1, or `null` while the size isn't known yet (the
  /// caller should render an indeterminate indicator then).
  double? get attachProgress {
    if (_attachBytesTotal <= 0) return null;
    return (_attachBytesDone / _attachBytesTotal).clamp(0.0, 1.0);
  }

  void _beginAttach(String name) {
    _isAttaching = true;
    _attachName = name;
    _attachBytesDone = 0;
    _attachBytesTotal = 0;
    notifyListeners();
  }

  void _endAttach() {
    if (!_isAttaching) return;
    _isAttaching = false;
    _attachName = '';
    _attachBytesDone = 0;
    _attachBytesTotal = 0;
    notifyListeners();
  }

  /// Emits [bytes] in chunks, updating the attach counters as each one is handed
  /// to the SFTP writer. A single `Stream.value(bytes)` uploads the same data
  /// but reports nothing until it's already over.
  Stream<Uint8List> _attachChunks(Uint8List bytes) async* {
    const chunkSize = 32 * 1024;
    _attachBytesTotal = bytes.length;
    _attachBytesDone = 0;
    notifyListeners();
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end =
          offset + chunkSize > bytes.length ? bytes.length : offset + chunkSize;
      yield Uint8List.sublistView(bytes, offset, end);
      _attachBytesDone = end;
      notifyListeners();
    }
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
    if (session == null) return (ok: false, message: tr('No hay sesión activa'));

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
      return (ok: false, message: tr('Adjuntar requiere una sesión SSH activa'));
    }
    final String shellPath;
    _beginAttach(name);
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
      await f.write(_attachChunks(bytes));
      await f.close();
    } catch (e) {
      return (ok: false, message: tr('No se pudo adjuntar: {0}', [e]));
    } finally {
      _endAttach();
    }

    // Leading + trailing space keep the path separate from whatever the user
    // types around it. The path itself is bare when safe, quoted when not.
    _typeLiteral(session, ' ${_formatPathForInput(shellPath)} ');
    return (ok: true, message: tr('Adjuntado: {0}', [name]));
  }

  /// Picks files from the user's phone/device and uploads them directly to the
  /// current folder in the active explorer session.
  Future<({bool ok, String message})> uploadFilesFromPhone() async {
    final session = activeSession;
    if (session == null) return (ok: false, message: tr('No hay sesión activa'));

    try {
      await _ensureStoragePermission();
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true,
      );
      if (picked == null || picked.files.isEmpty) {
        return (ok: false, message: ''); // User cancelled
      }

      session.isLoadingFiles = true;
      notifyListeners();

      int count = 0;
      for (final file in picked.files) {
        final src = file.path;
        if (src == null) continue;
        final rawName = file.name;
        final name = _sanitizeFilename(rawName);

        if (session.connectionStatus == ConnectionStatus.remote) {
          final sftp = await _getSftpClient(session);
          final remoteFilePath = '${session.currentPath}/$name'.replaceAll('//', '/');
          final bytes = await File(src).readAsBytes();
          final f = await sftp.open(
            remoteFilePath,
            mode: SftpFileOpenMode.write |
                SftpFileOpenMode.create |
                SftpFileOpenMode.truncate,
          );
          await f.write(Stream.value(bytes));
          await f.close();
        } else {
          final localFilePath = '${session.currentPath}/$name'.replaceAll('//', '/');
          final bytes = await File(src).readAsBytes();
          await File(localFilePath).writeAsBytes(bytes);
        }
        count++;
      }

      return (ok: true, message: tr('Se subió {0} archivo(s) correctamente', [count]));
    } catch (e) {
      return (ok: false, message: tr('Error al subir: {0}', [e]));
    } finally {
      session.isLoadingFiles = false;
      notifyListeners();
      await _loadFiles();
    }
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





  // ---- Text scale -----------------------------------------------------------
  // Flutter already honours the system font-size setting, so the app has always
  // scaled *somewhat*. Two things were missing, and both matter here: this UI
  // has labels down to 8px (tags, session meta, panel titles), so "a bit
  // bigger" is a real need even for people who leave the system alone; and the
  // chrome is built from fixed heights (a 46px toolbar, a 42px path bar), which
  // a 2x system scale overflows. So the app publishes its own multiplier and
  // clamps the product — see main.dart, where it is applied.

  static const String _kTextScale = 'settings_text_scale';
  static const double minTextScale = 0.85;
  static const double maxTextScale = 1.5;

  /// Upper bound on system × app scaling. Past this the fixed-height bars stop
  /// being able to contain their own labels, which is worse for everyone than
  /// text that stopped growing.
  static const double maxEffectiveTextScale = 1.6;

  double _textScale = 1.0;
  double get textScale => _textScale;

  Future<void> setTextScale(double value) async {
    final clamped = value.clamp(minTextScale, maxTextScale);
    if (clamped == _textScale) return;
    _textScale = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kTextScale, clamped);
  }

  // ---- Onboarding -----------------------------------------------------------
  // Whether the three-card introduction has been shown. Versioned in the key so
  // a future rewrite of the cards can be shown again to existing users without
  // clearing anything else.
  static const String _kOnboardingSeen = 'onboarding_seen_v1';

  bool _onboardingSeen = false;
  bool get onboardingSeen => _onboardingSeen;

  Future<void> markOnboardingSeen() async {
    if (_onboardingSeen) return;
    _onboardingSeen = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOnboardingSeen, true);
  }

  /// Lets the user replay the introduction from Ajustes.
  Future<void> resetOnboarding() async {
    _onboardingSeen = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kOnboardingSeen);
  }

  // ---- Terminal chrome ------------------------------------------------------
  // Which of the terminal's optional bars are showing. This lived as private
  // State inside TerminalTab, which was fine while the toolbar was the only
  // thing that could toggle it — a keyboard shortcut (and the command palette)
  // need to reach the same switch, and two sources of truth for "is the quick
  // keyboard up" is how a toggle ends up out of sync with its own button.

  static const String _kQuickKeysVisible = 'settings_quick_keys_visible';

  bool _quickKeysVisible = true;
  bool get quickKeysVisible => _quickKeysVisible;

  Future<void> setQuickKeysVisible(bool value) async {
    if (_quickKeysVisible == value) return;
    _quickKeysVisible = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kQuickKeysVisible, value);
  }

  void toggleQuickKeys() => setQuickKeysVisible(!_quickKeysVisible);

  // Dictation bar. Not persisted: it is opened for a specific stretch of
  // dictation and costs vertical space, so it should not come back by itself.
  bool _composeBarVisible = false;
  bool get composeBarVisible => _composeBarVisible;

  void setComposeBarVisible(bool value) {
    if (_composeBarVisible == value) return;
    _composeBarVisible = value;
    notifyListeners();
  }

  void toggleComposeBar() => setComposeBarVisible(!_composeBarVisible);

  // Scrollback search. The query and the match cursor live in TerminalTab (they
  // are meaningless without the buffer they were computed against); only
  // "is the search bar up" belongs here, so Ctrl+Shift+F can raise it from
  // anywhere.
  bool _terminalSearchOpen = false;
  bool get terminalSearchOpen => _terminalSearchOpen;

  void setTerminalSearchOpen(bool value) {
    if (_terminalSearchOpen == value) return;
    _terminalSearchOpen = value;
    notifyListeners();
  }

  // ---- Command history ------------------------------------------------------
  // Every line submitted to a shell, newest last. The keystroke stream is
  // already being watched to identify which agent a session is running
  // (see [_noteInputEvidence]); this reuses the same Enter boundary.
  //
  // Only recorded from the normal buffer: inside a full-screen TUI those
  // keystrokes are chat messages to an agent or vim commands, not shell
  // history, and mixing them in makes the list useless.

  static const String _kCommandHistory = 'command_history';
  static const String _kCommandHistoryEnabled = 'settings_command_history';

  /// How many lines are kept. Enough to cover a working session; small enough
  /// that the prefs write on every command stays cheap.
  static const int maxCommandHistory = 200;

  List<String> _commandHistory = [];

  /// Newest first — the order the history sheet shows them in.
  List<String> get commandHistory => List.unmodifiable(_commandHistory.reversed);

  bool _commandHistoryEnabled = true;
  bool get commandHistoryEnabled => _commandHistoryEnabled;

  Future<void> setCommandHistoryEnabled(bool value) async {
    if (_commandHistoryEnabled == value) return;
    _commandHistoryEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kCommandHistoryEnabled, value);
    // Turning it off throws away what was already collected: leaving it on disk
    // would defeat the point of the switch.
    if (!value) await clearCommandHistory();
  }

  Future<void> clearCommandHistory() async {
    if (_commandHistory.isEmpty) return;
    _commandHistory = [];
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kCommandHistory);
  }

  void _recordCommand(TerminalSession session, String rawLine) {
    if (!_commandHistoryEnabled) return;
    if (session.terminal.isUsingAltBuffer) return;
    final line = rawLine.trim();
    if (line.isEmpty) return;
    // A command repeated back-to-back (a failing `make` run four times) adds
    // nothing to a list whose whole job is recall.
    if (_commandHistory.isNotEmpty && _commandHistory.last == line) return;

    _commandHistory.add(line);
    if (_commandHistory.length > maxCommandHistory) {
      _commandHistory.removeRange(
          0, _commandHistory.length - maxCommandHistory);
    }
    notifyListeners();
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setStringList(_kCommandHistory, _commandHistory));
  }

  // ---- Explorer sorting -----------------------------------------------------
  // Persisted, because "logs newest first" is a standing preference and not a
  // per-visit one. Directories are pinned above files in every mode.

  static const String _kFileSortKey = 'settings_explorer_sort_key';
  static const String _kFileSortAsc = 'settings_explorer_sort_asc';

  FileSortKey _fileSortKey = FileSortKey.name;
  FileSortKey get fileSortKey => _fileSortKey;

  bool _fileSortAscending = true;
  bool get fileSortAscending => _fileSortAscending;

  Future<void> setFileSort(FileSortKey key, {bool? ascending}) async {
    // Tapping the active key flips the direction — the behaviour of every
    // sortable table there has ever been.
    final asc = ascending ?? (key == _fileSortKey ? !_fileSortAscending : true);
    if (key == _fileSortKey && asc == _fileSortAscending) return;
    _fileSortKey = key;
    _fileSortAscending = asc;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kFileSortKey, key.index);
    await prefs.setBool(_kFileSortAsc, asc);
  }

  /// Orders [files] by the current sort. Returns a new list; the caller's is
  /// left alone (it is usually the session's own cached listing).
  List<FileSystemEntityInfo> sortFiles(List<FileSystemEntityInfo> files) {
    final out = List<FileSystemEntityInfo>.from(files);
    final sign = _fileSortAscending ? 1 : -1;
    out.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      final cmp = switch (_fileSortKey) {
        FileSortKey.name =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        FileSortKey.modified => a.modified.compareTo(b.modified),
        FileSortKey.size => a.size.compareTo(b.size),
        FileSortKey.extension =>
          _extensionOf(a.name).compareTo(_extensionOf(b.name)),
      };
      // Same key value (two files modified in the same second, two `.log`s):
      // fall back to the name so the order can't shuffle between rebuilds.
      if (cmp != 0) return cmp * sign;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  static String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    // A leading dot is a hidden file, not an extension (`.bashrc`).
    if (dot <= 0) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  // ---- Explorer bookmarks ---------------------------------------------------
  // Pinned directories. Reaching /var/www/app on a phone is eight taps through
  // the tree every single time; this makes it one.

  static const String _kExplorerBookmarks = 'explorer_bookmarks';

  List<String> _explorerBookmarks = [];
  List<String> get explorerBookmarks => List.unmodifiable(_explorerBookmarks);

  void _loadExplorerBookmarks(SharedPreferences prefs) {
    _explorerBookmarks = prefs.getStringList(_kExplorerBookmarks) ?? [];
  }

  bool isBookmarked(String path) => _explorerBookmarks.contains(path);

  /// Pins or unpins [path]. Returns true if it is bookmarked afterwards, so the
  /// caller can word its confirmation without re-reading the list.
  Future<bool> toggleBookmark(String path) async {
    final added = !_explorerBookmarks.remove(path);
    if (added) _explorerBookmarks.add(path);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kExplorerBookmarks, _explorerBookmarks);
    return added;
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

  Future<FileOpResult> deleteSelection() async {
    final session = activeSession;
    final entries = _selectedEntries;
    if (session == null || entries.isEmpty) return FileOpResult.ok('');
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
      return FileOpResult.ok(entries.length == 1
          ? tr('Se eliminó "{0}"', [entries.first.name])
          : tr('Se eliminaron {0} elementos', ['${entries.length}']));
    } catch (e) {
      session.sftpClient = null;
      return FileOpResult.failed(tr('No se pudo eliminar'), e);
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

  /// Create an empty subdirectory named [name] inside the active session's
  /// current directory.
  Future<FileOpResult> createFolder(String name) async {
    final session = activeSession;
    if (session == null || name.isEmpty) return FileOpResult.ok('');
    session.isLoadingFiles = true;
    notifyListeners();
    try {
      final path = '${session.currentPath}/$name'.replaceAll('//', '/');
      if (session.connectionStatus == ConnectionStatus.remote) {
        final sftp = await _getSftpClient(session);
        await sftp.mkdir(path);
      } else {
        await Directory(path).create();
      }
      return FileOpResult.ok(tr('Se creó la carpeta "{0}"', [name]));
    } catch (e) {
      session.sftpClient = null;
      return FileOpResult.failed(tr('No se pudo crear la carpeta'), e);
    } finally {
      await _loadFiles();
    }
  }

  /// Create an empty file named [name] inside the active session's current
  /// directory.
  Future<FileOpResult> createFile(String name) async {
    final session = activeSession;
    if (session == null || name.isEmpty) return FileOpResult.ok('');
    session.isLoadingFiles = true;
    notifyListeners();
    try {
      final path = '${session.currentPath}/$name'.replaceAll('//', '/');
      if (session.connectionStatus == ConnectionStatus.remote) {
        final sftp = await _getSftpClient(session);
        final fileHandle = await sftp.open(
          path,
          mode: SftpFileOpenMode.write |
              SftpFileOpenMode.create |
              SftpFileOpenMode.truncate,
        );
        await fileHandle.close();
      } else {
        await File(path).create();
      }
      return FileOpResult.ok(tr('Se creó "{0}"', [name]));
    } catch (e) {
      session.sftpClient = null;
      return FileOpResult.failed(tr('No se pudo crear el archivo'), e);
    } finally {
      await _loadFiles();
    }
  }

  /// Rename [entry] to [newName], keeping it in the same directory.
  Future<FileOpResult> renameEntry(
      FileSystemEntityInfo entry, String newName) async {
    final session = activeSession;
    if (session == null || newName.isEmpty || newName == entry.name) {
      return FileOpResult.ok('');
    }
    final parent = entry.path.substring(
        0, entry.path.length - entry.name.length);
    final newPath = '$parent$newName';
    session.isLoadingFiles = true;
    notifyListeners();
    try {
      if (session.connectionStatus == ConnectionStatus.remote) {
        final sftp = await _getSftpClient(session);
        await sftp.rename(entry.path, newPath);
      } else if (entry.isDirectory) {
        await Directory(entry.path).rename(newPath);
      } else {
        await File(entry.path).rename(newPath);
      }
      return FileOpResult.ok(tr('Se renombró a "{0}"', [newName]));
    } catch (e) {
      session.sftpClient = null;
      return FileOpResult.failed(tr('No se pudo renombrar'), e);
    } finally {
      await _loadFiles();
    }
  }

  /// Paste the clipboard into the active session's current directory. Handles
  /// every source/destination combination (local↔local, remote↔remote, and
  /// local↔remote up/downloads). Move uses a rename fast path when source and
  /// destination share a filesystem, falling back to copy + delete.
  Future<FileOpResult> pasteClipboard() async {
    final session = activeSession;
    final entries = _clipboard;
    if (session == null || entries.isEmpty) return FileOpResult.ok('');
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
    // Skipped items are not failures — pasting a folder into itself is a
    // no-op, not an error — but staying silent about them would look like the
    // paste simply did nothing.
    final skipped = <String>[];
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
          skipped.add(entry.name);
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
      if (skipped.isNotEmpty) {
        return FileOpResult.ok(tr('No se puede pegar "{0}" dentro de sí misma',
            [skipped.first]));
      }
      return FileOpResult.ok(entries.length == 1
          ? (isMove
              ? tr('Se movió "{0}"', [entries.first.name])
              : tr('Se copió "{0}"', [entries.first.name]))
          : (isMove
              ? tr('Se movieron {0} elementos', ['${entries.length}'])
              : tr('Se copiaron {0} elementos', ['${entries.length}'])));
    } catch (e) {
      session.sftpClient = null;
      if (srcSession != null) srcSession.sftpClient = null;
      return FileOpResult.failed(
          isMove ? tr('No se pudo mover') : tr('No se pudo copiar'), e);
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
    _beginAttach(fileName);
    notifyListeners();

    try {
      if (session.connectionStatus == ConnectionStatus.remote) {
        final sftp = await _getSftpClient(session);
        final remoteFilePath = '${session.currentPath}/$fileName'.replaceAll('//', '/');
        final fileStream = await sftp.open(
          remoteFilePath,
          mode: SftpFileOpenMode.write | SftpFileOpenMode.create | SftpFileOpenMode.truncate,
        ).timeout(const Duration(seconds: 10));
        await fileStream.write(_attachChunks(imageBytes)).timeout(const Duration(seconds: 30));
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
      _endAttach();
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
      _finishDownloadWithError(tr('La sesión SSH no está conectada.'));
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
      // public Downloads/KAMMEL on Android, ~/Downloads/KAMMEL elsewhere.
      final String finalDir;
      if (destDir != null && destDir.isNotEmpty) {
        finalDir = destDir;
      } else if (Platform.isAndroid) {
        finalDir = '/storage/emulated/0/Download/KAMMEL';
      } else {
        final base = await getApplicationDocumentsDirectory();
        finalDir = '${base.path}/Downloads/KAMMEL';
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
            tr('No se puede escribir en {0}. Concede el permiso de almacenamiento o elige otra carpeta.', [finalDir]));
      }

      // A cached SFTP client can belong to a connection that has since dropped;
      // ask for a fresh one so a stale handle can't hang the download.
      if (isRemote) await _getSftpClient(session, fresh: true);

      // ---- Phase 1: plan ----------------------------------------------------
      final plan = <_DownloadItem>[];
      for (final entry in entries) {
        if (_downloadCancelled) break;
        _downloadCurrentName = entry.name;
        notifyListeners();
        final dest = _childPath(finalDir, entry.name, Platform.pathSeparator);
        if (isRemote) {
          await _planRemote(session, entry.path, dest, plan);
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
        void onBytes(int n) {
          _downloadBytesDone = settledBytes + n;
          _notifyDownloadProgress();
        }

        try {
          final sftp = isRemote ? await _getSftpClient(session) : null;
          await _downloadFile(sftp, item, onBytes: onBytes);
          _downloadFilesDone++;
        } catch (e) {
          // A dropped connection mid-batch would otherwise fail every
          // remaining file the same way; get a fresh SFTP channel and retry
          // this one file once before giving up on it.
          if (isRemote && !_downloadCancelled) {
            try {
              final fresh = await _getSftpClient(session, fresh: true);
              await _downloadFile(fresh, item, onBytes: onBytes);
              _downloadFilesDone++;
            } catch (e2) {
              _recordDownloadFailure(item.srcPath, e2);
            }
          } else {
            _recordDownloadFailure(item.srcPath, e);
          }
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

  // Run an SFTP operation against the session's cached client; if it throws
  // (a common symptom of a network blip on mobile — wifi/cellular handover,
  // the screen locking, a brief server hiccup), grab a fresh SFTP channel and
  // retry exactly once instead of letting one hiccup fail every remaining
  // file in the batch.
  Future<T> _sftpOpRetry<T>(
      TerminalSession session, Future<T> Function(SftpClient sftp) op) async {
    final sftp = await _getSftpClient(session);
    try {
      return await op(sftp);
    } catch (e) {
      if (_downloadCancelled) rethrow;
      final fresh = await _getSftpClient(session, fresh: true);
      return await op(fresh);
    }
  }

  // Walk a remote entry, appending the directories to create and the files to
  // fetch. `stat` (which follows symlinks) decides the type: the `listdir`
  // attributes report a symlinked directory as a plain link, and treating that
  // as a file used to blow up the whole download.
  Future<void> _planRemote(TerminalSession session, String srcPath,
      String destPath, List<_DownloadItem> out,
      {int depth = 0}) async {
    if (_downloadCancelled || depth > 32) return;
    final name = srcPath.split('/').last;

    SftpFileAttrs attrs;
    try {
      attrs = await _sftpOpRetry(
          session, (c) => c.stat(srcPath).timeout(_sftpOpTimeout));
    } catch (e) {
      _recordDownloadFailure(srcPath, e);
      return;
    }

    if (attrs.isDirectory) {
      out.add(_DownloadItem(
          srcPath: srcPath, destPath: destPath, name: name, isDirectory: true));
      final List<SftpName> items;
      try {
        items = await _sftpOpRetry(
            session, (c) => c.listdir(srcPath).timeout(_sftpOpTimeout));
      } catch (e) {
        _recordDownloadFailure(srcPath, e);
        return;
      }
      for (final item in items) {
        if (item.filename == '.' || item.filename == '..') continue;
        await _planRemote(
          session,
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
    _setTab(1);
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
      debugPrint(tr('Error al cargar archivos: {0}', [e]));
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

      _setTab(3); // Navigate to Editor Tab
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
    _setTab(2); // Go back to files tab
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

  /// A git client bound to the active session's working directory, or null
  /// when there is nothing to run commands through (no session, or a remote
  /// one whose connection dropped).
  ///
  /// A fresh instance per call is deliberate: it captures the session's SSH
  /// client at that moment, so a panel that outlives a reconnect asks for a
  /// new one instead of holding a dead channel.
  GitService? createGitService() {
    final session = activeSession;
    if (session == null) return null;
    final dir = _workingDirFor(session);
    if (dir.isEmpty) return null;
    if (session.connectionStatus == ConnectionStatus.remote) {
      final client = session.sshClient;
      if (client == null) return null;
      return GitService.remote(client: client, workdir: dir);
    }
    return GitService.local(workdir: dir);
  }

  /// Sends the explorer to a changed file's folder and opens it, which routes
  /// PDFs/Markdown/images to their viewer and everything else to the editor.
  /// A deleted path has nothing to open, so it only navigates.
  Future<void> navigateToGitFile(String absolutePath,
      {bool deleted = false}) async {
    final lastSlash = absolutePath.lastIndexOf('/');
    final parentDir = lastSlash > 0 ? absolutePath.substring(0, lastSlash) : '/';

    await changeDirectory(parentDir);

    if (deleted) {
      setActiveTabIndex(2);
      return;
    }
    final fileName =
        lastSlash >= 0 ? absolutePath.substring(lastSlash + 1) : absolutePath;
    await openFile(FileSystemEntityInfo(
      name: fileName,
      path: absolutePath,
      isDirectory: false,
      size: 0,
      modified: DateTime.now(),
    ));
  }

  /// Repository root of the active session's working directory, falling back
  /// to that directory itself when it isn't inside a repository.
  Future<String> getGitRoot() async {
    final session = activeSession;
    if (session == null) return '';
    final fallback = _workingDirFor(session);
    return (await createGitService()?.repoRoot()) ?? fallback;
  }

  /// Re-lists the active session's directory, e.g. after a commit or a
  /// discard changed what is on disk.
  Future<void> refreshFiles() => _loadFiles();

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
    if (session == null) return tr('No hay una sesión activa.');
    if (session.connectionStatus != ConnectionStatus.remote) {
      return tr('No hay una conexión activa.');
    }
    if (!session.terminal.isUsingAltBuffer) {
      return tr('No hay un agente de IA abierto en la terminal. Ábrelo (p. ej. claude) y vuelve a intentarlo.');
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _server?.dispose();
    for (final session in _sessions) {
      _cleanupSession(session);
    }
    tunnels.dispose();
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

  /// Shortest gap between two writes to the terminal. One frame: bursts still
  /// coalesce, but a lone keystroke echo is never held back.
  static const _minFlushGap = Duration(milliseconds: 16);

  var _lastFlush = DateTime.fromMillisecondsSinceEpoch(0);

  void add(List<int> data) {
    if (_disposed) return;
    _decoder.add(data);

    if (!isInForeground()) {
      _flush();
      return;
    }
    if (_flushTimer != null) return;
    // A flat debounce made every echoed keystroke wait out the full window,
    // which is what made typing feel mushy. Flush straight away when the last
    // write is already a frame old, and only coalesce inside that window.
    final since = DateTime.now().difference(_lastFlush);
    if (since >= _minFlushGap) {
      _flush();
    } else {
      _flushTimer = Timer(_minFlushGap - since, _flush);
    }
  }

  void _flush() {
    _flushTimer = null;
    _lastFlush = DateTime.now();
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
