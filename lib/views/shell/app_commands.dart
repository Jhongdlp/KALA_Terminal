import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../providers/app_state.dart';
import '../backup_sheet.dart';
import '../command_history_sheet.dart';
import '../git_panel_sheet.dart';
import '../prompts_sheet.dart';
import '../shortcuts_help_sheet.dart';

/// Where a command belongs in the help sheet and the palette.
enum CommandSection { sessions, navigation, terminal, app }

extension CommandSectionLabel on CommandSection {
  /// Spanish source string, translated at draw time.
  String get label => switch (this) {
        CommandSection.sessions => tr('Sesiones'),
        CommandSection.navigation => tr('Navegación'),
        CommandSection.terminal => tr('Terminal'),
        CommandSection.app => tr('Aplicación'),
      };
}

/// One thing the app can be told to do.
///
/// A single registry behind three surfaces — the keyboard bindings, the command
/// palette and the shortcut reference — because the alternative is what most
/// apps have: a keymap, a menu and a help page that disagree with each other.
class AppCommand {
  final String id;

  /// Spanish source text; run through `tr()` where it is drawn.
  final String label;
  final IconData icon;
  final CommandSection section;

  /// Physical binding, when it has one. Palette-only commands leave it null.
  final ShortcutActivator? activator;

  /// Whether it can run right now (e.g. anything needing a live session).
  final bool Function(AppState state)? enabled;

  final void Function(BuildContext context, AppState state) run;

  const AppCommand({
    required this.id,
    required this.label,
    required this.icon,
    required this.section,
    required this.run,
    this.activator,
    this.enabled,
  });

  bool isEnabled(AppState state) => enabled?.call(state) ?? true;
}

