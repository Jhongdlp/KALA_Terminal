import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_agent/models/git_status.dart';

/// Builds the exact bytes `git status --porcelain=v1 -z -b` produces:
/// every entry NUL-terminated, branch header first.
String porcelain(List<String> entries) => entries.map((e) => '$e\u0000').join();

void main() {
  group('branch header', () {
    test('branch with upstream and divergence', () {
      final info =
          GitRepoInfo.parse(porcelain(['## main...origin/main [ahead 2, behind 3]']));
      expect(info.branch, 'main');
      expect(info.upstream, 'origin/main');
      expect(info.ahead, 2);
      expect(info.behind, 3);
      expect(info.detached, isFalse);
      expect(info.isClean, isTrue);
    });

    test('ahead only', () {
      final info =
          GitRepoInfo.parse(porcelain(['## feat/x...origin/feat/x [ahead 1]']));
      expect(info.ahead, 1);
      expect(info.behind, 0);
    });

    test('branch without upstream', () {
      final info = GitRepoInfo.parse(porcelain(['## local-only']));
      expect(info.branch, 'local-only');
      expect(info.upstream, isNull);
      expect(info.ahead, 0);
    });

    test('a deleted upstream is not offered as a push target', () {
      final info =
          GitRepoInfo.parse(porcelain(['## main...origin/main [gone]']));
      expect(info.branch, 'main');
      expect(info.upstream, isNull);
    });

    test('detached HEAD', () {
      final info = GitRepoInfo.parse(porcelain(['## HEAD (no branch)']));
      expect(info.detached, isTrue);
      expect(info.branch, isNull);
      expect(info.branchLabel, 'HEAD');
    });

    test('fresh repository with no commit yet', () {
      final info = GitRepoInfo.parse(porcelain(['## No commits yet on main']));
      expect(info.noCommitsYet, isTrue);
      expect(info.branch, 'main');
    });
  });

  group('entries', () {
    test('splits the index and worktree columns', () {
      final info = GitRepoInfo.parse(porcelain([
        '## main',
        'M  lib/staged.dart',
        ' M lib/unstaged.dart',
        'MM lib/both.dart',
      ]));

      expect(info.files.length, 3);
      expect(info.staged.map((f) => f.path),
          containsAll(['lib/staged.dart', 'lib/both.dart']));
      expect(info.unstaged.map((f) => f.path),
          containsAll(['lib/unstaged.dart', 'lib/both.dart']));
      // A file modified on both sides shows up in each group exactly once.
      expect(info.staged.where((f) => f.path == 'lib/both.dart').length, 1);
    });

    test('untracked files are unstaged only, and labelled U', () {
      final info = GitRepoInfo.parse(porcelain(['## main', '?? nuevo.txt']));
      final file = info.files.single;
      expect(file.isUntracked, isTrue);
      expect(file.hasStaged, isFalse);
      expect(file.hasUnstaged, isTrue);
      expect(file.unstagedLetter, 'U');
    });

    test('a rename consumes the following NUL field as its source', () {
      final info = GitRepoInfo.parse(porcelain([
        '## main',
        'R  lib/nuevo.dart',
        'lib/viejo.dart',
        'M  lib/otro.dart',
      ]));

      expect(info.files.length, 2, reason: 'the source path is not an entry');
      final renamed = info.files.firstWhere((f) => f.index == 'R');
      expect(renamed.path, 'lib/nuevo.dart');
      expect(renamed.origPath, 'lib/viejo.dart');
      expect(info.files.any((f) => f.path == 'lib/otro.dart'), isTrue);
    });

    test('paths with spaces survive (that is what -z buys us)', () {
      final info =
          GitRepoInfo.parse(porcelain(['## main', ' M mi carpeta/mi archivo.txt']));
      expect(info.files.single.path, 'mi carpeta/mi archivo.txt');
      expect(info.files.single.name, 'mi archivo.txt');
      expect(info.files.single.parentDir, 'mi carpeta/');
    });

    test('unmerged entries are conflicts, in neither plain group', () {
      final info = GitRepoInfo.parse(porcelain([
        '## main',
        'UU lib/conflicto.dart',
        'AA lib/ambos.dart',
      ]));

      expect(info.hasConflicts, isTrue);
      expect(info.staged, isEmpty);
      expect(info.unstaged.length, 2);
      expect(info.files.every((f) => f.isConflicted), isTrue);
    });

    test('a collapsed untracked directory is flagged as one', () {
      final info = GitRepoInfo.parse(porcelain(['## main', '?? build/']));
      expect(info.files.single.isDirectory, isTrue);
      expect(info.files.single.name, 'build');
    });

    test('entries come back sorted by path', () {
      final info = GitRepoInfo.parse(porcelain([
        '## main',
        ' M zeta.dart',
        ' M alfa.dart',
        ' M media.dart',
      ]));
      expect(info.files.map((f) => f.path),
          ['alfa.dart', 'media.dart', 'zeta.dart']);
    });

    test('output without a branch header still parses', () {
      final info = GitRepoInfo.parse(porcelain(['M  solo.dart']));
      expect(info.branch, isNull);
      expect(info.files.single.path, 'solo.dart');
    });

    test('empty output is a clean tree', () {
      final info = GitRepoInfo.parse('');
      expect(info.isClean, isTrue);
      expect(info.hasConflicts, isFalse);
    });
  });
}
