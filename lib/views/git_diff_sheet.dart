import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/git_status.dart';
import '../services/git_service.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';

/// Unified diff of a single path, colored the way a terminal `git diff` is.
///
/// Lines are laid out in a horizontally scrollable column rather than wrapped:
/// a wrapped diff loses the alignment that makes it readable, and on a phone
/// almost every code line would wrap.
class GitDiffSheet extends StatefulWidget {
  final GitService git;
  final GitFileStatus file;

  /// Diff the index against HEAD instead of the worktree against the index.
  final bool staged;

  const GitDiffSheet({
    super.key,
    required this.git,
    required this.file,
    required this.staged,
  });

  @override
  State<GitDiffSheet> createState() => _GitDiffSheetState();
}

class _GitDiffSheetState extends State<GitDiffSheet> {
  String? _diff;
  bool _loading = true;

  // Explicit controllers so both axes can carry a Scrollbar: a long diff is
  // unnavigable with a mouse otherwise.
  final ScrollController _hScroll = ScrollController();
  final ScrollController _vScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _hScroll.dispose();
    _vScroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final text = await widget.git.diff(widget.file, staged: widget.staged);
    if (!mounted) return;
    setState(() {
      _diff = text;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          Hairline(),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.file.name,
                    style: AppText.mono(12, color: AppColors.bone),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                Text(
                  widget.staged
                      ? tr('DIFERENCIAS PREPARADAS')
                      : tr('CAMBIOS SIN PREPARAR'),
                  style: AppText.label(8, color: AppColors.muted, spacing: 1.2),
                ),
              ],
            ),
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

  Widget _body() {
    if (_loading) {
      return Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child:
              CircularProgressIndicator(strokeWidth: 1.5, color: AppColors.accent),
        ),
      );
    }

    final lines = (_diff ?? '').split('\n');
    // Everything up to the first hunk is git's own file header (index/---/+++);
    // it adds nothing on a screen that already names the file.
    final start = lines.indexWhere((l) => l.startsWith('@@'));
    final body = start > 0 ? lines.sublist(start) : lines;

    if (body.isEmpty || body.every((l) => l.trim().isEmpty)) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(tr('SIN DIFERENCIAS QUE MOSTRAR'),
              style: AppText.label(9, color: AppColors.muted, spacing: 1.0),
              textAlign: TextAlign.center),
        ),
      );
    }

    // Each hunk line paints a full-width background stripe, so the rows have to
    // fill the viewer. Measure the viewer's own box, not the window: sized from
    // MediaQuery, a diff shown in a 500px panel still laid out 1920px-wide rows
    // and its stripes ran far past the panel edge.
    return LayoutBuilder(
      builder: (context, constraints) => Scrollbar(
        controller: _hScroll,
        child: SingleChildScrollView(
          controller: _hScroll,
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Scrollbar(
              controller: _vScroll,
              child: SingleChildScrollView(
                controller: _vScroll,
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [for (final line in body) _diffLine(line)],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _diffLine(String line) {
    Color color = AppColors.bone;
    Color? background;

    if (line.startsWith('@@')) {
      color = AppColors.gitRenamed;
      background = AppColors.gitRenamed.withValues(alpha: 0.10);
    } else if (line.startsWith('+')) {
      color = AppColors.gitAdded;
      background = AppColors.gitAdded.withValues(alpha: 0.10);
    } else if (line.startsWith('-')) {
      color = AppColors.gitDeleted;
      background = AppColors.gitDeleted.withValues(alpha: 0.10);
    } else if (line.startsWith('diff --git') ||
        line.startsWith('index ') ||
        line.startsWith('new file') ||
        line.startsWith('deleted file') ||
        line.startsWith('similarity index') ||
        line.startsWith('rename ')) {
      color = AppColors.muted;
    } else if (line.startsWith('\\')) {
      color = AppColors.faint;
    }

    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: Text(
        line.isEmpty ? ' ' : line,
        style: AppText.mono(10.5, color: color),
        softWrap: false,
        maxLines: 1,
      ),
    );
  }
}
