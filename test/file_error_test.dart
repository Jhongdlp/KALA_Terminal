import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:terminal_agent/l10n/l10n.dart';
import 'package:terminal_agent/providers/app_state.dart';
import 'package:terminal_agent/services/file_error.dart';

void main() {
  // `tr()` reads a global loaded from prefs, and that needs the binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    L10n.notifier.value = AppLang.es;
    await L10n.load();
  });

  group('describeFileError', () {
    // The words a POSIX filesystem actually uses. SFTP surfaces them through
    // dartssh2 and dart:io surfaces them locally, so both paths land here.
    test('names the cause instead of echoing the exception', () {
      expect(describeFileError(Exception('SftpStatusError: Permission denied')),
          contains('permiso'));
      expect(describeFileError(Exception('No such file or directory')),
          contains('existe'));
      expect(describeFileError(Exception('File exists')), contains('ya existe'));
      expect(describeFileError(Exception('Directory not empty')),
          contains('vacía'));
      expect(describeFileError(Exception('No space left on device')),
          contains('espacio'));
    });

    test('reads a bare errno the same as the wording', () {
      expect(describeFileError(
              const FileSystemExceptionStub('… (OS Error: …, errno = 13)')),
          describeFileError(Exception('Permission denied')));
    });

    // A failure we can't place still says something specific: a vague known
    // message would be worse than the original text.
    test('an unrecognised failure keeps its own text', () {
      final msg = describeFileError(Exception('kernel panic in the flux array'));
      expect(msg, contains('flux array'));
    });

    test('a very long message is trimmed rather than filling the snackbar', () {
      final msg = describeFileError(Exception('x' * 400));
      expect(msg.length, lessThanOrEqualTo(120));
      expect(msg, endsWith('…'));
    });

    test('rawDetail keeps the original for the detail dialog', () {
      expect(rawDetail(Exception('Permission denied')), 'Permission denied');
    });
  });

  group('FileOpResult', () {
    test('a failure carries both the action and the reason', () {
      final r = FileOpResult.failed('No se pudo eliminar',
          Exception('Permission denied'));
      expect(r.ok, isFalse);
      expect(r.message, startsWith('No se pudo eliminar'));
      expect(r.message, contains('permiso'));
      // Kept verbatim so "DETALLE" has something real to show.
      expect(r.detail, 'Permission denied');
    });

    test('a success has nothing to disclose', () {
      const r = FileOpResult.ok('Se creó "notas.txt"');
      expect(r.ok, isTrue);
      expect(r.detail, isNull);
      expect(r.isSilent, isFalse);
    });

    // A no-op (nothing selected, empty name) must not flash a snackbar.
    test('an empty message is silent', () {
      expect(const FileOpResult.ok('').isSilent, isTrue);
    });
  });
}

/// Stands in for a `FileSystemException`, whose real constructor formats its
/// own text; only `toString()` matters to the classifier.
class FileSystemExceptionStub implements Exception {
  final String text;
  const FileSystemExceptionStub(this.text);
  @override
  String toString() => text;
}
