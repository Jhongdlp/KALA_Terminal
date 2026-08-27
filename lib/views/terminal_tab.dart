import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/xterm.dart';
import '../models/connection_error.dart';
import '../providers/app_state.dart';
import 'agent_launcher_sheet.dart';
import '../services/terminal_search.dart';
import '../theme/app_theme.dart';
import '../widgets/adaptive_sheet.dart';
import '../widgets/swiss.dart';
import '../widgets/tap_target.dart';
import '../widgets/terminal_selection.dart';
import 'command_history_sheet.dart';
import 'prompts_sheet.dart';
import 'shortcuts_help_sheet.dart';
import 'terminal_compose_bar.dart';
import 'git_panel_sheet.dart';
import 'terminal_quick_keys.dart';
import 'tunnel_editor_sheet.dart';
import 'tunnels_tab.dart';
import '../models/connection_profile.dart';
import '../services/tunnel_manager.dart';
import '../widgets/joystick_recognizer.dart';
import '../widgets/terminal_touch_pad.dart';
import '../models/touch_pad.dart';
import '../widgets/profile_tint.dart';
import '../l10n/l10n.dart';

class TerminalTab extends StatefulWidget {
  const TerminalTab({super.key});

  @override
  State<TerminalTab> createState() => _TerminalTabState();
}

class _TerminalTabState extends State<TerminalTab> with WidgetsBindingObserver {
  final FocusNode _terminalFocusNode = FocusNode();

  // ---- Touch pad -----------------------------------------------------------
  // Hold a beat and the finger becomes a d-pad; hold a beat longer without
  // pulling and it blooms into the radial. The gesture arena work is in
  // [JoystickGestureRecognizer]; what lives here is what the pad *does* and
  // what it looks like while doing it.
  //
  // Coordinates are local to [_padSpaceKey]'s stack, because the overlay is
  // painted inside it while the recogniser reports global positions.
  final GlobalKey _padSpaceKey = GlobalKey();
  Offset? _padOrigin;
  Offset? _padCurrent;
  TouchPadMode? _padMode;
  PadDirection? _padDirection;
  bool _padAccelerated = false;
  double _padTension = 0;
  // Set when the slot under the finger is a one-shot action rather than keys,
  // so a bound sheet opens once instead of once per repeat tick.
  bool _padActionFired = false;
  Timer? _padRepeatTimer;
  Timer? _padRadialTimer;
  Duration _padRepeatInterval = const Duration(milliseconds: 300);

  /// How close to a slot the finger has to be for the radial to consider it
  /// picked. Deliberately much smaller than the radius the chips are drawn at:
  /// the finger only has to *lean* towards a slot, not reach it.
  static const double _radialPickRadius = 34;

  Offset _toPadSpace(Offset global) {
    final box = _padSpaceKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return global;
    return box.globalToLocal(global);
  }

  Offset _fromPadSpace(Offset local) {
    final box = _padSpaceKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return local;
    return box.localToGlobal(local);
  }

  /// Sends whatever [direction] is bound to. Returns false when the slot is
  /// empty or is a one-shot action, i.e. when there is nothing to repeat.
  bool _firePadSlot(AppState state, PadDirection direction) {
    final shortcut = state.terminalPadConfig.slot(direction);
    if (shortcut == null) return false;
    if (shortcut.value.startsWith('system:')) {
      _runKeyAction(state, shortcut.value.substring('system:'.length));
      return false;
    }
    _sendTerminalKey(state, shortcut.parsedValue);
    return true;
  }

  void _firePadRepeatTick(AppState state) {
    final direction = _padDirection;
    if (_padOrigin == null || direction == null) return;
    if (_padMode != TouchPadMode.repeat) return;
    if (!_firePadSlot(state, direction)) {
      // A one-shot slot: fire once and stop, rather than reopening a sheet
      // three times a second for as long as the finger is held.
      _padActionFired = true;
      _padRepeatTimer?.cancel();
      _padRepeatTimer = null;
      return;
    }
    _padRepeatTimer?.cancel();
    _padRepeatTimer = Timer(_padRepeatInterval, () {
      if (mounted) _firePadRepeatTick(state);
    });
  }

  /// Called on every move once the pad owns the pointer. Decides which of the
  /// three modes we are in and keeps the HUD in step with it.
  void _updatePad(AppState state) {
    final origin = _padOrigin;
    final current = _padCurrent;
    if (origin == null || current == null) return;
    final delta = current - origin;

    // The radial has already opened: it owns the gesture until release, so a
    // pull no longer starts a repeat. Waiting for the menu and then dragging
    // has to mean "pick this slot", or the wait would be punished.
    if (_padMode == TouchPadMode.radial) {
      final picked = padDirectionFor(delta,
          deadzone: _radialPickRadius, corners: true);
      if (picked != _padDirection) {
        HapticFeedback.selectionClick();
        setState(() => _padDirection = picked);
      }
      return;
    }

    final deadzone = state.terminalGestureDeadzone;
    final direction =
        padDirectionFor(delta, deadzone: deadzone, corners: false);

    if (direction == null) {
      // Back inside the deadzone: stop repeating and start counting towards
      // the radial again.
      _padRepeatTimer?.cancel();
      _padRepeatTimer = null;
      _padActionFired = false;
      _armRadialTimer(state);
      if (_padDirection != null || _padAccelerated || _padTension != 0) {
        setState(() {
          _padDirection = null;
          _padAccelerated = false;
          _padTension = 0;
        });
      }
      return;
    }

    // Pulling: the radial is off the table until the finger comes back.
    _padRadialTimer?.cancel();
    _padRadialTimer = null;

    final pull = direction == PadDirection.left || direction == PadDirection.right
        ? delta.dx.abs()
        : delta.dy.abs();
    final ratio = ((pull - deadzone) / 160).clamp(0.0, 1.0);
    _padRepeatInterval = Duration(milliseconds: 300 - (270 * ratio).toInt());
    final accelerated = ratio >= 0.35;
    if (!_padAccelerated && accelerated) HapticFeedback.selectionClick();

    final changed = _padDirection != direction;
    if (changed) _padActionFired = false;
    if (changed || _padAccelerated != accelerated || _padMode != TouchPadMode.repeat) {
      setState(() {
        _padMode = TouchPadMode.repeat;
        _padDirection = direction;
        _padAccelerated = accelerated;
        _padTension = ratio;
      });
    } else if ((_padTension - ratio).abs() > 0.05) {
      setState(() => _padTension = ratio);
    }

    if (_padActionFired) return;
    if (_padRepeatTimer == null || !_padRepeatTimer!.isActive) {
      _firePadRepeatTick(state);
    }
  }

