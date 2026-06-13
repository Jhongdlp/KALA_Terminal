import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';

/// Warp-style "smart" command bar that sits above the quick-keys strip.
///
/// The user types a command here instead of straight into the PTY. As they
/// type it offers:
///  * inline ghost text (fish-style autosuggestion) for the best history match,
///    accepted with TAB or the ⇥ button;
///  * a dropdown of suggestions blended from the persisted command history,
///    a set of common commands, and filename completion drawn from the
///    explorer's already-loaded directory listing ([AppState.files]).
///
/// Submitting (Enter / send button) writes the whole line to the active shell
/// via [AppState.submitCommand], which also records it in history. Everything
/// here is local — no network, no AI.
class CommandBar extends StatefulWidget {
  const CommandBar({super.key});

  @override
  State<CommandBar> createState() => _CommandBarState();
}

class _CommandBarState extends State<CommandBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  // Shared text metrics so the ghost overlay lines up pixel-for-pixel with the
  // TextField's own glyphs (same family, size, padding).
  static const EdgeInsets _fieldPadding = EdgeInsets.symmetric(vertical: 9);
  static const double _fontSize = 13;

  /// A small, curated set of frequently-typed commands. Entries ending in a
  /// space expect an argument (so the cursor lands ready to type it).
  static const List<String> _commonCommands = [
    'ls -la', 'cd ', 'cd ..', 'pwd', 'clear', 'cat ', 'less ', 'tail -f ',
    'mkdir ', 'rm ', 'rm -rf ', 'cp ', 'mv ', 'touch ', 'chmod +x ',
    'grep -r ', 'find . -name ', 'ps aux', 'kill ', 'top', 'htop',
    'df -h', 'du -sh ', 'free -h', 'tar -xzf ', 'tar -czf ',
    'curl ', 'wget ', 'ping ', 'ssh ', 'nano ', 'vim ', 'export ',
    'git status', 'git add .', 'git commit -m "', 'git push', 'git pull',
    'git log --oneline', 'git diff', 'git checkout ', 'git branch',
    'docker ps', 'docker images', 'docker compose up -d',
    'npm install', 'npm run ', 'pip install ', 'python3 ',
    'flutter run', 'flutter pub get', 'sudo ', 'apt install ',
    'systemctl status ',
  ];

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _focusNode.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  // ---- Suggestion engine ----------------------------------------------------

  /// Builds the ordered suggestion list for the current input. Order: history
  /// prefix matches, common-command prefix matches, filename completions, then
  /// history "contains" matches as a fallback. De-duplicated, capped.
  List<String> _suggestions(AppState state) {
    final text = _controller.text;
    final seen = <String>{};
    final results = <String>[];

    void addAll(Iterable<String> items) {
      for (final item in items) {
        if (item != text && seen.add(item)) results.add(item);
      }
    }

    // Empty field → favorites first, then the most recent history.
    if (text.trim().isEmpty) {
      addAll(state.favoriteCommands);
      addAll(state.commandHistory);
      return results.take(7).toList();
    }

    final lower = text.toLowerCase();

    addAll(state.favoriteCommands
        .where((f) => f.toLowerCase().startsWith(lower)));
    addAll(state.commandHistory
        .where((h) => h.toLowerCase().startsWith(lower)));
    addAll(_commonCommands.where((c) => c.startsWith(lower)));
    addAll(_fileCompletions(state, text));
    addAll(state.commandHistory
        .where((h) => h.toLowerCase().contains(lower)));

    return results.take(7).toList();
  }

  /// Completes the last whitespace-separated token against the names in the
  /// explorer's current directory. Only basenames in the current dir are
  /// completed (tokens containing `/` are skipped to avoid wrong guesses).
  List<String> _fileCompletions(AppState state, String text) {
    final lastSpace = text.lastIndexOf(' ');
    final prefix = lastSpace >= 0 ? text.substring(0, lastSpace + 1) : '';
    final token = lastSpace >= 0 ? text.substring(lastSpace + 1) : text;
    if (token.isEmpty || token.contains('/') || token.startsWith('-')) {
      return const [];
    }

    final lowerToken = token.toLowerCase();
    final out = <String>[];
    for (final file in state.files) {
      if (file.name.toLowerCase().startsWith(lowerToken)) {
        final name = file.name.contains(' ') ? '"${file.name}"' : file.name;
        out.add('$prefix$name${file.isDirectory ? '/' : ''}');
      }
    }
    return out;
  }

  /// The ghost completion: the tail of the first suggestion that continues the
  /// exact typed text. Empty when nothing extends the input.
  String _ghostFor(List<String> suggestions, String text) {
    if (text.isEmpty) return '';
    for (final s in suggestions) {
      if (s.length > text.length &&
          s.toLowerCase().startsWith(text.toLowerCase())) {
        return s.substring(text.length);
      }
    }
    return '';
  }

  // ---- Actions --------------------------------------------------------------

  void _fill(String value) {
    _controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _focusNode.requestFocus();
  }

  void _acceptGhost(String ghost) => _fill(_controller.text + ghost);

  void _run(AppState state) {
    final command = _controller.text;
    if (command.trim().isEmpty) return;
    state.submitCommand(command);
    _controller.clear();
    _focusNode.requestFocus(); // keep the soft keyboard up for the next command
  }

  KeyEventResult _handleKey(KeyEvent event, String ghost) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // TAB accepts the ghost suggestion instead of inserting a tab character.
    if (event.logicalKey == LogicalKeyboardKey.tab && ghost.isNotEmpty) {
      _acceptGhost(ghost);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---- UI -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    final text = _controller.text;
    final suggestions = _suggestions(state);
    final ghost = _ghostFor(suggestions, text);
    final showDropdown = _focusNode.hasFocus && suggestions.isNotEmpty;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.ink,
        border: Border(top: BorderSide(color: AppColors.hairline, width: 1)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showDropdown) _dropdown(state, suggestions, text),
          _inputRow(state, ghost),
        ],
      ),
    );
  }

  Widget _dropdown(AppState state, List<String> suggestions, String text) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 168),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.hairline, width: 1)),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: suggestions.length,
        itemBuilder: (_, i) => _suggestionRow(state, suggestions[i], text),
      ),
    );
  }

  Widget _suggestionRow(AppState state, String suggestion, String text) {
    // Highlight the matched portion so the user sees why it surfaced.
    final lower = suggestion.toLowerCase();
    final matchStart = text.isEmpty ? -1 : lower.indexOf(text.toLowerCase());
    final spans = <TextSpan>[];
    if (matchStart < 0) {
      spans.add(TextSpan(text: suggestion));
    } else {
      spans.add(TextSpan(text: suggestion.substring(0, matchStart)));
      spans.add(TextSpan(
        text: suggestion.substring(matchStart, matchStart + text.length),
        style: TextStyle(color: AppColors.bone, fontWeight: FontWeight.w700),
      ));
      spans.add(TextSpan(text: suggestion.substring(matchStart + text.length)));
    }

    final isFavorite = state.isFavoriteCommand(suggestion);
    return InkWell(
      onTap: () => _fill(suggestion),
      // Long-press pins/unpins the command as a favorite (favorites rank
      // first in the dropdown and survive history pruning).
      onLongPress: () {
        state.toggleFavoriteCommand(suggestion);
        _toast(isFavorite ? 'Quitado de favoritos' : 'Añadido a favoritos');
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            Icon(isFavorite ? Icons.star : Icons.chevron_right,
                size: 13,
                color: isFavorite ? AppColors.bone : AppColors.faint),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(
                  style: AppText.mono(11, color: AppColors.muted),
                  children: spans,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
        duration: const Duration(milliseconds: 1200),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _inputRow(AppState state, String ghost) {
    final text = _controller.text.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 6, 2),
      child: Row(
        children: [
          Text('›',
              style: AppText.mono(16, color: AppColors.muted, weight: FontWeight.w700)),
          const SizedBox(width: 8),
          Expanded(child: _fieldWithGhost(state, ghost)),
          if (text.isNotEmpty)
            _iconBtn(
              state.isFavoriteCommand(text)
                  ? Icons.star
                  : Icons.star_border,
              'Guardar como favorito',
              () {
                state.toggleFavoriteCommand(text);
                setState(() {});
              },
            ),
          if (ghost.isNotEmpty)
            _iconBtn(Icons.keyboard_tab, 'Aceptar sugerencia (TAB)',
                () => _acceptGhost(ghost)),
          _iconBtn(Icons.arrow_upward, 'Ejecutar', () => _run(state),
              inverted: _controller.text.trim().isNotEmpty),
        ],
      ),
    );
  }

  /// The TextField with the ghost completion painted behind it. Both layers use
  /// identical style + padding so the ghost tail aligns with the typed glyphs.
  Widget _fieldWithGhost(AppState state, String ghost) {
    final baseStyle = AppText.mono(_fontSize, color: AppColors.bone);

    return Stack(
      children: [
        if (ghost.isNotEmpty)
          Positioned.fill(
            child: IgnorePointer(
              child: Padding(
                padding: _fieldPadding,
                child: Text.rich(
                  TextSpan(children: [
                    // The typed part is invisible (the real field paints it);
                    // only the ghost tail shows through.
                    TextSpan(
                        text: _controller.text,
                        style: baseStyle.copyWith(color: Colors.transparent)),
                    TextSpan(
                        text: ghost,
                        style: baseStyle.copyWith(color: AppColors.faint)),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                ),
              ),
            ),
          ),
        Focus(
          onKeyEvent: (_, event) => _handleKey(event, ghost),
          child: TextField(
            controller: _controller,
            focusNode: _focusNode,
            style: baseStyle,
            cursorColor: AppColors.bone,
            cursorWidth: 1.5,
            maxLines: 1,
            textInputAction: TextInputAction.go,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.text,
            onSubmitted: (_) => _run(state),
            decoration: InputDecoration(
              isCollapsed: true,
              contentPadding: _fieldPadding,
              border: InputBorder.none,
              filled: false,
              hintText: 'Escribe un comando…',
              hintStyle: AppText.mono(_fontSize, color: AppColors.faint),
            ),
          ),
        ),
      ],
    );
  }

  Widget _iconBtn(IconData icon, String tip, VoidCallback onTap,
      {bool inverted = false}) {
    final sz = (16 * context.read<AppState>().uiIconFactor).roundToDouble();
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Material(
        color: inverted ? AppColors.bone : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Tooltip(
            message: tip,
            child: Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: inverted
                  ? null
                  : BoxDecoration(
                      border: Border.all(color: AppColors.hairline, width: 1)),
              child: Icon(icon,
                  size: sz,
                  color: inverted ? AppColors.ink : AppColors.muted),
            ),
          ),
        ),
      ),
    );
  }
}
