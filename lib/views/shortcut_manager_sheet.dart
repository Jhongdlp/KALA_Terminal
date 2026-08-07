import 'package:flutter/material.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/adaptive_sheet.dart';
import '../models/terminal_shortcut.dart';
import '../widgets/swiss.dart';
import '../l10n/l10n.dart';

class ShortcutManagerSheet {
  static void show(BuildContext context, AppState state) {
    showAdaptiveSheet(
      context,
      backgroundColor: AppColors.panel,
      isScrollControlled: true,
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (dialogCtx, setSheetState) {
            return Container(
              padding: EdgeInsets.fromLTRB(
                  16, 16, 16, MediaQuery.of(dialogCtx).viewInsets.bottom + 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(tr('PERSONALIZAR ATAJOS'),
                          style: AppText.mono(12,
                              color: AppColors.bone, weight: FontWeight.w700)),
                      IconButton(
                        icon: Icon(Icons.add, color: AppColors.accent),
                        onPressed: () => _showAddEditShortcutDialog(
                            dialogCtx, state, null, (newShortcut) {
                          state.addCustomShortcut(newShortcut);
                          setSheetState(() {});
                        }),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(tr('ALTO TECLAS'),
                          style: AppText.mono(9, color: AppColors.muted)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Slider(
                          value: state.shortcutKeyHeight,
                          min: 20.0,
                          max: 45.0,
                          divisions: 25,
                          label: '${state.shortcutKeyHeight.round()}px',
                          activeColor: AppColors.accent,
                          inactiveColor: AppColors.hairline,
                          onChanged: (val) {
                            state.setShortcutKeyHeight(val);
                            setSheetState(() {});
                          },
                        ),
                      ),
                      Text('${state.shortcutKeyHeight.round()}px',
                          style: AppText.mono(9, color: AppColors.bone)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text(tr('ANCHO TECLAS'),
                          style: AppText.mono(9, color: AppColors.muted)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Slider(
                          value: state.shortcutKeyWidth,
                          min: 20.0,
                          max: 120.0,
                          divisions: 100,
                          label: '${state.shortcutKeyWidth.round()}px',
                          activeColor: AppColors.accent,
                          inactiveColor: AppColors.hairline,
                          onChanged: (val) {
                            state.setShortcutKeyWidth(val);
                            setSheetState(() {});
                          },
                        ),
                      ),
                      Text('${state.shortcutKeyWidth.round()}px',
                          style: AppText.mono(9, color: AppColors.bone)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(dialogCtx).size.height * 0.45,
                    ),
                    child: state.customShortcuts.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: Center(
                              child: Text(tr('No hay atajos personalizados'),
                                  style: AppText.body(13,
                                      color: AppColors.muted)),
                            ),
                          )
                        : ReorderableListView.builder(
                            shrinkWrap: true,
                            itemCount: state.customShortcuts.length,
                            // ignore: deprecated_member_use
                            onReorder: (oldIndex, newIndex) {
                              state.reorderCustomShortcuts(oldIndex, newIndex);
                              setSheetState(() {});
                            },
                            itemBuilder: (itemCtx, index) {
                              final shortcut = state.customShortcuts[index];
                              final isSystem =
                                  shortcut.value.startsWith('system:');
                              return ListTile(
                                // Identity, not position: a key built from the
                                // index travels with the slot instead of the
                                // row, so after a drag the list shows the item
                                // that used to be there.
                                key: ObjectKey(shortcut),
                                contentPadding: EdgeInsets.zero,
                                leading: Checkbox(
                                  activeColor: AppColors.accent,
                                  checkColor: AppColors.ink,
                                  side: BorderSide(color: AppColors.muted),
                                  value: shortcut.enabled,
                                  onChanged: (bool? val) {
                                    final updated = TerminalShortcut(
                                      label: shortcut.label,
                                      value: shortcut.value,
                                      enabled: val ?? true,
                                    );
                                    state.updateCustomShortcut(index, updated);
                                    setSheetState(() {});
                                  },
                                ),
                                title: Text(tr(shortcut.label),
                                    style: AppText.mono(12,
                                        color: AppColors.bone,
                                        weight: FontWeight.w600)),
                                subtitle: Text(
                                  isSystem
                                      ? tr('Acción del sistema')
                                      : shortcut.value,
                                  style:
                                      AppText.mono(10, color: AppColors.muted),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (!isSystem) ...[
                                      IconButton(
                                        icon: Icon(Icons.edit,
                                            size: 16, color: AppColors.bone),
                                        onPressed: () =>
                                            _showAddEditShortcutDialog(
                                                dialogCtx, state, shortcut,
                                                (updatedShortcut) {
                                          state.updateCustomShortcut(
                                              index, updatedShortcut);
                                          setSheetState(() {});
                                        }),
                                      ),
                                      IconButton(
                                        icon: Icon(Icons.delete_outline,
                                            size: 16, color: Colors.redAccent),
                                        onPressed: () {
                                          state.deleteCustomShortcut(index);
                                          setSheetState(() {});
                                        },
                                      ),
                                    ],
                                    Icon(Icons.drag_handle,
                                        color: AppColors.muted),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      GhostButton(
                        label: tr('Restablecer'),
                        dense: true,
                        onPressed: () {
                          state.setCustomShortcuts(state.getDefaultShortcuts());
                          setSheetState(() {});
                        },
                      ),
                      const SizedBox(width: 10),
                      InvertedButton(
                        label: tr('Cerrar'),
                        dense: true,
                        onPressed: () => Navigator.of(sheetCtx).pop(),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  static void _showAddEditShortcutDialog(
      BuildContext context,
      AppState state,
      TerminalShortcut? existing,
      void Function(TerminalShortcut shortcut) onSave) {
    final labelController = TextEditingController(text: existing?.label ?? '');
    final valueController = TextEditingController(text: existing?.value ?? '');

    showDialog(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          backgroundColor: AppColors.panel,
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(4))),
          title: Text(existing == null ? tr('AGREGAR ATAJO') : tr('EDITAR ATAJO'),
              style: AppText.mono(11,
                  color: AppColors.bone, weight: FontWeight.w700)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: labelController,
                  autofocus: true,
                  enableIMEPersonalizedLearning: true,
                  decoration: InputDecoration(
                    labelText: tr('ETIQUETA (ej: ls, ^C, ~)'),
                    labelStyle: TextStyle(color: AppColors.muted),
                  ),
                  style: AppText.body(13),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: valueController,
                  enableIMEPersonalizedLearning: true,
                  decoration: InputDecoration(
                    labelText: tr('VALOR A ENVIAR (ej: ls\\n, \\x03, ~)'),
                    labelStyle: TextStyle(color: AppColors.muted),
                  ),
                  style: AppText.body(13),
                ),
                const SizedBox(height: 16),
                Text(tr('Atajos rápidos de control:'),
                    style: AppText.mono(8.5, color: AppColors.muted)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _dialogHelperButton(
                        dialogCtx, 'Tab', r'\t', valueController),
                    _dialogHelperButton(
                        dialogCtx, 'Esc', r'\x1b', valueController),
                    _dialogHelperButton(
                        dialogCtx, 'Enter', r'\n', valueController),
                    _dialogHelperButton(
                        dialogCtx, 'Ctrl+C', r'\x03', valueController),
                    _dialogHelperButton(
                        dialogCtx, 'Ctrl+D', r'\x04', valueController),
                    _dialogHelperButton(
                        dialogCtx, 'Ctrl+A', r'\x01', valueController),
                    _dialogHelperButton(
                        dialogCtx, 'F1', r'\x1b[11~', valueController),
                    _dialogHelperButton(
                        dialogCtx, 'F2', r'\x1b[12~', valueController),
                    _dialogHelperButton(
                        dialogCtx, 'F3', r'\x1b[13~', valueController),
                    _dialogHelperButton(
                        dialogCtx, 'F4', r'\x1b[14~', valueController),
                    _dialogHelperButton(
                        dialogCtx, 'F5', r'\x1b[15~', valueController),
                    _dialogHelperButton(
                        dialogCtx, tr('Re Pág'), r'\x1b[5~', valueController),
                    _dialogHelperButton(
                        dialogCtx, tr('Av Pág'), r'\x1b[6~', valueController),
                    _dialogHelperButton(
                        dialogCtx, tr('Inicio'), r'\x1b[H', valueController),
                    _dialogHelperButton(
                        dialogCtx, tr('Fin'), r'\x1b[F', valueController),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            GhostButton(
              label: tr('Cancelar'),
              dense: true,
              onPressed: () => Navigator.of(dialogCtx).pop(),
            ),
            InvertedButton(
              label: tr('Guardar'),
              dense: true,
              onPressed: () {
                if (labelController.text.isNotEmpty &&
                    valueController.text.isNotEmpty) {
                  onSave(TerminalShortcut(
                    label: labelController.text,
                    value: valueController.text,
                    enabled: existing?.enabled ?? true,
                  ));
                  Navigator.of(dialogCtx).pop();
                }
              },
            ),
          ],
        );
      },
    );
  }

  static Widget _dialogHelperButton(BuildContext context, String label,
      String val, TextEditingController controller) {
    return InkWell(
      onTap: () {
        controller.text = val;
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.hairline, width: 1),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Text(
          label,
          style: AppText.mono(8.5, color: AppColors.bone),
        ),
      ),
    );
  }
}
