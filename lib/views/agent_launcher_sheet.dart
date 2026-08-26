import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/agent_launcher.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/adaptive_sheet.dart';
import '../widgets/swiss.dart';

/// The agent launcher, reached from the pad's radial (or the quick keys) as
/// `system:agents`.
///
/// A grid of marks rather than a list of names: the whole value is that
/// starting an agent stops being a typed command line, and a brand mark is
/// recognised faster than any label at thumb distance.
Future<void> showAgentLauncher(BuildContext context) {
  return showAdaptiveSheet(
    context,
    backgroundColor: AppColors.panel,
    isScrollControlled: true,
    maxWidth: 460,
    builder: (_) => const _AgentLauncherBody(),
  );
}

class _AgentLauncherBody extends StatelessWidget {
  const _AgentLauncherBody();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final launchers = state.enabledAgentLaunchers;
    final connected = state.connectionStatus == ConnectionStatus.remote;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(tr('LANZAR AGENTE'),
                      style: AppText.label(12,
                          color: AppColors.bone, spacing: 1.6)),
                ),
                IconButton(
                  tooltip: tr('Configurar agentes'),
                  onPressed: () {
                    Navigator.of(context).pop();
                    // Personalizar, where the commands and marks are edited.
                    state.setActiveTabIndex(6);
                  },
                  icon: Icon(Icons.tune, size: 18, color: AppColors.muted),
                ),
              ],
            ),
          ),
          const Hairline(),
          if (!connected)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                tr('Conéctate a un servidor para lanzar un agente.'),
                style: AppText.body(11, color: AppColors.danger),
              ),
            ),
          if (launchers.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                tr('No tienes agentes configurados. Añádelos en Personalizar → Agentes.'),
                style: AppText.body(12, color: AppColors.muted),
              ),
            )
          else
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final launcher in launchers)
                      _LauncherTile(
                        launcher: launcher,
                        enabled: connected,
                        onTap: () {
                          Navigator.of(context).pop();
                          state.runAgentLauncher(launcher);
                        },
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LauncherTile extends StatelessWidget {
  final AgentLauncher launcher;
  final bool enabled;
  final VoidCallback onTap;

  const _LauncherTile({
    required this.launcher,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${launcher.name}. ${launcher.command}',
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: Material(
          color: AppColors.panelHi,
          child: InkWell(
            onTap: enabled ? onTap : null,
            child: Container(
              width: 98,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.hairline),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AgentMark(iconId: launcher.iconId, size: 30),
                  const SizedBox(height: 8),
                  Text(
                    launcher.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: AppText.body(11,
                        color: AppColors.bone, weight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    launcher.command,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: AppText.mono(8, color: AppColors.muted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An agent's real mark.
///
/// Drawn **untinted**, unlike every other image in the app: these are brand
/// logos, and recolouring them to the palette is both wrong and the reason a
/// user would stop recognising them at a glance. A missing asset falls back to
/// a neutral glyph rather than to Flutter's broken-image box.
class AgentMark extends StatelessWidget {
  final String iconId;
  final double size;

  const AgentMark({super.key, required this.iconId, this.size = 24});

  @override
  Widget build(BuildContext context) {
    final path = kAgentIcons.contains(iconId)
        ? 'assets/agents/$iconId.png'
        : 'assets/agents/generic.png';
    return Image.asset(
      path,
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, _, _) =>
          Icon(Icons.smart_toy_outlined, size: size, color: AppColors.muted),
    );
  }
}
