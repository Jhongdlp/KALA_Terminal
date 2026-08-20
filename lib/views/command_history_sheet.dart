import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/adaptive_sheet.dart';
import '../widgets/swiss.dart';
import '../widgets/tap_target.dart';

/// The last commands sent to a shell, newest first.
///
/// Typing on a phone is the expensive part of using a terminal from one, and
/// the shell's own history (up-arrow) only reaches the session it was typed in
/// — reconnect, or switch to another server, and it's gone. This list is the
/// app's, so it crosses both.
///
/// Tap inserts the command **without** running it: the point is to edit the
/// path or the flag that changed, and a list that auto-executed would be one
/// mis-tap away from `rm -rf` on the wrong box. [onInserted] refocuses the
/// terminal so the edit can start immediately.
void showCommandHistorySheet(BuildContext context, {VoidCallback? onInserted}) {
  showAdaptiveSheet(
    context,
    backgroundColor: AppColors.panel,
    isScrollControlled: true,
    maxWidth: 560,
    builder: (sheetCtx) => _CommandHistorySheet(onInserted: onInserted),
  );
}

class _CommandHistorySheet extends StatefulWidget {
  final VoidCallback? onInserted;
  const _CommandHistorySheet({this.onInserted});

  @override
  State<_CommandHistorySheet> createState() => _CommandHistorySheetState();
}

class _CommandHistorySheetState extends State<_CommandHistorySheet> {
  final TextEditingController _filterController = TextEditingController();
  String _filter = '';

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final all = state.commandHistory;
    final q = _filter.trim().toLowerCase();
    final visible =
        q.isEmpty ? all : all.where((c) => c.toLowerCase().contains(q)).toList();

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
            child: Row(
              children: [
                Text(tr('HISTORIAL'),
                    style:
                        AppText.label(11, color: AppColors.bone, spacing: 1.4)),
                const Spacer(),
                Text('${all.length}',
                    style: AppText.mono(10, color: AppColors.muted)),
                const SizedBox(width: 4),
                if (all.isNotEmpty)
                  IconTapTarget(
                    icon: Icons.delete_sweep_outlined,
                    label: tr('Borrar historial'),
                    size: 16,
                    min: 40,
                    color: AppColors.muted,
                    onTap: () => _confirmClear(context, state),
                  ),
              ],
            ),
          ),
          if (all.length > 8) _filterField(),
          Hairline(),
          Flexible(
            child: all.isEmpty
                ? _empty(state)
                : visible.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(28),
                        child: Text(
                            tr('Ningún comando coincide con «{0}».', [_filter]),
                            textAlign: TextAlign.center,
                            style: AppText.body(12, color: AppColors.muted)),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: visible.length,
                        separatorBuilder: (_, _) => Hairline(),
                        itemBuilder: (ctx, i) => _row(ctx, state, visible[i]),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _filterField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Row(
        children: [
          Icon(Icons.search, size: 14, color: AppColors.muted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _filterController,
              onChanged: (v) => setState(() => _filter = v),
              style: AppText.mono(12, color: AppColors.bone),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: tr('Filtrar comandos…'),
                hintStyle: AppText.body(12, color: AppColors.faint),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty(AppState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      child: Column(
        children: [
          Icon(Icons.history, size: 30, color: AppColors.muted),
          const SizedBox(height: 14),
          Text(
            state.commandHistoryEnabled
                ? tr('Aún no hay comandos. Los que envíes a un shell aparecerán aquí.')
                : tr('El historial está desactivado en Ajustes → Terminal.'),
            textAlign: TextAlign.center,
            style: AppText.body(12, color: AppColors.muted),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext ctx, AppState state, String command) {
    return InkWell(
      onTap: () {
        state.insertPromptText(command);
        Navigator.of(ctx).pop();
        widget.onInserted?.call();
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(command,
                  style: AppText.mono(12, color: AppColors.bone),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            IconTapTarget(
              icon: Icons.copy_outlined,
              label: tr('Copiar comando'),
              size: 14,
              min: 40,
              color: AppColors.muted,
              onTap: () {
                Clipboard.setData(ClipboardData(text: command));
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text(tr('Comando copiado'))),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmClear(BuildContext context, AppState state) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text(tr('BORRAR HISTORIAL'),
            style: AppText.label(11, color: AppColors.bone, spacing: 1.4)),
        content: Text(
            tr('Se borrarán los {0} comandos guardados. No afecta al historial del propio servidor.',
                [state.commandHistory.length]),
            style: AppText.body(12, color: AppColors.muted)),
        actions: [
          GhostButton(
              label: tr('Cancelar'),
              dense: true,
              onPressed: () => Navigator.of(ctx).pop()),
          GhostButton(
            label: tr('Borrar'),
            dense: true,
            danger: true,
            onPressed: () {
              state.clearCommandHistory();
              Navigator.of(ctx).pop();
            },
          ),
        ],
      ),
    );
  }
}
