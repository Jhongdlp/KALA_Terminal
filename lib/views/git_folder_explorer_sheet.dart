import 'package:flutter/material.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';
import '../l10n/l10n.dart';

class FolderTreeNode {
  final String path;
  final String name;
  final bool isDirectory;
  final FolderTreeNode? parent;
  List<FolderTreeNode>? children;
  bool isExpanded;
  bool isLoading;

  FolderTreeNode({
    required this.path,
    required this.name,
    this.isDirectory = true,
    this.parent,
    this.children,
    this.isExpanded = false,
    this.isLoading = false,
  });
}

class GitFolderExplorerSheet extends StatefulWidget {
  final AppState state;
  // Shown by the caller (on the root messenger) after the panel closes, e.g.
  // the "sent to AI" confirmation for the delegate-commit buttons.
  final void Function(String message)? onToast;

  const GitFolderExplorerSheet({
    super.key,
    required this.state,
    this.onToast,
  });

  @override
  State<GitFolderExplorerSheet> createState() => _GitFolderExplorerSheetState();
}

class _GitFolderExplorerSheetState extends State<GitFolderExplorerSheet> {
  final TextEditingController _commitMessageController = TextEditingController();

  FolderTreeNode? _rootNode;
  String _rootPath = '';
  bool _loadingRoot = true;
  bool _committing = false;

  bool _changesExpanded = true;
  bool _treeExpanded = true;

  Future<List<GitChangedFile>>? _gitChangesFuture;

  @override
  void initState() {
    super.initState();
    _refreshGitChanges();
    _initTree();
  }

  @override
  void dispose() {
    _commitMessageController.dispose();
    super.dispose();
  }

  void _refreshGitChanges() {
    setState(() {
      _gitChangesFuture = widget.state.getGitStatus();
    });
  }

  Future<void> _initTree() async {
    setState(() {
      _loadingRoot = true;
    });

    final rootPath = await widget.state.getGitRoot();
    if (!mounted) return;

    final node = FolderTreeNode(
      path: rootPath,
      name: rootPath.split('/').last.isEmpty
          ? tr('Proyecto')
          : rootPath.split('/').last,
      isExpanded: true,
    );

    setState(() {
      _rootPath = rootPath;
      _rootNode = node;
    });

    final entries = await widget.state.listTreeEntries(rootPath);
    if (!mounted) return;

    node.children = entries.map(_nodeFor(node)).toList();

    setState(() {
      _loadingRoot = false;
    });
  }

  FolderTreeNode Function(FileSystemEntityInfo) _nodeFor(FolderTreeNode parent) {
    return (e) => FolderTreeNode(
          path: e.path,
          name: e.name,
          isDirectory: e.isDirectory,
          parent: parent,
        );
  }

  Future<void> _toggleNode(FolderTreeNode node) async {
    if (!node.isDirectory) return;
    if (node.isExpanded) {
      setState(() {
        node.isExpanded = false;
      });
      return;
    }
    setState(() {
      node.isExpanded = true;
    });
    if (node.children == null) {
      setState(() {
        node.isLoading = true;
      });
      final entries = await widget.state.listTreeEntries(node.path);
      if (!mounted) return;

      node.children = entries.map(_nodeFor(node)).toList();

      setState(() {
        node.isLoading = false;
      });
    }
  }

  int _getDepth(FolderTreeNode node) {
    int depth = 0;
    FolderTreeNode? p = node.parent;
    while (p != null) {
      depth++;
      p = p.parent;
    }
    return depth;
  }

  List<FolderTreeNode> _buildFlatList() {
    if (_rootNode == null) return [];
    final list = <FolderTreeNode>[];
    _flattenTree(_rootNode!, list);
    return list;
  }

  void _flattenTree(FolderTreeNode node, List<FolderTreeNode> list) {
    list.add(node);
    if (node.isExpanded && node.children != null) {
      for (final child in node.children!) {
        _flattenTree(child, list);
      }
    }
  }

  Future<void> _performCommit() async {
    final message = _commitMessageController.text.trim();
    if (message.isEmpty) {
      _snack(tr('El mensaje de commit no puede estar vacío.'), AppColors.bone);
      return;
    }

    setState(() {
      _committing = true;
    });

    final error = await widget.state.commitChanges(message);
    if (!mounted) return;

    setState(() {
      _committing = false;
    });

    if (error != null) {
      _snack(tr('Error al hacer commit: {0}', [error]), AppColors.danger);
    } else {
      _commitMessageController.clear();
      _refreshGitChanges();
      _snack(tr('Commit realizado con éxito'), AppColors.accent);
    }
  }

