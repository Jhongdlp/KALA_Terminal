import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../l10n/l10n.dart';
import '../models/git_status.dart';

/// Outcome of one git invocation.
class GitCmdResult {
  final String stdout;
  final String stderr;
  final int exitCode;

  const GitCmdResult(this.stdout, this.stderr, this.exitCode);

  bool get ok => exitCode == 0;

  /// What to show the user when [ok] is false: git writes its errors to
  /// stderr, but a few subcommands (`commit` with nothing staged) explain
  /// themselves on stdout instead.
  String get message {
    final err = stderr.trim();
    if (err.isNotEmpty) return err;
    final out = stdout.trim();
    if (out.isNotEmpty) return out;
    return tr('git terminó con código {0}', [exitCode]);
  }
}

/// Runs git commands for one session's working directory — over SSH for a
/// remote session, or through `Process.run` for a local one.
///
/// Every call goes through [_run], which builds the command from an argument
/// *list*: the remote path quotes each argument individually, so a branch name
/// or a commit message can contain quotes, `$` or newlines without escaping
/// its way out into the shell.
class GitService {
  GitService._(this.workdir, this._client);

  /// Git over an existing SSH connection.
  factory GitService.remote({
    required SSHClient client,
    required String workdir,
  }) =>
      GitService._(workdir, client);

  /// Git on the machine the app itself runs on (Linux desktop; on Android the
  /// app process has no git binary and commands fail cleanly).
  factory GitService.local({required String workdir}) =>
      GitService._(workdir, null);

  final String workdir;
  final SSHClient? _client;

  bool get isRemote => _client != null;

  static const Duration _fastTimeout = Duration(seconds: 25);
  static const Duration _networkTimeout = Duration(seconds: 90);

  /// Keeps git from ever blocking on a prompt we cannot answer: without these
  /// a push needing a passphrase or a username would hang the exec channel
  /// until the timeout instead of failing with a message we can show.
  static const Map<String, String> _env = {
    'GIT_TERMINAL_PROMPT': '0',
    // `true` prints nothing and exits 0, so a credential prompt resolves to an
    // empty answer and fails immediately instead of waiting for input.
    'GIT_ASKPASS': 'true',
    'SSH_ASKPASS': 'true',
    'GIT_PAGER': 'cat',
    'GIT_SSH_COMMAND': 'ssh -o BatchMode=yes',
  };

  /// POSIX single-quoting: everything inside is literal, and an embedded
  /// quote is closed, escaped and reopened.
  static String _q(String s) => "'${s.replaceAll("'", r"'\''")}'";

  Future<GitCmdResult> _run(
    List<String> args, {
    Duration? timeout,
  }) async {
    final limit = timeout ?? _fastTimeout;
    try {
      return isRemote
          ? await _runRemote(args, limit)
          : await _runLocal(args, limit);
    } on TimeoutException {
      return GitCmdResult(
          '', tr('git no respondió tras {0} s.', [limit.inSeconds]), 124);
    } catch (e) {
      debugPrint('git ${args.join(' ')} failed: $e');
      return GitCmdResult('', e.toString(), 1);
    }
  }

  Future<GitCmdResult> _runRemote(List<String> args, Duration timeout) async {
    final envPrefix =
        _env.entries.map((e) => '${e.key}=${_q(e.value)}').join(' ');
    final cmd = 'cd ${_q(workdir)} && $envPrefix '
        'git --no-pager ${args.map(_q).join(' ')}';

    final session = await _client!.execute(cmd).timeout(timeout);
    try {
      // Nothing is ever fed to git's stdin; leaving it open makes commands
      // that read it (a pager, a credential helper) wait forever.
      await session.stdin.close();
      final streams = await Future.wait([
        utf8.decoder.bind(session.stdout.cast<List<int>>()).join(),
        utf8.decoder.bind(session.stderr.cast<List<int>>()).join(),
      ]).timeout(timeout);
      await session.done.timeout(timeout);
      return GitCmdResult(streams[0], streams[1], session.exitCode ?? 1);
    } on TimeoutException {
      session.kill(SSHSignal.KILL);
      session.close();
      rethrow;
    }
  }

  Future<GitCmdResult> _runLocal(List<String> args, Duration timeout) async {
    final res = await Process.run(
      'git',
      ['--no-pager', ...args],
      workingDirectory: workdir,
      environment: _env,
      runInShell: false,
    ).timeout(timeout);
    return GitCmdResult(
        res.stdout as String, res.stderr as String, res.exitCode);
  }

