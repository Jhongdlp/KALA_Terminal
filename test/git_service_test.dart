@TestOn('linux')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_agent/services/git_service.dart';

/// Drives [GitService] against a throwaway repository on disk.
///
/// The parser has its own unit tests; what this covers is the other half —
/// that the commands the service builds are the ones git actually accepts,
/// including the paths it quotes and the fallbacks it chains.
void main() {
  late Directory repo;
  late GitService git;

  Future<ProcessResult> raw(List<String> args) =>
      Process.run('git', args, workingDirectory: repo.path);

  setUpAll(() async {
    final probe = await Process.run('which', ['git']);
    if (probe.exitCode != 0) {
      markTestSkipped('git is not installed');
    }
  });

  setUp(() async {
    repo = await Directory.systemTemp.createTemp('kala_git_test_');
    await raw(['init', '-q', '-b', 'main']);
    await raw(['config', 'user.email', 'test@kala.local']);
    await raw(['config', 'user.name', 'KALA Test']);
    git = GitService.local(workdir: repo.path);
  });

  tearDown(() async {
    if (await repo.exists()) await repo.delete(recursive: true);
  });

  Future<void> write(String name, String content) =>
      File('${repo.path}/$name').writeAsString(content);

  test('reports the repository root', () async {
    final root = await git.repoRoot();
    // macOS/Linux temp dirs can be symlinked; compare resolved paths.
    expect(Directory(root!).resolveSymbolicLinksSync(),
        repo.resolveSymbolicLinksSync());
  });

  test('a directory outside any repository has no root and no status',
      () async {
    final plain = await Directory.systemTemp.createTemp('kala_not_a_repo_');
    addTearDown(() => plain.delete(recursive: true));
    final outside = GitService.local(workdir: plain.path);
    expect(await outside.repoRoot(), isNull);
    expect(await outside.status(), isNull);
  });

  test('an empty repository reads as "no commits yet"', () async {
    final info = await git.status();
    expect(info, isNotNull);
    expect(info!.noCommitsYet, isTrue);
    expect(info.branch, 'main');
    expect(info.isClean, isTrue);
  });

  test('stage moves a file from the unstaged group to the staged one',
      () async {
    await write('hola.txt', 'contenido\n');

    var info = await git.status();
    expect(info!.unstaged.single.path, 'hola.txt');
    expect(info.unstaged.single.isUntracked, isTrue);
    expect(info.staged, isEmpty);

    expect((await git.stage(['hola.txt'])).ok, isTrue);

    info = await git.status();
    expect(info!.staged.single.path, 'hola.txt');
    expect(info.staged.single.index, 'A');
    expect(info.unstaged, isEmpty);
  });

  test('unstage works before the first commit, where `reset HEAD` fails',
      () async {
    await write('nuevo.txt', 'x\n');
    await git.stage(['nuevo.txt']);

    expect((await git.unstage(['nuevo.txt'])).ok, isTrue);

    final info = await git.status();
    expect(info!.staged, isEmpty);
    expect(info.unstaged.single.isUntracked, isTrue);
  });

  test('commit empties the staged group and shows up as HEAD', () async {
    await write('uno.txt', 'primero\n');
    await git.stageAll();

    final result = await git.commit('primer commit');
    expect(result.ok, isTrue, reason: result.message);

    final info = await git.status();
    expect(info!.isClean, isTrue);
    expect(info.noCommitsYet, isFalse);
    expect(await git.headSummary(), contains('primer commit'));
    expect(await git.headMessage(), 'primer commit');
  });

  test(r'a commit message with quotes, $ and newlines survives intact',
      () async {
    await write('raro.txt', 'x\n');
    await git.stageAll();

    const message = 'fix: "comillas" \$HOME y \'simples\'\n\nsegundo párrafo';
    final result = await git.commit(message);
    expect(result.ok, isTrue, reason: result.message);
    expect(await git.headMessage(), message);
  });

  test('paths with spaces are quoted, not split', () async {
    await Directory('${repo.path}/mi carpeta').create();
    await write('mi carpeta/mi archivo.txt', 'hola\n');

    expect((await git.stage(['mi carpeta/mi archivo.txt'])).ok, isTrue);

    final info = await git.status();
    expect(info!.staged.single.path, 'mi carpeta/mi archivo.txt');
  });

  test('commit fails cleanly with an empty index', () async {
    await write('sin-preparar.txt', 'x\n');
    final result = await git.commit('nada preparado');
    expect(result.ok, isFalse);
    expect(result.message, isNotEmpty);
  });

  test('discard deletes an untracked file and restores a tracked one',
      () async {
    await write('versionado.txt', 'original\n');
    await git.stageAll();
    await git.commit('base');

    await write('versionado.txt', 'editado\n');
    await write('intruso.txt', 'temporal\n');

    final info = await git.status();
    final tracked =
        info!.unstaged.firstWhere((f) => f.path == 'versionado.txt');
    final untracked =
        info.unstaged.firstWhere((f) => f.path == 'intruso.txt');

    expect((await git.discard(tracked)).ok, isTrue);
    expect((await git.discard(untracked)).ok, isTrue);

    expect(await File('${repo.path}/versionado.txt').readAsString(),
        'original\n');
    expect(await File('${repo.path}/intruso.txt').exists(), isFalse);
    expect((await git.status())!.isClean, isTrue);
  });

  test('diff shows the worktree change, and the staged one separately',
      () async {
    await write('doc.txt', 'linea uno\n');
    await git.stageAll();
    await git.commit('base');

    await write('doc.txt', 'linea uno\nlinea dos\n');
    var info = await git.status();
    final file = info!.unstaged.single;

    final worktree = await git.diff(file, staged: false);
    expect(worktree, contains('+linea dos'));
    // Nothing in the index yet, so the staged side is empty.
    expect(await git.diff(file, staged: true), isEmpty);

    await git.stage([file.path]);
    info = await git.status();
    expect(await git.diff(info!.staged.single, staged: true),
        contains('+linea dos'));
  });

  test('an untracked file diffs against /dev/null as all additions', () async {
    await write('recien.txt', 'contenido nuevo\n');
    final info = await git.status();

    final diff = await git.diff(info!.unstaged.single, staged: false);
    expect(diff, contains('+contenido nuevo'));
  });

  test('push without a remote fails with git\'s own message, not a hang',
      () async {
    await write('a.txt', 'x\n');
    await git.stageAll();
    await git.commit('base');

    final result = await git.push();
    expect(result.ok, isFalse);
    // The panel shows this verbatim, so it has to be git's explanation and
    // not an empty string or a timeout.
    expect(result.exitCode, isNot(124));
    expect(result.message.toLowerCase(), contains('push destination'));
  });
}
