import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import 'shell/app_commands.dart';

/// One row of the palette: a label, what it is, and what running it does.
class _PaletteEntry {
  final IconData icon;

  /// Already translated — entries are built per-open, not stored.
  final String label;

  /// Right-hand hint: a keyboard shortcut, a host, a path.
  final String? trailing;

  /// Group heading this belongs to.
  final String group;
  final VoidCallback run;

  const _PaletteEntry({
    required this.icon,
    required this.label,
    required this.group,
    required this.run,
    this.trailing,
  });
}

/// Everything the app can do, one search box away.
///
/// A terminal app accumulates capability faster than it accumulates room for
/// buttons: this one has ten screens, five quick-key layers, tunnels, git, a
/// prompt library and a backup system, most of it two or three taps deep. The
/// palette is the flat index over all of it — and it is the only navigation
/// surface that scales when the next feature lands.
///
/// It searches commands, saved servers, open sessions and pinned folders in one
/// list, because "conectar a prod" and "abrir el panel de git" are the same kind
/// of intention from the user's side.
Future<void> showCommandPalette(BuildContext context) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: tr('Cerrar'),
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (dialogCtx, _, _) => const _CommandPalette(),
    transitionBuilder: (_, anim, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
      child: child,
    ),
  );
}

class _CommandPalette extends StatefulWidget {
  const _CommandPalette();

  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();
  String _query = '';
  int _selected = 0;

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<_PaletteEntry> _entries(BuildContext context, AppState state) {
    final out = <_PaletteEntry>[];

    for (final command in appCommands()) {
      if (!command.isEnabled(state)) continue;
      // The palette can't offer to open itself.
      if (command.id == 'app.palette') continue;
      out.add(_PaletteEntry(
        icon: command.icon,
        label: tr(command.label),
        group: command.section.label,
        trailing: command.activator == null
            ? null
            : describeActivator(command.activator!),
        run: () => command.run(context, state),
      ));
    }

    for (final profile in state.profiles) {
      out.add(_PaletteEntry(
        icon: Icons.dns_outlined,
        label: tr('Conectar a {0}', [profile.name]),
        group: tr('Servidores'),
        trailing: '${profile.username}@${profile.host}',
        run: () => state.connectToSSH(profile),
      ));
    }

    for (var i = 0; i < state.sessions.length; i++) {
      final session = state.sessions[i];
      out.add(_PaletteEntry(
        icon: Icons.terminal_outlined,
        label: tr('Ir a la sesión {0}', [session.name]),
        group: tr('Sesiones abiertas'),
        trailing: i < 9 ? 'Alt+${i + 1}' : null,
        run: () {
          state.switchSession(i);
          state.setActiveTabIndex(1);
        },
      ));
    }

    for (final path in state.explorerBookmarks) {
      out.add(_PaletteEntry(
        icon: Icons.bookmark_outline,
        label: tr('Abrir {0}', [path]),
        group: tr('Carpetas fijadas'),
        run: () {
          state.changeDirectory(path);
          state.setActiveTabIndex(2);
        },
      ));
    }

    return out;
  }

  /// Subsequence match, the way every palette works: "gitp" finds "Panel de
  /// Git". Falls back to nothing clever — no fuzzy scoring — because ranking
  /// surprises are worse than a short list.
  bool _matches(String haystack, String needle) {
    if (needle.isEmpty) return true;
    final h = haystack.toLowerCase();
    final n = needle.toLowerCase();
    if (h.contains(n)) return true;
    var i = 0;
    for (final rune in n.runes) {
      i = h.indexOf(String.fromCharCode(rune), i);
      if (i < 0) return false;
      i++;
    }
    return true;
  }

  void _move(int delta, int count) {
    if (count == 0) return;
    setState(() {
      _selected = (_selected + delta) % count;
      if (_selected < 0) _selected += count;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final all = _entries(context, state);
    final visible = all
        .where((e) => _matches('${e.label} ${e.group} ${e.trailing ?? ''}', _query))
        .toList();
    if (_selected >= visible.length) _selected = 0;

    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).size.height * 0.08,
          left: 16,
          right: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620, maxHeight: 480),
          child: Material(
            color: AppColors.panel,
            shape: Border.all(color: AppColors.hairline, width: 1),
            child: Shortcuts(
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.arrowDown):
                    _PaletteMoveIntent(1),
                SingleActivator(LogicalKeyboardKey.arrowUp):
                    _PaletteMoveIntent(-1),
              },
              child: Actions(
                actions: {
                  _PaletteMoveIntent: CallbackAction<_PaletteMoveIntent>(
                    onInvoke: (intent) {
                      _move(intent.delta, visible.length);
                      return null;
                    },
                  ),
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _field(visible),
                    Container(height: 1, color: AppColors.hairline),
                    Flexible(
                      child: visible.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(28),
                              child: Text(tr('Nada coincide con «{0}».', [_query]),
                                  style:
                                      AppText.body(12, color: AppColors.muted)),
                            )
                          : ListView.builder(
                              controller: _scroll,
                              shrinkWrap: true,
                              itemCount: visible.length,
                              itemBuilder: (ctx, i) => _row(
                                  visible[i],
                                  i == _selected,
                                  i == 0 || visible[i].group != visible[i - 1].group),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(List<_PaletteEntry> visible) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          Icon(Icons.bolt_outlined, size: 16, color: AppColors.accent),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _controller,
              autofocus: true,
              style: AppText.body(14, color: AppColors.bone),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: tr('Escribe una acción, un servidor o una carpeta…'),
                hintStyle: AppText.body(14, color: AppColors.faint),
              ),
              onChanged: (v) => setState(() {
                _query = v;
                _selected = 0;
              }),
              onSubmitted: (_) {
                if (visible.isEmpty) return;
                _invoke(visible[_selected]);
              },
            ),
          ),
        ],
      ),
    );
  }

  void _invoke(_PaletteEntry entry) {
    // Pop first: several commands push their own sheet, and running them under
    // a dying route puts the sheet behind the palette's own barrier.
    Navigator.of(context).pop();
    entry.run();
  }

  Widget _row(_PaletteEntry entry, bool selected, bool startsGroup) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (startsGroup)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
            child: Text(entry.group.toUpperCase(),
                style: AppText.label(8, color: AppColors.faint, spacing: 1.4)),
          ),
        Material(
          color: selected ? AppColors.accent : Colors.transparent,
          child: InkWell(
            onTap: () => _invoke(entry),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              child: Row(
                children: [
                  Icon(entry.icon,
                      size: 15,
                      color: selected ? AppColors.ink : AppColors.muted),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(entry.label,
                        style: AppText.body(13,
                            color:
                                selected ? AppColors.ink : AppColors.bone),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                  if (entry.trailing != null) ...[
                    const SizedBox(width: 10),
                    Text(entry.trailing!,
                        style: AppText.mono(9,
                            color:
                                selected ? AppColors.ink : AppColors.faint)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PaletteMoveIntent extends Intent {
  final int delta;
  const _PaletteMoveIntent(this.delta);
}
