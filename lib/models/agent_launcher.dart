import 'dart:convert';

/// A one-tap way to start a coding agent in the terminal.
///
/// Typing `claude --dangerously-skip-permissions` on a phone keyboard is the
/// kind of thing nobody does twice, so the flags a user always wants belong in
/// the launcher, not in their fingers. The command is stored **verbatim** and
/// sent verbatim: it is the user's own shell line, not something the app
/// composes, so anything their shell accepts works — `cd repo && claude`,
/// `npx opencode`, a wrapper script.
///
/// The [iconId] deliberately reuses the ids the agent *detector* already uses
/// (`AppState._agentMarkers`) and that the Android notification badges are
/// keyed by (`AlertNotifier.agentBadge`). One vocabulary, so the mark on the
/// launcher, the badge on the notification and the label on the agents
/// dashboard are the same agent's.
class AgentLauncher {
  final String id;

  /// Shown under the icon. Not translated: these are product names.
  final String name;

  /// The exact shell line to send.
  final String command;

  /// Which mark to draw — an entry of [kAgentIcons], or anything unknown,
  /// which falls back to the generic mark rather than to a blank tile.
  final String iconId;

  /// Whether tapping runs the command (Enter appended) or only types it.
  ///
  /// Default true, because the whole point is one tap. False is for a launcher
  /// whose line the user finishes by hand — `ssh-add && claude --model `, say.
  final bool autoRun;

  final bool enabled;

  const AgentLauncher({
    required this.id,
    required this.name,
    required this.command,
    this.iconId = 'generic',
    this.autoRun = true,
    this.enabled = true,
  });

  /// Asset path of the mark. Unknown ids resolve to the generic one, so an
  /// entry that survives an icon being removed still draws something.
  String get assetPath =>
      'assets/agents/${kAgentIcons.contains(iconId) ? iconId : 'generic'}.png';

  AgentLauncher copyWith({
    String? name,
    String? command,
    String? iconId,
    bool? autoRun,
    bool? enabled,
  }) =>
      AgentLauncher(
        id: id,
        name: name ?? this.name,
        command: command ?? this.command,
        iconId: iconId ?? this.iconId,
        autoRun: autoRun ?? this.autoRun,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'command': command,
        'iconId': iconId,
        'autoRun': autoRun,
        'enabled': enabled,
      };

  factory AgentLauncher.fromMap(Map<String, dynamic> map) => AgentLauncher(
        id: map['id'] as String? ?? '',
        name: map['name'] as String? ?? '',
        command: map['command'] as String? ?? '',
        iconId: map['iconId'] as String? ?? 'generic',
        // Older entries predate these flags; both default to the useful value.
        autoRun: map['autoRun'] as bool? ?? true,
        enabled: map['enabled'] as bool? ?? true,
      );

  static String encodeList(List<AgentLauncher> list) =>
      jsonEncode(list.map((l) => l.toMap()).toList());

  /// Never throws: a corrupt blob costs the user their launcher list, and
  /// throwing here would cost them the app's startup.
  static List<AgentLauncher> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final data = jsonDecode(raw);
      if (data is! List) return const [];
      return data
          .whereType<Map>()
          .map((m) => AgentLauncher.fromMap(Map<String, dynamic>.from(m)))
          .where((l) => l.id.isNotEmpty && l.name.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }
}

/// The marks that ship with the app, in `assets/agents/`.
///
/// `generic` is last and is the fallback: a new agent the user adds before we
/// have its mark still gets a tile rather than a hole.
const List<String> kAgentIcons = [
  'claude',
  'antigravity',
  'codex',
  'gemini',
  'aider',
  'opencode',
  'copilot',
  'cursor',
  'qwen',
  'generic',
];

/// What a fresh install starts with.
///
/// Commands are the bare binary, with **no** flags: a launcher that silently
/// added `--dangerously-skip-permissions` would be making a security decision
/// on the user's behalf. The flags are exactly what the editor is for, and the
/// permission-skipping ones are one tap away for whoever actually wants them.
const List<AgentLauncher> kDefaultAgentLaunchers = [
  AgentLauncher(
      id: 'claude', name: 'Claude Code', command: 'claude', iconId: 'claude'),
  AgentLauncher(
      id: 'antigravity',
      name: 'Antigravity',
      command: 'antigravity',
      iconId: 'antigravity'),
  AgentLauncher(id: 'codex', name: 'Codex', command: 'codex', iconId: 'codex'),
  AgentLauncher(
      id: 'gemini', name: 'Gemini CLI', command: 'gemini', iconId: 'gemini'),
  AgentLauncher(id: 'aider', name: 'Aider', command: 'aider', iconId: 'aider'),
  AgentLauncher(
      id: 'opencode',
      name: 'OpenCode',
      command: 'opencode',
      iconId: 'opencode'),
  AgentLauncher(
      id: 'copilot',
      name: 'Copilot CLI',
      command: 'copilot',
      iconId: 'copilot',
      enabled: false),
  AgentLauncher(
      id: 'cursor',
      name: 'Cursor',
      command: 'cursor-agent',
      iconId: 'cursor',
      enabled: false),
  AgentLauncher(
      id: 'qwen',
      name: 'Qwen Code',
      command: 'qwen',
      iconId: 'qwen',
      enabled: false),
];

/// Flags worth offering in the editor, so the most-wanted one is not a typo
/// away. Spanish source text is the l10n key; the flag itself is never
/// translated.
const List<(String agentId, String flag, String description)>
    kCommonAgentFlags = [
  ('claude', '--dangerously-skip-permissions',
      'No pregunta antes de cada acción. Úsalo solo en máquinas donde confíes.'),
  ('codex', '--full-auto',
      'Ejecuta sin pedir confirmación en cada paso.'),
  ('aider', '--yes-always', 'Responde que sí a todo automáticamente.'),
];
