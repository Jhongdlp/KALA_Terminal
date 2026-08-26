import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/terminal_key_layer.dart';
import '../models/terminal_shortcut.dart';
import '../models/touch_pad.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/adaptive_sheet.dart';
import '../widgets/swiss.dart';

/// Picker for one slot of the terminal touch pad.
///
/// The catalogue is deliberately the *same* vocabulary as the quick keyboard —
/// the built-in key blocks, the `system:` actions and the user's own shortcuts
/// — rather than a second, parallel list of things a pad can do. Anything the
/// user has already taught the app to send can go on the pad.
Future<void> showPadSlotSheet(
  BuildContext context,
  AppState state,
  PadDirection direction,
) {
  final current = state.terminalPadConfig.slot(direction);

  void pick(BuildContext sheetCtx, TerminalShortcut? shortcut) {
    state.setTerminalPadSlot(direction, shortcut);
    Navigator.of(sheetCtx).pop();
  }

  /// Built-in keys arrive as raw bytes; the pad stores the escaped form so a
  /// slot round-trips through JSON as readable text.
  TerminalShortcut fromKey(QuickKey key) =>
      TerminalShortcut(label: key.label, value: padEscape(key.data ?? ''));

  return showAdaptiveSheet(
    context,
    backgroundColor: AppColors.panel,
    isScrollControlled: true,
    heightFactor: 0.8,
    maxWidth: 520,
    builder: (sheetCtx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Text(tr('RANURA {0}', [tr(direction.label)]),
                    style:
                        AppText.label(11, color: AppColors.bone, spacing: 1.4)),
                const Spacer(),
                if (current != null)
                  Text(tr(current.label),
                      style: AppText.mono(11, color: AppColors.muted)),
              ],
            ),
          ),
          Hairline(),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                _row(
                  label: tr('VACÍO'),
                  hint: tr('La ranura no envía nada.'),
                  onTap: () => pick(sheetCtx, null),
                ),
                _group(tr('FLECHAS'), [
                  for (final k in kArrowKeys)
                    _KeyOption(k.label, () => pick(sheetCtx, fromKey(k))),
                ]),
                _group(tr('BÁSICAS'), [
                  _KeyOption('ESC',
                      () => pick(sheetCtx, TerminalShortcut(label: 'ESC', value: r'\x1b'))),
                  _KeyOption('TAB',
                      () => pick(sheetCtx, TerminalShortcut(label: 'TAB', value: r'\t'))),
                  _KeyOption('⏎',
                      () => pick(sheetCtx, TerminalShortcut(label: '⏎', value: r'\r'))),
                  _KeyOption('⌫',
                      () => pick(sheetCtx, TerminalShortcut(label: '⌫', value: r'\x7f'))),
                ]),
                _group(tr('CONTROL'), [
                  _KeyOption('^C',
                      () => pick(sheetCtx, TerminalShortcut(label: '^C', value: r'\x03'))),
                  for (final k in kControlKeys)
                    _KeyOption(k.label, () => pick(sheetCtx, fromKey(k))),
                ]),
                _group(tr('NAVEGACIÓN'), [
                  for (final k in kNavKeys)
                    if (k.data != null)
                      _KeyOption(k.label, () => pick(sheetCtx, fromKey(k))),
                ]),
                _group(tr('FUNCIÓN'), [
                  for (final k in kFnKeys)
                    _KeyOption(k.label, () => pick(sheetCtx, fromKey(k))),
                ]),
                if (state.actionShortcuts.isNotEmpty)
                  _group(tr('ACCIONES'), [
                    for (final s in state.actionShortcuts)
                      _KeyOption(tr(s.label), () => pick(sheetCtx, s)),
                  ]),
                if (state.myShortcuts.isNotEmpty)
                  _group(tr('MIS ATAJOS'), [
                    for (final s in state.myShortcuts)
                      _KeyOption(tr(s.label), () => pick(sheetCtx, s)),
                  ]),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

Widget _row({
  required String label,
  required String hint,
  required VoidCallback onTap,
}) {
  return Material(
    type: MaterialType.transparency,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Text(label,
                style: AppText.label(10, color: AppColors.bone, spacing: 1.0)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(hint,
                  textAlign: TextAlign.right,
                  style: AppText.label(8.5, color: AppColors.faint)),
            ),
          ],
        ),
      ),
    ),
  );
}

/// One block of keys, drawn as a wrap of chips: a list row per key would make
/// this sheet eighty rows long for what is really a keyboard.
Widget _group(String title, List<_KeyOption> options) {
  if (options.isEmpty) return const SizedBox.shrink();
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Hairline(),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Text(title, style: AppText.label(9, color: AppColors.muted)),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final option in options)
              Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: option.onTap,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 56),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 10),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.hairline),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(option.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.mono(12, color: AppColors.bone)),
                  ),
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

class _KeyOption {
  const _KeyOption(this.label, this.onTap);
  final String label;
  final VoidCallback onTap;
}
