import 'package:flutter/foundation.dart';

import '../models/agent_activity.dart';

/// Live per-session agent activity, for the agents dashboard.
///
/// **Its own `ChangeNotifier`, deliberately.** The watch loop in `AppState`
/// re-inspects a session's screen every 300ms for as long as output keeps
/// flowing; notifying through `AppState` there would rebuild the whole app
/// several times a second. Same split — and the same reason — as
/// `TunnelManager`'s byte counters and `ServerController`'s refreshes: owned by
/// `AppState`, provided alongside it, listened to only by what needs it.
///
/// The second half of that guarantee is [note], which compares before it
/// notifies. An agent that is working writes constantly while staying in
/// exactly the same dashboard state, so a busy session costs nothing to watch.
class AgentMonitor extends ChangeNotifier {
  final Map<String, AgentActivity> _activity = {};

  Map<String, AgentActivity> get all => Map.unmodifiable(_activity);

  AgentActivity? forSession(String sessionId) => _activity[sessionId];

  /// Sessions asking for an answer right now. Drives the badge on the drawer,
  /// the rail and the compact nav strip — knowing without opening the screen is
  /// arguably worth more than the screen.
  int get waitingCount =>
      _activity.values.where((a) => a.state == AgentState.waiting).length;

  /// Counts for the one-line summary above the sections.
  ({int waiting, int working, int idle, int offline}) get summary {
    var waiting = 0, working = 0, idle = 0, offline = 0;
    for (final a in _activity.values) {
      switch (a.state) {
        case AgentState.waiting:
          waiting++;
        case AgentState.working:
          working++;
        case AgentState.done:
        case AgentState.prompt:
          idle++;
        case AgentState.connecting:
        case AgentState.disconnected:
          offline++;
      }
    }
    return (waiting: waiting, working: working, idle: idle, offline: offline);
  }

  /// Moves [sessionId] into [state], keeping the elapsed clock running when the
  /// state has not actually changed.
  ///
  /// Notifies **only** on a real change (see the class doc). [snippet],
  /// [agentId] and [agentLabel] are left alone when omitted, so a caller that
  /// only knows the state — the connection handlers, say — cannot wipe the
  /// question that is on screen; [clearAgent] is how the badge is dropped when
  /// the agent has actually exited.
  void note(
    String sessionId,
    AgentState state, {
    String? snippet,
    String? agentId,
    String? agentLabel,
    bool clearAgent = false,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    final previous = _activity[sessionId];
    final next = previous == null
        ? AgentActivity(
            sessionId: sessionId,
            state: state,
            since: at,
            snippet: snippet ?? '',
            agentId: clearAgent ? null : agentId,
            agentLabel: clearAgent ? null : agentLabel,
          )
        : previous.moveTo(
            state,
            now: at,
            snippet: snippet,
            agentId: agentId,
            agentLabel: agentLabel,
            clearAgent: clearAgent,
          );

    if (next == previous) return;
    _activity[sessionId] = next;
    notifyListeners();
  }

  /// Drops a session's activity. Called from the same places that already tell
  /// `TunnelManager` a session is gone.
  void removeSession(String sessionId) {
    if (_activity.remove(sessionId) == null) return;
    notifyListeners();
  }

  void clear() {
    if (_activity.isEmpty) return;
    _activity.clear();
    notifyListeners();
  }
}
