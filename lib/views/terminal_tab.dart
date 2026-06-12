import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/command_bar.dart';
import '../widgets/swiss.dart';
import '../widgets/terminal_selection.dart';

class TerminalTab extends StatefulWidget {
  const TerminalTab({super.key});

  @override
  State<TerminalTab> createState() => _TerminalTabState();
}

class _TerminalTabState extends State<TerminalTab> {
  final FocusNode _terminalFocusNode = FocusNode();

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
  bool _showCmdBar = true;
  bool _fullscreen = false;

  // Tracks whether the active terminal is in the alternate screen buffer (a
  // full-screen TUI like vim/htop/claude is running). The smart command bar is
  // a line-based input that makes no sense — and looks like a duplicate input
  // box — over such apps, so it is hidden while [_altScreen] is true and the
  // raw terminal takes all keystrokes. We observe the Terminal directly because
  // its alt-buffer changes don't flow through AppState's notifications.
  Terminal? _observedTerminal;
  bool _altScreen = false;

  @override
  void dispose() {
    _observedTerminal?.removeListener(_onTerminalChanged);
    _terminalFocusNode.dispose();
    _terminalController.dispose();
    _terminalScrollController.dispose();
    super.dispose();
  }

  /// Re-point the alt-buffer listener at [terminal] (called on every build so it
  /// follows session switches). Cheap no-op when the instance is unchanged.
  void _syncTerminalObserver(Terminal terminal) {
    if (identical(_observedTerminal, terminal)) return;
    _observedTerminal?.removeListener(_onTerminalChanged);
    _observedTerminal = terminal;
    terminal.addListener(_onTerminalChanged);
    _altScreen = terminal.isUsingAltBuffer;
    // Selection anchors belong to the previous terminal's buffer; drop them so
    // "Copiar" never reads a stale selection after a session switch.
    _terminalController.clearSelection();
  }

