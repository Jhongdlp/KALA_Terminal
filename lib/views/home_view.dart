import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import 'connections_tab.dart';
import 'terminal_tab.dart';
import 'explorer_tab.dart';
import 'editor_tab.dart';
import 'settings_tab.dart';

class HomeView extends StatelessWidget {
  const HomeView({super.key});

  static const _items = <_NavSpec>[
    _NavSpec('CONEXIONES', Icons.dns_outlined),
    _NavSpec('CONSOLA', Icons.terminal_outlined),
    _NavSpec('ARCHIVOS', Icons.folder_outlined),
    _NavSpec('EDITOR', Icons.code),
    _NavSpec('AJUSTES', Icons.tune),
  ];

  @override
  Widget build(BuildContext context) {
    // The shell only depends on the active tab and the editor dirty dot. Select
    // just those so unrelated notifications (terminal output, file listings…)
    // don't rebuild the nav bar and IndexedStack.
    final activeTabIndex = context.select<AppState, int>((s) => s.activeTabIndex);
    final isFileDirty = context.select<AppState, bool>((s) => s.isFileDirty);
    // AppColors is a global, mutable palette swapped on theme change (see
    // app_theme.dart). Depend on themeMode so this subtree rebuilds and re-reads
    // the new colors; without it an isolated tab keeps the old theme's colors
    // until something else happens to rebuild it.
    context.select<AppState, ThemeMode>((s) => s.themeMode);

    const tabs = [
      ConnectionsTab(),
      TerminalTab(),
      ExplorerTab(),
      EditorTab(),
      SettingsTab(),
    ];

    return Scaffold(
      backgroundColor: AppColors.ink,
      // Keep the soft keyboard from covering navigation: nav lives at the top,
      // the keyboard only ever pushes up the content below it.
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // Top navigation bar — always visible, keyboard-safe.
            Container(
              decoration: BoxDecoration(
                color: AppColors.ink,
                border: Border(
                  bottom: BorderSide(color: AppColors.hairline, width: 1),
                ),
              ),
              child: SizedBox(
                height: 54,
                child: Row(
                  children: List.generate(_items.length, (i) {
                    return Expanded(
                      child: _TopNavItem(
                        spec: _items[i],
                        active: activeTabIndex == i,
                        dirty: i == 3 && isFileDirty,
                        onTap: () => context.read<AppState>().setActiveTabIndex(i),
                      ),
                    );
                  }),
                ),
              ),
            ),
            Expanded(
              child: IndexedStack(index: activeTabIndex, children: tabs),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavSpec {
  final String label;
  final IconData icon;
  const _NavSpec(this.label, this.icon);
}

class _TopNavItem extends StatelessWidget {
  final _NavSpec spec;
  final bool active;
  final bool dirty;
  final VoidCallback onTap;

  const _TopNavItem({
    required this.spec,
    required this.active,
    required this.dirty,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = active ? AppColors.bone : AppColors.muted;
    return InkWell(
      onTap: onTap,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(spec.icon, size: 18, color: fg),
                  if (dirty)
                    Positioned(
                      right: -5,
                      top: -2,
                      child: Container(
                          width: 5, height: 5, color: AppColors.bone),
                    ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                spec.label,
                style: AppText.mono(8,
                    color: fg,
                    weight: active ? FontWeight.w700 : FontWeight.w500,
                    spacing: 0.8),
              ),
            ],
          ),
          // Active indicator: 2px bone bar along the bottom edge.
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 2,
              color: active ? AppColors.bone : Colors.transparent,
            ),
          ),
        ],
      ),
    );
  }
}
