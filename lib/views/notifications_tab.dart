import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/notification_prefs.dart';
import '../providers/app_state.dart';
import '../services/notification_service.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';
import '../l10n/l10n.dart';

/// Everything about agent notifications in one place: which events raise an
/// alert, how loud each one is, when they're allowed through, how sensitive the
/// autodetector is, plus a test button and a log of recent decisions.
///
/// The log matters as much as the switches: the detector's job is guesswork
/// (is the agent asking, or just pausing?), and without a record of what fired
/// and why, a misfire can only be described from memory.
class NotificationsTab extends StatelessWidget {
  const NotificationsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = context.select<AppState, NotificationPrefs>(
        (s) => s.notificationPrefs);
    final state = context.read<AppState>();

    return ContentColumn(
      color: AppColors.ink,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          ScreenHeader(tr('Notificaciones'), eyebrow: tr('Avisos de agente')),

          const _PermissionWarning(),

          // ---- Master switch ---------------------------------------------
          SwissPanel(
            title: tr('General'),
            children: [
              ToggleRow(
                label: tr('AVISOS DE AGENTE'),
                description:
                    tr('Interruptor maestro. Con esto apagado no se envía ningún aviso, sin importar el resto de ajustes.'),
                value: prefs.enabled,
                onChanged: (v) =>
                    state.updateNotificationPrefs(prefs.copyWith(enabled: v)),
              ),
              const Hairline(),
              // Lives here rather than in Ajustes because it shares the
              // detector with the switch above: between the two of them they
              // decide whether the screen-watching loop runs at all.
              ToggleRow(
                label: tr('TABLERO DE AGENTES'),
                description: tr(
                    'Mantiene el estado en vivo de cada sesión para la pantalla Agentes. Se puede tener sin avisos, y avisos sin él; con ambos apagados no se vigila ninguna pantalla.'),
                value: context.select<AppState, bool>(
                    (s) => s.agentDashboardEnabled),
                onChanged: (v) => state.setAgentDashboardEnabled(v),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ---- Per-kind intensity ----------------------------------------
          SwissPanel(
            title: tr('Qué avisar y con cuánta fuerza'),
            children: [
              for (var i = 0; i < AlertKind.values.length; i++) ...[
                if (i > 0) Hairline(),
                _IntensityRow(
                  kind: AlertKind.values[i],
                  value: prefs.intensityFor(AlertKind.values[i]),
                  enabled: prefs.enabled,
                  onChanged: (level) {
                    final next =
                        Map<AlertKind, AlertIntensity>.from(prefs.intensity);
                    next[AlertKind.values[i]] = level;
                    state.updateNotificationPrefs(
                        prefs.copyWith(intensity: next));
                  },
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),

          // ---- When ------------------------------------------------------
          SwissPanel(
            title: tr('Cuándo'),
            children: [
              ToggleRow(
                label: tr('TAMBIÉN CON LA APP ABIERTA'),
                description:
                    tr('Si estás dentro de la app, marca la pestaña de la sesión en vez de enviar una notificación del sistema. Apagado, sólo avisa en segundo plano.'),
                value: prefs.when == AlertWhen.always,
                onChanged: (v) => state.updateNotificationPrefs(prefs.copyWith(
                    when: v ? AlertWhen.always : AlertWhen.backgroundOnly)),
              ),
              Hairline(),
              ToggleRow(
                label: tr('NO AVISAR DE LA SESIÓN ACTIVA'),
                description:
                    tr('No te avisa de la sesión que ya estás mirando en pantalla.'),
                value: prefs.skipActiveSession,
                onChanged: (v) => state.updateNotificationPrefs(
                    prefs.copyWith(skipActiveSession: v)),
              ),
              Hairline(),
              _QuietHoursRow(prefs: prefs),
            ],
          ),
          const SizedBox(height: 16),

          // ---- Detector sensitivity --------------------------------------
          SwissPanel(
            title: tr('Sensibilidad del detector'),
            children: [
              _IdleDelayRow(prefs: prefs),
              Hairline(),
              ToggleRow(
                label: tr('SÓLO SI HAY UN AGENTE'),
                description:
                    tr('Avisa de "pregunta" y "terminó" sólo cuando se detecta un agente en la sesión. Apagado, un terminal en el prompt también puede avisarte al salir de la app. La campana del programa avisa siempre.'),
                value: prefs.requireAgent,
                onChanged: (v) => state.updateNotificationPrefs(
                    prefs.copyWith(requireAgent: v)),
              ),
              Hairline(),
              ToggleRow(
                label: tr('LAS PAUSAS LARGAS NO SON EL FINAL'),
                description:
                    tr('Si el agente sigue mostrando un spinner o un "esc to interrupt", se considera que sigue trabajando y no se avisa. Es lo que evita los avisos falsos mientras piensa.'),
                value: prefs.suppressWhileBusy,
                onChanged: (v) => state.updateNotificationPrefs(
                    prefs.copyWith(suppressWhileBusy: v)),
              ),
              Hairline(),
              ToggleRow(
                label: tr('INCLUIR EXTRACTO DE LA PANTALLA'),
                description:
                    tr('Añade las últimas líneas del terminal al cuerpo del aviso. Apágalo si no quieres que salga contenido remoto en la pantalla de bloqueo.'),
                value: prefs.includeSnippet,
                onChanged: (v) => state.updateNotificationPrefs(
                    prefs.copyWith(includeSnippet: v)),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ---- Per-session ------------------------------------------------
          const _SessionsPanel(),
          const SizedBox(height: 16),

          // ---- Diagnostics -------------------------------------------------
          SwissPanel(
            title: tr('Diagnóstico'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 4),
                child: Text(
                  tr('Envía un aviso de cada tipo para comprobar que llegan y suenan como esperas.'),
                  style:
                      AppText.label(8.5, color: AppColors.faint, spacing: 0.3),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
                child: GhostButton(
                  label: tr('PROBAR NOTIFICACIÓN'),
                  onPressed: state.sendTestNotifications,
                ),
              ),
              Hairline(),
              const _AlertLogPanel(),
            ],
          ),
        ],
      ),
    );
  }
}

/// Surfaced only when Android is blocking notifications outright — no amount
/// of in-app configuration works until that is fixed, so it goes on top.
class _PermissionWarning extends StatefulWidget {
  const _PermissionWarning();

  @override
  State<_PermissionWarning> createState() => _PermissionWarningState();
}

class _PermissionWarningState extends State<_PermissionWarning> {
  bool _allowed = true;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final allowed = await NotificationService.areNotificationsEnabled();
    if (mounted) setState(() => _allowed = allowed);
  }

  @override
  Widget build(BuildContext context) {
    if (_allowed) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.accent, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('NOTIFICACIONES BLOQUEADAS'),
                style: AppText.label(9, color: AppColors.accent)),
            const SizedBox(height: 6),
            Text(
              tr('Android tiene bloqueadas las notificaciones de esta app, así que ningún ajuste de esta pantalla tendrá efecto.'),
              style: AppText.label(8.5, color: AppColors.faint, spacing: 0.3),
            ),
            const SizedBox(height: 10),
            GhostButton(
              label: tr('ABRIR AJUSTES DEL SISTEMA'),
              onPressed: () async {
                await NotificationService.openSystemSettings();
                await _check();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// One alert kind with its four-way intensity selector.
class _IntensityRow extends StatelessWidget {
  final AlertKind kind;
  final AlertIntensity value;
  final bool enabled;
  final ValueChanged<AlertIntensity> onChanged;

  const _IntensityRow({
    required this.kind,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(kind.label, style: AppText.label(9, color: AppColors.muted)),
            const SizedBox(height: 5),
            Text(kind.description,
                style:
                    AppText.label(8.5, color: AppColors.faint, spacing: 0.3)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final level in AlertIntensity.values)
                  _LevelChip(
                    label: level.label,
                    selected: level == value,
                    onTap: enabled ? () => onChanged(level) : null,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(value.description,
                style: AppText.label(8, color: AppColors.faint, spacing: 0.3)),
          ],
        ),
      ),
    );
  }
}

class _LevelChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  const _LevelChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.hairline;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: color, width: 1),
          color: selected ? AppColors.accent : Colors.transparent,
        ),
        child: Text(
          label,
          style: AppText.mono(8.5,
              color: selected ? AppColors.ink : AppColors.muted),
        ),
      ),
    );
  }
}