  void _onTerminalChanged() {
    final alt = _observedTerminal?.isUsingAltBuffer ?? false;
    if (alt == _altScreen) return;
    setState(() => _altScreen = alt);
    // Entering a full-screen app: hand keyboard focus to the terminal so it
    // receives keys without the user having to tap it first.
    if (alt) _terminalFocusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    _syncTerminalObserver(state.terminal);

    if (!state.isTerminalInitialized) {
      return Container(
        color: AppColors.ink,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: AppColors.bone),
              ),
              const SizedBox(height: 16),
              Text('INICIALIZANDO TERMINAL',
                  style:
                      AppText.mono(9, color: AppColors.muted, spacing: 1.5)),
            ],
          ),
        ),
      );
    }

    return Container(
      color: AppColors.ink,
      child: SafeArea(
        top: false,
        child: Stack(
          children: [
            Column(
              children: [
                if (!_fullscreen) _buildToolbar(context, state),
                Expanded(
                  child: GestureDetector(
                    onTap: () => _terminalFocusNode.requestFocus(),
                    child: TerminalSelectionArea(
                      terminal: state.terminal,
                      controller: _terminalController,
                      terminalViewKey: _terminalViewKey,
                      scrollController: _terminalScrollController,
                      onSendInput: (text) {
                        state.sendTerminalInput(text);
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
                        theme: AppTerminalTheme.forBrightness(
                            Theme.of(context).brightness),
                        cursorType: TerminalCursorType.block,
                        backgroundOpacity: 1,
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                        textStyle: TerminalStyle(
                          fontSize: state.terminalFontSize,
                          height: 1.3,
                          fontFamily: AppText.cascadiaFamily,
                          fontFamilyFallback: const ['monospace'],
                        ),
                      ),
                    ),
                  ),
                ),
                if (!_fullscreen && _showCmdBar && !_altScreen)
                  const CommandBar(),
                if (!_fullscreen && _showKeys) _buildKeys(state),
              ],
            ),
            if (_fullscreen)
              Positioned(
                right: 14,
                bottom: 14,
                child: _FloatingControl(
                  icon: Icons.close_fullscreen,
                  onTap: () => setState(() => _fullscreen = false),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---- Toolbar (sessions + actions) ----------------------------------------

  Widget _buildToolbar(BuildContext context, AppState state) {
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: AppColors.ink,
        border:
            Border(bottom: BorderSide(color: AppColors.hairline, width: 1)),
      ),
      child: Row(
        children: [
          Expanded(child: _sessionSelector(context, state)),
          Container(width: 1, height: 38, color: AppColors.hairline),
          _toolbarIcon(Icons.text_decrease, 'Reducir letra',
              () => state.bumpTerminalFontSize(-1)),
          _toolbarIcon(Icons.text_increase, 'Aumentar letra',
              () => state.bumpTerminalFontSize(1)),
          _toolbarIcon(
            _showCmdBar ? Icons.bolt : Icons.bolt_outlined,
            'Barra inteligente',
            () => setState(() => _showCmdBar = !_showCmdBar),
          ),
          _toolbarIcon(
            _showKeys ? Icons.keyboard_hide_outlined : Icons.keyboard_outlined,
            'Teclas rápidas',
            () => setState(() => _showKeys = !_showKeys),
          ),
          _toolbarIcon(Icons.open_in_full, 'Expandir terminal',
              () => setState(() => _fullscreen = true)),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  /// Copies the active terminal's current selection to the clipboard. If
  /// nothing is selected, nudges the user to long-press and drag first.
  Future<void> _copySelection(AppState state) async {
    final selection = _terminalController.selection;
    if (selection == null) {
      _toast('Mantén pulsado y arrastra para seleccionar texto');
      return;
    }
    final text = state.terminal.buffer.getText(selection);
    _terminalController.clearSelection();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _toast('Copiado al portapapeles');
  }

  /// Pastes clipboard text into the active shell as raw input.
  Future<void> _paste(AppState state) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    state.sendTerminalInput(text);
    _terminalFocusNode.requestFocus();
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
    return IconButton(
      icon: Icon(icon, color: AppColors.muted, size: 16),
      onPressed: onTap,
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 38),
    );
  }

  IconData _statusIcon(TerminalSession s) {
    switch (s.connectionStatus) {
      case ConnectionStatus.remote:
        return Icons.circle;
      case ConnectionStatus.connecting:
        return Icons.adjust;
      default:
        return Icons.circle_outlined;
    }
  }

  /// Status glyph for a session: an animated spinner while the SSH handshake is
  /// in flight ([ConnectionStatus.connecting]), otherwise the static dot icon.
  Widget _statusGlyph(TerminalSession s,
      {required double size, required Color color}) {
    if (s.connectionStatus == ConnectionStatus.connecting) {
      return SizedBox(
        width: size,
        height: size,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
      );
    }
    return Icon(_statusIcon(s), size: size, color: color);
  }

  String _sessionMeta(TerminalSession s) {
    switch (s.connectionStatus) {
      case ConnectionStatus.remote:
        return 'SSH · ${s.activeProfile?.name ?? ''}';
      case ConnectionStatus.connecting:
        return 'CONECTANDO…';
      case ConnectionStatus.local:
        return 'LOCAL';
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
                ? _statusGlyph(active, size: 11, color: AppColors.bone)
                : Icon(Icons.circle_outlined, size: 11, color: AppColors.bone),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                active?.name ?? 'Sesión',
                style: AppText.mono(11,
                    color: AppColors.bone, weight: FontWeight.w700),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                  border: Border.all(color: AppColors.hairline, width: 1)),
              child: Text('${state.sessions.length}',
                  style: AppText.mono(9, color: AppColors.muted)),
            ),
            Icon(Icons.expand_more, size: 16, color: AppColors.muted),
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
              _menuTile(sheetCtx, Icons.add, 'NUEVA TERMINAL LOCAL',
                  () => s.createNewSession()),
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
              _statusGlyph(session, size: 12, color: fg),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(session.name,
                        style: AppText.mono(12,
                            color: fg, weight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(_sessionMeta(session),
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

  Widget _buildKeys(AppState state) {
    // Two fixed rows, each an Expanded Row so every key shares the available
    // width evenly: the strip is always exactly two lines, never wraps to a
    // third, and stays compact regardless of screen width.
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
            // Row 1 — modifiers + signals.
            Row(
              children: [
                _key('CTRL', state.toggleCtrl, armed: state.ctrlArmed),
                _key('ESC', () => state.sendTerminalInput('\x1b')),
                _key('TAB', () => state.sendTerminalInput('\t')),
                // ALT acts as the Meta prefix: it sends ESC, so pressing ALT
                // then a letter on the system keyboard yields Alt+<letter>.
                _key('ALT', () => state.sendTerminalInput('\x1b')),
                _key('^C', () => state.sendTerminalInput('\x03'), inverted: true),
                _key('COPIAR', () => _copySelection(state),
                    icon: Icons.content_copy_outlined),
                _key('PEGAR', () => _paste(state),
                    icon: Icons.content_paste_outlined),
              ],
            ),
            const SizedBox(height: 5),
            // Row 2 — navigation, confirmations, symbols.
            Row(
              children: [
                _key('↑', () => state.sendTerminalInput('\x1b[A')),
                _key('↓', () => state.sendTerminalInput('\x1b[B')),
                _key('←', () => state.sendTerminalInput('\x1b[D')),
                _key('→', () => state.sendTerminalInput('\x1b[C')),
                _key('~', () => state.sendTerminalInput('~')),
                _key('/', () => state.sendTerminalInput('/')),
                _key('-', () => state.sendTerminalInput('-')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _key(
    String label,
    VoidCallback onPressed, {
    bool inverted = false,
    bool armed = false,
    IconData? icon,
  }) {
    // `armed` (the live CTRL toggle) wins over the static `inverted` accent.
    final highlighted = armed || inverted;
    final bg = highlighted ? AppColors.bone : Colors.transparent;
    final fg = highlighted ? AppColors.ink : AppColors.bone;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Material(
          color: bg,
          child: InkWell(
            onTap: onPressed,
            child: Container(
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border.all(
                  color: highlighted ? Colors.transparent : AppColors.hairline,
                  width: 1,
                ),
              ),
              child: icon != null
                  ? Icon(icon, size: 15, color: fg)
                  : Text(
                      label,
                      textAlign: TextAlign.center,
                      style: AppText.mono(11,
                          color: fg,
                          weight:
                              highlighted ? FontWeight.w700 : FontWeight.w500,
                          spacing: 0.3),
                    ),
            ),
          ),
        ),
      ),
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
