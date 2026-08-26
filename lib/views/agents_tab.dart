import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/format.dart';
import '../l10n/l10n.dart';
import '../models/agent_activity.dart';
import '../providers/app_state.dart';
import '../services/agent_monitor.dart';
import '../theme/app_theme.dart';
import '../theme/breakpoints.dart';
import '../theme/dimens.dart';
import '../widgets/profile_tint.dart';
import '../widgets/swiss.dart';
import '../widgets/tap_target.dart';
import 'shell/app_screen.dart';

/// The agents dashboard: which session needs you right now, and what for.
///
/// Four terminals running four agents are four identical black rectangles of
/// monospaced text. Finding the one that stopped to ask a question means
/// visiting each tab and reading it — and the cost of *not* finding it is an
/// agent idling for twenty minutes on a question that took two seconds to
/// answer.
///
/// Everything here is derived: `AppState`'s watch loop already classifies every
/// session's screen on each output batch to decide whether to post a
/// notification. [AgentMonitor] is that decision kept instead of discarded.
class AgentsTab extends StatefulWidget {
  const AgentsTab({super.key});

  @override
  State<AgentsTab> createState() => _AgentsTabState();
}

class _AgentsTabState extends State<AgentsTab> {
  /// Repaints the elapsed-time counters. Ten seconds, not one: below a minute
  /// the counters are drawn in whole seconds and a ten-second lag is invisible
  /// against "esperando 4 min", while a per-second timer would rebuild the
  /// screen 3600 times an hour to move nothing.
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Arms the ticker only while something on screen is actually counting, so a
  /// dashboard full of disconnected sessions costs nothing.
  void _syncTicker(bool needed) {
    if (needed == (_ticker != null)) return;
    if (needed) {
      _ticker = Timer.periodic(const Duration(seconds: 10), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    // Watched directly, like the tunnels screen watches its manager: the state
    // it carries changes far more often than the rest of the app.
    final monitor = context.watch<AgentMonitor>();

    // Sessions in tab order, paired with their activity. Order is fixed here
    // and never re-sorted inside a section: cards reshuffling under the finger
    // while an agent changes state is exactly how the wrong one gets tapped.
    final rows = <({int index, AgentActivity activity})>[];
    for (var i = 0; i < state.sessions.length; i++) {
      final session = state.sessions[i];
      rows.add((
        index: i,
        activity: monitor.forSession(session.id) ??
            AgentActivity(
              sessionId: session.id,
              // A session the watch loop has not reached yet is reported by its
              // connection, which is always known. Claiming "en el prompt"
              // before anything was read would be a guess.
              state: session.connectionStatus == ConnectionStatus.remote
                  ? AgentState.prompt
                  : AgentState.disconnected,
              since: DateTime.now(),
            ),
      ));
    }

    _syncTicker(rows.any((r) => r.activity.state.isTimed));

    final summary = monitor.summary;

    return ContentColumn(
      color: AppColors.ink,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          ScreenHeader(
            tr('AGENTES'),
            eyebrow: rows.isEmpty
                ? tr('ESTADO EN VIVO')
                : tr('{0} SESIONES', [rows.length]),
          ),
          if (rows.isEmpty)
            const _EmptyState()
          else ...[
            _SummaryLine(summary: summary),
            for (final group in AgentState.values)
              if (rows.any((r) => r.activity.state == group)) ...[
                _StateSection(
                  group: group,
                  rows: rows
                      .where((r) => r.activity.state == group)
                      .toList(growable: false),
                  state: state,
                ),
                const SizedBox(height: 16),
              ],
          ],
        ],
      ),
    );
  }
}

/// "2 esperando · 1 trabajando · 1 en reposo" — the whole screen in one line,
/// for the glance that does not need the cards.
class _SummaryLine extends StatelessWidget {
  final ({int waiting, int working, int idle, int offline}) summary;

  const _SummaryLine({required this.summary});

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      if (summary.waiting > 0) tr('{0} esperando', [summary.waiting]),
      if (summary.working > 0) tr('{0} trabajando', [summary.working]),
      if (summary.idle > 0) tr('{0} en reposo', [summary.idle]),
      if (summary.offline > 0) tr('{0} sin conexión', [summary.offline]),
    ];
    if (parts.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Text(
        parts.join(' · '),
        style: AppText.mono(
          11,
          color: summary.waiting > 0 ? AppColors.accent : AppColors.muted,
        ),
      ),
    );
  }
}

class _StateSection extends StatelessWidget {
  final AgentState group;
  final List<({int index, AgentActivity activity})> rows;
  final AppState state;

  const _StateSection({
    required this.group,
    required this.rows,
    required this.state,
  });

  @override
  Widget build(BuildContext context) {
    return SwissPanel(
      title: group.label,
      trailing: MonoTag('${rows.length}'),
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const Hairline(),
          _AgentCard(
            sessionIndex: rows[i].index,
            activity: rows[i].activity,
            state: state,
          ),
        ],
      ],
    );
  }
}

class _AgentCard extends StatelessWidget {
  final int sessionIndex;
  final AgentActivity activity;
  final AppState state;

  const _AgentCard({
    required this.sessionIndex,
    required this.activity,
    required this.state,
  });