/// The idle threshold, as a slider. Exposed because the right value depends on
/// the agent and the machine: a fast local model pauses far less than a remote
/// one running long tool calls.
class _IdleDelayRow extends StatelessWidget {
  final NotificationPrefs prefs;
  const _IdleDelayRow({required this.prefs});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(tr('ESPERA ANTES DE AVISAR'),
                    style: AppText.label(9, color: AppColors.muted)),
              ),
              MonoTag('${prefs.idleDelaySeconds}S',
                  bordered: true, color: AppColors.accent),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            tr('Silencio que debe pasar antes de dar al agente por parado. Más bajo avisa antes, pero confunde una pausa larga con el final de la tarea.'),
            style: AppText.label(8.5, color: AppColors.faint, spacing: 0.3),
          ),
          Slider(
            value: prefs.idleDelaySeconds.toDouble().clamp(3, 30),
            min: 3,
            max: 30,
            divisions: 27,
            activeColor: AppColors.accent,
            inactiveColor: AppColors.hairline,
            label: '${prefs.idleDelaySeconds}s',
            onChanged: (v) => state.updateNotificationPrefs(
                prefs.copyWith(idleDelaySeconds: v.round())),
          ),
        ],
      ),
    );
  }
}

/// Quiet hours: a start/end time pair, or off.
class _QuietHoursRow extends StatelessWidget {
  final NotificationPrefs prefs;
  const _QuietHoursRow({required this.prefs});

  static String _format(int minutes) {
    final h = (minutes ~/ 60).toString().padLeft(2, '0');
    final m = (minutes % 60).toString().padLeft(2, '0');
    return '$h:$m';
  }

