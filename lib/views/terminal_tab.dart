import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/xterm.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';
import '../widgets/terminal_selection.dart';
import 'prompts_sheet.dart';
import 'git_folder_explorer_sheet.dart';
import 'shortcut_manager_sheet.dart';
import '../models/terminal_shortcut.dart';

class TerminalTab extends StatefulWidget {
  const TerminalTab({super.key});

  @override
  State<TerminalTab> createState() => _TerminalTabState();
}

class _TerminalTabState extends State<TerminalTab> with WidgetsBindingObserver {
  final FocusNode _terminalFocusNode = FocusNode();
  double? _dragStartX;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (_terminalFocusNode.hasFocus) {
      // Run a series of delayed scrolls to keep the scroll position at the bottom
      // during the keyboard slide animation without doing it on every single frame.
      for (final ms in [50, 150, 250, 350]) {
        Future.delayed(Duration(milliseconds: ms), () {
          if (mounted && _terminalScrollController.hasClients) {
            _terminalScrollController.jumpTo(_terminalScrollController.position.maxScrollExtent);
          }
        });
      }
    }
  }

  // Holds the current text selection of the active terminal so the "Copiar"
  // toolbar button can read it. Shared across sessions; the selection is
  // cleared whenever the active terminal changes (see [_syncTerminalObserver]).
  final TerminalController _terminalController = TerminalController();

  // Give the selection overlay access to the terminal's render object (for
  // cell↔pixel mapping) and its scroll position (for auto-scroll on drag).
  final GlobalKey<TerminalViewState> _terminalViewKey =
      GlobalKey<TerminalViewState>();
  final ScrollController _terminalScrollController = ScrollController();

  bool _showKeys = true;

  // Tracks whether the active terminal is in the alternate screen buffer (a
  // full-screen TUI like vim/htop/claude is running). The smart command bar is
  // a line-based input that makes no sense — and looks like a duplicate input
  // box — over such apps, so it is hidden while [_altScreen] is true and the
  // raw terminal takes all keystrokes. We observe the Terminal directly because
  // its alt-buffer changes don't flow through AppState's notifications.
  Terminal? _observedTerminal;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _observedTerminal?.removeListener(_onTerminalChanged);
    _terminalFocusNode.dispose();
    _terminalController.dispose();
    _terminalScrollController.dispose();
    super.dispose();
  }

  void _sendTerminalKey(AppState state, String keyString) {
    _terminalViewKey.currentState?.resetInputConnection();
    state.sendTerminalInput(keyString);
  }

  /// Re-point the alt-buffer listener at [terminal] (called on every build so it
  /// follows session switches). Cheap no-op when the instance is unchanged.
  void _syncTerminalObserver(Terminal terminal) {
    if (identical(_observedTerminal, terminal)) return;
    _observedTerminal?.removeListener(_onTerminalChanged);
    _observedTerminal = terminal;
    terminal.addListener(_onTerminalChanged);
    // Selection anchors belong to the previous terminal's buffer; drop them so
    // "Copiar" never reads a stale selection after a session switch.
    _terminalController.clearSelection();
  }

  void _onTerminalChanged() {
    final alt = _observedTerminal?.isUsingAltBuffer ?? false;
    // Entering a full-screen app: hand keyboard focus to the terminal so it
    // receives keys without the user having to tap it first.
    if (alt) _terminalFocusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    final fullscreen = state.terminalFullscreen;
    _syncTerminalObserver(state.terminal);

    if (!state.isTerminalInitialized) {
      return Container(
        color: AppColors.ink,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.dns_outlined, size: 40, color: AppColors.muted),
              const SizedBox(height: 16),
              Text('SIN SESIÓN ACTIVA',
                  style:
                      AppText.mono(9, color: AppColors.muted, spacing: 1.5)),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  'Conéctate a un servidor SSH desde la pestaña Conexiones para abrir una terminal.',
                  textAlign: TextAlign.center,
                  style: AppText.body(13, color: AppColors.muted),
                ),
              ),
              const SizedBox(height: 20),
              InvertedButton(
                label: 'Ir a Conexiones',
                icon: Icons.dns_outlined,
                dense: true,
                onPressed: () => state.setActiveTabIndex(0),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      color: AppColors.ink,
      child: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {

            return Stack(
              children: [
                Column(
                  children: [
                if (!fullscreen) _buildToolbar(context, state),
                // Dropped connection with a known profile → offer to
                // re-establish it in place (with tmux this re-attaches to
                // whatever kept running on the server). Shown in fullscreen
                // too: it's exactly when an agent was left working.
                if (state.activeSession?.connectionStatus ==
                        ConnectionStatus.disconnected &&
                    state.activeSession?.activeProfile != null)
                  _reconnectBanner(state),
                Expanded(
                  child: GestureDetector(
                    onHorizontalDragStart: (details) {
                      if (_terminalController.selection == null) {
                        _dragStartX = details.globalPosition.dx;
                      } else {
                        _dragStartX = null;
                      }
                    },
                    onHorizontalDragUpdate: (details) {
                      if (_dragStartX == null) return;
                      final dx = details.globalPosition.dx - _dragStartX!;
                      // Threshold for cursor movement (12.0 pixels per character/move)
                      const threshold = 12.0;
                      if (dx.abs() >= threshold) {
                        if (dx > 0) {
                          _sendTerminalKey(state, '\x1b[C'); // Right Arrow
                        } else {
                          _sendTerminalKey(state, '\x1b[D'); // Left Arrow
                        }
                        _dragStartX = details.globalPosition.dx;
                      }
                    },
                    onHorizontalDragEnd: (_) {
                      _dragStartX = null;
                    },
                    child: _PinchFontZoom(
                      state: state,
                      child: TerminalSelectionArea(
                        terminal: state.terminal,
                        controller: _terminalController,
                        terminalViewKey: _terminalViewKey,
                        scrollController: _terminalScrollController,
                        onSendInput: (text) {
                          state.insertPromptText(text);
                          _terminalFocusNode.requestFocus();
                        },
                        onToast: _toast,
                        child: TerminalView(
                          state.terminal,
                          key: _terminalViewKey,
                          controller: _terminalController,
                          scrollController: _terminalScrollController,
                          focusNode: _terminalFocusNode,
                          autofocus: true,
                          deleteDetection: true,
                          theme: AppTerminalTheme.byId(state.terminalScheme,
                              Theme.of(context).brightness,
                              accentColor: AppColors.accent),
                          cursorType: TerminalCursorType.block,
                          backgroundOpacity: 1,
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                          textStyle: TerminalStyle(
                            fontSize: state.terminalFontSize,
                            height: 1.3,
                            fontFamily: state.monoFontFamily,
                            fontFamilyFallback: const ['monospace'],
                          ),
                          // Gboard inline image paste: the soft keyboard hands
                          // us the image bytes directly (no need to hit "PEGAR").
                          // Enabled by the vendored, patched xterm in
                          // third_party/xterm (see pubspec dependency_overrides).
                          onInsertContent: (content) async {
                            if (content.data != null) {
                              final mime = content.mimeType.toLowerCase();
                              final ext = mime.contains('gif')
                                  ? 'gif'
                                  : mime.contains('webp')
                                      ? 'webp'
                                      : mime.contains('jpg') ||
                                              mime.contains('jpeg')
                                          ? 'jpg'
                                          : 'png';
                              await state.pasteImageBytes(content.data!,
                                  ext: ext);
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                ),
                // Quick-access keys stay available even in fullscreen.
                if (_showKeys) _buildKeys(state),
              ],
            ),
            if (fullscreen)
              Positioned(
                right: 14,
                bottom: 14,
                child: _FloatingControl(
                  icon: Icons.close_fullscreen,
                  onTap: () => state.setTerminalFullscreen(false),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

  // ---- Reconnect banner ------------------------------------------------------

  /// Thin strip shown while the active session's SSH connection is down: one
  /// tap re-establishes it (see [AppState.reconnectSession]).
  Widget _reconnectBanner(AppState state) {
    final session = state.activeSession!;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.panel,
        border:
            Border(bottom: BorderSide(color: AppColors.hairline, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.link_off, size: 14, color: AppColors.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Text('CONEXIÓN PERDIDA',
                style: AppText.label(9, color: AppColors.muted, spacing: 1.2)),
          ),
          session.reconnecting
              ? SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.5, color: AppColors.muted),
                )
              : GhostButton(
                  label: 'Reconectar',
                  icon: Icons.refresh,
                  dense: true,
                  onPressed: () => state.reconnectSession(session),
                ),
        ],
      ),
    );
  }

  // ---- Toolbar (sessions + actions) ----------------------------------------

  Widget _buildToolbar(BuildContext context, AppState state) {
    return Container(
      height: 46,
      decoration: BoxDecoration(
        color: AppColors.ink,
        border:
            Border(bottom: BorderSide(color: AppColors.hairline, width: 1)),
      ),
      child: Row(
        children: [
          Expanded(child: _sessionSelector(context, state)),
          Container(width: 1, height: 46, color: AppColors.hairline),
          _toolbarIcon(Icons.text_decrease, 'Reducir letra',
              () => state.bumpTerminalFontSize(-1)),
          _toolbarIcon(Icons.text_increase, 'Aumentar letra',
              () => state.bumpTerminalFontSize(1)),
          _toolbarIcon(
            _showKeys ? Icons.keyboard_hide_outlined : Icons.keyboard_outlined,
            'Teclas rápidas',
            () => setState(() => _showKeys = !_showKeys),
          ),
          _toolbarIcon(Icons.open_in_full, 'Expandir terminal',
              () => state.setTerminalFullscreen(true)),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  /// Opens the saved-prompt library / composer; after inserting, focus goes
  /// back to the terminal so the user can review and submit.
  void _showPrompts(AppState state) {
    showPromptsSheet(context,
        onInserted: () => _terminalFocusNode.requestFocus());
  }

  /// Opens the Git changes / project panel as a full-height drawer that slides
  /// in from the left edge.
  void _showGitSlider(AppState state) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Cerrar',
      barrierColor: Colors.black.withValues(alpha: 0.5),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (dialogCtx, _, _) {
        return Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: MediaQuery.of(dialogCtx).size.width * 0.86,
            height: double.infinity,
            // Own ScaffoldMessenger so the panel's SnackBars render in front of
            // the slide instead of behind it on the root Scaffold.
            child: ScaffoldMessenger(
              child: Scaffold(
                backgroundColor: AppColors.panel,
                body: GitFolderExplorerSheet(
                  state: state,
                  // Shown after the panel closes, so it must go to the root
                  // messenger (over the terminal), not the panel's.
                  onToast: _toast,
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (_, anim, _, child) {
        final curved =
            CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(-1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    );
  }

  /// Lets the user pick a file/image; it's uploaded to the server over SFTP and
  /// its remote path inserted into the prompt for a TUI agent (Claude Code) to
  /// read. Surfaces the backend's outcome; an empty message means the user
  /// cancelled the picker.
  Future<void> _attach(AppState state) async {
    final result = await state.attachFile();
    if (!mounted) return;
    if (result.message.isNotEmpty) _toast(result.message);
    if (result.ok) _terminalFocusNode.requestFocus();
  }

  // ---- URL detection --------------------------------------------------------

  static final RegExp _urlRegex = RegExp(r'''https?://[^\s"'<>]+''');

  /// Scans the terminal's scrollback for URLs and offers them in a bottom
  /// sheet, most recent first. Tapping one opens it in the browser.
  void _showLinksSheet(AppState state) {
    final text = state.terminal.buffer.getText();
    final seen = <String>{};
    final urls = <String>[];
    for (final m in _urlRegex.allMatches(text)) {
      // Trailing punctuation is almost always prose around the link, not part
      // of it ("visita https://x.com." / "(ver https://y.com)").
      final url = m.group(0)!.replaceFirst(RegExp(r'''[.,;:)\]}'"]+$'''), '');
      if (seen.add(url)) urls.add(url);
    }
    if (urls.isEmpty) {
      _toast('No hay enlaces en el terminal');
      return;
    }
    final recentFirst = urls.reversed.take(20).toList();

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.panel,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('ENLACES',
                  style:
                      AppText.label(11, color: AppColors.bone, spacing: 1.4)),
            ),
            Hairline(),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: recentFirst.length,
                separatorBuilder: (_, _) => Hairline(),
                itemBuilder: (_, i) => InkWell(
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    launchUrl(Uri.parse(recentFirst[i]),
                        mode: LaunchMode.externalApplication);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 13),
                    child: Row(
                      children: [
                        Icon(Icons.open_in_new,
                            size: 14, color: AppColors.muted),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(recentFirst[i],
                              style: AppText.mono(11, color: AppColors.bone),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message,
            style: AppText.mono(11, color: AppColors.bone, spacing: 0.3)),
        backgroundColor: AppColors.panelHi,
        duration: const Duration(milliseconds: 1400),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _toolbarIcon(IconData icon, String tip, VoidCallback onTap) {
    final sz = (16 * context.read<AppState>().uiIconFactor).roundToDouble();
    return IconButton(
      icon: Icon(icon, color: AppColors.muted, size: sz),
      onPressed: onTap,
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 38, minHeight: 46),
    );
  }

  /// Status glyph for a session, shown where the connection dot used to be: a
  /// spinner during the SSH handshake, a server icon for a live SSH session,
  /// falling back to a dot.
  Widget _statusGlyph(TerminalSession s, AppState state,
      {required double size, required Color color}) {
    switch (s.connectionStatus) {
      case ConnectionStatus.connecting:
        return SizedBox(
          width: size,
          height: size,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
        );
      case ConnectionStatus.remote:
        return Icon(Icons.dns, size: size, color: color);
      case ConnectionStatus.disconnected:
        return Icon(Icons.circle_outlined, size: size, color: color);
    }
  }

  String _sessionMeta(TerminalSession s, AppState state) {
    switch (s.connectionStatus) {
      case ConnectionStatus.remote:
        return 'SSH · ${s.activeProfile?.name ?? ''}';
      case ConnectionStatus.connecting:
        return 'CONECTANDO…';
      case ConnectionStatus.disconnected:
        return 'DESCONECTADO';
    }
  }

  /// Compact button in the toolbar: shows the active session and opens the
  /// slide-up sessions panel.
  Widget _sessionSelector(BuildContext context, AppState state) {
    final active = state.activeSession;
    return InkWell(
      onTap: () => _showSessionsSheet(context, state),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            active != null
                ? _statusGlyph(active, state,
                    size: 18 * state.uiIconFactor, color: AppColors.bone)
                : Icon(Icons.circle_outlined,
                    size: 18 * state.uiIconFactor, color: AppColors.bone),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                active?.name ?? 'Sesión',
                style: AppText.mono(13,
                    color: AppColors.bone, weight: FontWeight.w700),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 7),
            // A non-active session rang the bell (agent waiting) → draw the
            // eye to the session switcher.
            if (state.sessions.any((s) => s.hasPendingAlert)) ...[
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                    color: AppColors.bone, shape: BoxShape.circle),
              ),
              const SizedBox(width: 7),
            ],
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                  border: Border.all(color: AppColors.hairline, width: 1)),
              child: Text('${state.sessions.length}',
                  style: AppText.mono(10, color: AppColors.muted)),
            ),
            Icon(Icons.expand_more, size: 18, color: AppColors.muted),
          ],
        ),
      ),
    );
  }

  void _showSessionsSheet(BuildContext context, AppState state) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.panel,
      isScrollControlled: true,
      builder: (sheetCtx) => Consumer<AppState>(
        builder: (ctx, s, _) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Text('SESIONES',
                        style: AppText.label(11,
                            color: AppColors.bone, spacing: 1.4)),
                    const Spacer(),
                    Text('${s.sessions.length}',
                        style: AppText.mono(10, color: AppColors.muted)),
                  ],
                ),
              ),
              Hairline(),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: s.sessions.length,
                  separatorBuilder: (_, _) => Hairline(),
                  itemBuilder: (ctx, i) => _sessionSheetRow(sheetCtx, s, i),
                ),
              ),
              Hairline(),
              _menuTile(sheetCtx, Icons.dns_outlined, 'CONECTAR POR SSH…',
                  () => s.setActiveTabIndex(0)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sessionSheetRow(BuildContext sheetCtx, AppState state, int index) {
    final session = state.sessions[index];
    final isActive = index == state.activeSessionIndex;
    final fg = isActive ? AppColors.ink : AppColors.bone;
    final metaFg = isActive ? AppColors.ink : AppColors.muted;

    return Material(
      color: isActive ? AppColors.bone : Colors.transparent,
      child: InkWell(
        onTap: () {
          state.switchSession(index);
          Navigator.of(sheetCtx).pop();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              _statusGlyph(session, state, size: 20, color: fg),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(session.name,
                              style: AppText.mono(12,
                                  color: fg, weight: FontWeight.w700),
                              overflow: TextOverflow.ellipsis),
                        ),
                        // Pending agent alert: this session asked for
                        // attention while another one was visible.
                        if (session.hasPendingAlert) ...[
                          const SizedBox(width: 8),
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                                color: fg, shape: BoxShape.circle),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(_sessionMeta(session, state),
                        style: AppText.mono(8, color: metaFg, spacing: 1)),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () =>
                    _showRenameDialog(sheetCtx, state, index, session.name),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(Icons.edit_outlined,
                      size: 15,
                      color: isActive ? AppColors.ink : AppColors.muted),
                ),
              ),
              const SizedBox(width: 2),
              GestureDetector(
                onTap: () => state.closeSession(index),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(Icons.close,
                      size: 15,
                      color: isActive ? AppColors.ink : AppColors.muted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Dialogs / menus -----------------------------------------------------

  void _showRenameDialog(
      BuildContext context, AppState state, int index, String currentName) {
    final controller = TextEditingController(text: currentName);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text('RENOMBRAR SESIÓN',
            style: AppText.label(11, color: AppColors.bone, spacing: 1.4)),
        content: TextField(
          controller: controller,
          autofocus: true,
          enableIMEPersonalizedLearning: true,
          decoration: const InputDecoration(labelText: 'NOMBRE DE LA SESIÓN'),
          style: AppText.body(13),
        ),
        actions: [
          GhostButton(
            label: 'Cancelar',
            dense: true,
            onPressed: () => Navigator.of(context).pop(),
          ),
          InvertedButton(
            label: 'Guardar',
            dense: true,
            onPressed: () {
              state.renameSession(index, controller.text);
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }

  Widget _menuTile(
      BuildContext sheetCtx, IconData icon, String label, VoidCallback action) {
    return InkWell(
      onTap: () {
        Navigator.of(sheetCtx).pop();
        action();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: [
            Icon(icon, size: 16, color: AppColors.bone),
            const SizedBox(width: 12),
            Text(label,
                style: AppText.label(10, color: AppColors.bone, spacing: 1.0)),
          ],
        ),
      ),
    );
  }

  // ---- Smart keyboard (extra keys, Termux-style) ---------------------------

  Widget _buildDpad(AppState state) {
    final h = state.shortcutKeyHeight;
    final totalH = h * 2 + 5;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _key('←', () => _sendTerminalKey(state, '\x1b[D'), width: 34, height: totalH),
        const SizedBox(width: 4),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _key('↑', () => _sendTerminalKey(state, '\x1b[A'), width: 34, height: h),
            const SizedBox(height: 5),
            _key('↓', () => _sendTerminalKey(state, '\x1b[B'), width: 34, height: h),
          ],
        ),
        const SizedBox(width: 4),
        _key('→', () => _sendTerminalKey(state, '\x1b[C'), width: 34, height: totalH),
      ],
    );
  }

  Widget _buildScrollableRow1(AppState state) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _key('CTRL', state.toggleCtrl, armed: state.ctrlArmed, width: 44),
          _key('SHIFT', state.toggleShift, armed: state.shiftArmed, width: 48),
          _key('ESC', () => _sendTerminalKey(state, '\x1b'), width: 36),
          _key('TAB', () => _sendTerminalKey(state, '\t'), width: 36),
          _key('ALT', () => _sendTerminalKey(state, '\x1b'), width: 36),
          _key('^C', () => _sendTerminalKey(state, '\x03'), inverted: true, width: 32),
          _key('^D', () => _sendTerminalKey(state, '\x04'), width: 32),
          _key('HOME', () => _sendTerminalKey(state, '\x1b[H')),
          _key('END', () => _sendTerminalKey(state, '\x1b[F')),
          _key('PGUP', () => _sendTerminalKey(state, '\x1b[5~')),
          _key('PGDN', () => _sendTerminalKey(state, '\x1b[6~')),
          _key('INS', () => _sendTerminalKey(state, '\x1b[2~')),
          _key('DEL', () => _sendTerminalKey(state, '\x1b[3~')),
        ],
      ),
    );
  }

  Widget _buildScrollableRow2(AppState state) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: _buildPagedKeys(state),
      ),
    );
  }

  Widget _buildKeys(AppState state) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.ink,
        border: Border(top: BorderSide(color: AppColors.hairline, width: 1)),
      ),
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            if (state.shortcutLayout == TerminalShortcutLayout.dpadLeft) ...[
              Row(
                children: [
                  _buildDpad(state),
                  const SizedBox(width: 6),
                  Container(width: 1, height: 61, color: AppColors.hairline),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildScrollableRow1(state),
                        const SizedBox(height: 5),
                        _buildScrollableRow2(state),
                      ],
                    ),
                  ),
                ],
              )
            ] else if (state.shortcutLayout == TerminalShortcutLayout.dpadRight) ...[
              Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildScrollableRow1(state),
                        const SizedBox(height: 5),
                        _buildScrollableRow2(state),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(width: 1, height: 61, color: AppColors.hairline),
                  const SizedBox(width: 6),
                  _buildDpad(state),
                ],
              )
            ] else ...[
              // Classic double row layout.
              // Row 1 — modifiers + signals (Expanded to fit screen width evenly)
              Row(
                children: [
                  _key('CTRL', state.toggleCtrl, armed: state.ctrlArmed),
                  _key('SHIFT', state.toggleShift, armed: state.shiftArmed),
                  _key('ESC', () => _sendTerminalKey(state, '\x1b')),
                  _key('TAB', () => _sendTerminalKey(state, '\t')),
                  _key('ALT', () => _sendTerminalKey(state, '\x1b')),
                  _key('^C', () => _sendTerminalKey(state, '\x03'), inverted: true),
                ],
              ),
              const SizedBox(height: 5),
              // Row 2 — Horizontally scrollable row of custom shortcuts.
              _buildScrollableRow2(state),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _buildPagedKeys(AppState state) {
    final enabledKeys = state.customShortcuts.where((s) => s.enabled).toList();
    if (enabledKeys.isEmpty) {
      return [
        _key('', () => ShortcutManagerSheet.show(context, state), icon: Icons.settings, width: 34),
      ];
    }

    const int pageSize = 5;
    if (enabledKeys.length <= pageSize) {
      return enabledKeys.map((s) => _buildShortcutKey(state, s)).toList();
    }

    final List<List<TerminalShortcut>> pages = [];
    int index = 0;
    while (index < enabledKeys.length) {
      if (pages.isEmpty) {
        final takeCount = pageSize - 1;
        pages.add(enabledKeys.sublist(index, index + takeCount));
        index += takeCount;
      } else {
        final remaining = enabledKeys.length - index;
        if (remaining <= pageSize - 1) {
          pages.add(enabledKeys.sublist(index));
          index = enabledKeys.length;
        } else {
          pages.add(enabledKeys.sublist(index, index + (pageSize - 2)));
          index += (pageSize - 2);
        }
      }
    }

    int pageIndex = state.shortcutPageIndex;
    if (pageIndex >= pages.length) {
      pageIndex = pages.length - 1;
      if (pageIndex < 0) pageIndex = 0;
    }

    final List<Widget> rowKeys = [];
    final currentPageKeys = pages[pageIndex];

    if (pageIndex > 0) {
      rowKeys.add(_key('', () => state.setShortcutPageIndex(pageIndex - 1), icon: Icons.arrow_back, width: 34));
    }

    for (final s in currentPageKeys) {
      rowKeys.add(_buildShortcutKey(state, s));
    }

    if (pageIndex < pages.length - 1) {
      rowKeys.add(_key('', () => state.setShortcutPageIndex(pageIndex + 1), icon: Icons.arrow_forward, width: 34));
    }

    return rowKeys;
  }

  Widget _buildShortcutKey(AppState state, TerminalShortcut shortcut) {
    if (shortcut.value.startsWith('system:')) {
      final action = shortcut.value.substring(7);
      switch (action) {
        case 'attach':
          return _key('ADJUNTAR', () => _attach(state), icon: Icons.attach_file, width: 76);
        case 'prompts':
          return _key('PROMPTS', () => _showPrompts(state), icon: Icons.bolt_outlined, width: 76);
        case 'commit':
          return _key('COMMIT', () => _showGitSlider(state), icon: Icons.commit_outlined, width: 76);
        case 'links':
          return _key('ENLACES', () => _showLinksSheet(state), icon: Icons.link, width: 76);
        case 'settings':
          return _key('', () => ShortcutManagerSheet.show(context, state), icon: Icons.settings, width: 34);
        default:
          return const SizedBox.shrink();
      }
    } else {
      return _key(
        shortcut.label,
        () => _sendTerminalKey(state, shortcut.parsedValue),
      );
    }
  }

  Widget _key(
    String label,
    VoidCallback onPressed, {
    bool inverted = false,
    bool armed = false,
    IconData? icon,
    double? width,
    double? height,
  }) {
    final state = Provider.of<AppState>(context, listen: false);
    final keyHeight = height ?? state.shortcutKeyHeight;
    // `armed` (the live CTRL toggle) wins over the static `inverted` accent.
    final highlighted = armed || inverted;
    final bg = highlighted ? AppColors.bone : Colors.transparent;
    final fg = highlighted ? AppColors.ink : AppColors.bone;

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: bg,
        child: InkWell(
          onTap: onPressed,
          child: Container(
            height: keyHeight,
            width: width ?? state.shortcutKeyWidth,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(
                color: highlighted ? Colors.transparent : AppColors.hairline,
                width: 1,
              ),
            ),
            child: icon != null
                ? Icon(icon, size: 14, color: fg)
                : Text(
                    label,
                    textAlign: TextAlign.center,
                    style: AppText.mono(10.5,
                        color: fg,
                        weight:
                            highlighted ? FontWeight.w700 : FontWeight.w500,
                        spacing: 0.2),
                  ),
          ),
        ),
      ),
    );

    if (width != null) {
      return SizedBox(width: width, child: content);
    }
    return Expanded(child: content);
  }
}

