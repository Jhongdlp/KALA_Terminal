import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/color_picker_dialog.dart';
import '../widgets/swiss.dart';
import 'shortcut_manager_sheet.dart';
import '../l10n/l10n.dart';

/// Screen dedicated to personalizing the application aesthetics, terminal styling,
/// and keyboard shortcuts layout.
class PersonalizationTab extends StatelessWidget {
  const PersonalizationTab({super.key});

  @override
  Widget build(BuildContext context) {
    final themeChoice =
        context.select<AppState, AppThemeChoice>((s) => s.themeChoice);
    final iconScale =
        context.select<AppState, AppIconScale>((s) => s.iconScale);
    final terminalFontSize =
        context.select<AppState, double>((s) => s.terminalFontSize);
    final terminalScheme =
        context.select<AppState, String>((s) => s.terminalScheme);
    final accentColorHex =
        context.select<AppState, String>((s) => s.accentColorHex);
    final terminalGestureDeadzone =
        context.select<AppState, double>((s) => s.terminalGestureDeadzone);
    // Selected as a joined string: `customAccentColors` hands back a fresh list
    // every call, so a List selector would never compare equal.
    final customAccentJoined = context
        .select<AppState, String>((s) => s.customAccentColors.join(','));
    final customAccentColors =
        customAccentJoined.isEmpty ? <String>[] : customAccentJoined.split(',');
    final monoFontChoice =
        context.select<AppState, String>((s) => s.monoFontChoice);
    // Selected, not read: without a dependency the selector keeps highlighting
    // the previous layout after a tap, even though the terminal already moved.
    final shortcutLayout =
        context.select<AppState, TerminalShortcutLayout>((s) => s.shortcutLayout);
    final state = context.read<AppState>();

    return ContentColumn(
      color: AppColors.ink,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          ScreenHeader(tr('Personalizar'), eyebrow: tr('Apariencia y Terminal')),

          // ---- Appearance ------------------------------------------------
          SwissPanel(
            title: tr('Apariencia'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
                child: Text(tr('TEMA DE LA APLICACIÓN'),
                    style: AppText.label(9, color: AppColors.muted)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                child: _ThemeSelector(
                  value: themeChoice,
                  onChanged: state.setThemeChoice,
                ),
              ),
              Hairline(),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
                child: Text(tr('TAMAÑO DE ICONOS'),
                    style: AppText.label(9, color: AppColors.muted)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                child: _IconScaleSelector(
                  value: iconScale,
                  onChanged: state.setIconScale,
                ),
              ),
              Hairline(),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
                child: Text(tr('COLOR DE ACENTO (MONOCHROME-PLUS)'),
                    style: AppText.label(9, color: AppColors.muted)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                child: _AccentColorSelector(
                  value: accentColorHex,
                  customColors: customAccentColors,
                  onChanged: state.setAccentColorHex,
                  onCustomAdded: state.addCustomAccentColor,
                  onCustomRemoved: state.removeCustomAccentColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ---- Terminal --------------------------------------------------
          SwissPanel(
            title: tr('Terminal'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(tr('TAMAÑO DE FUENTE'),
                          style: AppText.label(9, color: AppColors.muted)),
                    ),
                    Text('${terminalFontSize.toStringAsFixed(0)} PT',
                        style: AppText.mono(12, color: AppColors.bone)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  children: [
                    _StepButton(
                      icon: Icons.remove,
                      onTap: () => state.bumpTerminalFontSize(-1),
                    ),
                    Expanded(
                      child: Slider(
                        value: terminalFontSize,
                        min: AppState.minTerminalFontSize,
                        max: AppState.maxTerminalFontSize,
                        divisions: (AppState.maxTerminalFontSize -
                                AppState.minTerminalFontSize)
                            .round(),
                        activeColor: AppColors.bone,
                        inactiveColor: AppColors.hairline,
                        thumbColor: AppColors.bone,
                        onChanged: state.setTerminalFontSize,
                      ),
                    ),
                    _StepButton(
                      icon: Icons.add,
                      onTap: () => state.bumpTerminalFontSize(1),
                    ),
                  ],
                ),
              ),
              Hairline(),
              // Live preview of the chosen size.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Text(
                  tr(r'user@kala:~$ echo "Hola"'),
                  style: AppText.mono(terminalFontSize,
                      color: AppColors.bone),
                ),
              ),
              Hairline(),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(tr('SENSIBILIDAD GESTOS (ZONA MUERTA)'),
                          style: AppText.label(9, color: AppColors.muted)),
                    ),
                    Text('${terminalGestureDeadzone.toStringAsFixed(0)} PX',
                        style: AppText.mono(12, color: AppColors.bone)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: terminalGestureDeadzone,
                        min: 10,
                        max: 150,
                        divisions: 140,
                        activeColor: AppColors.bone,
                        inactiveColor: AppColors.hairline,
                        thumbColor: AppColors.bone,
                        onChanged: state.setTerminalGestureDeadzone,
                      ),
                    ),
                  ],
                ),
              ),
              Hairline(),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
                child: Text(tr('ESQUEMA DE COLOR'),
                    style: AppText.label(9, color: AppColors.muted)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                child: _SchemeSelector(
                  value: terminalScheme,
                  onChanged: state.setTerminalScheme,
                ),
              ),
              Hairline(),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
                child: Text(tr('TIPOGRAFÍA MONOESPACIADA'),
                    style: AppText.label(9, color: AppColors.muted)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                child: _FontSelector(
                  value: monoFontChoice,
                  onChanged: state.setMonoFontChoice,
                ),
              ),
              Hairline(),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
                child: Text(tr('DISTRIBUCIÓN DE ATAJOS'),
                    style: AppText.label(9, color: AppColors.muted)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                child: _ShortcutLayoutSelector(
                  value: shortcutLayout,
                  onChanged: state.setShortcutLayout,
                ),
              ),
              Hairline(),
              // The panel paints its own background, so the tile needs a
              // Material of its own or its ink splash is painted behind it.
              Material(
                type: MaterialType.transparency,
                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  title: Text(tr('PERSONALIZAR BOTONES DE TECLADO'),
                      style: AppText.label(9, color: AppColors.muted)),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4.0),
                    child: Text(
                        tr('Arrastra para reordenar y activa/desactiva los atajos y botones del teclado inteligente.'),
                        style: AppText.label(8.5,
                            color: AppColors.faint, spacing: 0.3)),
                  ),
                  trailing:
                      Icon(Icons.keyboard_arrow_right, color: AppColors.muted),
                  onTap: () => ShortcutManagerSheet.show(context, state),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SchemeSelector extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const _SchemeSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.hairline, width: 1),
      ),
      child: Row(
        children: [
          for (int i = 0; i < AppTerminalTheme.schemeOptions.length; i++) ...[
            if (i > 0) Container(width: 1, color: AppColors.hairline),
            Expanded(child: _schemeCell(context, AppTerminalTheme.schemeOptions[i])),
          ],
        ],
      ),
    );
  }

  Widget _schemeCell(BuildContext context, (String, String) option) {
    final (id, label) = option;
    final active = value == id;
    final theme = AppTerminalTheme.byId(id, Theme.of(context).brightness);
    final fg = active ? AppColors.ink : AppColors.bone;

    return Material(
      color: active ? AppColors.bone : Colors.transparent,
      child: InkWell(
        onTap: () => onChanged(id),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            children: [
              Container(
                width: 44,
                height: 18,
                decoration: BoxDecoration(
                  color: theme.background,
                  border: Border.all(color: AppColors.hairline, width: 1),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final c in [
                      theme.red,
                      theme.green,
                      theme.yellow,
                      theme.blue
                    ])
                      Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.symmetric(horizontal: 1.5),
                        decoration:
                            BoxDecoration(color: c, shape: BoxShape.circle),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(label,
                  style: AppText.label(8,
                      color: fg,
                      weight: active ? FontWeight.w800 : FontWeight.w600,
                      spacing: 1.0)),
            ],
          ),
        ),
      ),
    );
  }
}

