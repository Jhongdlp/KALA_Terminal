import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../theme/breakpoints.dart';
import '../services/update_service.dart';
import '../widgets/menu_drawer.dart';
import 'command_palette.dart';
import 'onboarding_sheet.dart';
import 'shell/app_commands.dart';
import 'shell/app_screen.dart';
import 'shell/desktop_shell.dart';
import 'shell/git_pane.dart';
import 'connections_tab.dart';
import 'terminal_tab.dart';
import 'explorer_tab.dart';
import 'editor_tab.dart';
import 'server_tab.dart';
import 'settings_tab.dart';
import 'personalization_tab.dart';
import 'about_tab.dart';
import 'notifications_tab.dart';
import 'tunnels_tab.dart';
import 'update_dialog.dart';
import '../l10n/l10n.dart';

class HomeView extends StatefulWidget {
  const HomeView({super.key});

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  static List<_NavSpec> get _items => <_NavSpec>[
    _NavSpec(tr('CONEXIONES'), Icons.dns_outlined),
    _NavSpec(tr('CONSOLA'), Icons.terminal_outlined),
    _NavSpec(tr('ARCHIVOS'), Icons.folder_outlined),
    _NavSpec(tr('EDITOR'), Icons.code),
    _NavSpec(tr('MENÚ'), Icons.menu),
  ];

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// One [GlobalKey] per screen, allocated per *mount* of the shell.
  ///
  /// Moving a keyed subtree between the compact `IndexedStack` and a desktop
  /// pane **within a single build** re-parents its Element instead of
  /// rebuilding it, so a live [TerminalTab] keeps its FocusNode,
  /// ScrollControllers and terminal controller across a breakpoint crossing.
  ///
  /// It is an instance field and deliberately **not** static: `_LockGate`
  /// remounts [HomeView] on a language change (see main.dart), and a
  /// process-wide key map would turn that remount into a re-parent — every
  /// `tr()` inside a tab would keep the previous language, which is exactly
  /// what `test/settings_switches_test.dart` pins down.
  late final Map<AppScreen, GlobalKey> _screenKeys = {
    for (final screen in AppScreen.values)
      screen: GlobalKey(debugLabel: 'screen_${screen.name}'),
  };

  /// Mounts [screen] under its stable key. Every presentation of a screen must
  /// go through this, and a screen must never be mounted in two places at once
  /// — a duplicate key is a hard crash rather than a silent state loss.
  Widget mount(AppScreen screen) =>
      KeyedSubtree(key: _screenKeys[screen]!, child: _widgetFor(screen));

  Widget _widgetFor(AppScreen screen) => switch (screen) {
        AppScreen.connections => const ConnectionsTab(),
        AppScreen.terminal => const TerminalTab(),
        AppScreen.explorer => const ExplorerTab(),
        AppScreen.editor => const EditorTab(),
        AppScreen.server => const ServerTab(),
        AppScreen.settings => const SettingsTab(),
        AppScreen.personalization => const PersonalizationTab(),
        AppScreen.about => const AboutTab(),
        AppScreen.notifications => const NotificationsTab(),
        AppScreen.tunnels => const TunnelsTab(),
        AppScreen.git => const GitPane(),
      };

  // Timestamp of the last back press on the root tab, for double-back-to-exit.
  DateTime? _lastBackPress;

  /// Whether the release check already ran in this process. The shell is
  /// remounted on a language change, so without this the check (a network round
  /// trip, and possibly a dialog) would run again on every switch.
  static bool _updateChecked = false;