  // ---------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------

  /// Absolute path of the repository root, or null when [workdir] is not
  /// inside a git repository.
  Future<String?> repoRoot() async {
    final r = await _run(['rev-parse', '--show-toplevel']);
    if (!r.ok) return null;
    final path = r.stdout.trim();
    return path.isEmpty ? null : path;
  }

  /// Full working-tree state, or null when this is not a repository (or git
  /// isn't installed, which reads the same to the caller: no panel to show).
  Future<GitRepoInfo?> status() async {
    final r = await _run(['status', '--porcelain=v1', '-z', '-b']);
    if (!r.ok) return null;
    return GitRepoInfo.parse(r.stdout);
  }

  /// `<short sha> <subject>` of HEAD, or null on an empty repository.
  Future<String?> headSummary() async {
    final r = await _run(['log', '-1', '--pretty=%h %s']);
    if (!r.ok) return null;
    final line = r.stdout.trim();
    return line.isEmpty ? null : line;
  }

  /// Unified diff of one path. [staged] compares the index against HEAD
  /// instead of the worktree against the index.
  ///
  /// An untracked file has nothing to diff against, so it is compared to
  /// /dev/null — that form exits 1 by design, so its output is taken as-is.
  Future<String> diff(GitFileStatus file, {required bool staged}) async {
    if (file.isUntracked && !staged) {
      final r = await _run(
          ['diff', '--no-color', '--no-index', '--', '/dev/null', file.path]);
      return r.stdout.isNotEmpty ? r.stdout : r.stderr;
    }
    final r = await _run([
      'diff',
      '--no-color',
      if (staged) '--cached',
      '--',
      file.path,
    ]);
    return r.ok ? r.stdout : r.message;
  }

  // ---------------------------------------------------------------------
  // Index
  // ---------------------------------------------------------------------

  Future<GitCmdResult> stage(List<String> paths) =>
      _run(['add', '--', ...paths]);

  Future<GitCmdResult> stageAll() => _run(['add', '-A']);

  /// Takes paths back out of the index. `restore --staged` needs git ≥ 2.23
  /// and a HEAD to restore from, so both older git and the first commit of a
  /// fresh repository fall back a step at a time.
  Future<GitCmdResult> unstage(List<String> paths) async {
    final restore = await _run(['restore', '--staged', '--', ...paths]);
    if (restore.ok) return restore;
    final reset = await _run(['reset', '-q', 'HEAD', '--', ...paths]);
    if (reset.ok) return reset;
    return _run(['rm', '-r', '--cached', '-q', '--', ...paths]);
  }

  Future<GitCmdResult> unstageAll() async {
    final restore = await _run(['restore', '--staged', '--', '.']);
    if (restore.ok) return restore;
    return _run(['reset', '-q']);
  }

  /// Throws away the worktree changes of one entry: an untracked file is
  /// deleted outright, a tracked one is restored from the index.
  Future<GitCmdResult> discard(GitFileStatus file) {
    if (file.isUntracked) {
      return _run(['clean', '-fdq', '--', file.path]);
    }
    return _run(['checkout', '--', file.path]);
  }

  // ---------------------------------------------------------------------
  // Commit & sync
  // ---------------------------------------------------------------------

  /// Commits what is in the index. [amend] rewrites HEAD instead.
  Future<GitCmdResult> commit(String message, {bool amend = false}) =>
      _run(['commit', if (amend) '--amend', '-m', message]);

  /// Subject of HEAD, used to prefill the message box when amending.
  Future<String?> headMessage() async {
    final r = await _run(['log', '-1', '--pretty=%B']);
    if (!r.ok) return null;
    final msg = r.stdout.trim();
    return msg.isEmpty ? null : msg;
  }

  Future<GitCmdResult> fetch() =>
      _run(['fetch', '--prune'], timeout: _networkTimeout);

  Future<GitCmdResult> pull({bool rebase = false}) =>
      _run(['pull', if (rebase) '--rebase'], timeout: _networkTimeout);

  /// Pushes the current branch. When it has no upstream yet, [setUpstream]
  /// publishes it with `-u origin <branch>`.
  Future<GitCmdResult> push({
    bool setUpstream = false,
    String? branch,
  }) =>
      _run([
        'push',
        if (setUpstream) ...['-u', 'origin', ?branch],
      ], timeout: _networkTimeout);
}