/// Two-finger pinch on the terminal adjusts the font size (Termux-style).
///
/// Implemented with a raw [Listener] instead of a scale [GestureDetector] so
/// it never enters the gesture arena: single-finger scrolling/selection inside
/// [TerminalView] keeps working exactly as before, and we only act while two
/// pointers are down. The size is persisted once, when the pinch ends.
class _PinchFontZoom extends StatefulWidget {
  final AppState state;
  final Widget child;
  const _PinchFontZoom({required this.state, required this.child});

  @override
  State<_PinchFontZoom> createState() => _PinchFontZoomState();
}

class _PinchFontZoomState extends State<_PinchFontZoom> {
  final Map<int, Offset> _pointers = {};
  double? _startDistance;
  double _startFontSize = 0;
  bool _pinched = false;

  double get _distance {
    final p = _pointers.values.toList();
    return (p[0] - p[1]).distance;
  }

  void _down(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2) {
      _startDistance = _distance;
      _startFontSize = widget.state.terminalFontSize;
    }
  }

  void _move(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    final start = _startDistance;
    if (_pointers.length != 2 || start == null || start <= 0) return;
    _pinched = true;
    widget.state
        .setTerminalFontSize(_startFontSize * (_distance / start), persist: false);
  }

  void _up(int pointer) {
    _pointers.remove(pointer);
    if (_pointers.length < 2) {
      _startDistance = null;
      if (_pinched) {
        _pinched = false;
        // Re-set with the current value to persist the final size.
        widget.state.setTerminalFontSize(widget.state.terminalFontSize);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: (e) => _up(e.pointer),
      onPointerCancel: (e) => _up(e.pointer),
      child: widget.child,
    );
  }
}

/// Floating pill control used to exit fullscreen terminal mode.
class _FloatingControl extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _FloatingControl({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.panelHi,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: AppColors.hairline, width: 1),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, size: 18, color: AppColors.bone),
        ),
      ),
    );
  }
}
