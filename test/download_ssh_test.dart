@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:terminal_agent/models/connection_profile.dart';
import 'package:terminal_agent/providers/app_state.dart';

/// End-to-end download test against a real SSH/SFTP server.
///
/// It needs an sshd listening on 127.0.0.1:2222 that accepts the key in
/// $KAMMEL_TEST_KEY, plus $KAMMEL_TEST_TREE (the remote folder to download) and
/// $KAMMEL_TEST_OUT (the local destination). Skipped when those aren't set, so a
/// plain `flutter test` run stays hermetic — see scripts in the PR description
/// for how the fixture server is started.
void main() {
  final keyPath = Platform.environment['KAMMEL_TEST_KEY'];
  final treeDir = Platform.environment['KAMMEL_TEST_TREE'];
  final outDir = Platform.environment['KAMMEL_TEST_OUT'];

  if (keyPath == null || treeDir == null || outDir == null) {
    test('ssh download (skipped: no fixture server)', () {}, skip: true);
    return;
  }

  test('downloads a tree with symlinks, unreadable files and a big file',
      () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});

    final state = AppState();
    await state.connectToSSH(ConnectionProfile(
      id: 'test',
      name: 'test',
      host: '127.0.0.1',
      port: 2222,
      username: Platform.environment['USER']!,
      privateKey: await File(keyPath).readAsString(),
    ));

    // connectToSSH kicks the connection off without awaiting it.
    for (var i = 0; i < 100 && state.connectionStatus != ConnectionStatus.remote; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(state.connectionStatus, ConnectionStatus.remote);
    // The connect flow resolves the initial cwd and lists it *after* flipping
    // the status; let that settle so it can't clobber the cd below.
    await Future<void>.delayed(const Duration(seconds: 2));

    await state.changeDirectory(treeDir);
    expect(state.currentPath, treeDir);
    expect(state.files, isNotEmpty);
    state.selectPaths(state.files.map((f) => f.path));

    await state.downloadSelection(destDir: outDir);
    expect(state.downloadPhase, DownloadPhase.done,
        reason: 'error: ${state.downloadError}');

    // Every readable file landed, including through the symlinked directory.
    expect(File('$outDir/file_small.txt').readAsStringSync(), 'hola');
    expect(File('$outDir/linkfile').readAsStringSync(), 'hola');
    expect(File('$outDir/sub/nested/deep.txt').readAsStringSync(), 'deep');
    expect(File('$outDir/linkdir/nested/deep.txt').readAsStringSync(), 'deep');

    // The 5MB file is streamed — it must arrive byte-identical.
    final big = File('$outDir/file_big.bin').readAsBytesSync();
    final expected = File('$treeDir/file_big.bin').readAsBytesSync();
    expect(big.length, expected.length);
    expect(big, expected);

    // The unreadable file and the broken symlink are reported, not fatal.
    expect(state.downloadFailures.length, 2, reason: '${state.downloadFailures}');
    expect(state.downloadFailures.join(), contains('noperm.txt'));
    expect(state.downloadFailures.join(), contains('broken'));

    // No half-written leftovers.
    final leftovers = Directory(outDir)
        .listSync(recursive: true)
        .where((e) => e.path.endsWith('.part'))
        .toList();
    expect(leftovers, isEmpty);

    // Progress ended consistent with what was actually written.
    expect(state.downloadFilesDone, 5);
    expect(state.downloadProgress, 1.0);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
