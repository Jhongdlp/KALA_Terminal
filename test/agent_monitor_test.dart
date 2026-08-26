import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_agent/models/agent_activity.dart';
import 'package:terminal_agent/services/agent_monitor.dart';

/// The dashboard's state store. Two properties carry the whole design: the
/// elapsed clock must survive a re-read of the same state, and a session that
/// keeps doing the same thing must not notify — the watch loop pushes into this
/// several times a second for as long as an agent is writing.
void main() {
  late AgentMonitor monitor;
  late int notifications;

  setUp(() {
    monitor = AgentMonitor();
    notifications = 0;
    monitor.addListener(() => notifications++);
  });

  tearDown(() => monitor.dispose());

  group('note', () {
    test('a first sighting is recorded and notifies', () {
      monitor.note('s1', AgentState.working);
      expect(monitor.forSession('s1')!.state, AgentState.working);
      expect(notifications, 1);
    });

    test('re-noting the same state does not notify', () {
      // This is what makes the dashboard nearly free: a busy agent writes
      // constantly while staying in exactly the same state.
      final t0 = DateTime(2026, 1, 1, 12);
      monitor.note('s1', AgentState.working, snippet: 'x', now: t0);
      expect(notifications, 1);

      for (var i = 0; i < 20; i++) {
        monitor.note('s1', AgentState.working,
            snippet: 'x', now: t0.add(Duration(milliseconds: 300 * i)));
      }
      expect(notifications, 1);
    });

    test('the elapsed clock does not reset while the state holds', () {
      final t0 = DateTime(2026, 1, 1, 12);
      monitor.note('s1', AgentState.waiting, now: t0);
      monitor.note('s1', AgentState.waiting, now: t0.add(const Duration(minutes: 4)));
      // "esperando 4 min" is the number the screen exists to show; recomputing
      // `since` on every read would peg it at zero forever.
      expect(monitor.forSession('s1')!.since, t0);
    });

    test('a real transition restarts the clock and notifies', () {
      final t0 = DateTime(2026, 1, 1, 12);
      final t1 = t0.add(const Duration(minutes: 4));
      monitor.note('s1', AgentState.working, now: t0);
      monitor.note('s1', AgentState.waiting, now: t1);
      expect(monitor.forSession('s1')!.since, t1);
      expect(notifications, 2);
    });

    test('a changed snippet notifies even when the state holds', () {
      // The agent asked a second question without going back to work: the
      // state is the same but the card is now wrong.
      final t0 = DateTime(2026, 1, 1, 12);
      monitor.note('s1', AgentState.waiting, snippet: '¿Sigo?', now: t0);
      monitor.note('s1', AgentState.waiting, snippet: '¿Borro?', now: t0);
      expect(notifications, 2);
      expect(monitor.forSession('s1')!.snippet, '¿Borro?');
    });

    test('an omitted snippet is kept, not wiped', () {
      // The connection handlers know the state and nothing else; they must not
      // erase the question that is still on screen.
      monitor.note('s1', AgentState.waiting, snippet: '¿Sigo?');
      monitor.note('s1', AgentState.disconnected);
      expect(monitor.forSession('s1')!.snippet, '¿Sigo?');
    });

    test('clearAgent drops the badge, which null cannot express', () {
      monitor.note('s1', AgentState.waiting,
          agentId: 'claude', agentLabel: 'Claude Code');
      // The agent exited to a shell prompt: announcing the next redraw under
      // its name would be a lie.
      monitor.note('s1', AgentState.prompt, clearAgent: true);
      expect(monitor.forSession('s1')!.agentId, isNull);
      expect(monitor.forSession('s1')!.agentLabel, isNull);
    });
  });

  group('counts', () {
    test('waitingCount only counts sessions actually asking', () {
      monitor.note('a', AgentState.waiting);
      monitor.note('b', AgentState.waiting);
      monitor.note('c', AgentState.working);
      monitor.note('d', AgentState.prompt);
      monitor.note('e', AgentState.disconnected);
      expect(monitor.waitingCount, 2);
    });

    test('summary buckets every state', () {
      monitor.note('a', AgentState.waiting);
      monitor.note('b', AgentState.working);
      monitor.note('c', AgentState.done);
      monitor.note('d', AgentState.prompt);
      monitor.note('e', AgentState.connecting);
      monitor.note('f', AgentState.disconnected);
      final s = monitor.summary;
      expect(s.waiting, 1);
      expect(s.working, 1);
      // "done" and "prompt" are both at rest as far as the summary line cares.
      expect(s.idle, 2);
      expect(s.offline, 2);
    });
  });

  group('lifecycle', () {
    test('removeSession drops it and notifies once', () {
      monitor.note('s1', AgentState.waiting);
      notifications = 0;
      monitor.removeSession('s1');
      expect(monitor.forSession('s1'), isNull);
      expect(notifications, 1);
      // Removing what is not there must not wake the UI.
      monitor.removeSession('s1');
      expect(notifications, 1);
    });

    test('clear empties everything, and is silent when already empty', () {
      monitor.note('s1', AgentState.waiting);
      notifications = 0;
      monitor.clear();
      expect(monitor.all, isEmpty);
      expect(notifications, 1);
      monitor.clear();
      expect(notifications, 1);
    });

    test('all is an unmodifiable view', () {
      monitor.note('s1', AgentState.waiting);
      expect(() => monitor.all.remove('s1'), throwsUnsupportedError);
    });
  });

  group('urgency', () {
    test('waiting sorts ahead of everything else', () {
      // The section order of the screen is this list, so it has to start with
      // the state that needs the user.
      expect(AgentState.waiting.urgency, 0);
      final sorted = AgentState.values.toList()
        ..sort((a, b) => a.urgency.compareTo(b.urgency));
      expect(sorted.first, AgentState.waiting);
      expect(sorted.last, AgentState.disconnected);
    });

    test('only live states carry a clock, and only waiting takes a reply', () {
      expect(AgentState.waiting.isTimed, isTrue);
      expect(AgentState.disconnected.isTimed, isFalse);
      expect(AgentState.waiting.acceptsReply, isTrue);
      // Typing into a working agent would land in the middle of its output.
      expect(AgentState.working.acceptsReply, isFalse);
    });
  });
}
