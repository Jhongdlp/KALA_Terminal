import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../services/update_service.dart';
import '../widgets/menu_drawer.dart';
import 'connections_tab.dart';
import 'terminal_tab.dart';
import 'explorer_tab.dart';
import 'editor_tab.dart';
import 'server_tab.dart';
import 'settings_tab.dart';
import 'update_dialog.dart';

class HomeView extends StatefulWidget {
  const HomeView({super.key});

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  static const _items = <_NavSpec>[
    _NavSpec('CONEXIONES', Icons.dns_outlined),
    _NavSpec('CONSOLA', Icons.terminal_outlined),
    _NavSpec('ARCHIVOS', Icons.folder_outlined),
    _NavSpec('EDITOR', Icons.code),
    _NavSpec('MENÚ', Icons.menu),
  ];

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // Timestamp of the last back press on the root tab, for double-back-to-exit.
  DateTime? _lastBackPress;

  @override
  void initState() {
    super.initState();
    // Silent, best-effort update check against GitHub Releases after the first
    // frame; only surfaces a dialog when a newer APK actually exists.
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdate());
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
          const SnackBar(
            content: Text('Presiona atrás de nuevo para salir'),
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

    const tabs = [
      ConnectionsTab(),
      TerminalTab(),
      ExplorerTab(),
      EditorTab(),
      ServerTab(),
      SettingsTab(),
    ];

    return PopScope(
      // Never let the system pop (= close) the activity directly; _onBackPressed
      // walks the in-app hierarchy and exits via SystemNavigator only on a
      // confirmed double press. Dialogs/sheets sit on their own routes above
      // this one, so back still dismisses them normally.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _onBackPressed();
      },
      child: Scaffold(
        key: _scaffoldKey,
        endDrawer: const MenuDrawer(),
        backgroundColor: AppColors.ink,
        resizeToAvoidBottomInset: activeTabIndex != 1,
        // Keep the soft keyboard from covering navigation: nav lives at the top,
        // the keyboard only ever pushes up the content below it.
        body: SafeArea(
          bottom: false,
          child: Column(
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
                child: IndexedStack(index: activeTabIndex, children: tabs),
              ),
            ],
          ),
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
