import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_agent/l10n/strings_en.dart';
import 'package:terminal_agent/l10n/strings_zh.dart';
import 'package:terminal_agent/models/agent_launcher.dart';

/// One-tap agent launchers. The command is the user's own shell line and is
/// stored and sent verbatim, so what matters here is that nothing mangles it
/// and that a broken stored blob never costs more than the list itself.
void main() {
  group('persistence', () {
    test('a launcher survives a JSON round trip', () {
      const launcher = AgentLauncher(
        id: 'x',
        name: 'Claude Code',
        command: 'claude --dangerously-skip-permissions',
        iconId: 'claude',
        autoRun: false,
        enabled: false,
      );
      final back = AgentLauncher.decodeList(
          AgentLauncher.encodeList([launcher])).single;
      expect(back.id, 'x');
      expect(back.name, 'Claude Code');
      expect(back.command, 'claude --dangerously-skip-permissions');
      expect(back.iconId, 'claude');
      expect(back.autoRun, isFalse);
      expect(back.enabled, isFalse);
    });

    test('a command with quotes and && is stored untouched', () {
      // The whole contract: this is a shell line, not something we compose.
      const raw = r'''cd "/srv/my repo" && ENV=1 claude --model 'sonnet' ''';
      const launcher =
          AgentLauncher(id: 'x', name: 'n', command: raw, iconId: 'generic');
      expect(
        AgentLauncher.decodeList(AgentLauncher.encodeList([launcher]))
            .single
            .command,
        raw,
      );
    });

    test('an entry written before the flags existed keeps working', () {
      final back = AgentLauncher.fromMap({
        'id': 'old',
        'name': 'Aider',
        'command': 'aider',
      });
      expect(back.iconId, 'generic');
      // Both default to the useful value rather than to false.
      expect(back.autoRun, isTrue);
      expect(back.enabled, isTrue);
    });

    test('a corrupt blob costs the list, never the launch', () {
      for (final raw in ['', 'not json', '{"not":"a list"}', '[1, 2, 3]']) {
        expect(AgentLauncher.decodeList(raw), isEmpty, reason: raw);
      }
      expect(AgentLauncher.decodeList(null), isEmpty);
    });

    test('entries with no id or no name are dropped, not drawn blank', () {
      const json = '[{"id":"","name":"x","command":"c"},'
          '{"id":"y","name":"","command":"c"},'
          '{"id":"z","name":"ok","command":"c"}]';
      expect(AgentLauncher.decodeList(json).map((l) => l.id), ['z']);
    });
  });

  group('icons', () {
    test('an unknown icon falls back to the generic mark, not to a hole', () {
      const launcher = AgentLauncher(
          id: 'x', name: 'Nuevo', command: 'nuevo', iconId: 'does-not-exist');
      expect(launcher.assetPath, 'assets/agents/generic.png');
    });

    test('a known icon resolves to its own asset', () {
      const launcher = AgentLauncher(
          id: 'x', name: 'Claude', command: 'claude', iconId: 'claude');
      expect(launcher.assetPath, 'assets/agents/claude.png');
    });

    test('generic is available as a real choice', () {
      expect(kAgentIcons, contains('generic'));
    });
  });

  group('defaults', () {
    test('ship no permission-skipping flags', () {
      // Adding those silently would be making a security decision for the
      // user. They are one tap away in the editor for whoever wants them.
      for (final launcher in kDefaultAgentLaunchers) {
        expect(launcher.command, isNot(contains('--')),
            reason: '${launcher.id} ships a flag');
      }
    });

    test('every default has a unique id and a bundled mark', () {
      final ids = kDefaultAgentLaunchers.map((l) => l.id).toList();
      expect(ids.toSet().length, ids.length);
      for (final launcher in kDefaultAgentLaunchers) {
        expect(kAgentIcons, contains(launcher.iconId),
            reason: '${launcher.id} has no bundled mark');
      }
    });
  });

  group('suggested flags', () {
    test('every description is translated', () {
      // Drawn via tr(description), so scripts/i18n_check.py cannot see them.
      for (final (_, _, description) in kCommonAgentFlags) {
        expect(enStrings.containsKey(description), isTrue,
            reason: 'no English translation for: $description');
        expect(zhStrings.containsKey(description), isTrue,
            reason: 'no Chinese translation for: $description');
      }
    });

    test('each one targets an agent that actually ships', () {
      final ids = kDefaultAgentLaunchers.map((l) => l.id).toSet();
      for (final (agentId, _, _) in kCommonAgentFlags) {
        expect(ids, contains(agentId));
      }
    });
  });

  group('copyWith', () {
    test('keeps the id and changes only what is named', () {
      const launcher = AgentLauncher(
          id: 'x', name: 'A', command: 'a', iconId: 'aider', autoRun: true);
      final edited = launcher.copyWith(command: 'a --yes-always');
      expect(edited.id, 'x');
      expect(edited.name, 'A');
      expect(edited.iconId, 'aider');
      expect(edited.autoRun, isTrue);
      expect(edited.command, 'a --yes-always');
    });
  });
}
