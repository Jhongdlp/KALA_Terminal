import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../l10n/l10n.dart';
import '../models/agent_launcher.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/adaptive_sheet.dart';
import '../widgets/swiss.dart';
import '../widgets/tap_target.dart';
import 'agent_launcher_sheet.dart';

/// Personalizar → Agentes: the commands behind the launcher.
///
/// This is where `claude` becomes `claude --dangerously-skip-permissions`, and
/// where an agent that did not exist when the app shipped gets added. The
/// command is free text on purpose — the app does not know next year's CLI, and
/// guessing its flags would be worse than letting the user type them once.
class AgentLaunchersPanel extends StatelessWidget {
  const AgentLaunchersPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final launchers = state.agentLaunchers;

    return SwissPanel(
      title: tr('Agentes'),
      trailing: IconTapTarget(
        icon: Icons.add,
        label: tr('Añadir agente'),
        size: 16,
        onTap: () => _editLauncher(context, state, null),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Text(
            tr('Lo que abre el botón AGENTES de la terminal. El comando se envía tal cual, así que puedes añadirle las banderas que siempre usas.'),
            style: AppText.body(11, color: AppColors.muted),
          ),
        ),
        const Hairline(),
        if (launchers.isEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: Text(tr('No hay agentes en la lista.'),
                      style: AppText.body(12, color: AppColors.muted)),
                ),
                GhostButton(
                  label: tr('RESTAURAR'),
                  dense: true,
                  onPressed: state.restoreDefaultAgentLaunchers,
                ),
              ],
            ),
          )
        else
          for (var i = 0; i < launchers.length; i++) ...[
            if (i > 0) const Hairline(),
            _LauncherRow(
              launcher: launchers[i],
              onEdit: () => _editLauncher(context, state, launchers[i]),
              onToggle: (v) => state.saveAgentLauncher(
                  launchers[i].copyWith(enabled: v)),
            ),
          ],
      ],
    );
  }
}

class _LauncherRow extends StatelessWidget {
  final AgentLauncher launcher;
  final VoidCallback onEdit;
  final ValueChanged<bool> onToggle;

  const _LauncherRow({
    required this.launcher,
    required this.onEdit,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            AgentMark(iconId: launcher.iconId, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(launcher.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body(13,
                          color: AppColors.bone, weight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(
                    launcher.autoRun
                        ? launcher.command
                        : tr('{0} · sin ejecutar', [launcher.command]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.mono(9, color: AppColors.muted),
                  ),
                ],
              ),
            ),
            Switch(
              value: launcher.enabled,
              onChanged: onToggle,
              activeThumbColor: AppColors.accent,
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens the editor for [existing], or for a brand-new launcher when null.
Future<void> _editLauncher(
    BuildContext context, AppState state, AgentLauncher? existing) {
  return showAdaptiveSheet(
    context,
    backgroundColor: AppColors.panel,
    isScrollControlled: true,
    maxWidth: 560,
    builder: (_) => _LauncherEditor(state: state, existing: existing),
  );
}

class _LauncherEditor extends StatefulWidget {
  final AppState state;
  final AgentLauncher? existing;

  const _LauncherEditor({required this.state, required this.existing});

  @override
  State<_LauncherEditor> createState() => _LauncherEditorState();
}

class _LauncherEditorState extends State<_LauncherEditor> {
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _command =
      TextEditingController(text: widget.existing?.command ?? '');
  late String _iconId = widget.existing?.iconId ?? 'generic';
  late bool _autoRun = widget.existing?.autoRun ?? true;

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    super.dispose();
  }

  /// Flags offered for whatever the command already looks like, so the one
  /// everybody wants is a tap instead of a phone-keyboard typo.
  List<(String, String)> get _suggestions {
    final command = _command.text.toLowerCase();
    return [
      for (final (agentId, flag, description) in kCommonAgentFlags)
        if (command.contains(agentId) && !command.contains(flag))
          (flag, description),
    ];
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final command = _command.text.trim();
    if (name.isEmpty || command.isEmpty) return;
    await widget.state.saveAgentLauncher(AgentLauncher(
      id: widget.existing?.id ?? const Uuid().v4(),
      name: name,
      command: command,
      iconId: _iconId,
      autoRun: _autoRun,
      enabled: widget.existing?.enabled ?? true,
    ));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = _suggestions;

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, MediaQuery.viewInsetsOf(context).bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.existing == null ? tr('NUEVO AGENTE') : tr('EDITAR AGENTE'),
              style: AppText.label(12, color: AppColors.bone, spacing: 1.6),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              style: AppText.body(13, color: AppColors.bone),
              decoration: InputDecoration(labelText: tr('NOMBRE')),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _command,
              style: AppText.mono(12, color: AppColors.bone),
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: tr('COMANDO'),
                hintText: 'claude --dangerously-skip-permissions',
                hintStyle: AppText.mono(11, color: AppColors.faint),
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (suggestions.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(tr('BANDERAS HABITUALES'),
                  style: AppText.label(9, color: AppColors.muted)),
              const SizedBox(height: 6),
              for (final (flag, description) in suggestions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: InkWell(
                    onTap: () => setState(() {
                      _command.text = '${_command.text.trim()} $flag';
                    }),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        border: Border.all(color: AppColors.hairline),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('+ $flag',
                              style:
                                  AppText.mono(11, color: AppColors.accent)),
                          const SizedBox(height: 2),
                          // Said in words, because a flag that skips every
                          // confirmation is a decision, not a convenience.
                          Text(tr(description),
                              style:
                                  AppText.body(10, color: AppColors.muted)),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 14),
            Text(tr('ICONO'), style: AppText.label(9, color: AppColors.muted)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final id in kAgentIcons)
                  _IconChoice(
                    iconId: id,
                    selected: _iconId == id,
                    onTap: () => setState(() => _iconId = id),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            ToggleRow(
              label: tr('EJECUTAR AL TOCAR'),
              description: tr(
                  'Envía el comando con Enter. Apágalo si prefieres terminar de escribirlo tú.'),
              value: _autoRun,
              onChanged: (v) => setState(() => _autoRun = v),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                if (widget.existing != null)
                  GhostButton(
                    label: tr('ELIMINAR'),
                    dense: true,
                    danger: true,
                    onPressed: () async {
                      await widget.state
                          .deleteAgentLauncher(widget.existing!.id);
                      if (context.mounted) Navigator.of(context).pop();
                    },
                  ),
                const Spacer(),
                GhostButton(
                  label: tr('CANCELAR'),
                  dense: true,
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 8),
                InvertedButton(
                  label: tr('GUARDAR'),
                  dense: true,
                  onPressed: _save,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _IconChoice extends StatelessWidget {
  final String iconId;
  final bool selected;
  final VoidCallback onTap;

  const _IconChoice({
    required this.iconId,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      label: iconId,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: AppColors.panelHi,
            border: Border.all(
              color: selected ? AppColors.bone : AppColors.hairline,
              width: selected ? 2 : 1,
            ),
          ),
          child: Center(child: AgentMark(iconId: iconId, size: 24)),
        ),
      ),
    );
  }
}
