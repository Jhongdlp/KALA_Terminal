import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:terminal_agent/l10n/l10n.dart';
import 'package:terminal_agent/models/agent_activity.dart';
import 'package:terminal_agent/models/connection_profile.dart';
import 'package:terminal_agent/providers/app_state.dart';
import 'package:terminal_agent/services/agent_monitor.dart';
import 'package:terminal_agent/views/agents_tab.dart';
import 'package:terminal_agent/widgets/agent_waiting_badge.dart';

/// The dashboard screen. What is pinned down here is the part that is not
/// obvious from reading it: the urgency order of the sections, that a reply is
/// only ever offered on a session that is actually asking, and that a
/// production machine cannot be typed into without a confirmation.
ConnectionProfile _profile({bool isProduction = false}) => ConnectionProfile(
      id: 'p1',
      name: 'prod-web',
      host: '10.0.0.1',
      port: 22,
      username: 'root',
      isProduction: isProduction,
    );

/// Creates a disconnected session, the way [AppState._restoreSessions] does.
String _addSession(AppState state, String name, {ConnectionProfile? profile}) {
  state.createNewSession(
    profile: profile ?? _profile(),
    sessionName: name,
    connect: false,
  );
  return state.sessions.last.id;
}

Future<AppState> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({'onboarding_seen_v1': true});
  L10n.notifier.value = AppLang.es;
  await L10n.load();

  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(800, 1600);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final state = AppState();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: state),
        ChangeNotifierProvider<AgentMonitor>.value(value: state.agents),
      ],
      child: const MaterialApp(home: Scaffold(body: AgentsTab())),
    ),
  );
  await tester.pump();
  return state;
}

void main() {
  testWidgets('with no sessions it explains what the screen is for',
      (tester) async {
    await _pump(tester);
    expect(find.text('NO HAY SESIONES ABIERTAS'), findsOneWidget);
  });

  testWidgets('one card per session, grouped by state', (tester) async {
    final state = await _pump(tester);
    final a = _addSession(state, 'alpha');
    final b = _addSession(state, 'beta');
    state.agents.note(a, AgentState.waiting, snippet: '¿Aplico el cambio?');
    state.agents.note(b, AgentState.working);
    await tester.pump();

    expect(find.text('ESPERANDO'), findsWidgets);
    expect(find.text('TRABAJANDO'), findsWidgets);
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);
  });

  testWidgets('the waiting section is drawn above the working one',
      (tester) async {
    final state = await _pump(tester);
    // Deliberately created in the wrong order: the screen sorts by urgency,
    // not by tab index, or the session that needs you sits below three that
    // don't.
    final working = _addSession(state, 'trabaja');
    final waiting = _addSession(state, 'pregunta');
    state.agents.note(working, AgentState.working);
    state.agents.note(waiting, AgentState.waiting, snippet: '¿Sigo?');
    await tester.pump();

    expect(
      tester.getTopLeft(find.text('pregunta')).dy,
      lessThan(tester.getTopLeft(find.text('trabaja')).dy),
    );
  });

  testWidgets('the question is shown on the card', (tester) async {
    final state = await _pump(tester);
    final id = _addSession(state, 'alpha');
    state.agents.note(id, AgentState.waiting,
        snippet: '¿Aplico el cambio a auth.ts? (y/n)');
    await tester.pump();
    expect(find.text('¿Aplico el cambio a auth.ts? (y/n)'), findsOneWidget);
  });

  testWidgets('reply buttons appear only on a waiting session',
      (tester) async {
    final state = await _pump(tester);
    final id = _addSession(state, 'alpha');

    state.agents.note(id, AgentState.working);
    await tester.pump();
    expect(find.text('Y'), findsNothing);

    state.agents.note(id, AgentState.waiting, snippet: '¿Sigo?');
    await tester.pump();
    // GhostButton uppercases its label at draw time.
    expect(find.text('Y'), findsOneWidget);
    expect(find.text('N'), findsOneWidget);
    expect(find.text('ESC'), findsOneWidget);
  });

  testWidgets('a production machine asks before anything is sent',
      (tester) async {
    final state = await _pump(tester);
    final id = _addSession(state, 'alpha',
        profile: _profile(isProduction: true));
    state.agents.note(id, AgentState.waiting, snippet: '¿Borro la tabla?');
    await tester.pump();

    await tester.tap(find.text('Y'));
    await tester.pumpAndSettle();

    expect(find.text('ENVIAR A PRODUCCIÓN'), findsOneWidget);
    // Cancelling must send nothing; the session is disconnected anyway, which
    // is the second guard.
    await tester.tap(find.text('CANCELAR'));
    await tester.pumpAndSettle();
    expect(find.text('ENVIAR A PRODUCCIÓN'), findsNothing);
  });

  testWidgets('a non-production machine sends without a dialog',
      (tester) async {
    final state = await _pump(tester);
    final id = _addSession(state, 'alpha', profile: _profile());
    state.agents.note(id, AgentState.waiting, snippet: '¿Sigo?');
    await tester.pump();

    await tester.tap(find.text('Y'));
    await tester.pumpAndSettle();
    expect(find.text('ENVIAR A PRODUCCIÓN'), findsNothing);
    // Disconnected, so nothing was written and the user is told so rather than
    // being left believing the keystroke landed.
    expect(find.text('La sesión no está conectada; no se envió nada.'),
        findsOneWidget);
  });

  testWidgets('tapping a card focuses that session and the terminal',
      (tester) async {
    final state = await _pump(tester);
    _addSession(state, 'alpha');
    final b = _addSession(state, 'beta');
    state.agents.note(b, AgentState.waiting, snippet: '¿Sigo?');
    state.switchSession(0);
    await tester.pump();

    await tester.tap(find.text('beta'));
    await tester.pumpAndSettle();

    expect(state.sessions[state.activeSessionIndex].name, 'beta');
    expect(state.activeTabIndex, 1);
  });

  group('AgentWaitingBadge', () {
    testWidgets('draws nothing when nobody is waiting', (tester) async {
      final monitor = AgentMonitor();
      addTearDown(monitor.dispose);
      monitor.note('s1', AgentState.working);
      await tester.pumpWidget(ChangeNotifierProvider<AgentMonitor>.value(
        value: monitor,
        child: const MaterialApp(home: AgentWaitingBadge()),
      ));
      expect(find.text('1'), findsNothing);
    });

    testWidgets('counts the sessions asking for an answer', (tester) async {
      final monitor = AgentMonitor();
      addTearDown(monitor.dispose);
      monitor.note('s1', AgentState.waiting);
      monitor.note('s2', AgentState.waiting);
      monitor.note('s3', AgentState.working);
      await tester.pumpWidget(ChangeNotifierProvider<AgentMonitor>.value(
        value: monitor,
        child: const MaterialApp(home: AgentWaitingBadge()),
      ));
      expect(find.text('2'), findsOneWidget);
    });
  });
}
