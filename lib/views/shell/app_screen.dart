/// The app's top-level screens, in their historical tab-index order.
///
/// This is the stable *identity* of a screen, independent of how it is
/// presented: the compact shell shows one at a time in an `IndexedStack`, the
/// desktop shell puts the paneable ones side by side. `AppState.activeTabIndex`
/// keeps storing the plain index, so every existing call site is unaffected.
///
/// The git panel joins this enum as a paneable screen with no tab index once it
/// has a desktop mount (it is a route pushed from the terminal toolbar today).
enum AppScreen {
  connections(0),
  terminal(1),
  explorer(2),
  editor(3),
  server(4),
  settings(5),
  personalization(6),
  about(7),
  notifications(8),
  tunnels(9),
  agents(10),

  /// The git panel. It has no tab index: on the compact layout it is a route
  /// pushed from the terminal toolbar, and on the desktop shell it is a real
  /// pane. Excluded from [inTabOrder] for that reason.
  git(-1);

  const AppScreen(this.tabIndex);

  /// Index into `AppState.activeTabIndex` / the compact shell's `IndexedStack`.
  final int tabIndex;

  static AppScreen fromTab(int index) => values.firstWhere(
        (screen) => screen.tabIndex == index,
        orElse: () => AppScreen.connections,
      );

  /// The tab-backed screens in `IndexedStack` order. The compact shell indexes
  /// its stack directly with `activeTabIndex`, so declaration order has to keep
  /// matching [tabIndex] — reordering the enum without this assert would
  /// silently show the wrong screen.
  static List<AppScreen> get inTabOrder {
    final tabbed = values.where((screen) => screen.tabIndex >= 0).toList();
    assert(
      tabbed.every((screen) => tabbed.indexOf(screen) == screen.tabIndex),
      'AppScreen declaration order must match tabIndex',
    );
    return tabbed;
  }

  /// Screens that can share the desktop workspace simultaneously. Everything
  /// else takes the whole canvas beside the rail.
  bool get isPaneable =>
      this == terminal || this == explorer || this == editor || this == git;
}
