import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';

class ExplorerTab extends StatelessWidget {
  const ExplorerTab({super.key});

  @override
  Widget build(BuildContext context) {
    // Listen only to the slices the explorer renders, so unrelated state
    // changes (terminal output, editor edits…) don't rebuild this tab. The
    // `files` reference changes on each reload (see AppState._loadFilesForSession).
    final currentPath = context.select<AppState, String>((s) => s.currentPath);
    final isLoadingFiles =
        context.select<AppState, bool>((s) => s.isLoadingFiles);
    final files = context
        .select<AppState, List<FileSystemEntityInfo>>((s) => s.files);
    // AppColors is a global, mutable palette swapped on theme change; depend on
    // themeMode so this isolated tab rebuilds and re-reads the new colors.
    context.select<AppState, ThemeMode>((s) => s.themeMode);

    return Container(
      color: AppColors.ink,
      child: Column(
        children: [
          // Path / breadcrumb bar
          Container(
            height: 42,
            decoration: BoxDecoration(
              color: AppColors.panel,
              border: Border(
                  bottom: BorderSide(color: AppColors.hairline, width: 1)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(Icons.arrow_upward,
                      color: AppColors.muted, size: 16),
                  onPressed: () => context.read<AppState>().navigateUp(),
                  tooltip: 'Subir un nivel',
                ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    reverse: true,
                    child: Text(
                      currentPath.isEmpty ? '~' : currentPath,
                      style: AppText.mono(11, color: AppColors.bone),
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.refresh,
                      color: AppColors.muted, size: 16),
                  onPressed: () =>
                      context.read<AppState>().changeDirectory(currentPath),
                  tooltip: 'Actualizar',
                ),
              ],
            ),
          ),

          Expanded(child: _buildBody(context, isLoadingFiles, files)),
        ],
      ),
    );
  }

  Widget _buildBody(
      BuildContext context, bool isLoadingFiles, List<FileSystemEntityInfo> files) {
    if (isLoadingFiles) {
      return Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
              strokeWidth: 1.5, color: AppColors.bone),
        ),
      );
    }

    if (files.isEmpty) {
      return Center(
        child: Text('DIRECTORIO VACÍO',
            style: AppText.mono(9, color: AppColors.muted, spacing: 1.5)),
      );
    }

    return ListView.separated(
      itemCount: files.length,
      separatorBuilder: (_, _) => Hairline(),
      itemBuilder: (context, index) {
        final item = files[index];
        return LayerRow(
          glyph: Icon(item.isDirectory
              ? Icons.folder_outlined
              : Icons.description_outlined),
          title: item.name,
          meta: item.isDirectory
              ? 'CARPETA'
              : '${_formatBytes(item.size)} · ${_formatDate(item.modified)}',
          trailing: item.isDirectory ? const Icon(Icons.chevron_right) : null,
          onTap: () {
            final state = context.read<AppState>();
            if (item.isDirectory) {
              state.changeDirectory(item.path);
            } else {
              state.openFile(item);
            }
          },
        );
      },
    );
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB'];
    var i = 0;
    double size = bytes.toDouble();
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(1)} ${suffixes[i]}';
  }

  String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }
}
