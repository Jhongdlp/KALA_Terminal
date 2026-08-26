import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_theme.dart';

/// What a session is doing, as one value, for the agents dashboard.
///
/// This is the *derived* half of the agent detector: `AppState` already decides
/// all of this on every output batch in order to answer "should I buzz the
/// phone", and then throws it away. Keeping it means the question the dashboard
/// exists for — which of my six agents needs me — can be answered without
/// opening six tabs.
///
/// Declaration order is [urgency] order, and that is what the screen's sections
/// are sorted by.
enum AgentState {
  /// The agent stopped and is asking something: a question, a permission, a
  /// selection menu. The one state that justifies the whole screen.
  waiting,

  /// The agent stopped writing without asking anything — normally a finished
  /// task.
  done,

  /// Output is moving, or the screen still offers a way to interrupt.
  working,

  /// An idle shell prompt: connected, but nothing is running.
  prompt,

  /// Dialling (including any jump hops).
  connecting,

  /// No live SSH connection.
  disconnected,
}

extension AgentStateLabel on AgentState {
  /// Section heading and chip text. Uppercase, like every other label here.
  String get label => switch (this) {
        AgentState.waiting => tr('ESPERANDO'),
        AgentState.done => tr('TERMINÓ'),
        AgentState.working => tr('TRABAJANDO'),
        AgentState.prompt => tr('EN EL PROMPT'),
        AgentState.connecting => tr('CONECTANDO'),
        AgentState.disconnected => tr('SIN CONEXIÓN'),
      };

  /// One line saying what the state means, for the section header.
  String get description => switch (this) {
        AgentState.waiting =>
          tr('Se detuvo esperando una respuesta tuya: una pregunta, un permiso o un menú.'),
        AgentState.done =>
          tr('Dejó de escribir sin pedirte nada, normalmente porque acabó.'),
        AgentState.working => tr('Está produciendo salida ahora mismo.'),
        AgentState.prompt =>
          tr('Conectada, con el prompt libre y nada corriendo.'),
        AgentState.connecting => tr('Abriendo la conexión.'),
        AgentState.disconnected => tr('Sin conexión SSH viva.'),
      };

  /// Sorting weight — lower is more urgent. Ties are broken by tab order, never
  /// by anything that moves on its own: cards reshuffling under the finger is
  /// exactly how the wrong machine gets tapped.
  int get urgency => index;

  /// Whether the elapsed-time counter is worth drawing. A disconnected session
  /// has no clock anybody cares about.
  bool get isTimed =>
      this == AgentState.waiting ||
      this == AgentState.done ||
      this == AgentState.working;

  /// Whether the user can answer from the card. Only a session that is actually
  /// asking something gets reply buttons: offering them on a working agent
  /// would push a stray keystroke into the middle of its output.
  bool get acceptsReply => this == AgentState.waiting;

  /// Read lazily, never stored: the palette entries are mutable statics swapped
  /// on every theme change.
  ///
  /// The palette is deliberately monochrome — the profile tint is the one hue
  /// allowed in — so the states are separated by *weight*, not by hue:
  /// accent for the one that needs you, bone for alive, muted for resting.
  Color get color => switch (this) {
        AgentState.waiting => AppColors.accent,
        AgentState.done => AppColors.bone,
        AgentState.working => AppColors.bone,
        AgentState.prompt => AppColors.muted,
        AgentState.connecting => AppColors.muted,
        AgentState.disconnected => AppColors.danger,
      };

  IconData get icon => switch (this) {
        AgentState.waiting => Icons.pending_outlined,
        AgentState.done => Icons.check_circle_outline,
        AgentState.working => Icons.autorenew,
        AgentState.prompt => Icons.chevron_right,
        AgentState.connecting => Icons.hourglass_empty,
        AgentState.disconnected => Icons.link_off,
      };
}

/// A session's activity as the dashboard sees it.
///
/// Immutable and compared by value, which is the whole point: `AgentMonitor`
/// only notifies its listeners when one of these actually changes. An agent
/// that is working writes output several times a second while staying in the
/// same state, and rebuilding the screen on every one of those batches would
/// cost more than the screen is worth.
@immutable
class AgentActivity {
  final String sessionId;
  final AgentState state;

  /// When the session *entered* [state]. Deliberately not "last output": the
  /// number worth showing is how long an agent has been waiting on you, and
  /// that clock must not reset because a spinner ticked.
  final DateTime since;

  /// The last meaningful lines of the screen (`AgentScreen.snippet`) — the
  /// question actually being asked. Without it the dashboard is a row of
  /// coloured lights.
  final String snippet;

  /// Detected agent, for the badge. Null when none was identified.
  final String? agentId;
  final String? agentLabel;

  const AgentActivity({
    required this.sessionId,
    required this.state,
    required this.since,
    this.snippet = '',
    this.agentId,
    this.agentLabel,
  });

  /// The same activity with a new [state], keeping [since] when the state did
  /// not actually change — a card that says "esperando 4 min" must not reset to
  /// zero every time the screen is re-read.
  ///
  /// Omitted fields are kept, so a caller that only knows the connection
  /// changed cannot wipe the question that is on screen. Dropping the badge is
  /// therefore an explicit [clearAgent], the same way `ConnectionProfile`
  /// spells out `clearGroupId`: the agent exiting at a prompt has to take its
  /// name with it, and "null means leave it alone" cannot express that.
  AgentActivity moveTo(
    AgentState next, {
    required DateTime now,
    String? snippet,
    String? agentId,
    String? agentLabel,
    bool clearAgent = false,
  }) =>
      AgentActivity(
        sessionId: sessionId,
        state: next,
        since: next == state ? since : now,
        snippet: snippet ?? this.snippet,
        agentId: clearAgent ? null : (agentId ?? this.agentId),
        agentLabel: clearAgent ? null : (agentLabel ?? this.agentLabel),
      );

  @override
  bool operator ==(Object other) =>
      other is AgentActivity &&
      other.sessionId == sessionId &&
      other.state == state &&
      other.since == since &&
      other.snippet == snippet &&
      other.agentId == agentId &&
      other.agentLabel == agentLabel;

  @override
  int get hashCode =>
      Object.hash(sessionId, state, since, snippet, agentId, agentLabel);

  @override
  String toString() => 'AgentActivity($sessionId, ${state.name}, since $since)';
}
