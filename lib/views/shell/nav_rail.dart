import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_theme.dart';
import '../../theme/dimens.dart';
import '../../widgets/agent_waiting_badge.dart';
import '../../widgets/swiss.dart';
import 'app_screen.dart';

/// One entry in the rail.
class NavRailItem {
  final AppScreen screen;
  final String label;
  final IconData icon;
  const NavRailItem(this.screen, this.label, this.icon);
}

/// The desktop shell's left icon rail.
///
/// Replaces the compact layout's five-slot top strip: every screen is one click
/// away instead of five of them being buried behind a drawer, and the rail
/// costs 56px of width rather than 54px of the much scarcer height.
///
/// The active indicator has two tiers, because on a desktop several screens are
/// visible at once: a screen mounted in a visible pane reads as *on screen*
/// (muted bar), and exactly one reads as *focused* (accent bar). Without that
/// split, four lit icons would say nothing about where the keyboard is going.
class NavRail extends StatelessWidget {
  /// Screens currently mounted in a visible pane, or the active full-canvas one.
  final Set<AppScreen> onScreen;

  /// The one screen that owns focus.
  final AppScreen focused;

  /// The editor's unsaved-changes dot.
  final bool isFileDirty;

  final ValueChanged<AppScreen> onSelect;

  const NavRail({
    super.key,
    required this.onScreen,
    required this.focused,
    required this.isFileDirty,
    required this.onSelect,
  });

  /// Grouped so the workspace, the infrastructure screens and the app's own
  /// settings read as three things rather than one list of ten.
  static List<List<NavRailItem>> get groups => [
        [
          NavRailItem(AppScreen.terminal, tr('CONSOLA'), Icons.terminal_outlined),
          NavRailItem(AppScreen.explorer, tr('ARCHIVOS'), Icons.folder_outlined),
          NavRailItem(AppScreen.editor, tr('EDITOR'), Icons.code),
          NavRailItem(AppScreen.git, tr('GIT'), Icons.account_tree_outlined),
        ],
        [
          NavRailItem(
              AppScreen.connections, tr('CONEXIONES'), Icons.dns_outlined),
          NavRailItem(AppScreen.server, tr('SERVIDOR'), Icons.storage_outlined),
          NavRailItem(AppScreen.tunnels, tr('TÚNELES'), Icons.swap_horiz),
        ],
        [
          NavRailItem(AppScreen.agents, tr('AGENTES'), Icons.smart_toy_outlined),
          NavRailItem(AppScreen.notifications, tr('NOTIFICACIONES'),
              Icons.notifications_active_outlined),
          NavRailItem(AppScreen.settings, tr('AJUSTES'), Icons.tune),
          NavRailItem(AppScreen.personalization, tr('PERSONALIZACIÓN'),
              Icons.palette_outlined),
          NavRailItem(AppScreen.about, tr('ACERCA DE'), Icons.info_outline),
        ],
      ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: Dim.railWidth,
      color: AppColors.ink,
      child: SingleChildScrollView(
        child: Column(
          children: [
            for (final (groupIndex, group) in groups.indexed) ...[
              if (groupIndex > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: Dim.x3, vertical: Dim.x2),
                  child: Hairline(),
                ),
              for (final item in group)
                _RailButton(
                  item: item,
                  focused: focused == item.screen,
                  onScreen: onScreen.contains(item.screen),
                  dirty: item.screen == AppScreen.editor && isFileDirty,
                  onTap: () => onSelect(item.screen),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  final NavRailItem item;
  final bool focused;
  final bool onScreen;
  final bool dirty;
  final VoidCallback onTap;

  const _RailButton({
    required this.item,
    required this.focused,
    required this.onScreen,
    required this.dirty,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final foreground = focused
        ? AppColors.accent
        : onScreen
            ? AppColors.bone
            : AppColors.muted;
    final indicator = focused
        ? AppColors.accent
        : onScreen
            ? AppColors.muted
            : Colors.transparent;

    return Tooltip(
      message: item.label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 44,
            child: Row(
              children: [
                // Active indicator on the leading edge, where a vertical rail
                // reads it — the compact strip underlines instead.
                Container(width: 2, height: 44, color: indicator),
                Expanded(
                  child: Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.center,
                    children: [
                      Icon(item.icon, size: 18, color: foreground),
                      // Sessions waiting on an answer, on the entry that leads
                      // to them. A dot rather than the count: a 56px rail has
                      // no room for a number beside an 18px glyph.
                      if (item.screen == AppScreen.agents)
                        const Positioned(
                          right: 8,
                          top: 10,
                          child: AgentWaitingBadge(showCount: false),
                        ),
                      if (dirty)
                        Positioned(
                          right: 8,
                          top: 10,
                          child: Container(
                            width: 5,
                            height: 5,
                            color: AppColors.accent,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