  void _armRadialTimer(AppState state) {
    _padRadialTimer?.cancel();
    if (!state.terminalPadRadialEnabled) return;
    _padRadialTimer = Timer(state.terminalPadRadialDelay, () {
      _padRadialTimer = null;
      if (!mounted || _padOrigin == null) return;
      HapticFeedback.mediumImpact();
      setState(() {
        _padMode = TouchPadMode.radial;
        _padDirection = null;
        _padAccelerated = false;
        _padTension = 0;
      });
    });
  }

  /// The finger has been still long enough that a nudge would arm the pad.
  /// Nothing has been won in the arena yet — this only draws the ring, which
  /// is the whole point: the gesture used to be invisible until it fired.
  void _handleHoldQualified(Offset global, AppState state) {
    if (!state.terminalPadEnabled) return;
    if (_terminalController.selection != null) return;
    HapticFeedback.selectionClick();
    setState(() {
      _padOrigin = _toPadSpace(global);
      _padCurrent = _padOrigin;
      _padMode = TouchPadMode.armed;
      _padDirection = null;
      _padAccelerated = false;
      _padTension = 0;
    });
  }

  /// It turned out to be a swipe, a tap or a long press: take the ring away.
  void _handleHoldCancelled() {
    if (_padMode == null) return;
    _clearPad();
  }

  /// The finger rested long enough that the pad claimed the pointer: open the
  /// radial straight away.
  ///
  /// Called right after [_handleJoystickStart], which has already set the
  /// origin and armed a *second* radial timer — cancel it, or the menu would
  /// re-open under itself and reset the picked slot.
  void _handleRadialDwell(AppState state) {
    if (_padOrigin == null) return;
    _padRadialTimer?.cancel();
    _padRadialTimer = null;
    HapticFeedback.mediumImpact();
    setState(() {
      _padMode = TouchPadMode.radial;
      _padDirection = null;
      _padAccelerated = false;
      _padTension = 0;
    });
  }

  void _handleJoystickStart(Offset global, AppState state) {
    if (_terminalController.selection != null) return;
    setState(() {
      _padOrigin = _toPadSpace(global);
      _padCurrent = _padOrigin;
      _padMode = TouchPadMode.armed;
    });
    _armRadialTimer(state);
  }

  void _handleJoystickMove(Offset global, AppState state) {
    if (_padOrigin == null) return;
    _padCurrent = _toPadSpace(global);
    _updatePad(state);
  }

  void _handleJoystickEnd(AppState state) {
    // Releasing on a radial slot is what fires it — the whole menu is a
    // pick-and-release, so nothing happens while the finger is still down.
    if (_padMode == TouchPadMode.radial && _padDirection != null) {
      _firePadSlot(state, _padDirection!);
      HapticFeedback.selectionClick();
    }
    _clearPad();
  }

