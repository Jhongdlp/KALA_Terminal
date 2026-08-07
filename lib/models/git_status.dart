/// Parsed `git status --porcelain=v1 -z -b` output.
///
/// The porcelain v1 format is deliberately frozen by git, so parsing it is the
/// supported way to read a working tree programmatically. Every entry carries
/// two status columns — the index (staged) and the worktree (unstaged) — and
/// keeping them apart is what makes the VS Code style staged/unstaged split
/// possible; collapsing them into a single letter (what the old panel did)
/// loses the distinction.
library;

/// One changed path, with its index and worktree columns kept separate.
class GitFileStatus {
  /// The staged column (`X`): ' ', 'M', 'A', 'D', 'R', 'C', 'U' or '?'.
  final String index;

  /// The unstaged column (`Y`): same alphabet as [index].
  final String worktree;

  /// Path relative to the repository root. Directories (git collapses a fully
  /// untracked folder into a single entry) end with '/'.
  final String path;

  /// Source path of a rename/copy, when [index] is 'R' or 'C'.
  final String? origPath;

  const GitFileStatus({
    required this.index,
    required this.worktree,
    required this.path,
    this.origPath,
  });

  bool get isUntracked => index == '?';

  bool get isIgnored => index == '!';

  /// A collapsed untracked directory: git reports it as a single `?? dir/`
  /// entry, so it can be staged but has no diff of its own.
  bool get isDirectory => path.endsWith('/');

  /// Unmerged: either column is 'U', or both are 'A' (both added) or 'D'
  /// (both deleted). These belong in neither group until resolved.
  bool get isConflicted =>
      index == 'U' ||
      worktree == 'U' ||
      (index == 'A' && worktree == 'A') ||
      (index == 'D' && worktree == 'D');

  /// Has something in the index that a commit would pick up.
  bool get hasStaged =>
      !isUntracked && !isIgnored && !isConflicted && index != ' ';

  /// Has something in the worktree that a commit would *not* pick up.
  bool get hasUnstaged =>
      isUntracked || isConflicted || (worktree != ' ' && !isIgnored);

  /// True when the path no longer exists in the working tree — either the
  /// deletion is unstaged, or it is staged and nothing recreated the file.
  /// There is nothing to open in the editor for these.
  bool get isDeletedOnDisk =>
      worktree == 'D' || (index == 'D' && worktree == ' ');

  /// The single letter shown on a staged row.
  String get stagedLetter => index;

  /// The single letter shown on an unstaged row. Untracked files get 'U' (the
  /// letter VS Code uses) rather than the raw '?'.
  String get unstagedLetter {
    if (isConflicted) return 'C';
    if (isUntracked) return 'U';
    return worktree;
  }

  /// Last path segment, for the row's bold part.
  String get name {
    final trimmed = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final i = trimmed.lastIndexOf('/');
    return i < 0 ? trimmed : trimmed.substring(i + 1);
  }

  /// Everything before [name], kept dim in the row.
  String get parentDir {
    final trimmed = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final i = trimmed.lastIndexOf('/');
    return i < 0 ? '' : trimmed.substring(0, i + 1);
  }
}

/// Branch, tracking info and the full list of changed paths.
class GitRepoInfo {
  /// Current branch, or null when HEAD is detached.
  final String? branch;

  /// Upstream ref (`origin/main`), or null when the branch doesn't track one.
  final String? upstream;

  /// Commits ahead of / behind [upstream].
  final int ahead;
  final int behind;

  final bool detached;

  /// True on a fresh repo whose HEAD has no commit yet — push and amend are
  /// meaningless there, and `git reset HEAD` fails.
  final bool noCommitsYet;

  final List<GitFileStatus> files;

  const GitRepoInfo({
    this.branch,
    this.upstream,
    this.ahead = 0,
    this.behind = 0,
    this.detached = false,
    this.noCommitsYet = false,
    this.files = const [],
  });

  List<GitFileStatus> get staged =>
      files.where((f) => f.hasStaged && !f.isConflicted).toList();

  List<GitFileStatus> get unstaged =>
      files.where((f) => f.hasUnstaged).toList();

  bool get hasConflicts => files.any((f) => f.isConflicted);

  bool get isClean => files.isEmpty;

  /// Label for the branch chip: the branch name, or a short marker when HEAD
  /// is detached.
  String get branchLabel => branch ?? 'HEAD';

  /// Parses the NUL-separated output of
  /// `git status --porcelain=v1 -z -b`.
  ///
  /// Entries are `XY <path>` and a rename/copy is followed by a *second*
  /// NUL-terminated field holding the original path, which is why this can't
  /// be a plain `map` over the split.
  static GitRepoInfo parse(String raw) {
    final parts = raw.split('\u0000');
    String? branch;
    String? upstream;
    int ahead = 0;
    int behind = 0;
    bool detached = false;
    bool noCommits = false;

    int i = 0;
    if (parts.isNotEmpty && parts[0].startsWith('## ')) {
      final header = parts[0].substring(3);
      final noCommitsMatch =
          RegExp(r'^No commits yet on (.+?)(?:\.\.\.|$)').firstMatch(header);
      if (noCommitsMatch != null) {
        noCommits = true;
        branch = noCommitsMatch.group(1)?.trim();
      } else if (header.startsWith('HEAD (no branch)')) {
        detached = true;
      } else {
        final divergence =
            RegExp(r'\s\[(.+)\]$').firstMatch(header)?.group(1) ?? '';
        final refs =
            header.replaceFirst(RegExp(r'\s\[.+\]$'), '').trim();
        final sep = refs.indexOf('...');
        if (sep >= 0) {
          branch = refs.substring(0, sep);
          final up = refs.substring(sep + 3).trim();
          if (up.isNotEmpty) upstream = up;
        } else {
          branch = refs;
        }
        ahead = int.tryParse(
                RegExp(r'ahead (\d+)').firstMatch(divergence)?.group(1) ??
                    '') ??
            0;
        behind = int.tryParse(
                RegExp(r'behind (\d+)').firstMatch(divergence)?.group(1) ??
                    '') ??
            0;
        // "[gone]": the upstream branch was deleted on the remote.
        if (divergence.trim() == 'gone') upstream = null;
      }
      i = 1;
    }

    final files = <GitFileStatus>[];
    for (; i < parts.length; i++) {
      final entry = parts[i];
      // Shortest possible entry is "XY p": two columns, a space, one char.
      if (entry.length < 4) continue;
      final index = entry[0];
      final worktree = entry[1];
      final path = entry.substring(3);
      String? orig;
      if (index == 'R' || index == 'C' || worktree == 'R' || worktree == 'C') {
        if (i + 1 < parts.length) orig = parts[++i];
      }
      files.add(GitFileStatus(
        index: index,
        worktree: worktree,
        path: path,
        origPath: orig,
      ));
    }
    files.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));

    return GitRepoInfo(
      branch: branch,
      upstream: upstream,
      ahead: ahead,
      behind: behind,
      detached: detached,
      noCommitsYet: noCommits,
      files: files,
    );
  }
}
