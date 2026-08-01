import 'dart:convert';
import '../l10n/l10n.dart';

/// How loudly a class of alert is delivered. Maps onto a distinct Android
/// notification channel, because importance can only be set when a channel is
/// created — changing the level swaps the channel rather than editing it.
enum AlertIntensity {
  /// Heads-up banner, sound and vibration.
  high,

  /// Posted with sound, but no heads-up banner.
  medium,

  /// Silent: it shows in the shade only.
  low,

  /// Never posted.
  off,
}

extension AlertIntensityLabel on AlertIntensity {
  String get label => switch (this) {
        AlertIntensity.high => tr('ALTA'),
        AlertIntensity.medium => tr('MEDIA'),
        AlertIntensity.low => tr('BAJA'),
        AlertIntensity.off => tr('NO AVISAR'),
      };

  String get description => switch (this) {
        AlertIntensity.high => tr('Banner emergente, sonido y vibración.'),
        AlertIntensity.medium => tr('Suena, pero sin banner emergente.'),
        AlertIntensity.low => tr('Silenciosa: sólo aparece en la bandeja.'),
        AlertIntensity.off => tr('Este tipo de aviso no se envía.'),
      };
}

/// The kinds of event that can raise an alert. Each one is configured
/// independently so a noisy class can be turned down without losing the rest —
/// the old single on/off switch forced an all-or-nothing choice.
enum AlertKind {
  /// The agent stopped and appears to be waiting for an answer.
  question,

  /// The agent stopped writing without asking anything.
  done,

  /// The program explicitly signalled (BEL, OSC 9, OSC 777).
  bell,

  /// The session's SSH connection dropped.
  disconnect,
}

extension AlertKindLabel on AlertKind {
  String get key => name;

  String get label => switch (this) {
        AlertKind.question => tr('EL AGENTE PREGUNTA'),
        AlertKind.done => tr('EL AGENTE TERMINÓ'),
        AlertKind.bell => tr('CAMPANA DEL PROGRAMA'),
        AlertKind.disconnect => tr('SESIÓN CAÍDA'),
      };

  String get description => switch (this) {
        AlertKind.question =>
          tr('Espera tu respuesta: una pregunta, un permiso o un menú de selección.'),
        AlertKind.done =>
          tr('Dejó de escribir sin pedirte nada, normalmente porque acabó la tarea.'),
        AlertKind.bell =>
          tr('El programa pidió tu atención explícitamente (campana u OSC 9/777). Es la señal más fiable.'),
        AlertKind.disconnect =>
          tr('Se perdió la conexión SSH de una sesión que estaba viva.'),
      };
}

/// When alerts are allowed to reach the user.
enum AlertWhen {
  /// Only while the app is not visible.
  backgroundOnly,

  /// Also with the app open — resolved as an in-app badge and haptic on the
  /// session tab rather than as a system notification.
  always,
}

/// Looks an enum value up by its `name`, returning null instead of throwing so
/// a blob written by a newer build (unknown kind or level) degrades to the
/// default rather than wiping the whole configuration.
T? _byName<T extends Enum>(List<T> values, Object? name) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}

/// Every setting behind agent notifications, persisted as one JSON blob.
///
/// Replaces the single `settings_agent_alerts` boolean; [fromLegacy] carries
/// that old value over so nobody who had alerts switched off gets them back
/// after updating.
class NotificationPrefs {
  /// Master switch: off means nothing is ever posted, whatever the rest says.
  final bool enabled;

  /// Per-kind delivery level.
  final Map<AlertKind, AlertIntensity> intensity;

  final AlertWhen when;

  /// Suppress alerts for the session the user is already looking at.
  final bool skipActiveSession;

  /// Seconds of silence before a stopped agent counts as stopped. Lower reacts
  /// faster but risks announcing a pause mid-task as a finished task.
  final int idleDelaySeconds;

  /// Treat spinners and "esc to interrupt" status lines as "still working".
  /// On by default; exposed mainly so a misbehaving agent can be debugged.
  final bool suppressWhileBusy;

  /// Include a few lines of the terminal in the notification body. Off keeps
  /// remote output off the lock screen.
  final bool includeSnippet;

  /// Quiet hours, as minutes past midnight. Null disables the window.
  final int? quietFromMinutes;
  final int? quietToMinutes;

  /// Session ids the user muted individually.
  final Set<String> mutedSessionIds;

  const NotificationPrefs({
    this.enabled = true,
    this.intensity = const {},
    this.when = AlertWhen.always,
    this.skipActiveSession = true,
    this.idleDelaySeconds = 7,
    this.suppressWhileBusy = true,
    this.includeSnippet = true,
    this.quietFromMinutes,
    this.quietToMinutes,
    this.mutedSessionIds = const {},
  });

  /// Defaults: questions and completions are equally loud (both are things the
  /// user is actively waiting for), the bell follows them, and a dropped
  /// connection is informational.
  static const Map<AlertKind, AlertIntensity> defaultIntensity = {
    AlertKind.question: AlertIntensity.high,
    AlertKind.done: AlertIntensity.high,
    AlertKind.bell: AlertIntensity.high,
    AlertKind.disconnect: AlertIntensity.low,
  };