  void _clearPad() {
    _padRepeatTimer?.cancel();
    _padRepeatTimer = null;
    _padRadialTimer?.cancel();
    _padRadialTimer = null;
    _padActionFired = false;
    if (!mounted) return;
    setState(() {
      _padOrigin = null;
      _padCurrent = null;
      _padMode = null;
      _padDirection = null;
      _padAccelerated = false;
      _padTension = 0;
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _terminalScrollController.addListener(_onScrollChanged);
  }

  /// Flips [_scrolledUp] when the viewport leaves (or returns to) the bottom.
  /// Guarded on the value actually changing: this fires on every scroll pixel.
  void _onScrollChanged() {
    if (!_terminalScrollController.hasClients) return;
    final position = _terminalScrollController.position;
    // A couple of lines of slack: xterm's stick-to-bottom already sits a
    // fraction of a pixel off the extent while output is streaming.
    final up = position.pixels < position.maxScrollExtent - 40;
    if (up != _scrolledUp) setState(() => _scrolledUp = up);
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

  // Whether the quick keyboard and the dictation bar are up lives in AppState:
  // the toolbar, the keyboard shortcuts and the command palette all toggle the
  // same thing, and two copies of that flag drift apart the first time one of
  // them is used.

  // ---- Scrollback search ---------------------------------------------------
  // Matches are a snapshot taken when the query was typed. Their line indices
  // can drift if enough new output pushes lines out of the 10k buffer, but the
  // *selection* is anchor-based, so the highlight follows the text either way.
  final TextEditingController _searchController = TextEditingController();
  List<TerminalMatch> _matches = const [];
  int _matchIndex = 0;

  // Whether the view is scrolled off the bottom, which is what puts the
  // "jump to the prompt" button on screen. Reading it from the controller on
  // every build would be cheaper than a listener, but the button has to appear
  // the moment the user drags — not on the next unrelated rebuild.
  bool _scrolledUp = false;

  // Tracks whether the active terminal is in the alternate screen buffer (a
  // full-screen TUI like vim/htop/claude is running). The smart command bar is
  // a line-based input that makes no sense — and looks like a duplicate input
  // box — over such apps, so it is hidden while [_altScreen] is true and the
  // raw terminal takes all keystrokes. We observe the Terminal directly because
  // its alt-buffer changes don't flow through AppState's notifications.
  Terminal? _observedTerminal;

  // Last alt-buffer state seen, so the focus grab below runs on the transition
  // rather than on every output batch.
  bool _observedAltBuffer = false;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // The pad's timers outlive the widget otherwise: a repeat tick firing
    // after the tab is gone would push keys into a dead session.
    _padRepeatTimer?.cancel();
    _padRadialTimer?.cancel();
    _observedTerminal?.removeListener(_onTerminalChanged);
    _terminalFocusNode.dispose();
    _terminalController.dispose();
    _searchController.dispose();
    _terminalScrollController.removeListener(_onScrollChanged);
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
    _observedAltBuffer = terminal.isUsingAltBuffer;
    terminal.addListener(_onTerminalChanged);
    // Selection anchors belong to the previous terminal's buffer; drop them so
    // "Copiar" never reads a stale selection after a session switch.
    _terminalController.clearSelection();
  }

  void _onTerminalChanged() {
    // This fires on every batch of remote output. Only the *transition* into
    // the alternate buffer is interesting — asking for focus on every batch
    // walked the focus tree dozens of times a second while a TUI redrew.
    final alt = _observedTerminal?.isUsingAltBuffer ?? false;
    if (alt == _observedAltBuffer) return;
    _observedAltBuffer = alt;
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
              Text(tr('SIN SESIÓN ACTIVA'),
                  style:
                      AppText.mono(9, color: AppColors.muted, spacing: 1.5)),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  tr('Conéctate a un servidor SSH desde la pestaña Conexiones para abrir una terminal.'),
                  textAlign: TextAlign.center,
                  style: AppText.body(13, color: AppColors.muted),
                ),
              ),
              const SizedBox(height: 20),
              InvertedButton(
                label: tr('Ir a Conexiones'),
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
              key: _padSpaceKey,
              children: [
                Column(
                  children: [
                // Which machine this is, in 3px. Above the toolbar and outside
                // it so fullscreen keeps it — fullscreen is exactly when the
                // session name is no longer on screen.
                ProfileTintBand(
                    tint: profileTint(state.activeSession?.activeProfile)),
                if (!fullscreen) _buildToolbar(context, state),
                // Dropped connection with a known profile → offer to
                // re-establish it in place (with tmux this re-attaches to
                // whatever kept running on the server). Shown in fullscreen
                // too: it's exactly when an agent was left working.
                if (state.activeSession?.connectionStatus ==
                        ConnectionStatus.disconnected &&
                    state.activeSession?.activeProfile != null)
                  _reconnectBanner(state),
                // Scrollback search. Under the chrome, never over the buffer:
                // an overlay would cover the output being searched.
                if (state.terminalSearchOpen) _searchBar(state),
                Expanded(
                  child: RawGestureDetector(
                    behavior: HitTestBehavior.translucent,
                    gestures: <Type, GestureRecognizerFactory>{
                      JoystickGestureRecognizer: GestureRecognizerFactoryWithHandlers<JoystickGestureRecognizer>(
                        () => JoystickGestureRecognizer(
                          onJoystickStart: (pos) => _handleJoystickStart(pos, state),
                          onJoystickMove: (pos) => _handleJoystickMove(pos, state),
                          onJoystickEnd: () => _handleJoystickEnd(state),
                          onHoldQualified: (pos) =>
                              _handleHoldQualified(pos, state),
                          onHoldCancelled: _handleHoldCancelled,
                          onRadialDwell: () => _handleRadialDwell(state),
                          holdDelay: state.terminalPadHoldDelay,
                          // Null when the radial is off, which is what hands
                          // the long press back to text selection.
                          radialDelay: state.terminalPadRadialEnabled
                              ? state.terminalPadRadialDelay
                              : null,
                          isSelectionActive: () =>
                              _terminalController.selection != null ||
                              !state.terminalPadEnabled,
                        ),
                        (JoystickGestureRecognizer instance) {
                          instance.onJoystickStart = (pos) => _handleJoystickStart(pos, state);
                          instance.onJoystickMove = (pos) => _handleJoystickMove(pos, state);
                          instance.onJoystickEnd = () => _handleJoystickEnd(state);
                          instance.onHoldQualified = (pos) =>
                              _handleHoldQualified(pos, state);
                          instance.onHoldCancelled = _handleHoldCancelled;
                          instance.onRadialDwell = () => _handleRadialDwell(state);
                          instance.holdDelay = state.terminalPadHoldDelay;
                          instance.radialDelay = state.terminalPadRadialEnabled
                              ? state.terminalPadRadialDelay
                              : null;
                          instance.isSelectionActive = () =>
                              _terminalController.selection != null ||
                              !state.terminalPadEnabled;
                        },
                      ),
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
                        autocorrect: state.terminalKeyboardAutocorrect,
                        enableSuggestions: state.terminalKeyboardAutocorrect,
                        // Ajustes → Terminal. Off means a swipe inside a TUI
                        // that ignores the wheel does nothing, instead of
                        // walking an agent's prompt history.
                        simulateScroll: state.terminalAltScrollKeys,
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
                        // Gboard inline image paste
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
                // The compose bar sits between the terminal and the quick
                // keys, where the soft keyboard pushes it into view.
                if (state.composeBarVisible)
                  TerminalComposeBar(
                    state: state,
                    onClose: () => state.setComposeBarVisible(false),
                  ),
                // Quick-access keys stay available even in fullscreen.
                if (state.quickKeysVisible)
                  TerminalQuickKeys(
                    state: state,
                    onSend: (data) => _sendTerminalKey(state, data),
                    onAction: (action) => _runKeyAction(state, action),
                    banner: state.isAttaching
                        ? _buildUploadBanner(state)
                        : null,
                  ),
              ],
            ),
            // The pad's ring, repeat chip and radial. Pure paint over the
            // buffer: the pointer belongs to the recogniser that armed it.
            if (_padOrigin != null && _padMode != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: TouchPadOverlay(
                    origin: _padOrigin!,
                    current: _padCurrent,
                    mode: _padMode!,
                    config: state.terminalPadConfig,
                    active: _padDirection,
                    accelerated: _padAccelerated,
                    tension: _padTension,
                  ),
                ),
              ),
            // Reading back through the scrollback used to be a one-way trip:
            // the only way back to the prompt was dragging until the buffer
            // ran out. Only shown while actually scrolled up.
            if (_scrolledUp)
              Positioned(
                right: 14,
                bottom: fullscreen ? 70 : 14,
                child: _FloatingControl(
                  icon: Icons.keyboard_double_arrow_down,
                  onTap: () {
                    if (!_terminalScrollController.hasClients) return;
                    _terminalScrollController.jumpTo(
                        _terminalScrollController.position.maxScrollExtent);
                  },
                ),
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


  // ---- Scrollback search -----------------------------------------------------

  /// Runs [query] over the whole buffer and jumps to the **last** hit.
  ///
  /// Last, not first: the scrollback grows downwards and the interesting
  /// occurrence of an error is almost always the most recent one. Starting at
  /// the top would make the user press "next" thirty times to reach it.
  void _runSearch(String query, Terminal terminal) {
    final matches = TerminalSearch.find(terminal, query);
    setState(() {
      _matches = matches;
      _matchIndex = matches.isEmpty ? 0 : matches.length - 1;
    });
    if (matches.isNotEmpty) _revealMatch(terminal);
  }

  void _stepMatch(int delta, Terminal terminal) {
    if (_matches.isEmpty) return;
    setState(() {
      // Wraps, so "next" at the end goes back to the top instead of dead-ending.
      _matchIndex = (_matchIndex + delta) % _matches.length;
      if (_matchIndex < 0) _matchIndex += _matches.length;
    });
    _revealMatch(terminal);
  }

  /// Scrolls the current match into view and selects it, so the existing
  /// selection painting *is* the highlight — no second highlight mechanism to
  /// keep in sync with the theme.
  void _revealMatch(Terminal terminal) {
    if (_matches.isEmpty) return;
    final match = _matches[_matchIndex];
    final render = _terminalViewKey.currentState?.renderTerminal;
    if (render == null || !_terminalScrollController.hasClients) return;

    final position = _terminalScrollController.position;
    // A third of the way down rather than at the very top: the lines *around*
    // an error are most of why you were looking for it.
    final target =
        match.line * render.lineHeight - position.viewportDimension / 3;
    _terminalScrollController
        .jumpTo(target.clamp(0.0, position.maxScrollExtent));

    final buffer = terminal.buffer;
    _terminalController.setSelection(
      buffer.createAnchorFromOffset(CellOffset(match.start, match.line)),
      buffer.createAnchorFromOffset(CellOffset(match.end, match.line)),
    );
  }

  void _closeSearch(AppState state) {
    state.setTerminalSearchOpen(false);
    _searchController.clear();
    _terminalController.clearSelection();
    setState(() {
      _matches = const [];
      _matchIndex = 0;
    });
    _terminalFocusNode.requestFocus();
  }

  /// The search bar. Sits under the toolbar rather than floating over the
  /// buffer: an overlay would cover the very output being searched.
  Widget _searchBar(AppState state) {
    final terminal = state.terminal;
    final hasQuery = _searchController.text.isNotEmpty;
    final count = _matches.length;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border(bottom: BorderSide(color: AppColors.hairline, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Icon(Icons.search, size: 15, color: AppColors.muted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchController,
              autofocus: true,
              textInputAction: TextInputAction.search,
              style: AppText.mono(12, color: AppColors.bone),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: tr('Buscar en la salida…'),
                hintStyle: AppText.body(12, color: AppColors.faint),
              ),
              onChanged: (q) => _runSearch(q, terminal),
              onSubmitted: (_) => _stepMatch(1, terminal),
            ),
          ),
          if (hasQuery)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                count == 0
                    ? tr('sin resultados')
                    : '${_matchIndex + 1}/$count'
                        '${count >= TerminalSearch.maxMatches ? '+' : ''}',
                style: AppText.mono(10, color: AppColors.muted),
              ),
            ),
          IconTapTarget(
            icon: Icons.keyboard_arrow_up,
            label: tr('Coincidencia anterior'),
            min: 38,
            color: count == 0 ? AppColors.hairline : AppColors.muted,
            onTap: count == 0 ? null : () => _stepMatch(-1, terminal),
          ),
          IconTapTarget(
            icon: Icons.keyboard_arrow_down,
            label: tr('Coincidencia siguiente'),
            min: 38,
            color: count == 0 ? AppColors.hairline : AppColors.muted,
            onTap: count == 0 ? null : () => _stepMatch(1, terminal),
          ),
          IconTapTarget(
            icon: Icons.close,
            label: tr('Cerrar búsqueda'),
            min: 38,
            color: AppColors.muted,
            onTap: () => _closeSearch(state),
          ),
        ],
      ),
    );
  }

  /// Copies the whole scrollback to the clipboard.
  Future<void> _copyBuffer(AppState state) async {
    final buffer = state.terminal.buffer;
    final text = buffer.getText(BufferRangeLine(
      const CellOffset(0, 0),
      CellOffset(buffer.viewWidth - 1, buffer.lines.length - 1),
    ));
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _toast(tr('Salida copiada ({0} líneas)', [buffer.lines.length]));
  }

  /// Writes the scrollback to a file next to the app's downloads, so a long
  /// session can be attached to a bug report instead of screenshotted.
  Future<void> _saveBuffer(AppState state) async {
    final buffer = state.terminal.buffer;
    final text = buffer.getText(BufferRangeLine(
      const CellOffset(0, 0),
      CellOffset(buffer.viewWidth - 1, buffer.lines.length - 1),
    ));
    try {
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final name =
          '${state.activeSession?.name ?? 'sesion'}-$stamp.log'.replaceAll(
              RegExp(r'[^A-Za-z0-9._-]'), '_');
      String dir;
      if (Platform.isAndroid &&
          await Directory('/storage/emulated/0/Download').exists()) {
        dir = '/storage/emulated/0/Download/KAMMEL';
      } else {
        dir = (await getApplicationDocumentsDirectory()).path;
      }
      await Directory(dir).create(recursive: true);
      final file = File('$dir/$name');
      await file.writeAsString(text);
      if (!mounted) return;
      _toast(tr('Guardado en {0}', [file.path]));
    } catch (e) {
      if (!mounted) return;
      _toast(tr('No se pudo guardar: {0}', [e]));
    }
  }

  // ---- Reconnect banner ------------------------------------------------------

  /// Thin strip shown while the active session's SSH connection is down: it
  /// names the reason (classified in [ConnectionError], not the raw dartssh2
  /// text) and one tap re-establishes the connection.
  Widget _reconnectBanner(AppState state) {
    final session = state.activeSession!;
    final failure = session.lastError;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.panel,
        border:
            Border(bottom: BorderSide(color: AppColors.hairline, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.link_off,
              size: 14,
              color: failure == null ? AppColors.muted : AppColors.danger),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(failure?.title ?? tr('CONEXIÓN PERDIDA'),
                    style: failure == null
                        ? AppText.label(9, color: AppColors.muted, spacing: 1.2)
                        : AppText.body(11, color: AppColors.bone),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                if (failure != null)
                  InkWell(
                    onTap: () => _showFailureDetails(state, session, failure),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(tr('Ver qué hacer'),
                          style: AppText.label(8,
                              color: AppColors.accent, spacing: 1.0)),
                    ),
                  ),
              ],
            ),
          ),
          session.reconnecting
              ? SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.5, color: AppColors.muted),
                )
              : GhostButton(
                  label: tr('Reconectar'),
                  icon: Icons.refresh,
                  dense: true,
                  onPressed: () => state.reconnectSession(session),
                ),
        ],
      ),
    );
  }

  /// The full story behind a failed connection: what happened, what to do, the
  /// action that most likely fixes it, and the original error text folded away
  /// for whoever wants it.
  void _showFailureDetails(
      AppState state, TerminalSession session, ConnectionError failure) {
    showAdaptiveSheet(
      context,
      backgroundColor: AppColors.panel,
      isScrollControlled: true,
      maxWidth: 520,
      builder: (sheetCtx) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.error_outline,
                        size: 16, color: AppColors.danger),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(failure.title.toUpperCase(),
                          style: AppText.label(11,
                              color: AppColors.bone, spacing: 1.2)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (failure.hint != null)
                  Text(failure.hint!,
                      style: AppText.body(12, color: AppColors.muted)),
                const SizedBox(height: 16),
                InvertedButton(
                  label: failure.primaryActionLabel,
                  expand: true,
                  onPressed: () {
                    Navigator.of(sheetCtx).pop();
                    if (failure.suggestsKnownHosts) {
                      state.setActiveTabIndex(5); // Ajustes → servidores conocidos
                    } else if (failure.suggestsEditingProfile) {
                      state.setActiveTabIndex(0); // Conexiones, para editarlo
                    } else {
                      state.reconnectSession(session);
                    }
                  },
                ),
                if (!failure.suggestsKnownHosts) ...[
                  const SizedBox(height: 10),
                  GhostButton(
                    label: tr('Reintentar ahora'),
                    icon: Icons.refresh,
                    dense: true,
                    onPressed: () {
                      Navigator.of(sheetCtx).pop();
                      state.reconnectSession(session);
                    },
                  ),
                ],
                const SizedBox(height: 18),
                Hairline(),
                const SizedBox(height: 12),
                Text(tr('DETALLE TÉCNICO'),
                    style:
                        AppText.label(9, color: AppColors.muted, spacing: 1.4)),
                const SizedBox(height: 6),
                SelectableText(failure.detail,
                    style: AppText.mono(10, color: AppColors.faint)),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: GhostButton(
                    label: tr('Copiar detalle'),
                    icon: Icons.copy_outlined,
                    dense: true,
                    onPressed: () => Clipboard.setData(
                        ClipboardData(text: failure.detail)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- Toolbar (sessions + actions) ----------------------------------------

  /// The terminal's own chrome.
  ///
  /// It is width-aware rather than fixed: at 46px tall every icon is a real
  /// tap target, and on a 360px phone seven of them plus the session name do
  /// not fit. So the bar keeps the three controls that are used constantly —
  /// the session switcher, search and the quick keyboard — and everything else
  /// moves into "más", which is one tap and is *labelled*, unlike a row of
  /// glyphs a new user has to decode.
  Widget _buildToolbar(BuildContext context, AppState state) {
    return Container(
      height: 46,
      decoration: BoxDecoration(
        color: AppColors.ink,
        border:
            Border(bottom: BorderSide(color: AppColors.hairline, width: 1)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Below this the secondary icons crowd the session name out; the
          // exact number is where the selector stops being able to show a
          // profile name at all.
          final wide = constraints.maxWidth >= 520;
          return Row(
            children: [
              Expanded(child: _sessionSelector(context, state)),
              Container(width: 1, height: 46, color: AppColors.hairline),
              if (wide) ...[
                _toolbarIcon(Icons.text_decrease, tr('Reducir letra'),
                    () => state.bumpTerminalFontSize(-1)),
                _toolbarIcon(Icons.text_increase, tr('Aumentar letra'),
                    () => state.bumpTerminalFontSize(1)),
              ],
              _toolbarIcon(
                Icons.search,
                tr('Buscar en la salida'),
                () => state.setTerminalSearchOpen(!state.terminalSearchOpen),
                active: state.terminalSearchOpen,
              ),
              _toolbarIcon(
                state.quickKeysVisible
                    ? Icons.keyboard_hide_outlined
                    : Icons.keyboard_outlined,
                tr('Teclas rápidas'),
                state.toggleQuickKeys,
              ),
              if (wide) ...[
                _toolbarIcon(
                  Icons.mic_none_outlined,
                  tr('Barra de dictado'),
                  state.toggleComposeBar,
                  active: state.composeBarVisible,
                ),
                _tunnelsButton(context, state),
                _toolbarIcon(Icons.open_in_full, tr('Expandir terminal'),
                    () => state.setTerminalFullscreen(true)),
              ],
              _toolbarIcon(Icons.more_vert, tr('Más acciones'),
                  () => _showMoreSheet(context, state)),
              const SizedBox(width: 4),
            ],
          );
        },
      ),
    );
  }

  /// Everything the toolbar can't fit, with words instead of glyphs.
  ///
  /// This is also where features that had no entry point at all now live —
  /// scrollback export, the command history, the shortcut/gesture reference —
  /// so they stop being things only their author knows about.
  void _showMoreSheet(BuildContext context, AppState state) {
    final tunnelCount = state.tunnels.activeCount(state.activeSession?.id);

    showAdaptiveSheet(
      context,
      backgroundColor: AppColors.panel,
      isScrollControlled: true,
      maxWidth: 480,
      builder: (sheetCtx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(tr('TERMINAL'),
                    style: AppText.label(11,
                        color: AppColors.bone, spacing: 1.4)),
              ),
              Hairline(),
              _menuTile(sheetCtx, Icons.search, tr('BUSCAR EN LA SALIDA'),
                  () => state.setTerminalSearchOpen(true)),
              Hairline(),
              _menuTile(sheetCtx, Icons.history, tr('HISTORIAL DE COMANDOS'),
                  () => showCommandHistorySheet(context,
                      onInserted: _terminalFocusNode.requestFocus)),
              Hairline(),
              _menuTile(sheetCtx, Icons.bookmark_border, tr('PROMPTS GUARDADOS'),
                  () => _showPrompts(state)),
              Hairline(),
              _menuTile(sheetCtx, Icons.difference_outlined, tr('PANEL DE GIT'),
                  () => _showGitSlider(state)),
              Hairline(),
              _menuTile(sheetCtx, Icons.link, tr('ENLACES DETECTADOS'),
                  () => _showLinksSheet(state)),
              Hairline(),
              _menuTile(
                  sheetCtx,
                  Icons.mic_none_outlined,
                  state.composeBarVisible
                      ? tr('OCULTAR BARRA DE DICTADO')
                      : tr('BARRA DE DICTADO'),
                  state.toggleComposeBar),
              Hairline(),
              _menuTile(
                  sheetCtx,
                  Icons.swap_horiz,
                  tunnelCount > 0
                      ? tr('TÚNELES · {0} ACTIVO(S)', [tunnelCount])
                      : tr('TÚNELES'),
                  () => _showTunnelsSheet(
                      context, state, state.activeSession?.id ?? '')),
              Hairline(),
              _menuTile(sheetCtx, Icons.open_in_full, tr('PANTALLA COMPLETA'),
                  () => state.setTerminalFullscreen(true)),
              Hairline(),
              _menuTile(sheetCtx, Icons.copy_all_outlined,
                  tr('COPIAR TODA LA SALIDA'), () => _copyBuffer(state)),
              Hairline(),
              _menuTile(sheetCtx, Icons.save_alt, tr('GUARDAR SALIDA EN ARCHIVO'),
                  () => _saveBuffer(state)),
              Hairline(),
              _menuTile(sheetCtx, Icons.help_outline, tr('ATAJOS Y GESTOS'),
                  () => showShortcutsHelpSheet(context)),
            ],
          ),
        ),
      ),
    );
  }

  /// Opens the saved-prompt library / composer; after inserting, focus goes
  /// back to the terminal so the user can review and submit.
  void _showPrompts(AppState state) {
    showPromptsSheet(context,
        onInserted: () => _terminalFocusNode.requestFocus());
  }

  /// Opens the Git changes / project panel (see [showGitPanel]). The toast goes
  /// to the root messenger, over the terminal, not the panel's own.
  void _showGitSlider(AppState state) =>
      showGitPanel(context, state, onToast: _toast);

  /// Lets the user pick a file/image; it's uploaded to the server over SFTP and
  /// its remote path inserted into the prompt for a TUI agent (Claude Code) to
  /// read. Surfaces the backend's outcome; an empty message means the user
  /// cancelled the picker.
  Future<void> _attach(AppState state) async {
    if (state.isAttaching) return; // An upload is already in flight.
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
      _toast(tr('No hay enlaces en el terminal'));
      return;
    }
    final recentFirst = urls.reversed.take(20).toList();

    showAdaptiveSheet(
      context,
      backgroundColor: AppColors.panel,
      maxWidth: 520,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(tr('ENLACES'),
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

  /// Toolbar entry point for the active session's tunnels. Badged with the
  /// number of live ones (red when one failed) so a broken tunnel is visible
  /// without opening anything.
  Widget _tunnelsButton(BuildContext context, AppState state) {
    final session = state.activeSession;
    if (session == null) return const SizedBox.shrink();
    final manager = context.watch<TunnelManager>();
    final active = manager.activeCount(session.id);
    final failed = manager.failedCount(session.id);
    final total = manager.forSession(session.id).length;

    return Stack(
      alignment: Alignment.center,
      children: [
        _toolbarIcon(Icons.swap_horiz, tr('Túneles'),
            () => _showTunnelsSheet(context, state, session.id)),
        if (total > 0)
          Positioned(
            right: 4,
            top: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              color: failed > 0 ? AppColors.danger : AppColors.accent,
              child: Text('${failed > 0 ? failed : active}',
                  style: AppText.mono(8, color: AppColors.ink)),
            ),
          ),
      ],
    );
  }

  /// Session-scoped tunnel list: the same rows as the tunnels screen plus a
  /// shortcut to add one to the session's profile.
  void _showTunnelsSheet(
      BuildContext context, AppState state, String sessionId) {
    showAdaptiveSheet(
      context,
      backgroundColor: AppColors.panel,
      isScrollControlled: true,
      heightFactor: 0.8,
      maxWidth: 520,
      builder: (sheetCtx) {
        final manager = sheetCtx.watch<TunnelManager>();
        final tunnels = manager.forSession(sessionId);
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                  child: Text(tr('TÚNELES DE ESTA SESIÓN'),
                      style: AppText.label(11,
                          color: AppColors.bone, spacing: 1.4)),
                ),
                Hairline(),
                if (tunnels.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      tr('Esta sesión no tiene túneles. Añade uno para abrir un servicio del servidor en este teléfono, usar el servidor como proxy o publicar algo tuyo en él.'),
                      style: AppText.body(12, color: AppColors.muted),
                    ),
                  ),
                for (var i = 0; i < tunnels.length; i++) ...[
                  if (i > 0) Hairline(),
                  TunnelRow(
                    sessionId: sessionId,
                    runtime: tunnels[i],
                    manager: manager,
                    state: state,
                  ),
                ],
                Hairline(),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: GhostButton(
                    label: tr('Añadir túnel'),
                    icon: Icons.add,
                    dense: true,
                    onPressed: () => _addTunnel(sheetCtx, state, sessionId),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Tunnels belong to the profile, so adding one from here saves the profile;
  /// AppState then applies it to the live session without reconnecting.
  Future<void> _addTunnel(
      BuildContext sheetCtx, AppState state, String sessionId) async {
    final session = state.sessions.firstWhere((s) => s.id == sessionId);
    final profileId = session.activeProfile?.id;
    ConnectionProfile? profile;
    for (final p in state.profiles) {
      if (p.id == profileId) profile = p;
    }
    if (profile == null) {
      _toast(tr('Esta sesión no tiene un perfil guardado donde guardar el túnel.'));
      return;
    }
    final created = await showTunnelEditor(sheetCtx);
    if (created == null) return;
    await state.saveProfile(
        profile.copyWith(tunnels: [...profile.tunnels, created]));
  }

  Widget _toolbarIcon(IconData icon, String tip, VoidCallback onTap,
      {bool active = false}) {
    final sz = (16 * context.read<AppState>().uiIconFactor).roundToDouble();
    return IconButton(
      icon: Icon(icon,
          color: active ? AppColors.accent : AppColors.muted, size: sz),
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
        return tr('CONECTANDO…');
      case ConnectionStatus.disconnected:
        return tr('DESCONECTADO');
    }
  }

  /// Compact button in the toolbar: shows the active session and opens the
  /// slide-up sessions panel.
  Widget _sessionSelector(BuildContext context, AppState state) {
    final active = state.activeSession;
    final profile = active?.activeProfile;
    final tint = profileTint(profile);
    // The glyph's *shape* is what carries connection status (spinner / dns /
    // ring), so its color is free to carry identity instead.
    final glyphColor = tint ?? AppColors.bone;
    return InkWell(
      onTap: () => _showSessionsSheet(context, state),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            active != null
                ? _statusGlyph(active, state,
                    size: 18 * state.uiIconFactor, color: glyphColor)
                : Icon(Icons.circle_outlined,
                    size: 18 * state.uiIconFactor, color: AppColors.bone),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                active?.name ?? tr('Sesión'),
                style: AppText.mono(13,
                    color: AppColors.bone, weight: FontWeight.w700),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (profile?.isProduction ?? false) ...[
              const SizedBox(width: 7),
              ProdBadge(tint: tint),
            ],
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
    showAdaptiveSheet(
      context,
      backgroundColor: AppColors.panel,
      isScrollControlled: true,
      maxWidth: 460,
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
                    Text(tr('SESIONES'),
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
              _menuTile(sheetCtx, Icons.dns_outlined, tr('CONECTAR POR SSH…'),
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
    final tint = profileTint(session.activeProfile);

    final row = Material(
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
                        if (session.activeProfile?.isProduction ?? false) ...[
                          const SizedBox(width: 8),
                          ProdBadge(tint: tint),
                        ],
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
              // 15px glyphs with 6px of padding are a 27px target: closing a
              // live SSH session by mis-tap is expensive, so the hit area is
              // grown to the touch minimum without changing how it looks.
              IconTapTarget(
                icon: Icons.edit_outlined,
                label: tr('Renombrar sesión'),
                size: 15,
                color: isActive ? AppColors.ink : AppColors.muted,
                onTap: () =>
                    _showRenameDialog(sheetCtx, state, index, session.name),
              ),
              IconTapTarget(
                icon: Icons.close,
                label: tr('Cerrar sesión'),
                size: 15,
                color: isActive ? AppColors.ink : AppColors.muted,
                onTap: () {
                  final profile = session.activeProfile;
                  state.closeSession(index);
                  ScaffoldMessenger.of(sheetCtx)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(SnackBar(
                      content: Text(tr('Sesión "{0}" cerrada', [session.name])),
                      action: profile == null
                          ? null
                          : SnackBarAction(
                              label: tr('Reconectar'),
                              onPressed: () => state.connectToSSH(profile),
                            ),
                    ));
                },
              ),
            ],
          ),
        ),
      ),
    );

    if (tint == null) return row;
    return Stack(
      children: [
        row,
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: Container(width: 3, color: tint),
        ),
      ],
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
        title: Text(tr('RENOMBRAR SESIÓN'),
            style: AppText.label(11, color: AppColors.bone, spacing: 1.4)),
        content: TextField(
          controller: controller,
          autofocus: true,
          enableIMEPersonalizedLearning: true,
          decoration: InputDecoration(labelText: tr('NOMBRE DE LA SESIÓN')),
          style: AppText.body(13),
        ),
        actions: [
          GhostButton(
            label: tr('Cancelar'),
            dense: true,
            onPressed: () => Navigator.of(context).pop(),
          ),
          InvertedButton(
            label: tr('Guardar'),
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
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
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
              Expanded(
                child: Text(label,
                    style:
                        AppText.label(10, color: AppColors.bone, spacing: 1.0)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Runs a named action key from the quick keyboard's ACCIONES layer.
  void _runKeyAction(AppState state, String action) {
    switch (action) {
      case 'agents':
        showAgentLauncher(context);
        break;
      case 'attach':
        _attach(state);
        break;
      case 'prompts':
        _showPrompts(state);
        break;
      case 'commit':
        _showGitSlider(state);
        break;
      case 'links':
        _showLinksSheet(state);
        break;
      case 'select':
        _startSelection(state);
        break;
    }
  }

  /// Starts a text selection without a long press — the `system:select`
  /// action, which can sit on a pad slot or on the ACCIONES layer.
  ///
  /// Copying used to have exactly one entrance, and that entrance was a
  /// gesture the touch pad competes for on the same pixels: hold still and the
  /// long press selects, hold and drift and the pad takes the pointer instead.
  /// The pad standing down for a selection ([JoystickGestureRecognizer]'s
  /// `isSelectionActive`) only helps once a selection already exists, so this
  /// is the way in that no gesture can take away.
  ///
  /// Fired from the pad it selects the word under the finger that armed it —
  /// the press the user already made is the pointing gesture. Fired from a key
  /// there is nothing to point at, so it takes the last non-empty line, which
  /// is the command or the error that is nearly always what gets copied.
  void _startSelection(AppState state, {Offset? atGlobal}) {
    final viewState = _terminalViewKey.currentState;
    if (viewState == null) return;
    final render = viewState.renderTerminal;
    if (!render.attached) return;

    final origin = _padOrigin;
    final at = atGlobal ?? (origin == null ? null : _fromPadSpace(origin));
    if (at != null) {
      render.selectWord(render.globalToLocal(at));
    } else {
      _selectLastLine(state);
    }
    if (_terminalController.selection == null) return;
    HapticFeedback.selectionClick();
  }

  /// Selects the whole of the last line that has anything on it.
  void _selectLastLine(AppState state) {
    final buffer = state.terminal.buffer;
    var y = buffer.lines.length - 1;
    while (y > 0 && buffer.lines[y].getText().trim().isEmpty) {
      y--;
    }
    // `getText()` drops empty cells, so its length is a lower bound on the
    // column the line ends at — good enough for an end anchor, which is
    // clamped to the viewport anyway.
    final text = buffer.lines[y].getText().trimRight();
    if (text.isEmpty) return;
    _terminalController.setSelection(
      buffer.createAnchor(0, y),
      buffer.createAnchor(
          math.min(text.length, state.terminal.viewWidth), y),
    );
  }

  /// Thin banner over the shortcut rows while a file is being uploaded to the
  /// server. Covers the paths that don't go through the ADJUNTAR key either —
  /// e.g. pasting an image from the keyboard.
  Widget _buildUploadBanner(AppState state) {
    final progress = state.attachProgress;
    final pct = progress == null ? '' : ' ${(progress * 100).round()}%';
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                    strokeWidth: 1.4, color: AppColors.bone),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tr('SUBIENDO {0}{1}', [state.attachName, pct]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.mono(10,
                      color: AppColors.bone,
                      weight: FontWeight.w500,
                      spacing: 0.6),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: progress,
            minHeight: 2,
            color: AppColors.bone,
            backgroundColor: AppColors.hairline,
          ),
        ],
      ),
    );
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
    // Scrolling the alternate buffer used to live here as a two-finger swipe.
    // It now rides on the same one-finger drag as the normal buffer (see the
    // patched TerminalScrollGestureHandler), so doing it here as well would
    // scroll twice — once per finger.
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