/// The app's commands.
///
/// **Why Ctrl+Shift+letter, and nothing else.** App shortcuts sit *above* the
/// focused widget, so the terminal sees every key first and anything it claims
/// never reaches here. Two separate things claim keys:
///
///  - `CtrlInputHandler` folds Ctrl+letter into a control code — Ctrl+C,
///    Ctrl+W, Ctrl+T are the shell's, and stealing them would break the thing
///    the app exists for. It bows out the moment Shift is held, which is what
///    makes Ctrl+Shift+letter safe (and matches every desktop terminal).
///  - The **keytab** claims whole keys regardless of modifiers: `Tab`, the
///    arrows, Home/End, PgUp/PgDn and **F1–F12** all have records
///    (`key F1 -AnyMod : "\EOP"`). A binding on any of those is dead while the
///    terminal has focus — which is most of the time. That is why there is no
///    Ctrl+Tab here and no F1: they looked obvious and silently did nothing.
///
/// `test/ux_features_test.dart` pins both rules down.
List<AppCommand> appCommands() => <AppCommand>[
      // ---- Sessions --------------------------------------------------------
      AppCommand(
        id: 'session.new',
        label: 'Nueva sesión',
        icon: Icons.add_circle_outline,
        section: CommandSection.sessions,
        activator: const SingleActivator(LogicalKeyboardKey.keyT,
            control: true, shift: true),
        run: (context, state) {
          final profile = state.activeSession?.activeProfile;
          // Same server again is what "new tab" means in a terminal; with no
          // session to clone from, the connections screen is the honest answer.
          if (profile != null) {
            state.connectToSSH(profile);
          } else {
            state.setActiveTabIndex(0);
          }
        },
      ),
      AppCommand(
        id: 'session.close',
        label: 'Cerrar sesión actual',
        icon: Icons.close,
        section: CommandSection.sessions,
        activator: const SingleActivator(LogicalKeyboardKey.keyW,
            control: true, shift: true),
        enabled: (state) => state.sessions.isNotEmpty,
        run: (context, state) {
          final index = state.activeSessionIndex;
          if (index < 0 || index >= state.sessions.length) return;
          final session = state.sessions[index];
          final profile = session.activeProfile;
          state.closeSession(index);
          // SSH can't be un-closed, but reconnecting the same profile is the
          // thing the user actually wants after a mis-hit.
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(
              content: Text(tr('Sesión "{0}" cerrada', [session.name])),
              action: profile == null
                  ? null
                  : SnackBarAction(
                      label: tr('Reconectar'),
                      onPressed: () => state.connectToSSH(profile),
                    ),
            ));
        },
      ),
      AppCommand(
        id: 'session.next',
        label: 'Siguiente sesión',
        icon: Icons.arrow_forward,
        section: CommandSection.sessions,
        // "." and "," rather than Tab: the keytab claims Tab with and without
        // Shift, so Ctrl+Tab would only ever send a literal tab to the shell.
        activator: const SingleActivator(LogicalKeyboardKey.period,
            control: true, shift: true),
        enabled: (state) => state.sessions.length > 1,
        run: (context, state) => _cycleSession(state, 1),
      ),
      AppCommand(
        id: 'session.prev',
        label: 'Sesión anterior',
        icon: Icons.arrow_back,
        section: CommandSection.sessions,
        activator: const SingleActivator(LogicalKeyboardKey.comma,
            control: true, shift: true),
        enabled: (state) => state.sessions.length > 1,
        run: (context, state) => _cycleSession(state, -1),
      ),

      // ---- Navigation ------------------------------------------------------
      AppCommand(
        id: 'nav.connections',
        label: 'Ir a Conexiones',
        icon: Icons.dns_outlined,
        section: CommandSection.navigation,
        activator: const SingleActivator(LogicalKeyboardKey.keyO,
            control: true, shift: true),
        run: (context, state) => state.setActiveTabIndex(0),
      ),
      AppCommand(
        id: 'nav.terminal',
        label: 'Ir a la consola',
        icon: Icons.terminal_outlined,
        section: CommandSection.navigation,
        activator: const SingleActivator(LogicalKeyboardKey.keyJ,
            control: true, shift: true),
        run: (context, state) => state.setActiveTabIndex(1),
      ),
      AppCommand(
        id: 'nav.explorer',
        label: 'Ir al explorador',
        icon: Icons.folder_outlined,
        section: CommandSection.navigation,
        activator: const SingleActivator(LogicalKeyboardKey.keyE,
            control: true, shift: true),
        run: (context, state) => state.setActiveTabIndex(2),
      ),
      AppCommand(
        id: 'nav.editor',
        label: 'Ir al editor',
        icon: Icons.code,
        section: CommandSection.navigation,
        activator: const SingleActivator(LogicalKeyboardKey.keyD,
            control: true, shift: true),
        run: (context, state) => state.setActiveTabIndex(3),
      ),
      AppCommand(
        id: 'panel.git',
        label: 'Panel de Git',
        icon: Icons.difference_outlined,
        section: CommandSection.navigation,
        activator: const SingleActivator(LogicalKeyboardKey.keyG,
            control: true, shift: true),
        run: (context, state) => showGitPanel(context, state),
      ),

      // ---- Terminal --------------------------------------------------------
      AppCommand(
        id: 'terminal.search',
        label: 'Buscar en la salida',
        icon: Icons.search,
        section: CommandSection.terminal,
        activator: const SingleActivator(LogicalKeyboardKey.keyF,
            control: true, shift: true),
        run: (context, state) {
          state.setActiveTabIndex(1);
          state.setTerminalSearchOpen(true);
        },
      ),
      AppCommand(
        id: 'terminal.history',
        label: 'Historial de comandos',
        icon: Icons.history,
        section: CommandSection.terminal,
        activator: const SingleActivator(LogicalKeyboardKey.keyH,
            control: true, shift: true),
        run: (context, state) => showCommandHistorySheet(context),
      ),
      AppCommand(
        id: 'terminal.prompts',
        label: 'Prompts guardados',
        icon: Icons.bookmark_border,
        section: CommandSection.terminal,
        activator: const SingleActivator(LogicalKeyboardKey.keyB,
            control: true, shift: true),
        run: (context, state) => showPromptsSheet(context),
      ),
      AppCommand(
        id: 'terminal.quickKeys',
        label: 'Mostrar / ocultar teclas rápidas',
        icon: Icons.keyboard_outlined,
        section: CommandSection.terminal,
        activator: const SingleActivator(LogicalKeyboardKey.keyK,
            control: true, shift: true),
        run: (context, state) => state.toggleQuickKeys(),
      ),
      AppCommand(
        id: 'terminal.dictation',
        label: 'Barra de dictado',
        icon: Icons.mic_none_outlined,
        section: CommandSection.terminal,
        run: (context, state) => state.toggleComposeBar(),
      ),
      AppCommand(
        id: 'terminal.fullscreen',
        label: 'Pantalla completa',
        icon: Icons.open_in_full,
        section: CommandSection.terminal,
        // Not F11: the keytab claims every function key.
        activator: const SingleActivator(LogicalKeyboardKey.keyX,
            control: true, shift: true),
        run: (context, state) =>
            state.setTerminalFullscreen(!state.terminalFullscreen),
      ),

      // ---- App -------------------------------------------------------------
      AppCommand(
        id: 'app.palette',
        label: 'Paleta de comandos',
        icon: Icons.bolt_outlined,
        section: CommandSection.app,
        activator: const SingleActivator(LogicalKeyboardKey.keyP,
            control: true, shift: true),
        // Filled in by the shell, which owns the palette route. Declared here
        // so it shows up in the reference like every other command.
        run: (context, state) {},
      ),
      AppCommand(
        id: 'app.settings',
        label: 'Ajustes',
        icon: Icons.tune,
        section: CommandSection.app,
        activator: const SingleActivator(LogicalKeyboardKey.comma,
            control: true),
        run: (context, state) => state.setActiveTabIndex(5),
      ),
      AppCommand(
        id: 'app.personalization',
        label: 'Personalización',
        icon: Icons.palette_outlined,
        section: CommandSection.app,
        run: (context, state) => state.setActiveTabIndex(6),
      ),
      AppCommand(
        id: 'app.tunnels',
        label: 'Túneles',
        icon: Icons.swap_horiz,
        section: CommandSection.app,
        run: (context, state) => state.setActiveTabIndex(9),
      ),
      AppCommand(
        id: 'app.agents',
        label: 'Agentes',
        icon: Icons.smart_toy_outlined,
        section: CommandSection.app,
        activator: const SingleActivator(LogicalKeyboardKey.keyA,
            control: true, shift: true),
        run: (context, state) => state.setActiveTabIndex(10),
      ),
      AppCommand(
        id: 'app.notifications',
        label: 'Notificaciones',
        icon: Icons.notifications_active_outlined,
        section: CommandSection.app,
        run: (context, state) => state.setActiveTabIndex(8),
      ),
      AppCommand(
        id: 'app.backup',
        label: 'Copia de seguridad',
        icon: Icons.backup_outlined,
        section: CommandSection.app,
        run: (context, state) => showBackupSheet(context),
      ),
      AppCommand(
        id: 'app.help',
        label: 'Atajos y gestos',
        icon: Icons.help_outline,
        section: CommandSection.app,
        // Not F1, for the same reason as fullscreen.
        activator: const SingleActivator(LogicalKeyboardKey.keyI,
            control: true, shift: true),
        run: (context, state) => showShortcutsHelpSheet(context),
      ),
    ];

