import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/git_status.dart';
import '../providers/app_state.dart';
import '../services/git_service.dart';
import '../theme/app_theme.dart';
import '../widgets/adaptive_sheet.dart';
import '../widgets/swiss.dart';
import 'git_diff_sheet.dart';
import 'git_project_tree.dart';

/// Source-control panel: the staged / unstaged split, per-file stage, unstage
/// and discard, a diff viewer, the commit box and branch sync — the git client
/// KALA used to delegate to whatever was typed in the terminal.
///
/// Every command runs through [GitService], which is rebuilt on each refresh
/// from the *active* session, so the panel follows reconnects instead of
/// holding a stale SSH channel.
class GitPanelSheet extends StatefulWidget {
  final AppState state;

  /// Shown by the caller (on the root messenger) after the panel closes, e.g.
  /// the "sent to AI" confirmation for the delegate buttons.
  final void Function(String message)? onToast;

  const GitPanelSheet({
    super.key,
    required this.state,
    this.onToast,
  });

  @override
  State<GitPanelSheet> createState() => _GitPanelSheetState();
}

class _GitPanelSheetState extends State<GitPanelSheet> {
  final TextEditingController _message = TextEditingController();
  final GlobalKey<GitProjectTreeState> _treeKey = GlobalKey();

  GitService? _git;
  GitRepoInfo? _repo;
  String _rootPath = '';
  String? _headSummary;

  bool _loading = true;
  bool _notARepo = false;
  String? _fatal;

  /// Label of the command in flight, or null when idle. Doubles as the "some
  /// operation is running" flag that disables every action.
  String? _busy;

  bool _amend = false;

