import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:terminal_agent/l10n/l10n.dart';
import 'package:terminal_agent/models/agent_launcher.dart';
import 'package:terminal_agent/providers/app_state.dart';

/// One-tap agent launchers.
///
/// A launcher is only worth a tile if its command exists on the far side, so a
/// shipped default that names the wrong binary has to be corrected on setups
/// that already stored it — while never touching a command the user wrote.
Future<AppState> _state() async {
  L10n.notifier.value = AppLang.es;
  await L10n.load();
  final state = AppState();
  // Settings load asynchronously from prefs.
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  return state;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("the Antigravity launcher's command is corrected to agy", () async {
    // Antigravity's binary is `agy`; the launcher shipped with the long name,
    // so tapping it only ever printed "command not found".
    final owned = [
      const AgentLauncher(
          id: 'antigravity',
          name: 'Antigravity',
          command: 'antigravity',
          iconId: 'antigravity'),
      const AgentLauncher(
          id: 'mine', name: 'Mío', command: 'antigravity --yolo'),
    ];
    SharedPreferences.setMockInitialValues({
      'settings_agent_launchers': AgentLauncher.encodeList(owned),
    });
    final state = await _state();

    expect(state.agentLaunchers.first.command, 'agy');
    // A command the user typed is theirs, wrong or not.
    expect(state.agentLaunchers.last.command, 'antigravity --yolo');
  });

  test('a launcher command the user edited is never rewritten', () async {
    final owned = [
      const AgentLauncher(
          id: 'antigravity',
          name: 'Antigravity',
          command: 'cd ~/repo && antigravity',
          iconId: 'antigravity'),
    ];
    SharedPreferences.setMockInitialValues({
      'settings_agent_launchers': AgentLauncher.encodeList(owned),
    });
    final state = await _state();

    expect(state.agentLaunchers.single.command, 'cd ~/repo && antigravity');
  });

  test('a fresh install launches Antigravity with agy', () async {
    SharedPreferences.setMockInitialValues({});
    final state = await _state();

    expect(
      state.agentLaunchers.firstWhere((l) => l.id == 'antigravity').command,
      'agy',
    );
  });
}