class _IconScaleSelector extends StatelessWidget {
  final AppIconScale value;
  final ValueChanged<AppIconScale> onChanged;

  const _IconScaleSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final options = <(AppIconScale, String, IconData)>[
      (AppIconScale.small, tr('PEQUEÑO'), Icons.text_decrease),
      (AppIconScale.medium, tr('MEDIO'), Icons.format_size),
      (AppIconScale.large, tr('GRANDE'), Icons.text_increase),
    ];

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.hairline, width: 1),
      ),
      child: Row(
        children: [
          for (int i = 0; i < options.length; i++) ...[
            if (i > 0) Container(width: 1, color: AppColors.hairline),
            Expanded(
              child: _SegmentCell(
                label: options[i].$2,
                icon: options[i].$3,
                active: value == options[i].$1,
                onTap: () => onChanged(options[i].$1),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ThemeSelector extends StatelessWidget {
  final AppThemeChoice value;
  final ValueChanged<AppThemeChoice> onChanged;

  const _ThemeSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final options = <(AppThemeChoice, String, IconData)>[
      (AppThemeChoice.system, tr('SISTEMA'), Icons.brightness_auto_outlined),
      (AppThemeChoice.light, tr('CLARO'), Icons.light_mode_outlined),
      (AppThemeChoice.dark, tr('OSCURO'), Icons.dark_mode_outlined),
      (AppThemeChoice.oled, 'OLED', Icons.contrast_outlined),
    ];

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.hairline, width: 1),
      ),
      child: Row(
        children: [
          for (int i = 0; i < options.length; i++) ...[
            if (i > 0) Container(width: 1, color: AppColors.hairline),
            Expanded(
              child: _SegmentCell(
                label: options[i].$2,
                icon: options[i].$3,
                active: value == options[i].$1,
                onTap: () => onChanged(options[i].$1),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SegmentCell extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _SegmentCell({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = active ? AppColors.ink : AppColors.bone;
    return Material(
      color: active ? AppColors.bone : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            children: [
              Icon(icon, size: 17, color: fg),
              const SizedBox(height: 6),
              Text(label,
                  style: AppText.label(8,
                      color: fg,
                      weight: active ? FontWeight.w800 : FontWeight.w600,
                      spacing: 1.0)),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _StepButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, color: AppColors.bone, size: 18),
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }
}

class _AccentColorSelector extends StatelessWidget {
  final String value;
  final List<String> customColors;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onCustomAdded;
  final ValueChanged<String> onCustomRemoved;

  const _AccentColorSelector({
    required this.value,
    required this.customColors,
    required this.onChanged,
    required this.onCustomAdded,
    required this.onCustomRemoved,
  });

  Future<void> _pickColor(BuildContext context) async {
    final hex = await ColorPickerDialog.show(
      context,
      initialColor: AppColors.parseHex(value) ?? AppColors.accent,
    );
    if (hex != null) onCustomAdded(hex);
  }

  Future<void> _confirmRemove(BuildContext context, String hex) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: AppColors.hairline),
          borderRadius: BorderRadius.zero,
        ),
        title: Text(tr('ELIMINAR COLOR'),
            style: AppText.label(10, color: AppColors.bone)),
        content: Text(tr('¿Quitar {0} de tus colores guardados?', [hex]),
            style: AppText.mono(12, color: AppColors.muted)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(tr('CANCELAR'),
                style: AppText.label(9, color: AppColors.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(tr('ELIMINAR'),
                style: AppText.label(9, color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (remove == true) onCustomRemoved(hex);
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final full = customColors.length >= AppState.maxCustomAccentColors;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final preset in AppColors.accentPresets)
                _Dot(
                  color: preset.$1 == 'auto'
                      ? (isLight
                          ? const Color(0xFF1A1916)
                          : const Color(0xFFECE7DD))
                      : preset.$3,
                  selected: value == preset.$1,
                  onTap: () => onChanged(preset.$1),
                  child: preset.$1 == 'auto'
                      ? Icon(
                          Icons.circle_outlined,
                          size: 14,
                          color: isLight
                              ? const Color(0xFFECE7DD)
                              : const Color(0xFF1A1916),
                        )
                      : null,
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            tr('MIS COLORES ({0}/{1})', [customColors.length, AppState.maxCustomAccentColors]),
            style: AppText.label(8.5, color: AppColors.faint, spacing: 0.8),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final hex in customColors)
                _Dot(
                  color: AppColors.parseHex(hex) ?? AppColors.bone,
                  selected: value == hex,
                  onTap: () => onChanged(hex),
                  onLongPress: () => _confirmRemove(context, hex),
                ),
              // "+" slot: opens the picker. Disabled once the palette is full.
              GestureDetector(
                onTap: full ? null : () => _pickColor(context),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: full ? AppColors.faint : AppColors.muted,
                      width: 1,
                    ),
                  ),
                  child: Icon(Icons.add,
                      size: 16,
                      color: full ? AppColors.faint : AppColors.bone),
                ),
              ),
            ],
          ),
          if (customColors.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(tr('Mantén pulsado un color para eliminarlo.'),
                style: AppText.label(8, color: AppColors.faint, spacing: 0.3)),
          ],
          if (full) ...[
            const SizedBox(height: 8),
            Text(
                tr('Límite alcanzado: elimina uno para guardar otro.'),
                style: AppText.label(8, color: AppColors.faint, spacing: 0.3)),
          ],
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget? child;

  const _Dot({
    required this.color,
    required this.selected,
    required this.onTap,
    this.onLongPress,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? AppColors.bone : AppColors.hairline,
            width: selected ? 3 : 1,
          ),
        ),
        child: child == null ? null : Center(child: child),
      ),
    );
  }
}

class _FontSelector extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const _FontSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.hairline, width: 1),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _buildCell(AppText.monoFontOptions[0]),
              Container(width: 1, height: 40, color: AppColors.hairline),
              _buildCell(AppText.monoFontOptions[1]),
              Container(width: 1, height: 40, color: AppColors.hairline),
              _buildCell(AppText.monoFontOptions[2]),
            ],
          ),
          Container(height: 1, color: AppColors.hairline),
          Row(
            children: [
              _buildCell(AppText.monoFontOptions[3]),
              Container(width: 1, height: 40, color: AppColors.hairline),
              _buildCell(AppText.monoFontOptions[4]),
              Container(width: 1, height: 40, color: AppColors.hairline),
              _buildCell(AppText.monoFontOptions[5]),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCell((String, String) option) {
    final (id, label) = option;
    final active = value == id;
    final fg = active ? AppColors.ink : AppColors.bone;
    final fontFamily = AppText.resolveMonoFontFamily(id);

    return Expanded(
      child: Material(
        color: active ? AppColors.accent : Colors.transparent,
        child: InkWell(
          onTap: () => onChanged(id),
          child: Container(
            height: 40,
            alignment: Alignment.center,
            child: Text(
              label.toUpperCase(),
              style: TextStyle(
                fontSize: 8.5,
                fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                color: fg,
                fontFamily: fontFamily,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShortcutLayoutSelector extends StatelessWidget {
  final TerminalShortcutLayout value;
  final ValueChanged<TerminalShortcutLayout> onChanged;

  const _ShortcutLayoutSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.panelHi,
        border: Border.all(color: AppColors.hairline),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<TerminalShortcutLayout>(
          value: value,
          dropdownColor: AppColors.panel,
          iconEnabledColor: AppColors.bone,
          isExpanded: true,
          style: AppText.mono(11, color: AppColors.bone),
          items: [
            DropdownMenuItem(
              value: TerminalShortcutLayout.classic,
              child: Text(tr('CLÁSICO (DOBLE FILA)')),
            ),
            DropdownMenuItem(
              value: TerminalShortcutLayout.dpadLeft,
              child: Text(tr('D-PAD A LA IZQUIERDA')),
            ),
            DropdownMenuItem(
              value: TerminalShortcutLayout.dpadRight,
              child: Text(tr('D-PAD A LA DERECHA')),
            ),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}