  @override
  void initState() {
    super.initState();
    // Silent, best-effort update check against GitHub Releases after the first
    // frame; only surfaces a dialog when a newer APK actually exists.
    if (!_updateChecked) {
      _updateChecked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdate());
    }
    // First run: the three-card introduction. Guarded by its own persisted
    // flag (written before the sheet opens), so the language remount can't
    // show it twice.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) maybeShowOnboarding(context);
    });
  }

  Future<void> _checkForUpdate() async {
    final update = await UpdateService.checkForUpdate();
    if (update != null && mounted) showUpdateDialog(context, update);
  }

  /// System back: navigate backwards inside the app (close file, drop
  /// selection, return to connections) and only exit the activity on a second
  /// back press from the root tab.
  void _onBackPressed() {
    if (context.read<AppState>().handleBackNavigation()) return;

    final now = DateTime.now();
    if (_lastBackPress != null &&
        now.difference(_lastBackPress!) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    _lastBackPress = now;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
          SnackBar(
            content: Text(tr('Presiona atrás de nuevo para salir')),
            duration: Duration(seconds: 2),
          ),
      );
  }

  @override
  Widget build(BuildContext context) {
    // The shell only depends on the active tab and the editor dirty dot. Select
    // just those so unrelated notifications (terminal output, file listings…)
    // don't rebuild the nav bar and IndexedStack.
    final activeTabIndex = context.select<AppState, int>(
      (s) => s.activeTabIndex,
    );
    final isFileDirty = context.select<AppState, bool>((s) => s.isFileDirty);
    // Hide the top nav while the terminal is expanded to fullscreen, so the
    // shell gets the whole screen. Guarded by the active tab so leaving the
    // terminal (e.g. via back navigation) always brings the nav back.
    final hideTopNav = context.select<AppState, bool>(
      (s) => s.terminalFullscreen && s.activeTabIndex == 1,
    );
    // AppColors is a global, mutable palette swapped on theme change (see
    // app_theme.dart). Depend on themeChoice so this subtree rebuilds and
    // re-reads the new colors; without it an isolated tab keeps the old theme's
    // colors until something else happens to rebuild it.
    context.select<AppState, AppThemeChoice>((s) => s.themeChoice);

    // Android owns the system back gesture. On desktop there is nothing to
    // intercept, SystemNavigator.pop() does nothing, and the "press back again
    // to exit" SnackBar is nonsense — so the whole double-press contract is
    // gated to the platform that actually has it. defaultTargetPlatform rather
    // than dart:io Platform, so widget tests can override it.
    final hasSystemBack = defaultTargetPlatform == TargetPlatform.android;

    // Keyboard shortcuts for the whole app. They sit *above* the focused
    // widget, so the terminal still sees every key first — which is exactly why
    // every binding uses Ctrl+Shift (or Alt+digit, or a function key): xterm's
    // Ctrl handler bows out when Shift is held, so nothing here can swallow a
    // Ctrl+C on its way to the shell. See app_commands.dart.
    return CallbackShortcuts(
      bindings: appShortcutBindings(
        context,
        context.read<AppState>(),
        overrides: {
          // The palette owns a route, which the registry (pure data) can't.
          'app.palette': () => showCommandPalette(context),
        },
      ),
      child: Focus(
        autofocus: true,
        // Never take focus away from a text field or the terminal: this node
        // only exists so key events have somewhere to bubble up to.
        canRequestFocus: false,
        child: _buildShell(context, activeTabIndex, isFileDirty, hideTopNav,
            hasSystemBack),
      ),
    );
  }

  Widget _buildShell(BuildContext context, int activeTabIndex, bool isFileDirty,
      bool hideTopNav, bool hasSystemBack) {
    return PopScope(
      // Never let the system pop (= close) the activity directly; _onBackPressed
      // walks the in-app hierarchy and exits via SystemNavigator only on a
      // confirmed double press. Dialogs/sheets sit on their own routes above
      // this one, so back still dismisses them normally.
      canPop: !hasSystemBack,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !hasSystemBack) return;
        _onBackPressed();
      },
      child: Scaffold(
        key: _scaffoldKey,
        endDrawer: const MenuDrawer(),
        backgroundColor: AppColors.ink,
        // Keep the soft keyboard from covering navigation: nav lives at the top,
        // the keyboard only ever pushes up the content below it.
        body: SafeArea(
          bottom: false,
          // The layout class is derived from the shell's own box, so dragging a
          // desktop window across a breakpoint switches layouts live. Layout
          // carries only the class, not the pixel width, so this subtree
          // rebuilds once per crossing rather than once per pixel.
          child: LayoutBuilder(
            builder: (context, constraints) {
              final widthClass = constraints.widthClass;
              return Layout(
                widthClass: widthClass,
                // A bare if/else, deliberately: the two shells must swap within
                // this single build so the GlobalKey registry *re-parents* the
                // live screens. An AnimatedSwitcher or crossfade would mount
                // both at once — a duplicate-key crash at best, a torn-down
                // terminal session on every resize at worst.
                child: widthClass == WidthClass.compact
                    ? _buildCompactShell(
                        context,
                        activeTabIndex: activeTabIndex,
                        isFileDirty: isFileDirty,
                        hideTopNav: hideTopNav,
                      )
                    : _buildDesktopShell(
                        context,
                        activeTabIndex: activeTabIndex,
                        isFileDirty: isFileDirty,
                      ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// The desktop layout: an icon rail beside the workspace split.
  Widget _buildDesktopShell(
    BuildContext context, {
    required int activeTabIndex,
    required bool isFileDirty,
  }) {
    final state = context.watch<AppState>();

    return DesktopShell(
      mount: mount,
      activeTabIndex: activeTabIndex,
      focusedPaneTab: state.focusedPaneTab,
      isFileDirty: isFileDirty,
      explorerPaneOpen: state.explorerPaneOpen,
      gitPaneOpen: state.gitPaneOpen,
      onSelect: (screen) {
        // Git has no tab index: selecting it toggles its pane and hands it the
        // focus ring, leaving activeTabIndex on whatever pane was current.
        if (screen == AppScreen.git) {
          state.setGitPaneOpen(!state.gitPaneOpen);
          return;
        }
        // Re-selecting the visible explorer closes its pane; otherwise open it
        // and focus it. Every other screen is a plain tab switch.
        if (screen == AppScreen.explorer &&
            state.explorerPaneOpen &&
            state.focusedPaneTab == AppScreen.explorer.tabIndex) {
          state.setExplorerPaneOpen(false);
          return;
        }
        if (screen == AppScreen.explorer && !state.explorerPaneOpen) {
          state.setExplorerPaneOpen(true);
        }
        state.setActiveTabIndex(screen.tabIndex);
      },
    );
  }

  /// The historical phone layout: a top nav strip over one screen at a time.
  Widget _buildCompactShell(
    BuildContext context, {
    required int activeTabIndex,
    required bool isFileDirty,
    required bool hideTopNav,
  }) {
    return Column(
      children: [
        // Top navigation bar — keyboard-safe, hidden in terminal fullscreen.
        if (!hideTopNav)
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
                      active: activeTabIndex == i || (i == 4 && activeTabIndex >= 4),
                      dirty: i == 3 && isFileDirty,
                      onTap: () {
                        if (i == 4) {
                          _scaffoldKey.currentState?.openEndDrawer();
                        } else {
                          context.read<AppState>().setActiveTabIndex(i);
                        }
                      },
                    ),
                  );
                }),
              ),
            ),
          ),
        Expanded(
          child: IndexedStack(
            index: activeTabIndex,
            children: [for (final screen in AppScreen.inTabOrder) mount(screen)],
          ),
        ),
      ],
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
    final fg = active ? AppColors.accent : AppColors.muted;
    final iconSz = (18 * context.select<AppState, double>((s) => s.uiIconFactor)).roundToDouble();
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
                  Icon(spec.icon, size: iconSz, color: fg),
                  if (dirty)
                    Positioned(
                      right: -5,
                      top: -2,
                      child: Container(
                        width: 5,
                        height: 5,
                        color: AppColors.accent,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                spec.label,
                style: AppText.mono(
                  8,
                  color: fg,
                  weight: active ? FontWeight.w700 : FontWeight.w500,
                  spacing: 0.8,
                ),
              ),
            ],
          ),
          // Active indicator: 2px accent bar along the bottom edge.
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 2,
              color: active ? AppColors.accent : Colors.transparent,
            ),
          ),
        ],
      ),
    );
  }
}
