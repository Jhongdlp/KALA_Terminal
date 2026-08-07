import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';

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

/// Lazy file tree of the repository, rooted at [rootPath]. Folders load their
/// children the first time they are expanded, so a big repo costs one listdir
/// per opened level instead of a full walk.
class GitProjectTree extends StatefulWidget {
  final AppState state;
  final String rootPath;

  /// Called after a file leaf is opened, so the host panel can dismiss itself.
  final VoidCallback? onFileOpened;

  const GitProjectTree({
    super.key,
    required this.state,
    required this.rootPath,
    this.onFileOpened,
  });

  @override
  State<GitProjectTree> createState() => GitProjectTreeState();
}

class GitProjectTreeState extends State<GitProjectTree> {
  FolderTreeNode? _rootNode;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void didUpdateWidget(GitProjectTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rootPath != widget.rootPath) reload();
  }

  /// Rebuilds the tree from the root, dropping every expanded state.
  Future<void> reload() async {
    if (widget.rootPath.isEmpty) return;
    setState(() => _loading = true);

    final name = widget.rootPath.split('/').last;
    final node = FolderTreeNode(
      path: widget.rootPath,
      name: name.isEmpty ? tr('Proyecto') : name,
      isExpanded: true,
    );
    if (!mounted) return;
    setState(() => _rootNode = node);

    final entries = await widget.state.listTreeEntries(widget.rootPath);
    if (!mounted) return;
    node.children = entries.map(_nodeFor(node)).toList();
    setState(() => _loading = false);
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
      setState(() => node.isExpanded = false);
      return;
    }
    setState(() => node.isExpanded = true);
    if (node.children != null) return;

    setState(() => node.isLoading = true);
    final entries = await widget.state.listTreeEntries(node.path);
    if (!mounted) return;
    node.children = entries.map(_nodeFor(node)).toList();
    setState(() => node.isLoading = false);
  }

  int _depthOf(FolderTreeNode node) {
    int depth = 0;
    FolderTreeNode? p = node.parent;
    while (p != null) {
      depth++;
      p = p.parent;
    }
    return depth;
  }

  List<FolderTreeNode> _flatList() {
    final list = <FolderTreeNode>[];
    if (_rootNode != null) _flatten(_rootNode!, list);
    return list;
  }

  void _flatten(FolderTreeNode node, List<FolderTreeNode> list) {
    list.add(node);
    if (node.isExpanded && node.children != null) {
      for (final child in node.children!) {
        _flatten(child, list);
      }
    }
  }

  /// Navigates the explorer to the file's folder and opens it, which routes
  /// PDFs/Markdown/images to their viewer and everything else to the editor.
  Future<void> _openFileNode(FolderTreeNode node) async {
    await widget.state.navigateToGitFile(node.path);
    if (!mounted) return;
    widget.onFileOpened?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
                strokeWidth: 1.5, color: AppColors.accent),
          ),
        ),
      );
    }

    final nodes = _flatList();
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
    final depth = _depthOf(node);
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
                      : fileIconFor(node.name),
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
}

/// Icon for a file name, shared by the tree and the changed-file rows.
IconData fileIconFor(String name) {
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