  AlertIntensity intensityFor(AlertKind kind) =>
      intensity[kind] ?? defaultIntensity[kind] ?? AlertIntensity.high;

  /// Whether [kind] should produce anything at all right now.
  bool allows(AlertKind kind, {required DateTime at}) {
    if (!enabled) return false;
    if (intensityFor(kind) == AlertIntensity.off) return false;
    return !isQuiet(at);
  }

  /// Whether [at] falls inside the quiet-hours window. Handles windows that
  /// wrap past midnight (22:00 → 07:00).
  bool isQuiet(DateTime at) {
    final from = quietFromMinutes;
    final to = quietToMinutes;
    if (from == null || to == null || from == to) return false;
    final minutes = at.hour * 60 + at.minute;
    return from < to
        ? minutes >= from && minutes < to
        : minutes >= from || minutes < to;
  }

  bool isMuted(String sessionId) => mutedSessionIds.contains(sessionId);

  NotificationPrefs copyWith({
    bool? enabled,
    Map<AlertKind, AlertIntensity>? intensity,
    AlertWhen? when,
    bool? skipActiveSession,
    int? idleDelaySeconds,
    bool? suppressWhileBusy,
    bool? includeSnippet,
    int? quietFromMinutes,
    int? quietToMinutes,
    bool clearQuietHours = false,
    Set<String>? mutedSessionIds,
  }) {
    return NotificationPrefs(
      enabled: enabled ?? this.enabled,
      intensity: intensity ?? this.intensity,
      when: when ?? this.when,
      skipActiveSession: skipActiveSession ?? this.skipActiveSession,
      idleDelaySeconds: idleDelaySeconds ?? this.idleDelaySeconds,
      suppressWhileBusy: suppressWhileBusy ?? this.suppressWhileBusy,
      includeSnippet: includeSnippet ?? this.includeSnippet,
      quietFromMinutes:
          clearQuietHours ? null : (quietFromMinutes ?? this.quietFromMinutes),
      quietToMinutes:
          clearQuietHours ? null : (quietToMinutes ?? this.quietToMinutes),
      mutedSessionIds: mutedSessionIds ?? this.mutedSessionIds,
    );
  }

  /// Same defaults as [NotificationPrefs.new], but honouring the old boolean.
  factory NotificationPrefs.fromLegacy(bool agentAlertsEnabled) =>
      NotificationPrefs(enabled: agentAlertsEnabled);

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'intensity': {
          for (final e in intensity.entries) e.key.name: e.value.name,
        },
        'when': when.name,
        'skipActiveSession': skipActiveSession,
        'idleDelaySeconds': idleDelaySeconds,
        'suppressWhileBusy': suppressWhileBusy,
        'includeSnippet': includeSnippet,
        'quietFromMinutes': quietFromMinutes,
        'quietToMinutes': quietToMinutes,
        'mutedSessionIds': mutedSessionIds.toList(),
      };

  factory NotificationPrefs.fromJson(Map<String, dynamic> json) {
    final intensity = <AlertKind, AlertIntensity>{};
    final rawIntensity = json['intensity'];
    if (rawIntensity is Map) {
      for (final entry in rawIntensity.entries) {
        final kind = _byName(AlertKind.values, entry.key);
        final level = _byName(AlertIntensity.values, entry.value);
        if (kind != null && level != null) intensity[kind] = level;
      }
    }
    return NotificationPrefs(
      enabled: json['enabled'] as bool? ?? true,
      intensity: intensity,
      when: json['when'] == AlertWhen.backgroundOnly.name
          ? AlertWhen.backgroundOnly
          : AlertWhen.always,
      skipActiveSession: json['skipActiveSession'] as bool? ?? true,
      idleDelaySeconds: (json['idleDelaySeconds'] as num?)?.toInt() ?? 7,
      suppressWhileBusy: json['suppressWhileBusy'] as bool? ?? true,
      includeSnippet: json['includeSnippet'] as bool? ?? true,
      quietFromMinutes: (json['quietFromMinutes'] as num?)?.toInt(),
      quietToMinutes: (json['quietToMinutes'] as num?)?.toInt(),
      mutedSessionIds: {
        ...?(json['mutedSessionIds'] as List?)?.map((e) => e.toString()),
      },
    );
  }

  String encode() => jsonEncode(toJson());

  static NotificationPrefs decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) return NotificationPrefs.fromJson(json);
    } catch (_) {
      // Corrupt blob — fall through to defaults rather than losing alerts.
    }
    return const NotificationPrefs();
  }
}

/// One entry of the in-app diagnostics log: why an alert was or wasn't sent.
/// Exposed in the notifications screen so a misfire can be inspected after the
/// fact instead of reconstructed from memory.
class AlertLogEntry {
  final DateTime at;
  final String sessionName;
  final AlertKind kind;
  final String? agentLabel;

  /// Null when the alert was delivered; otherwise why it was dropped.
  final String? suppressedReason;

  final String detail;

  const AlertLogEntry({
    required this.at,
    required this.sessionName,
    required this.kind,
    required this.detail,
    this.agentLabel,
    this.suppressedReason,
  });

  bool get delivered => suppressedReason == null;
}