  bool _stagedExpanded = true;
  bool _changesExpanded = true;
  bool _treeExpanded = false;
  bool _agentExpanded = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Data
  // ---------------------------------------------------------------------

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _fatal = null;
    });

    final git = widget.state.createGitService();
    if (git == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _git = null;
        _fatal = tr('No hay una sesión activa para ejecutar git.');
      });
      return;
    }

    final root = await git.repoRoot();
    if (!mounted) return;
    if (root == null) {
      setState(() {
        _git = git;
        _loading = false;
        _notARepo = true;
        _repo = null;
      });
      return;
    }

    final info = await git.status();
    final head = await git.headSummary();
    if (!mounted) return;

    setState(() {
      _git = git;
      _rootPath = root;
      _notARepo = false;
      _repo = info;
      _headSummary = head;
      _loading = false;
    });
  }

  /// Runs one git command with the panel in its busy state, reports the
  /// failure (or [okMessage]) and reloads the status.
  ///
  /// [touchesWorkingTree] additionally re-lists the explorer, whose contents a
  /// pull, a discard or a checkout may have changed underneath it.
  Future<bool> _run(
    String label,
    Future<GitCmdResult> Function(GitService git) command, {
    String? okMessage,
    bool touchesWorkingTree = false,
  }) async {
    final git = _git;
    if (git == null || _busy != null) return false;

    setState(() => _busy = label);
    final result = await command(git);
    if (!mounted) return false;
    setState(() => _busy = null);

    if (!result.ok) {
      _showOutput(tr('ERROR DE GIT'), result.message);
    } else if (okMessage != null) {
      _snack(okMessage, AppColors.accent);
    }

    await _refresh();
    if (touchesWorkingTree && mounted) {
      await widget.state.refreshFiles();
    }
    return result.ok;
  }

  // ---------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------

  Future<void> _commit() async {
    final message = _message.text.trim();
    if (message.isEmpty) {
      _snack(tr('El mensaje de commit no puede estar vacío.'), AppColors.bone);
      return;
    }
    final repo = _repo;
    if (repo == null) return;

    if (repo.hasConflicts) {
      _snack(tr('Resuelve los conflictos antes de hacer commit.'),
          AppColors.danger);
      return;
    }

    // VS Code's behaviour: with an empty index, offer to stage everything
    // rather than failing with "nothing to commit".
    if (repo.staged.isEmpty && !_amend) {
      if (repo.unstaged.isEmpty) {
        _snack(tr('No hay cambios que confirmar.'), AppColors.bone);
        return;
      }
      final all = await _confirm(
        tr('SIN CAMBIOS PREPARADOS'),
        tr('No has preparado ningún cambio. ¿Preparar los {0} cambios y hacer commit?',
            [repo.unstaged.length]),
        tr('PREPARAR Y CONFIRMAR'),
      );
      if (!all) return;
      final staged = await _run(tr('preparando'), (g) => g.stageAll());
      if (!staged) return;
    }

    final amend = _amend;
    final ok = await _run(
      tr('confirmando'),
      (g) => g.commit(message, amend: amend),
      okMessage: amend ? tr('Commit enmendado') : tr('Commit creado'),
    );
    if (ok && mounted) {
      _message.clear();
      setState(() => _amend = false);
    }
  }

  Future<void> _push() async {
    final repo = _repo;
    if (repo == null) return;
    if (repo.detached) {
      _snack(tr('HEAD está separado: no hay rama que publicar.'),
          AppColors.bone);
      return;
    }
    final needsUpstream = repo.upstream == null;
    if (needsUpstream) {
      final ok = await _confirm(
        tr('RAMA SIN UPSTREAM'),
        tr('"{0}" no sigue a ninguna rama remota. ¿Publicarla en origin?',
            [repo.branchLabel]),
        tr('PUBLICAR'),
      );
      if (!ok) return;
    }
    await _run(
      tr('subiendo'),
      (g) => g.push(setUpstream: needsUpstream, branch: repo.branch),
      okMessage: tr('Push completado'),
    );
  }

  Future<void> _discard(GitFileStatus file) async {
    final ok = await _confirm(
      tr('DESCARTAR CAMBIOS'),
      file.isUntracked
          ? tr('"{0}" se eliminará del disco. Esta acción no se puede deshacer.',
              [file.path])
          : tr('Se perderán los cambios sin preparar de "{0}". Esta acción no se puede deshacer.',
              [file.path]),
      tr('DESCARTAR'),
      destructive: true,
    );
    if (!ok) return;
    await _run(
      tr('descartando'),
      (g) => g.discard(file),
      touchesWorkingTree: true,
    );
  }

  Future<void> _discardAll() async {
    final repo = _repo;
    if (repo == null || repo.unstaged.isEmpty) return;
    final ok = await _confirm(
      tr('DESCARTAR TODO'),
      tr('Se descartarán los {0} cambios sin preparar, incluidos los archivos nuevos. Esta acción no se puede deshacer.',
          [repo.unstaged.length]),
      tr('DESCARTAR TODO'),
      destructive: true,
    );
    if (!ok) return;

    setState(() => _busy = tr('descartando'));
    for (final file in repo.unstaged) {
      final git = _git;
      if (git == null) break;
      await git.discard(file);
    }
    if (!mounted) return;
    setState(() => _busy = null);
    await _refresh();
    if (mounted) await widget.state.refreshFiles();
  }

  Future<void> _toggleAmend() async {
    final next = !_amend;
    setState(() => _amend = next);
    if (next && _message.text.trim().isEmpty) {
      final previous = await _git?.headMessage();
      if (!mounted || previous == null) return;
      _message.text = previous;
    }
  }

  /// Opens the diff of [file]; [staged] picks which side of the index.
  ///
  /// A collapsed untracked directory has no diff of its own, so tapping it
  /// browses to it in the explorer instead.
  void _showDiff(GitFileStatus file, {required bool staged}) {
    final git = _git;
    if (git == null) return;
    if (file.isDirectory) {
      _browseTo(file);
      return;
    }
    showAdaptiveSheet(
      context,
      isScrollControlled: true,
      backgroundColor: AppColors.panel,
      // Diffs are wide by nature; give them the most room of any sheet.
      maxWidth: 1000,
      heightFactor: 0.9,
      builder: (_) => GitDiffSheet(git: git, file: file, staged: staged),
    );
  }

  /// Hands one of the canned git prompts to the AI agent in the terminal.
  void _sendAgentPrompt(String prompt, String okLabel) {
    final error = widget.state.sendAgentPrompt(prompt);
    if (error != null) {
      _snack(error, AppColors.danger);
      return;
    }
    Navigator.pop(context);
    widget.onToast?.call(okLabel);
  }

  // ---------------------------------------------------------------------
  // Feedback helpers
  // ---------------------------------------------------------------------

  void _snack(String message, Color color) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message, style: AppText.mono(11, color: color)),
          backgroundColor: AppColors.panelHi,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  /// git's own output, verbatim — a rejected push or a merge conflict says
  /// more in its four lines than any message we could paraphrase.
  void _showOutput(String title, String body) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        title: Text(title,
            style: AppText.label(11, color: AppColors.bone, spacing: 1.4)),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: SelectableText(body,
                style: AppText.mono(10.5, color: AppColors.muted)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('CERRAR'),
                style: AppText.label(10, color: AppColors.accent)),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirm(String title, String body, String confirmLabel,
      {bool destructive = false}) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        title: Text(title,
            style: AppText.label(11, color: AppColors.bone, spacing: 1.4)),
        content:
            Text(body, style: AppText.body(11, color: AppColors.muted)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('CANCELAR'),
                style: AppText.label(10, color: AppColors.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel,
                style: AppText.label(10,
                    color: destructive ? AppColors.danger : AppColors.accent)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  // ---------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          if (_busy != null) _busyBar(),
          Hairline(),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _busyBar() {
    return Container(
      color: AppColors.panelHi,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
                strokeWidth: 1.2, color: AppColors.accent),
          ),
          const SizedBox(width: 10),
          Text('git ${_busy!}…',
              style: AppText.mono(9.5, color: AppColors.muted)),
        ],
      ),
    );
  }

  Widget _header() {
    final repo = _repo;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 6, 10),
      child: Row(
        children: [
          Icon(Icons.account_tree_outlined, size: 16, color: AppColors.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        repo == null
                            ? tr('CONTROL DE VERSIONES')
                            : repo.branchLabel.toUpperCase(),
                        style: AppText.label(11,
                            color: AppColors.bone, spacing: 1.5),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (repo != null && (repo.ahead > 0 || repo.behind > 0)) ...[
                      const SizedBox(width: 8),
                      _syncCounters(repo),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  _headSummary ?? (_rootPath.isEmpty ? '' : _rootPath),
                  style: AppText.mono(9, color: AppColors.muted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.refresh, size: 17, color: AppColors.bone),
            tooltip: tr('Actualizar'),
            onPressed: _busy == null
                ? () {
                    _refresh();
                    _treeKey.currentState?.reload();
                  }
                : null,
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            icon: Icon(Icons.close, size: 17, color: AppColors.bone),
            tooltip: tr('Cerrar'),
            onPressed: () => Navigator.pop(context),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _syncCounters(GitRepoInfo repo) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (repo.ahead > 0) ...[
          Icon(Icons.arrow_upward, size: 10, color: AppColors.accent),
          Text('${repo.ahead}',
              style: AppText.mono(9.5, color: AppColors.accent)),
        ],
        if (repo.behind > 0) ...[
          const SizedBox(width: 6),
          Icon(Icons.arrow_downward, size: 10, color: AppColors.gitModified),
          Text('${repo.behind}',
              style: AppText.mono(9.5, color: AppColors.gitModified)),
        ],
      ],
    );
  }

  Widget _body() {
    if (_loading && _repo == null) {
      return Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
              strokeWidth: 1.5, color: AppColors.accent),
        ),
      );
    }

    if (_fatal != null) return _emptyState(Icons.link_off, _fatal!);

    if (_notARepo) {
      return _emptyState(
        Icons.folder_off_outlined,
        tr('Esta carpeta no es un repositorio git.'),
      );
    }

    final repo = _repo;
    if (repo == null) {
      return _emptyState(
        Icons.help_outline,
        tr('No se pudo leer el estado del repositorio.'),
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _commitBox(repo),
          Hairline(),
          _syncRow(repo),
          Hairline(),
          if (repo.hasConflicts) _conflictBanner(repo),
          _fileGroup(
            label: tr('CAMBIOS PREPARADOS'),
            files: repo.staged,
            expanded: _stagedExpanded,
            onToggle: () => setState(() => _stagedExpanded = !_stagedExpanded),
            staged: true,
            groupAction: repo.staged.isEmpty
                ? null
                : _GroupAction(
                    icon: Icons.remove,
                    tooltip: tr('Quitar todo de preparados'),
                    onTap: () => _run(tr('quitando de preparados'),
                        (g) => g.unstageAll()),
                  ),
          ),
          Hairline(),
          _fileGroup(
            label: tr('CAMBIOS'),
            files: repo.unstaged,
            expanded: _changesExpanded,
            onToggle: () =>
                setState(() => _changesExpanded = !_changesExpanded),
            staged: false,
            groupAction: repo.unstaged.isEmpty
                ? null
                : _GroupAction(
                    icon: Icons.add,
                    tooltip: tr('Preparar todo'),
                    onTap: () => _run(tr('preparando'), (g) => g.stageAll()),
                  ),
            secondaryGroupAction: repo.unstaged.isEmpty
                ? null
                : _GroupAction(
                    icon: Icons.undo,
                    tooltip: tr('Descartar todo'),
                    onTap: _discardAll,
                    danger: true,
                  ),
          ),
          Hairline(),
          _collapsible(
            label: tr('ARCHIVOS DEL PROYECTO'),
            expanded: _treeExpanded,
            onToggle: () => setState(() => _treeExpanded = !_treeExpanded),
            child: () => GitProjectTree(
              key: _treeKey,
              state: widget.state,
              rootPath: _rootPath,
              onFileOpened: () => Navigator.pop(context),
            ),
          ),
          Hairline(),
          _collapsible(
            label: tr('DELEGAR A LA IA'),
            expanded: _agentExpanded,
            onToggle: () => setState(() => _agentExpanded = !_agentExpanded),
            child: _agentButtons,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _emptyState(IconData icon, String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 26, color: AppColors.faint),
            const SizedBox(height: 12),
            Text(message,
                style: AppText.body(11, color: AppColors.muted),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  // --- commit -----------------------------------------------------------

  Widget _commitBox(GitRepoInfo repo) {
    final stagedCount = repo.staged.length;
    final label = _amend
        ? tr('ENMENDAR COMMIT')
        : (stagedCount > 0
            ? tr('COMMIT ({0})', [stagedCount])
            : tr('COMMIT TODO'));

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _message,
            maxLines: 3,
            minLines: 2,
            style: AppText.mono(11, color: AppColors.bone),
            decoration: InputDecoration(
              hintText: _amend
                  ? tr('Mensaje del commit enmendado…')
                  : tr('Mensaje de commit…'),
              hintStyle: AppText.mono(11, color: AppColors.muted),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              fillColor: AppColors.ink,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _busy == null ? _commit : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: AppColors.ink,
                    disabledBackgroundColor: AppColors.hairline,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.zero),
                  ),
                  child: Text(label,
                      style: AppText.label(10, color: AppColors.ink)),
                ),
              ),
              const SizedBox(width: 8),
              _squareButton(
                icon: Icons.history_toggle_off,
                tooltip: tr('Enmendar el último commit'),
                active: _amend,
                onTap: repo.noCommitsYet || _busy != null ? null : _toggleAmend,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _syncRow(GitRepoInfo repo) {
    final canSync = _busy == null && !repo.noCommitsYet;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          Expanded(
            child: _ghostAction(
              icon: Icons.arrow_downward,
              label: tr('PULL'),
              badge: repo.behind > 0 ? '${repo.behind}' : null,
              onTap: canSync
                  ? () => _run(tr('bajando cambios'), (g) => g.pull(),
                      okMessage: tr('Pull completado'),
                      touchesWorkingTree: true)
                  : null,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _ghostAction(
              icon: Icons.arrow_upward,
              label: tr('PUSH'),
              badge: repo.ahead > 0 ? '${repo.ahead}' : null,
              onTap: canSync ? _push : null,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _ghostAction(
              icon: Icons.sync,
              label: tr('FETCH'),
              onTap: canSync
                  ? () => _run(tr('consultando remoto'), (g) => g.fetch())
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _conflictBanner(GitRepoInfo repo) {
    return Container(
      color: AppColors.gitConflict.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 14, color: AppColors.gitConflict),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tr('{0} archivo(s) en conflicto: resuélvelos y prepáralos.',
                  [repo.files.where((f) => f.isConflicted).length]),
              style: AppText.mono(9.5, color: AppColors.gitConflict),
            ),
          ),
        ],
      ),
    );
  }

  // --- file groups ------------------------------------------------------

  Widget _fileGroup({
    required String label,
    required List<GitFileStatus> files,
    required bool expanded,
    required VoidCallback onToggle,
    required bool staged,
    _GroupAction? groupAction,
    _GroupAction? secondaryGroupAction,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 11, 8, 11),
            child: Row(
              children: [
                Icon(
                  expanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  size: 16,
                  color: AppColors.muted,
                ),
                const SizedBox(width: 8),
                Text(label,
                    style:
                        AppText.label(10, color: AppColors.bone, spacing: 1.0)),
                const SizedBox(width: 8),
                if (files.isNotEmpty) _countBadge(files.length),
                const Spacer(),
                if (secondaryGroupAction != null) _groupIcon(secondaryGroupAction),
                if (groupAction != null) _groupIcon(groupAction),
              ],
            ),
          ),
        ),
        if (expanded)
          if (files.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(46, 0, 16, 12),
              child: Text(
                staged
                    ? tr('Nada preparado para el commit')
                    : tr('Sin cambios en el árbol de trabajo'),
                style: AppText.mono(9.5, color: AppColors.faint),
              ),
            )
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: files.length,
              itemBuilder: (_, i) => _fileRow(files[i], staged: staged),
            ),
      ],
    );
  }

  Widget _groupIcon(_GroupAction action) {
    return IconButton(
      icon: Icon(action.icon,
          size: 16,
          color: action.danger ? AppColors.danger : AppColors.muted),
      tooltip: action.tooltip,
      onPressed: _busy == null ? action.onTap : null,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
    );
  }

  Widget _fileRow(GitFileStatus file, {required bool staged}) {
    final letter = staged ? file.stagedLetter : file.unstagedLetter;
    final color = _statusColor(letter, conflicted: file.isConflicted);

    return InkWell(
      onTap: () => _showDiff(file, staged: staged),
      onLongPress: () => _openInEditor(file),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 6, 4),
        child: Row(
          children: [
            Icon(_iconFor(file, letter), size: 14, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: RichText(
                overflow: TextOverflow.ellipsis,
                text: TextSpan(
                  style: AppText.mono(10.5, color: AppColors.bone),
                  children: [
                    if (file.parentDir.isNotEmpty)
                      TextSpan(
                        text: file.parentDir,
                        style:
                            TextStyle(color: AppColors.muted, fontSize: 9.5),
                      ),
                    TextSpan(
                      text: file.name,
                      style: TextStyle(
                        decoration: letter == 'D'
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(letter,
                style: AppText.mono(9.5,
                    color: color, weight: FontWeight.bold)),
            const SizedBox(width: 2),
            if (!staged) ...[
              _rowIcon(
                Icons.undo,
                tr('Descartar cambios'),
                () => _discard(file),
                color: AppColors.danger,
              ),
              _rowIcon(Icons.add, tr('Preparar'),
                  () => _run(tr('preparando'), (g) => g.stage([file.path]))),
            ] else
              _rowIcon(
                Icons.remove,
                tr('Quitar de preparados'),
                () => _run(tr('quitando de preparados'),
                    (g) => g.unstage([file.path])),
              ),
          ],
        ),
      ),
    );
  }

  Widget _rowIcon(IconData icon, String tooltip, VoidCallback onTap,
      {Color? color}) {
    return IconButton(
      icon: Icon(icon, size: 15, color: color ?? AppColors.muted),
      tooltip: tooltip,
      onPressed: _busy == null ? onTap : null,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      padding: EdgeInsets.zero,
    );
  }

  /// Absolute path of a repo-relative entry.
  String _absolute(String relative) {
    final root = _rootPath.endsWith('/')
        ? _rootPath.substring(0, _rootPath.length - 1)
        : _rootPath;
    return '$root/$relative';
  }

  /// Sends a changed file to the explorer/editor, the panel's old tap
  /// behaviour — now a long-press, since tapping shows the diff.
  Future<void> _openInEditor(GitFileStatus file) async {
    if (file.isDirectory) {
      _browseTo(file);
      return;
    }
    Navigator.pop(context);
    await widget.state.navigateToGitFile(
      _absolute(file.path),
      deleted: file.isDeletedOnDisk,
    );
  }

  /// Points the explorer at a directory entry and shows the files tab.
  Future<void> _browseTo(GitFileStatus file) async {
    final path = file.path.endsWith('/')
        ? file.path.substring(0, file.path.length - 1)
        : file.path;
    Navigator.pop(context);
    await widget.state.changeDirectory(_absolute(path));
    widget.state.setActiveTabIndex(2);
  }

  Color _statusColor(String letter, {bool conflicted = false}) {
    if (conflicted) return AppColors.gitConflict;
    switch (letter) {
      case 'A':
      case 'U':
        return AppColors.gitAdded;
      case 'M':
      case 'T':
        return AppColors.gitModified;
      case 'D':
        return AppColors.gitDeleted;
      case 'R':
      case 'C':
        return AppColors.gitRenamed;
      default:
        return AppColors.muted;
    }
  }

  IconData _iconFor(GitFileStatus file, String letter) {
    if (file.isConflicted) return Icons.merge_type;
    if (file.isDirectory) return Icons.folder_outlined;
    switch (letter) {
      case 'D':
        return Icons.delete_outline;
      case 'U':
      case 'A':
        return Icons.add_box_outlined;
      case 'R':
      case 'C':
        return Icons.drive_file_move_outline;
      default:
        return fileIconFor(file.name);
    }
  }

  // --- collapsible sections --------------------------------------------

  Widget _collapsible({
    required String label,
    required bool expanded,
    required VoidCallback onToggle,
    required Widget Function() child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Row(
              children: [
                Icon(
                  expanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  size: 16,
                  color: AppColors.muted,
                ),
                const SizedBox(width: 8),
                Text(label,
                    style:
                        AppText.label(10, color: AppColors.bone, spacing: 1.0)),
              ],
            ),
          ),
        ),
        if (expanded) child(),
      ],
    );
  }

  Widget _agentButtons() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: _agentButton(
              label: tr('COMMIT TODO'),
              icon: Icons.done_all,
              onTap: () => _sendAgentPrompt(
                tr('Haz git add -A y crea un commit con un mensaje descriptivo en español que resuma todos los cambios actuales.'),
                tr('Enviado a la IA: commit de todos los cambios'),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _agentButton(
              label: tr('COMMIT + PUSH'),
              icon: Icons.cloud_upload_outlined,
              onTap: () => _sendAgentPrompt(
                tr('Haz git add -A, crea un commit con un mensaje descriptivo en español que resuma todos los cambios actuales y luego haz git push.'),
                tr('Enviado a la IA: commit y push'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- small shared pieces ---------------------------------------------

  Widget _countBadge(int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text('$count',
          style:
              AppText.mono(8, color: AppColors.accent, weight: FontWeight.bold)),
    );
  }

  Widget _squareButton({
    required IconData icon,
    required String tooltip,
    required bool active,
    VoidCallback? onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: active ? AppColors.accent.withValues(alpha: 0.18) : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              border: Border.all(
                  color: active ? AppColors.accent : AppColors.hairline,
                  width: 1),
            ),
            child: Icon(icon,
                size: 16,
                color: onTap == null
                    ? AppColors.faint
                    : (active ? AppColors.accent : AppColors.bone)),
          ),
        ),
      ),
    );
  }

  Widget _ghostAction({
    required IconData icon,
    required String label,
    String? badge,
    VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    final color = enabled ? AppColors.bone : AppColors.faint;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.hairline, width: 1),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 5),
              Flexible(
                child: Text(label,
                    style: AppText.label(8.5, color: color, spacing: 0.6),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              if (badge != null) ...[
                const SizedBox(width: 4),
                Text(badge, style: AppText.mono(9, color: AppColors.accent)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _agentButton({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.hairline, width: 1),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 13, color: AppColors.bone),
              const SizedBox(width: 6),
              Flexible(
                child: Text(label,
                    style:
                        AppText.label(8.5, color: AppColors.bone, spacing: 0.6),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A button rendered on a group header (stage all, unstage all, discard all).
class _GroupAction {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool danger;

  const _GroupAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.danger = false,
  });
}
