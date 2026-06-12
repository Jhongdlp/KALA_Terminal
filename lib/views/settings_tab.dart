import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';

/// Central configuration screen. Every persisted user preference lives here so
/// there is a single place to surface anything that can be tuned.
class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);

    return Container(
      color: AppColors.ink,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          // Not const: ScreenHeader reads the active AppColors palette at build
          // time, so a const (identical) instance would be skipped on rebuild
          // and keep the dark-theme title color when switching to light.
          ScreenHeader('Ajustes', eyebrow: 'Configuración'),

          // ---- Appearance ------------------------------------------------
          SwissPanel(
            title: 'Apariencia',
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
                child: Text('TEMA DE LA APLICACIÓN',
                    style: AppText.label(9, color: AppColors.muted)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                child: _ThemeSelector(
                  value: state.themeMode,
                  onChanged: state.setThemeMode,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ---- Terminal --------------------------------------------------
          SwissPanel(
            title: 'Terminal',
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('TAMAÑO DE FUENTE',
                          style: AppText.label(9, color: AppColors.muted)),
                    ),
                    Text('${state.terminalFontSize.toStringAsFixed(0)} PT',
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
                        value: state.terminalFontSize,
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
                  r'user@aiterminal:~$ echo "Hola"',
                  style: AppText.mono(state.terminalFontSize,
                      color: AppColors.bone),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ---- About -----------------------------------------------------
          SwissPanel(
            title: 'Acerca de',
            children: [
              _InfoRow(label: 'APLICACIÓN', value: 'AITerminal'),
              Hairline(),
              _InfoRow(label: 'PAQUETE', value: 'terminal_agent'),
            ],
          ),
        ],
      ),
    );
  }
}

/// Three-way segmented control: Sistema / Claro / Oscuro.
class _ThemeSelector extends StatelessWidget {
  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;

  const _ThemeSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    const options = <(ThemeMode, String, IconData)>[
      (ThemeMode.system, 'SISTEMA', Icons.brightness_auto_outlined),
      (ThemeMode.light, 'CLARO', Icons.light_mode_outlined),
      (ThemeMode.dark, 'OSCURO', Icons.dark_mode_outlined),
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

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: AppText.label(9, color: AppColors.muted)),
          ),
          Text(value, style: AppText.mono(12, color: AppColors.bone)),
        ],
      ),
    );
  }
}