void _cycleSession(AppState state, int delta) {
  final count = state.sessions.length;
  if (count < 2) return;
  var next = (state.activeSessionIndex + delta) % count;
  if (next < 0) next += count;
  state.switchSession(next);
}

/// Key bindings for [CallbackShortcuts], including the Alt+1…9 session jumps
/// (which are generated rather than listed: nine near-identical registry
/// entries would bury the rest of the reference).
Map<ShortcutActivator, VoidCallback> appShortcutBindings(
  BuildContext context,
  AppState state, {
  Map<String, VoidCallback> overrides = const {},
}) {
  final bindings = <ShortcutActivator, VoidCallback>{};

  for (final command in appCommands()) {
    final activator = command.activator;
    if (activator == null) continue;
    final override = overrides[command.id];
    bindings[activator] = () {
      if (!command.isEnabled(state)) return;
      if (override != null) {
        override();
      } else {
        command.run(context, state);
      }
    };
  }

  const digits = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];
  for (var i = 0; i < digits.length; i++) {
    bindings[SingleActivator(digits[i], alt: true)] = () {
      if (i < state.sessions.length) state.switchSession(i);
    };
  }

  return bindings;
}

/// Renders an activator the way a keyboard shortcut is written down.
///
/// Modifier order is fixed (Ctrl, Alt, Shift, Meta) so the same combination
/// always reads the same way, and the trigger uses the key's own label — which
/// is why `LogicalKeyboardKey.comma` prints as "," and not as "Comma".
String describeActivator(ShortcutActivator activator) {
  if (activator is! SingleActivator) return activator.toString();

  final parts = <String>[
    if (activator.control) 'Ctrl',
    if (activator.alt) 'Alt',
    if (activator.shift) 'Shift',
    if (activator.meta) 'Meta',
  ];

  final key = activator.trigger;
  final label = switch (key) {
    LogicalKeyboardKey.tab => 'Tab',
    LogicalKeyboardKey.comma => ',',
    LogicalKeyboardKey.period => '.',
    LogicalKeyboardKey.slash => '/',
    LogicalKeyboardKey.minus => '-',
    LogicalKeyboardKey.equal => '=',
    LogicalKeyboardKey.enter => 'Enter',
    LogicalKeyboardKey.escape => 'Esc',
    _ => key.keyLabel.isNotEmpty ? key.keyLabel : key.debugName ?? '?',
  };
  parts.add(label);
  return parts.join('+');
}
