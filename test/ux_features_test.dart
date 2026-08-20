import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:terminal_agent/l10n/format.dart';
import 'package:terminal_agent/models/connection_error.dart';
import 'package:terminal_agent/services/backup_service.dart';
import 'package:terminal_agent/services/terminal_search.dart';
import 'package:terminal_agent/views/shell/app_commands.dart';
import 'package:xterm/xterm.dart';

void main() {
  // ---- Scrollback search ----------------------------------------------------

  group('TerminalSearch', () {
    Terminal terminalWith(List<String> lines) {
      final terminal = Terminal(maxLines: 200);
      for (final line in lines) {
        terminal.write('$line\r\n');
      }
      return terminal;
    }

    test('finds every occurrence, oldest line first', () {
      final terminal = terminalWith([
        'error: no such file',
        'ok',
        'error: permission denied',
      ]);

      final matches = TerminalSearch.find(terminal, 'error');

      expect(matches.length, 2);
      expect(matches.first.line, lessThan(matches.last.line));
    });

    test('columns point at the cell, not at a trimmed string', () {
      // Two leading spaces: BufferLine.getText() would drop the empty cells and
      // report the match two columns to the left, which is what would put the
      // highlight on the wrong characters.
      final terminal = terminalWith(['  needle']);

      final match = TerminalSearch.find(terminal, 'needle').single;

      expect(match.start, 2);
      expect(match.end, 8);
    });

    test('is case-insensitive until the query has a capital', () {
      final terminal = terminalWith(['Warning', 'warning']);

      expect(TerminalSearch.find(terminal, 'warning').length, 2);
      // Smart case: an explicit capital narrows, the way vim and ripgrep do.
      expect(TerminalSearch.find(terminal, 'Warning').length, 1);
    });

    test('an empty query matches nothing rather than everything', () {
      expect(TerminalSearch.find(terminalWith(['a', 'b']), ''), isEmpty);
    });

    test('overlapping hits are not double counted', () {
      final terminal = terminalWith(['aaaa']);
      // "aa" in "aaaa" is 2 non-overlapping hits, not 3.
      expect(TerminalSearch.find(terminal, 'aa').length, 2);
    });

    test('stops at the cap instead of walking the whole buffer', () {
      final terminal = terminalWith(List.filled(200, 'x x x x x'));
      final matches = TerminalSearch.find(terminal, 'x');
      expect(matches.length, TerminalSearch.maxMatches);
    });
  });

  // ---- Connection errors ----------------------------------------------------

  group('ConnectionError', () {
    test('a rejected password sends the user to the profile, not to retry', () {
      final failure = ConnectionError.from(
          Exception('SSHAuthFailError: authentication failed'));

      expect(failure.kind, ConnectionErrorKind.auth);
      expect(failure.suggestsEditingProfile, isTrue);
    });

    test('a refused port is an address problem, not a network one', () {
      final failure = ConnectionError.from(
          const SocketExceptionLike('Connection refused (errno = 111)'));

      expect(failure.kind, ConnectionErrorKind.address);
      expect(failure.suggestsEditingProfile, isTrue);
    });

    test('a timeout offers a retry, because retrying is what fixes it', () {
      final failure = ConnectionError.from(Exception('Connection timed out'));

      expect(failure.kind, ConnectionErrorKind.network);
      expect(failure.suggestsEditingProfile, isFalse);
      expect(failure.suggestsKnownHosts, isFalse);
    });

    test('a host key mismatch routes to the known-hosts screen', () {
      final failure =
          ConnectionError.from(Exception('host key verification failed'));

      expect(failure.kind, ConnectionErrorKind.hostKey);
      expect(failure.suggestsKnownHosts, isTrue);
      // And never to "edit the profile": the profile is not what changed.
      expect(failure.suggestsEditingProfile, isFalse);
    });

    test('keeps the raw text for the technical detail', () {
      final failure = ConnectionError.from(Exception('weird failure 0x42'));
      expect(failure.detail, contains('weird failure 0x42'));
    });
  });

  // ---- Relative time --------------------------------------------------------

  group('relativeTime', () {
    final now = DateTime(2026, 8, 19, 12, 0);

    test('collapses anything under a minute into "ahora"', () {
      expect(relativeTime(now.subtract(const Duration(seconds: 20)), now: now),
          'ahora');
    });

    test('counts minutes, then hours, then days', () {
      expect(relativeTime(now.subtract(const Duration(minutes: 5)), now: now),
          'hace 5 min');
      expect(relativeTime(now.subtract(const Duration(hours: 3)), now: now),
          'hace 3 h');
      expect(relativeTime(now.subtract(const Duration(days: 3)), now: now),
          'hace 3 días');
    });

    test('falls back to a date once "hace N días" stops being readable', () {
      expect(relativeTime(DateTime(2026, 1, 5), now: now), '05/01/2026');
    });

    test('a clock skew into the future never renders as a negative age', () {
      expect(relativeTime(now.add(const Duration(hours: 2)), now: now), 'ahora');
    });
  });

  // ---- Shortcut rendering ---------------------------------------------------

  group('describeActivator', () {
    test('writes modifiers in a fixed order', () {
      expect(
        describeActivator(const SingleActivator(LogicalKeyboardKey.keyF,
            control: true, shift: true)),
        'Ctrl+Shift+F',
      );
    });

    test('names keys that have no printable label', () {
      expect(
        describeActivator(
            const SingleActivator(LogicalKeyboardKey.tab, control: true)),
        'Ctrl+Tab',
      );
    });

    test('prints punctuation as the character, not as its key name', () {
      expect(
        describeActivator(
            const SingleActivator(LogicalKeyboardKey.comma, control: true)),
        'Ctrl+,',
      );
    });
  });

  group('appCommands', () {
    // Keys the terminal claims before the app ever sees them. The first group
    // is xterm's CtrlInputHandler (Ctrl+letter → a control code, unless Shift
    // is held); the second is the keytab, which claims these keys with *any*
    // modifier, so a binding on one of them is silently dead while the terminal
    // has focus. Both were learned the hard way: Ctrl+Tab and F1 looked like
    // the obvious choices and did nothing.
    final claimedByKeytab = <LogicalKeyboardKey>{
      LogicalKeyboardKey.tab,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.home,
      LogicalKeyboardKey.end,
      LogicalKeyboardKey.pageUp,
      LogicalKeyboardKey.pageDown,
      LogicalKeyboardKey.insert,
      LogicalKeyboardKey.delete,
      LogicalKeyboardKey.f1,
      LogicalKeyboardKey.f2,
      LogicalKeyboardKey.f3,
      LogicalKeyboardKey.f4,
      LogicalKeyboardKey.f5,
      LogicalKeyboardKey.f6,
      LogicalKeyboardKey.f7,
      LogicalKeyboardKey.f8,
      LogicalKeyboardKey.f9,
      LogicalKeyboardKey.f10,
      LogicalKeyboardKey.f11,
      LogicalKeyboardKey.f12,
    };

    test('no binding uses a key the terminal claims', () {
      for (final command in appCommands()) {
        final activator = command.activator;
        if (activator is! SingleActivator) continue;
        expect(claimedByKeytab.contains(activator.trigger), isFalse,
            reason: '${command.id} is bound to a key xterm consumes first, '
                'so it would do nothing while the terminal has focus');
      }
    });

    test('Ctrl+letter always carries Shift, so the shell keeps its control keys', () {
      for (final command in appCommands()) {
        final activator = command.activator;
        if (activator is! SingleActivator || !activator.control) continue;
        final label = activator.trigger.keyLabel;
        final isLetter = label.length == 1 && RegExp(r'[A-Za-z]').hasMatch(label);
        if (!isLetter) continue;
        expect(activator.shift, isTrue,
            reason: '${command.id} would swallow Ctrl+$label on its way to '
                'the shell');
      }
    });

    test('no two commands share a binding', () {
      final bound = appCommands()
          .where((c) => c.activator != null)
          .map((c) => describeActivator(c.activator!))
          .toList();
      expect(bound.toSet().length, bound.length);
    });

    test('command ids are unique', () {
      final ids = appCommands().map((c) => c.id).toList();
      expect(ids.toSet().length, ids.length);
    });
  });

  // ---- Backup ---------------------------------------------------------------

  group('BackupService', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('round-trips the settings it is given', () async {
      SharedPreferences.setMockInitialValues({
        'settings_terminal_font_size': 17.0,
        'settings_theme_mode': 2,
        'app_language': 'en',
        'explorer_bookmarks': <String>['/var/www'],
      });

      final envelope = await BackupService.build(includeSecrets: false);

      // Wipe, then restore.
      SharedPreferences.setMockInitialValues({});
      final result = await BackupService.restore(envelope);
      expect(result.error, isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('settings_terminal_font_size'), 17.0);
      expect(prefs.getInt('settings_theme_mode'), 2);
      expect(prefs.getString('app_language'), 'en');
      expect(prefs.getStringList('explorer_bookmarks'), ['/var/www']);
    });

    test('leaves device-local settings out', () async {
      SharedPreferences.setMockInitialValues({
        'settings_app_lock_enabled': true,
        'settings_split_side': 0.4,
        'settings_theme_mode': 1,
      });

      final envelope = await BackupService.build(includeSecrets: false);
      final prefsBlock = envelope['prefs'] as Map<String, dynamic>;

      // Restoring a lock onto a device with no biometric enrolled is a lockout,
      // and a split fraction belongs to the screen it was dragged on.
      expect(prefsBlock.containsKey('settings_app_lock_enabled'), isFalse);
      expect(prefsBlock.containsKey('settings_split_side'), isFalse);
      expect(prefsBlock.containsKey('settings_theme_mode'), isTrue);
    });

    test('omits secrets unless they were asked for', () async {
      final envelope = await BackupService.build(includeSecrets: false);
      expect(envelope.containsKey('secrets'), isFalse);
      expect(envelope['includesSecrets'], isFalse);
    });

    test('refuses a file that is not a backup', () async {
      final result = await BackupService.restore({'hello': 'world'});
      expect(result.error, isNotNull);
      expect(result.keys, 0);
    });

    test('refuses a backup from a newer format instead of half-applying it',
        () async {
      final result = await BackupService.restore({
        'kammel_backup': BackupService.formatVersion + 1,
        'prefs': {
          'settings_theme_mode': {'type': 'int', 'value': 2},
        },
      });

      expect(result.error, isNotNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('settings_theme_mode'), isNull);
    });

    test('a crafted file cannot write keys outside the allow-list', () async {
      final result = await BackupService.restore({
        'kammel_backup': BackupService.formatVersion,
        'prefs': {
          'settings_theme_mode': {'type': 'int', 'value': 2},
          'window_width': {'type': 'int', 'value': 99},
          'something_else': {'type': 'string', 'value': 'nope'},
        },
      });

      expect(result.keys, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('window_width'), isNull);
      expect(prefs.getString('something_else'), isNull);
    });
  });
}

/// Stands in for a `SocketException`, whose message is what the classifier
/// actually reads. Using the real class would drag `dart:io` into a test that
/// has no other reason to touch it.
class SocketExceptionLike implements Exception {
  final String message;
  const SocketExceptionLike(this.message);

  @override
  String toString() => 'SocketException: $message';
}