  @override
  Widget build(BuildContext context) {
    final session = state.sessions[sessionIndex];
    final profile = session.activeProfile;
    final tint = profileTint(profile);
    final stateColor = activity.state.color;

    final card = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          state.switchSession(sessionIndex);
          state.setActiveTabIndex(AppScreen.terminal.tabIndex);
        },
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              16,
              // maybeOf, not of: the card is also mounted directly by its
              // widget test, outside the shell that publishes the Layout.
              Dim.rowPadV(
                  Layout.maybeOf(context)?.widthClass ?? WidthClass.compact),
              12,
              12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(activity.state.icon, size: 16, color: stateColor),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      activity.agentLabel ?? session.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body(13,
                          color: AppColors.bone, weight: FontWeight.w700),
                    ),
                  ),
                  if (profile?.isProduction ?? false) ...[
                    const SizedBox(width: 6),
                    ProdBadge(tint: tint),
                  ],
                  const Spacer(),
                  MonoTag(activity.state.label, bordered: true,
                      color: stateColor),
                  if (activity.state.isTimed) ...[
                    const SizedBox(width: 6),
                    Text(
                      elapsedShort(DateTime.now().difference(activity.since)),
                      style: AppText.mono(10, color: AppColors.muted),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _meta(session),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.mono(9, color: AppColors.muted, spacing: 1),
              ),
              if (activity.snippet.isNotEmpty) ...[
                const SizedBox(height: 8),
                // The question itself, and it sits **above** the reply buttons
                // on purpose: it is the only thing standing between "answer the
                // agent" and "type into the wrong machine".
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  color: AppColors.panelHi,
                  child: Text(
                    activity.snippet,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.mono(10, color: AppColors.bone),
                  ),
                ),
              ],
              if (activity.state.acceptsReply) ...[
                const SizedBox(height: 10),
                _ReplyBar(session: session, state: state),
              ],
            ],
          ),
        ),
      ),
    );

    if (tint == null) return card;
    // Stacked, not prepended to the Row: a tinted card has to keep exactly the
    // alignment of an untinted one (same rule as LayerRow and the sessions
    // sheet).
    return Stack(
      children: [
        card,
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: Container(width: 3, color: tint),
        ),
      ],
    );
  }

  String _meta(TerminalSession session) {
    final profile = session.activeProfile;
    if (profile == null) return session.name.toUpperCase();
    return '${session.name} · ${profile.username}@${profile.host}'
        .toUpperCase();
  }
}

/// The reply controls, offered only on a session that is actually asking
/// something (see [AgentStateLabel.acceptsReply]).
class _ReplyBar extends StatefulWidget {
  final TerminalSession session;
  final AppState state;

  const _ReplyBar({required this.session, required this.state});

  @override
  State<_ReplyBar> createState() => _ReplyBarState();
}

class _ReplyBarState extends State<_ReplyBar> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Sends [text] after confirming, when the machine is marked as production.
  ///
  /// Marking a profile as production has to mean something on every surface
  /// that can touch it — and this is the one surface that types into a session
  /// the user is not looking at.
  Future<void> _send(String text,
      {bool submit = false, bool asPaste = false, String? describe}) async {
    final session = widget.session;
    final profile = session.activeProfile;

    if (profile?.isProduction ?? false) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.panel,
          title: Text(tr('ENVIAR A PRODUCCIÓN'),
              style: AppText.label(11, color: AppColors.bone, spacing: 1.4)),
          content: Text(
            tr('"{0}" está marcada como producción. ¿Enviar {1} a {2}?', [
              profile!.name,
              describe ?? '"$text"',
              session.name,
            ]),
            style: AppText.body(12, color: AppColors.bone),
          ),
          actions: [
            GhostButton(
              label: tr('Cancelar'),
              dense: true,
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
            GhostButton(
              label: tr('Enviar'),
              dense: true,
              danger: true,
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    final sent = widget.state.sendToSession(session.id, text,
        submit: submit, asPaste: asPaste);
    if (!mounted) return;
    if (!sent) {
      // Never swallow a keystroke the user believes they sent.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('La sesión no está conectada; no se envió nada.')),
      ));
      return;
    }
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            GhostButton(
              label: 'y',
              dense: true,
              onPressed: () => _send('y', submit: true),
            ),
            GhostButton(
              label: 'n',
              dense: true,
              onPressed: () => _send('n', submit: true),
            ),
            GhostButton(
              label: tr('ENTER'),
              dense: true,
              onPressed: () =>
                  _send('', submit: true, describe: tr('un Enter')),
            ),
            GhostButton(
              label: tr('ESC'),
              dense: true,
              // Raw, never as a paste: wrapped in bracketed-paste markers an
              // Esc is just text.
              onPressed: () => _send('\x1b', describe: tr('un Esc')),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                style: AppText.mono(11, color: AppColors.bone),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: tr('escribir respuesta…'),
                  hintStyle: AppText.mono(11, color: AppColors.faint),
                ),
                onSubmitted: (v) {
                  if (v.trim().isEmpty) return;
                  _send(v, submit: true, asPaste: true);
                },
              ),
            ),
            const SizedBox(width: 6),
            IconTapTarget(
              icon: Icons.send,
              label: tr('Enviar respuesta'),
              size: 16,
              onTap: () {
                final v = _controller.text;
                if (v.trim().isEmpty) return;
                _send(v, submit: true, asPaste: true);
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('NO HAY SESIONES ABIERTAS'),
              style: AppText.label(11, color: AppColors.bone, spacing: 1.4)),
          const SizedBox(height: 8),
          Text(
            tr('Cuando tengas varias sesiones con agentes, esta pantalla dice cuál se detuvo a preguntarte algo y desde hace cuánto, sin entrar en cada pestaña.'),
            style: AppText.body(12, color: AppColors.muted),
          ),
        ],
      ),
    );
  }
}