  /// Hands one of the canned git prompts to the AI agent running in the
  /// terminal. Surfaces the guard error (no agent / no connection) inline.
  void _sendAgentCommit(String prompt, String okLabel) {
    final error = widget.state.sendAgentPrompt(prompt);
    if (error != null) {
      _snack(error, AppColors.danger);
      return;
    }
    Navigator.pop(context);
    // Panel is gone now; show the confirmation on the root messenger.
    widget.onToast?.call(okLabel);
  }

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

  /// Opens a tree file: navigates the explorer to its folder and opens it,
  /// which routes PDFs/Markdown/images to their viewer and everything else to
  /// the editor.
  Future<void> _openFileNode(FolderTreeNode node) async {
    final lastSlash = node.path.lastIndexOf('/');
    final parentDir = lastSlash > 0 ? node.path.substring(0, lastSlash) : '/';
    await widget.state.changeDirectory(parentDir);
    if (!mounted) return;
    await widget.state.openFile(FileSystemEntityInfo(
      name: node.name,
      path: node.path,
      isDirectory: false,
      size: 0,
      modified: DateTime.now(),
    ));
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          Hairline(),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildGitChangesSection(),
                  Hairline(),
                  _buildFolderTreeSection(),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 12),
      child: Row(
        children: [
          Icon(Icons.account_tree_outlined, size: 16, color: AppColors.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('PROYECTO GIT'),
                    style:
                        AppText.label(11, color: AppColors.bone, spacing: 1.5)),
                if (_rootPath.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(_rootPath,
                      style: AppText.mono(9, color: AppColors.muted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.refresh, size: 17, color: AppColors.bone),
            onPressed: () {
              _refreshGitChanges();
              _initTree();
            },
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            icon: Icon(Icons.close, size: 17, color: AppColors.bone),
            onPressed: () => Navigator.pop(context),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader({
    required bool expanded,
    required String label,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
    return InkWell(
      onTap: onTap,
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
                style: AppText.label(10, color: AppColors.bone, spacing: 1.0)),
            const SizedBox(width: 8),
            ?trailing,
          ],
        ),
      ),
    );
  }

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

  Widget _buildGitChangesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          expanded: _changesExpanded,
          label: tr('CAMBIOS PENDIENTES'),
          onTap: () => setState(() => _changesExpanded = !_changesExpanded),
          trailing: FutureBuilder<List<GitChangedFile>>(
            future: _gitChangesFuture,
            builder: (context, snapshot) {
              if (snapshot.hasData && snapshot.data!.isNotEmpty) {
                return _countBadge(snapshot.data!.length);
              }
              return const SizedBox.shrink();
            },
          ),
        ),
        if (_changesExpanded)
          FutureBuilder<List<GitChangedFile>>(
            future: _gitChangesFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.5, color: AppColors.accent),
                    ),
                  ),
                );
              }

              if (snapshot.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Text('Error: ${snapshot.error}',
                      style: AppText.body(10, color: AppColors.danger)),
                );
              }

              final list = snapshot.data ?? [];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (list.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 16),
                      child: Column(
                        children: [
                          Icon(Icons.check_circle_outline,
                              size: 24, color: AppColors.muted),
                          const SizedBox(height: 8),
                          Text(tr('SIN CAMBIOS PENDIENTES'),
                              style: AppText.label(9,
                                  color: AppColors.muted, spacing: 1.0)),
                        ],
                      ),
                    )
                  else
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: list.length,
                      itemBuilder: (context, idx) => _changedFileRow(list[idx]),
                    ),
                  _buildCommitBox(list.isEmpty),
                ],
              );
            },
          ),
      ],
    );
  }

  Widget _changedFileRow(GitChangedFile file) {
    Color statusColor = AppColors.muted;
    String statusText = file.status;

    if (file.status == 'M') {
      statusColor = Colors.orange;
      statusText = 'M';
    } else if (file.status == '??') {
      statusColor = Colors.green;
      statusText = 'U';
    } else if (file.status == 'A') {
      statusColor = Colors.green;
      statusText = 'A';
    } else if (file.status == 'D') {
      statusColor = AppColors.danger;
      statusText = 'D';
    }

    final parts = file.relativePath.split('/');
    final isSubdir = parts.length > 1;
    final fileName = parts.last;
    final dirName = isSubdir
        ? '${parts.sublist(0, parts.length - 1).join('/')}/'
        : '';

    return InkWell(
      onTap: () {
        Navigator.pop(context);
        widget.state.navigateToGitFile(file);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Row(
          children: [
            Icon(
              file.status == 'D'
                  ? Icons.delete_outline
                  : (file.status == '??'
                      ? Icons.add_box_outlined
                      : Icons.edit_note_outlined),
              size: 14,
              color: statusColor,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: RichText(
                overflow: TextOverflow.ellipsis,
                text: TextSpan(
                  style: AppText.mono(10.5, color: AppColors.bone),
                  children: [
                    if (isSubdir)
                      TextSpan(
                        text: dirName,
                        style: TextStyle(
                            color: AppColors.muted, fontSize: 9.5),
                      ),
                    TextSpan(
                      text: fileName,
                      style: TextStyle(
                        decoration: file.status == 'D'
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(statusText,
                style: AppText.mono(9,
                    color: statusColor, weight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _buildCommitBox(bool noChanges) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _commitMessageController,
            maxLines: 2,
            style: AppText.mono(11, color: AppColors.bone),
            decoration: InputDecoration(
              hintText: tr('Mensaje de commit...'),
              hintStyle: AppText.mono(11, color: AppColors.muted),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              fillColor: AppColors.ink,
            ),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _committing ? null : _performCommit,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: AppColors.ink,
              elevation: 0,
              padding: const EdgeInsets.symmetric(vertical: 11),
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.zero,
              ),
            ),
            child: _committing
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: Colors.black),
                  )
                : Text(tr('HACER COMMIT'),
                    style: AppText.label(10, color: AppColors.ink)),
          ),
          const SizedBox(height: 14),
          // Delegate to the AI agent running in the terminal.
          Row(
            children: [
              Icon(Icons.auto_awesome, size: 12, color: AppColors.muted),
              const SizedBox(width: 6),
              Text(tr('DELEGAR A LA IA'),
                  style:
                      AppText.label(8, color: AppColors.muted, spacing: 1.2)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _agentButton(
                  label: tr('COMMIT TODO'),
                  icon: Icons.done_all,
                  onTap: () => _sendAgentCommit(
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
                  onTap: () => _sendAgentCommit(
                    tr('Haz git add -A, crea un commit con un mensaje descriptivo en español que resuma todos los cambios actuales y luego haz git push.'),
                    tr('Enviado a la IA: commit y push'),
                  ),
                ),
              ),
            ],
          ),
        ],
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
                    style: AppText.label(8.5,
                        color: AppColors.bone, spacing: 0.6),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFolderTreeSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          expanded: _treeExpanded,
          label: tr('ARCHIVOS DEL PROYECTO'),
          onTap: () => setState(() => _treeExpanded = !_treeExpanded),
        ),
        if (_treeExpanded)
          _loadingRoot
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.5, color: AppColors.accent),
                    ),
                  ),
                )
              : _buildTreeList(),
      ],
    );
  }

  Widget _buildTreeList() {
    final nodes = _buildFlatList();
    if (nodes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Text(tr('SIN ARCHIVOS'),
            style: AppText.mono(9, color: AppColors.muted),
            textAlign: TextAlign.center),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: nodes.length,
      itemBuilder: (context, index) => _treeRow(nodes[index]),
    );
  }

  Widget _treeRow(FolderTreeNode node) {
    final depth = _getDepth(node);
    final isDir = node.isDirectory;

    return Padding(
      padding: EdgeInsets.only(left: 8.0 + 14.0 * depth),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => isDir ? _toggleNode(node) : _openFileNode(node),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 7.0),
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: node.isLoading
                      ? Center(
                          child: SizedBox(
                            width: 10,
                            height: 10,
                            child: CircularProgressIndicator(
                                strokeWidth: 1.0, color: AppColors.accent),
                          ),
                        )
                      : isDir
                          ? Icon(
                              node.isExpanded
                                  ? Icons.keyboard_arrow_down
                                  : Icons.keyboard_arrow_right,
                              size: 15,
                              color: AppColors.muted,
                            )
                          : const SizedBox.shrink(),
                ),
                const SizedBox(width: 2),
                Icon(
                  isDir
                      ? (node.isExpanded ? Icons.folder_open : Icons.folder)
                      : _fileIcon(node.name),
                  size: 14,
                  color: isDir
                      ? (node.isExpanded ? AppColors.accent : AppColors.muted)
                      : AppColors.muted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(node.name,
                      style: AppText.mono(11, color: AppColors.bone),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _fileIcon(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.md')) return Icons.article_outlined;
    if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.svg')) {
      return Icons.image_outlined;
    }
    if (lower.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (lower.endsWith('.json') ||
        lower.endsWith('.yaml') ||
        lower.endsWith('.yml') ||
        lower.endsWith('.toml') ||
        lower.endsWith('.lock')) {
      return Icons.data_object;
    }
    return Icons.insert_drive_file_outlined;
  }
}
