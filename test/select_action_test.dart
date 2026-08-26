import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:terminal_agent/l10n/l10n.dart';
import 'package:terminal_agent/models/terminal_key_layer.dart';
import 'package:terminal_agent/models/terminal_shortcut.dart';
import 'package:terminal_agent/providers/app_state.dart';

/// `system:select` starts a text selection without a long press.
///
/// It exists because copying used to have exactly one entrance — a long press
/// on the same pixels the touch pad arms on — so a finger that drifts during
/// the hold loses the selection to the pad. A user who already owns a shortcut
/// list must get the new action too, hence the migration: the problem it
/// solves is not one only fresh installs have.
Future<AppState> _state() async {
  L10n.notifier.value = AppLang.es;
  await L10n.load();
  final state = AppState();
  // Settings load asynchronously from prefs.
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  return state;
}

String _encode(List<TerminalShortcut> shortcuts) =>
    json.encode(shortcuts.map((s) => s.toJson()).toList());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a fresh install has SELECCIONAR on the ACCIONES layer', () async {
    SharedPreferences.setMockInitialValues({});
    final state = await _state();

    expect(
      state.actionShortcuts.map((s) => s.value),
      contains('system:select'),
    );
    // The layer draws `system:` keys by icon, so a new action with no entry
    // there would come out as a blank cell.
    expect(kSystemActionIcons.containsKey('select'), isTrue);
  });

  test('an existing shortcut list gains it next to ENLACES', () async {
    final owned = [
      TerminalShortcut(label: 'ADJUNTAR', value: 'system:attach'),
      TerminalShortcut(label: 'ENLACES', value: 'system:links'),
      TerminalShortcut(label: 'AJUSTES', value: 'system:settings'),
      TerminalShortcut(label: 'mi cosa', value: 'htop\\n'),
    ];
    SharedPreferences.setMockInitialValues({
      'settings_custom_shortcuts_json': _encode(owned),
      // Everything up to v5 has already run for this user.
      'settings_shortcuts_migrated_v3': true,
      'settings_shortcuts_migrated_v4': true,
      'settings_shortcuts_migrated_v5': true,
    });
    final state = await _state();

    final values = state.actionShortcuts.map((s) => s.value).toList();
    expect(values, contains('system:select'));
    expect(values.indexOf('system:select'),
        values.indexOf('system:links') + 1,
        reason: 'it goes after ENLACES, not on top of the row');
    // The user's own key is untouched.
    expect(state.myShortcuts.map((s) => s.value), contains('htop\\n'));
  });

  test('a list that already has it is left alone', () async {
    final owned = [
      TerminalShortcut(label: 'SELECCIONAR', value: 'system:select'),
      TerminalShortcut(label: 'ENLACES', value: 'system:links'),
    ];
    SharedPreferences.setMockInitialValues({
      'settings_custom_shortcuts_json': _encode(owned),
      'settings_shortcuts_migrated_v3': true,
      'settings_shortcuts_migrated_v4': true,
      'settings_shortcuts_migrated_v5': true,
    });
    final state = await _state();

    expect(
      state.actionShortcuts.where((s) => s.value == 'system:select').length,
      1,
    );
  });
}
