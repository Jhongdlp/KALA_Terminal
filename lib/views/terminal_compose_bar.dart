import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../l10n/l10n.dart';

/// A real text field that lines up above the quick keys, for dictation and for
/// anything else that needs the soft keyboard to behave like a soft keyboard.
///
/// The terminal itself cannot offer this. `CustomTextEdit` — the shim xterm
/// attaches the IME to — deliberately keeps no text: it hands each keystroke
/// straight to the shell and then wipes its own buffer. So Gboard has no words
/// to predict from, nothing to autocorrect, and, worst of all, dictation gets
/// cut short every time the buffer is wiped out from under a running voice
/// session.
///
/// Here the words stay in a normal [TextField] until the user is done, so the
/// keyboard has the full context it wants: the suggestion strip, "fix the last
/// word", swipe typing and continuous dictation all work. Only when the line is
/// sent does it reach the shell — as a paste, so a TUI agent sees one insert
/// rather than a burst of keystrokes.
class TerminalComposeBar extends StatefulWidget {
  const TerminalComposeBar({
    super.key,
    required this.state,
    required this.onClose,
  });

  final AppState state;

  /// Called when the user dismisses the bar from its own close button.
  final VoidCallback onClose;

  @override
  State<TerminalComposeBar> createState() => _TerminalComposeBarState();
}

class _TerminalComposeBarState extends State<TerminalComposeBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    // Opening the bar is the user asking for the keyboard.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final hasText = _controller.text.trim().isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
  }

  /// Sends the composed text to the shell. [execute] appends the Enter that
  /// actually runs it (or submits the agent's prompt).
  void _send({required bool execute}) {
    final text = _controller.text;
    if (text.isEmpty) return;
    widget.state.insertPromptText(text);
    if (execute) widget.state.sendTerminalInput('\r');
    _controller.clear();
    // Keep the keyboard up: dictating one line usually means dictating another.
    _focusNode.requestFocus();
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border(top: BorderSide(color: AppColors.hairline, width: 1)),
      ),
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              // Everything the terminal shim has to switch off, on: this is the
              // whole point of the bar.
              autocorrect: true,
              enableSuggestions: true,
              enableIMEPersonalizedLearning: true,
              // Explicit, so a multi-line field doesn't get forced onto the
              // multiline keyboard — that would turn the action key into a
              // newline and there would be no way to send from the keyboard.
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.send,
              textCapitalization: TextCapitalization.none,
              minLines: 1,
              maxLines: 4,
              onSubmitted: (_) => _send(execute: true),
              style: AppText.mono(13, color: AppColors.bone),
              cursorColor: AppColors.accent,
              cursorWidth: 2,
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: AppColors.ink,
                hintText: tr('Dicta o escribe una línea…'),
                hintStyle: AppText.body(12, color: AppColors.faint),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                border: _border(AppColors.hairline),
                enabledBorder: _border(AppColors.hairline),
                focusedBorder: _border(AppColors.accent),
              ),
            ),
          ),
          _action(
            icon: Icons.subdirectory_arrow_left,
            tip: tr('Insertar sin ejecutar'),
            enabled: _hasText,
            onTap: () => _send(execute: false),
          ),
          _action(
            icon: Icons.send,
            tip: tr('Enviar y ejecutar'),
            enabled: _hasText,
            accent: true,
            onTap: () => _send(execute: true),
          ),
          _action(
            icon: Icons.close,
            tip: tr('Cerrar barra de dictado'),
            enabled: true,
            onTap: widget.onClose,
          ),
        ],
      ),
    );
  }

  OutlineInputBorder _border(Color color) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: BorderSide(color: color, width: 1),
      );

  Widget _action({
    required IconData icon,
    required String tip,
    required bool enabled,
    required VoidCallback onTap,
    bool accent = false,
  }) {
    final color = !enabled
        ? AppColors.faint
        : accent
            ? AppColors.accent
            : AppColors.muted;
    return IconButton(
      icon: Icon(icon, size: 18, color: color),
      onPressed: enabled ? onTap : null,
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 38, minHeight: 40),
    );
  }
}
