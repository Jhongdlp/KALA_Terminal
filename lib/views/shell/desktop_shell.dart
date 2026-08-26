import 'package:flutter/material.dart';

import '../../providers/app_state.dart';
import '../../theme/app_theme.dart';
import 'app_screen.dart';
import 'nav_rail.dart';
import 'workspace.dart';

/// The desktop layout: an icon rail beside either the workspace split or a
/// single full-canvas screen.
///
/// Navigation stays driven by `AppState.activeTabIndex` — this only *derives*
/// what to show from it, so the thirteen existing `setActiveTabIndex` call
/// sites keep working unchanged. "Go to the editor" becomes "focus the editor
/// pane" for free, because the editor is already on screen and the body index
/// doesn't move.
class DesktopShell extends StatelessWidget {
  /// Mounts a screen under its stable key. Comes from `_HomeViewState.mount`.
  final Widget Function(AppScreen) mount;
  final int activeTabIndex;
  final int focusedPaneTab;
  final bool isFileDirty;
  final bool explorerPaneOpen;
  final bool gitPaneOpen;
  final ValueChanged<AppScreen> onSelect;

  const DesktopShell({
    super.key,
    required this.mount,
    required this.activeTabIndex,
    required this.focusedPaneTab,
    required this.isFileDirty,
    required this.explorerPaneOpen,
    required this.gitPaneOpen,
    required this.onSelect,
  });

  /// Screens that take the whole canvas beside the rail, in stack order.
  static const List<AppScreen> fullCanvas = [
    AppScreen.connections,
    AppScreen.server,
    AppScreen.tunnels,
    AppScreen.agents,
    AppScreen.notifications,
    AppScreen.settings,
    AppScreen.personalization,
    AppScreen.about,
  ];

  bool get _workspaceVisible =>
      AppState.paneableTabs.contains(activeTabIndex);

  /// 0 is the workspace; the rest follow [fullCanvas].
  int get _bodyIndex => _workspaceVisible
      ? 0
      : 1 +
          fullCanvas.indexWhere((screen) => screen.tabIndex == activeTabIndex);

  /// What the rail lights up. With the workspace open several screens are on
  /// screen at once, so this is a set and the focused one is tracked apart.
  Set<AppScreen> get _onScreen => _workspaceVisible
      ? {
          AppScreen.terminal,
          AppScreen.editor,
          if (explorerPaneOpen) AppScreen.explorer,
          if (gitPaneOpen) AppScreen.git,
        }
      : {AppScreen.fromTab(activeTabIndex)};

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        NavRail(
          onScreen: _onScreen,
          focused: _workspaceVisible
              ? AppScreen.fromTab(focusedPaneTab)
              : AppScreen.fromTab(activeTabIndex),
          isFileDirty: isFileDirty,
          onSelect: onSelect,
        ),
        Container(width: 1, color: AppColors.hairline),
        Expanded(
          child: IndexedStack(
            index: _bodyIndex,
            children: [
              Workspace(mount: mount),
              // Only non-paneable screens live here: a screen mounted both in
              // the workspace and in this stack would be a duplicate GlobalKey.
              for (final screen in fullCanvas) mount(screen),
            ],
          ),
        ),
      ],
    );
  }
}
