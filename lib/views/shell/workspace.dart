import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_state.dart';
import '../../theme/breakpoints.dart';
import '../../widgets/split_pane.dart';
import 'app_screen.dart';

/// The desktop IDE split: a side column (explorer and/or git) beside a main
/// column that stacks the editor over the terminal.
///
/// At [WidthClass.expanded] the explorer and git panes can both be open, as two
/// side columns. At [WidthClass.medium] there is only room for one, so the side
/// column shows whichever is focused and the other stays mounted offstage.
///
/// Every paneable screen is mounted on every build — visible ones inside the
/// splits, hidden ones in an offstage bucket. That is what keeps exactly one
/// live instance of each screen (the GlobalKey registry in HomeView would
/// otherwise throw on a duplicate) and what makes toggling a pane restore its
/// scroll position instead of rebuilding it.
class Workspace extends StatelessWidget {
  /// Mounts a screen under its stable key. Comes from `_HomeViewState.mount`.
  final Widget Function(AppScreen) mount;

  const Workspace({super.key, required this.mount});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final layout = Layout.of(context);

    final explorerOpen = state.explorerPaneOpen;
    final gitOpen = state.gitPaneOpen;
    final focused = AppScreen.fromTab(state.focusedPaneTab);

    // Which screens actually get laid out this build.
    final visible = <AppScreen>{
      AppScreen.terminal,
      AppScreen.editor,
      if (explorerOpen) AppScreen.explorer,
      if (gitOpen) AppScreen.git,
    };

    // The main column: editor over terminal.
    final main = SplitPane(
      axis: Axis.vertical,
      fraction: state.splitEditorTerminal,
      onFractionChanged: state.setSplitEditorTerminal,
      first: mount(AppScreen.editor),
      second: mount(AppScreen.terminal),
    );

    Widget body;
    if (!explorerOpen && !gitOpen) {
      body = main;
    } else if (layout.isWide && explorerOpen && gitOpen) {
      // Room for both side panes: explorer | git | main.
      body = SplitPane(
        axis: Axis.horizontal,
        fraction: state.splitSide,
        onFractionChanged: state.setSplitSide,
        first: mount(AppScreen.explorer),
        second: SplitPane(
          axis: Axis.horizontal,
          // Nested split of the remainder; not persisted separately, the git
          // pane just takes a fixed share of what is left.
          fraction: 0.3,
          onFractionChanged: (_) {},
          first: mount(AppScreen.git),
          second: main,
        ),
      );
    } else {
      // One side column. When both panes are open but there is only room for
      // one, the focused screen wins; git otherwise takes precedence because
      // it is the pane the user just opened from the terminal toolbar.
      final side = explorerOpen && gitOpen
          ? (focused == AppScreen.explorer ? AppScreen.explorer : AppScreen.git)
          : (explorerOpen ? AppScreen.explorer : AppScreen.git);

      visible
        ..remove(AppScreen.explorer)
        ..remove(AppScreen.git)
        ..add(side);

      body = SplitPane(
        axis: Axis.horizontal,
        fraction: state.splitSide,
        onFractionChanged: state.setSplitSide,
        first: mount(side),
        second: main,
      );
    }

    final hidden = AppScreen.values
        .where((screen) => screen.isPaneable && !visible.contains(screen));

    // StackFit.expand, not the default: the only other children are offstage
    // and therefore zero-sized, so a loose Stack would collapse to nothing and
    // hand the splits a zero-width box.
    return Stack(
      fit: StackFit.expand,
      children: [
        body,
        // Mounted but unlaid-out and unpainted, so a pane toggled back on keeps
        // its scroll position and selection.
        for (final screen in hidden) Offstage(child: mount(screen)),
      ],
    );
  }
}
