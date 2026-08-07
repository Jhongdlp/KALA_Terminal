import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:terminal_agent/l10n/l10n.dart';
import 'package:terminal_agent/main.dart';
import 'package:terminal_agent/providers/app_state.dart';
import 'package:terminal_agent/services/tunnel_manager.dart';
import 'package:terminal_agent/views/editor_tab.dart';
import 'package:terminal_agent/views/explorer_tab.dart';
import 'package:terminal_agent/views/shell/desktop_shell.dart';
import 'package:terminal_agent/views/shell/nav_rail.dart';
import 'package:terminal_agent/views/terminal_tab.dart';
import 'package:terminal_agent/widgets/split_pane.dart';

/// Resize the test surface. Must run before `pumpWidget` for the first size,
/// and is pumped to settle afterwards for a change.
Future<void> _setSize(WidgetTester tester, Size logical) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = logical;
  await tester.pumpAndSettle();
}

Future<AppState> _pumpApp(WidgetTester tester, Size size) async {
  SharedPreferences.setMockInitialValues({});
  L10n.notifier.value = AppLang.es;
  await L10n.load();
  final state = AppState();

  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: state),
        ChangeNotifierProvider<TunnelManager>.value(value: state.tunnels),
      ],
      child: const MyApp(),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

void main() {
  testWidgets('a narrow window keeps the compact shell', (tester) async {
    await _pumpApp(tester, const Size(400, 800));

    expect(find.byType(NavRail), findsNothing);
    expect(find.byType(DesktopShell), findsNothing);
    // The compact shell's five-slot top strip.
    expect(find.text('CONEXIONES'), findsOneWidget);
  });

  testWidgets('a wide window shows the rail and the workspace split',
      (tester) async {
    final state = await _pumpApp(tester, const Size(1600, 900));
    state.setActiveTabIndex(1); // the terminal, i.e. the workspace
    await tester.pumpAndSettle();

    expect(find.byType(DesktopShell), findsOneWidget);
    expect(find.byType(NavRail), findsOneWidget);
    expect(find.byType(SplitPane), findsWidgets);

    // The point of the whole redesign: three screens on screen at once.
    expect(find.byType(TerminalTab), findsOneWidget);
    expect(find.byType(EditorTab), findsOneWidget);
    expect(find.byType(ExplorerTab), findsOneWidget);
  });

  testWidgets('crossing the breakpoint re-parents the live screens', (tester) async {
    final state = await _pumpApp(tester, const Size(400, 800));
    state.setActiveTabIndex(1);
    await tester.pumpAndSettle();

    // skipOffstage: false throughout — the compact shell keeps every screen but
    // the active one offstage in its IndexedStack, and the point here is the
    // identity of the State, not whether it is painted.
    State stateOf(Type type) =>
        tester.state(find.byType(type, skipOffstage: false));

    final terminalBefore = stateOf(TerminalTab);
    final editorBefore = stateOf(EditorTab);

    await _setSize(tester, const Size(1600, 900));

    // This is the assertion the GlobalKey registry exists for. If someone puts
    // an AnimatedSwitcher between the two shells, or mounts a screen in two
    // places, the State is rebuilt instead of re-parented and a live terminal
    // loses its FocusNode, scroll position and controller on every resize.
    expect(
      identical(stateOf(TerminalTab), terminalBefore),
      isTrue,
      reason: 'the compact→desktop swap must re-parent TerminalTab, not rebuild it',
    );
    expect(
      identical(stateOf(EditorTab), editorBefore),
      isTrue,
      reason: 'the compact→desktop swap must re-parent EditorTab, not rebuild it',
    );

    await _setSize(tester, const Size(400, 800));

    expect(
      identical(stateOf(TerminalTab), terminalBefore),
      isTrue,
      reason: 'and back again',
    );
  });

  testWidgets('navigation state survives a breakpoint crossing', (tester) async {
    final state = await _pumpApp(tester, const Size(400, 800));
    state.setActiveTabIndex(3); // editor
    await tester.pumpAndSettle();

    expect(state.focusedPaneTab, 3);

    await _setSize(tester, const Size(1600, 900));
    expect(state.activeTabIndex, 3);
    expect(state.focusedPaneTab, 3);
    expect(state.sessions.length, 0);

    await _setSize(tester, const Size(400, 800));
    expect(state.activeTabIndex, 3);
    expect(state.focusedPaneTab, 3);
  });
}