  Future<void> _pick(BuildContext context, {required bool isStart}) async {
    final state = context.read<AppState>();
    final current = isStart ? prefs.quietFromMinutes : prefs.quietToMinutes;
    final picked = await showTimePicker(
      context: context,
      initialTime: current != null
          ? TimeOfDay(hour: current ~/ 60, minute: current % 60)
          : TimeOfDay(hour: isStart ? 22 : 7, minute: 0),
    );
    if (picked == null) return;
    final minutes = picked.hour * 60 + picked.minute;
    state.updateNotificationPrefs(isStart
        ? prefs.copyWith(
            quietFromMinutes: minutes,
            quietToMinutes: prefs.quietToMinutes ?? 7 * 60)
        : prefs.copyWith(
            quietToMinutes: minutes,
            quietFromMinutes: prefs.quietFromMinutes ?? 22 * 60));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final on = prefs.quietFromMinutes != null && prefs.quietToMinutes != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 8, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr('HORARIO SILENCIOSO'),
                        style: AppText.label(9, color: AppColors.muted)),
                    const SizedBox(height: 5),
                    Text(
                      tr('Dentro de esta franja no se envía ningún aviso.'),
                      style: AppText.label(8.5,
                          color: AppColors.faint, spacing: 0.3),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Switch(
                value: on,
                onChanged: (v) => state.updateNotificationPrefs(v
                    ? prefs.copyWith(
                        quietFromMinutes: 22 * 60, quietToMinutes: 7 * 60)
                    : prefs.copyWith(clearQuietHours: true)),
                activeThumbColor: AppColors.ink,
                activeTrackColor: AppColors.accent,
                inactiveThumbColor: AppColors.muted,
                inactiveTrackColor: AppColors.hairline,
              ),
            ],
          ),
          if (on) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                GhostButton(
                  label: tr('DESDE {0}', [_format(prefs.quietFromMinutes!)]),
                  onPressed: () => _pick(context, isStart: true),
                ),
                const SizedBox(width: 8),
                GhostButton(
                  label: tr('HASTA {0}', [_format(prefs.quietToMinutes!)]),
                  onPressed: () => _pick(context, isStart: false),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Per-session controls: mute a chatty session, and correct the detected agent
/// when the guess is wrong (or the agent is one we don't know).
class _SessionsPanel extends StatelessWidget {
  const _SessionsPanel();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final sessions = state.sessions;
    if (sessions.isEmpty) return const SizedBox.shrink();
    final prefs = state.notificationPrefs;

    return SwissPanel(
      title: tr('Por sesión'),
      children: [
        for (var i = 0; i < sessions.length; i++) ...[
          if (i > 0) Hairline(),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(sessions[i].name.toUpperCase(),
                          style: AppText.label(9, color: AppColors.muted)),
                      const SizedBox(height: 4),
                      Text(
                        sessions[i].agentLabel != null
                            ? tr('Detectado: {0}', [sessions[i].agentLabel])
                            : tr('Agente no identificado'),
                        style: AppText.label(8,
                            color: AppColors.faint, spacing: 0.3),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(tr('SILENCIAR'),
                    style: AppText.mono(8, color: AppColors.faint)),
                Switch(
                  value: prefs.isMuted(sessions[i].id),
                  onChanged: (v) => state.setSessionMuted(sessions[i].id, v),
                  activeThumbColor: AppColors.ink,
                  activeTrackColor: AppColors.accent,
                  inactiveThumbColor: AppColors.muted,
                  inactiveTrackColor: AppColors.hairline,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// The last few alert decisions, delivered or dropped, each with its reason.
class _AlertLogPanel extends StatelessWidget {
  const _AlertLogPanel();

  static String _time(DateTime at) =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}:'
      '${at.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final log = context.select<AppState, List<AlertLogEntry>>(
        (s) => s.alertLog);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('ÚLTIMOS EVENTOS'),
              style: AppText.label(9, color: AppColors.muted)),
          const SizedBox(height: 5),
          Text(
            tr('Cada decisión del detector, se enviara o no, con su motivo.'),
            style: AppText.label(8.5, color: AppColors.faint, spacing: 0.3),
          ),
          const SizedBox(height: 10),
          if (log.isEmpty)
            Text(tr('Todavía no hay eventos registrados.'),
                style: AppText.mono(8.5, color: AppColors.faint))
          else
            for (final entry in log)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      margin: const EdgeInsets.only(top: 4, right: 8),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: entry.delivered
                            ? AppColors.accent
                            : AppColors.hairline,
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${_time(entry.at)} · ${entry.sessionName}'
                            '${entry.agentLabel != null ? ' · ${entry.agentLabel}' : ''}',
                            style:
                                AppText.mono(8.5, color: AppColors.muted),
                          ),
                          Text(
                            entry.delivered
                                ? tr('Enviado — {0}', [entry.kind.label])
                                : tr('Descartado — {0}', [entry.suppressedReason]),
                            style: AppText.label(8,
                                color: entry.delivered
                                    ? AppColors.accent
                                    : AppColors.faint,
                                spacing: 0.3),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
