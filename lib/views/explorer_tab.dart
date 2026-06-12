import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';

class ExplorerTab extends StatelessWidget {
  const ExplorerTab({super.key});

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);

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
                  onPressed: () => state.navigateUp(),
                  tooltip: 'Subir un nivel',
                ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    reverse: true,
                    child: Text(
                      state.currentPath.isEmpty ? '~' : state.currentPath,
                      style: AppText.mono(11, color: AppColors.bone),
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.refresh,
                      color: AppColors.muted, size: 16),
                  onPressed: () => state.changeDirectory(state.currentPath),
                  tooltip: 'Actualizar',
                ),
              ],
            ),
          ),

          Expanded(child: _buildBody(state)),
        ],
      ),
    );
  }

  Widget _buildBody(AppState state) {
    if (state.isLoadingFiles) {
      return Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
              strokeWidth: 1.5, color: AppColors.bone),
        ),
      );
    }

    if (state.files.isEmpty) {
      return Center(
        child: Text('DIRECTORIO VACÍO',
            style: AppText.mono(9, color: AppColors.muted, spacing: 1.5)),
      );
    }

    return ListView.separated(
      itemCount: state.files.length,
      separatorBuilder: (_, _) => const Hairline(),
      itemBuilder: (context, index) {
        final item = state.files[index];
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
