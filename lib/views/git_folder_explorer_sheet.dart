import 'package:flutter/material.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';

class FolderTreeNode {
  final String path;
  final String name;
  final FolderTreeNode? parent;
  List<FolderTreeNode>? children;
  bool isExpanded;
  bool isLoading;

  FolderTreeNode({
    required this.path,
    required this.name,
    this.parent,
    this.children,
    this.isExpanded = false,
    this.isLoading = false,
  });
}

class GitFolderExplorerSheet extends StatefulWidget {
  final AppState state;

  const GitFolderExplorerSheet({
    super.key,
    required this.state,
  });

  @override
  State<GitFolderExplorerSheet> createState() => _GitFolderExplorerSheetState();
}

class _GitFolderExplorerSheetState extends State<GitFolderExplorerSheet> {
  final TextEditingController _commitMessageController = TextEditingController();
  
  FolderTreeNode? _rootNode;
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
      name: rootPath.split('/').last.isEmpty ? 'Proyecto' : rootPath.split('/').last,
      isExpanded: true,
    );
    
    setState(() {
      _rootNode = node;
    });

    final subdirs = await widget.state.listDirectoriesOf(rootPath);
    if (!mounted) return;

    node.children = subdirs.map((d) => FolderTreeNode(
      path: d.path,
      name: d.name,
      parent: node,
    )).toList();

    setState(() {
      _loadingRoot = false;
    });
  }

  Future<void> _toggleNode(FolderTreeNode node) async {
    if (node.isExpanded) {
      setState(() {
        node.isExpanded = false;
      });
    } else {
      setState(() {
        node.isExpanded = true;
      });
      if (node.children == null) {
        setState(() {
          node.isLoading = true;
        });
        final subdirs = await widget.state.listDirectoriesOf(node.path);
        if (!mounted) return;
        
        node.children = subdirs.map((d) => FolderTreeNode(
          path: d.path,
          name: d.name,
          parent: node,
        )).toList();
        
        setState(() {
          node.isLoading = false;
        });
      }
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('El mensaje de commit no puede estar vacío.',
              style: AppText.mono(11, color: AppColors.bone)),
        ),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al hacer commit: $error',
              style: AppText.mono(11, color: AppColors.danger)),
          backgroundColor: AppColors.panelHi,
        ),
      );
    } else {
      _commitMessageController.clear();
      _refreshGitChanges();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Commit realizado con éxito',
              style: AppText.mono(11, color: AppColors.accent)),
        ),
      );
    }
  }

  void _navigateToFolder(String path) async {
    // Navigate file explorer to this directory
    await widget.state.changeDirectory(path);
    if (!mounted) return;
    
    // Switch to ARCHIVOS tab (index 2)
    widget.state.setActiveTabIndex(2);
    
    // Close the sheet
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.panel,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag handle / Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(Icons.account_tree_outlined, size: 16, color: AppColors.accent),
                  const SizedBox(width: 8),
                  Text(
                    'CONTROL DE CAMBIOS Y PROYECTO',
                    style: AppText.label(11, color: AppColors.bone, spacing: 1.5),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.refresh, size: 16, color: AppColors.bone),
                    onPressed: () {
                      _refreshGitChanges();
                      _initTree();
                    },
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    icon: Icon(Icons.close, size: 16, color: AppColors.bone),
                    onPressed: () => Navigator.pop(context),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
            Hairline(),
            
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildGitChangesSection(),
                    Hairline(),
                    _buildFolderTreeSection(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGitChangesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Section Header Toggle
        InkWell(
          onTap: () {
            setState(() {
              _changesExpanded = !_changesExpanded;
            });
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(
                  _changesExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                  size: 16,
                  color: AppColors.muted,
                ),
                const SizedBox(width: 8),
                Text(
                  'CAMBIOS PENDIENTES',
                  style: AppText.label(10, color: AppColors.bone, spacing: 1.0),
                ),
                const SizedBox(width: 8),
                FutureBuilder<List<GitChangedFile>>(
                  future: _gitChangesFuture,
                  builder: (context, snapshot) {
                    if (snapshot.hasData && snapshot.data!.isNotEmpty) {
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.accent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${snapshot.data!.length}',
                          style: AppText.mono(8, color: AppColors.accent, weight: FontWeight.bold),
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ],
            ),
          ),
        ),
        
        if (_changesExpanded)
          FutureBuilder<List<GitChangedFile>>(
            future: _gitChangesFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16.0),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white),
                    ),
                  ),
                );
              }
              
              if (snapshot.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Text(
                    'Error: ${snapshot.error}',
                    style: AppText.body(10, color: AppColors.danger),
                  ),
                );
              }

              final list = snapshot.data ?? [];
              if (list.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  child: Column(
                    children: [
                      Icon(Icons.check_circle_outline, size: 24, color: AppColors.muted),
                      const SizedBox(height: 8),
                      Text(
                        'SIN CAMBIOS PENDIENTES',
                        style: AppText.label(9, color: AppColors.muted, spacing: 1.0),
                      ),
                    ],
                  ),
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: list.length,
                    itemBuilder: (context, idx) {
                      final file = list[idx];
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
                      final dirName = isSubdir ? '${parts.sublist(0, parts.length - 1).join('/')}/' : '';

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
                                    : (file.status == '??' ? Icons.add_box_outlined : Icons.edit_note_outlined),
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
                                          style: TextStyle(color: AppColors.muted, fontSize: 9.5),
                                        ),
                                      TextSpan(
                                        text: fileName,
                                        style: TextStyle(
                                          decoration: file.status == 'D' ? TextDecoration.lineThrough : null,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                statusText,
                                style: AppText.mono(9, color: statusColor, weight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  
                  // Commit box
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _commitMessageController,
                          maxLines: 2,
                          style: AppText.mono(11, color: AppColors.bone),
                          decoration: InputDecoration(
                            hintText: 'Mensaje de commit...',
                            hintStyle: AppText.mono(11, color: AppColors.muted),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: const RoundedRectangleBorder(
                              borderRadius: BorderRadius.zero,
                            ),
                          ),
                          child: _committing
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.black),
                                )
                              : Text(
                                  'HACER COMMIT',
                                  style: AppText.label(10, color: AppColors.ink),
                                ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
      ],
    );
  }

  Widget _buildFolderTreeSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Section Header Toggle
        InkWell(
          onTap: () {
            setState(() {
              _treeExpanded = !_treeExpanded;
            });
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(
                  _treeExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                  size: 16,
                  color: AppColors.muted,
                ),
                const SizedBox(width: 8),
                Text(
                  'ÁRBOL DE CARPETAS',
                  style: AppText.label(10, color: AppColors.bone, spacing: 1.0),
                ),
              ],
            ),
          ),
        ),
        
        if (_treeExpanded)
          _loadingRoot
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24.0),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white),
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
        child: Text(
          'SIN CARPETAS',
          style: AppText.mono(9, color: AppColors.muted),
          textAlign: TextAlign.center,
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: nodes.length,
      itemBuilder: (context, index) {
        final node = nodes[index];
        final depth = _getDepth(node);
        final hasChevron = node.children == null || node.children!.isNotEmpty;

        return Padding(
          padding: EdgeInsets.only(left: 12.0 * depth),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _navigateToFolder(node.path),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
                child: Row(
                  children: [
                    // Expand/collapse chevron or loader
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: node.isLoading
                          ? const Center(
                              child: SizedBox(
                                width: 10,
                                height: 10,
                                child: CircularProgressIndicator(strokeWidth: 1.0, color: Colors.white),
                              ),
                            )
                          : hasChevron
                              ? IconButton(
                                  icon: Icon(
                                    node.isExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                                    size: 14,
                                    color: AppColors.muted,
                                  ),
                                  onPressed: () => _toggleNode(node),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                )
                              : const SizedBox.shrink(),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      node.isExpanded ? Icons.folder_open : Icons.folder,
                      size: 14,
                      color: node.isExpanded ? AppColors.accent : AppColors.muted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        node.name,
                        style: AppText.mono(11, color: AppColors.bone),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
