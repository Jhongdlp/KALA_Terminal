import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';

class ExplorerTab extends StatefulWidget {
  const ExplorerTab({super.key});

  @override
  State<ExplorerTab> createState() => _ExplorerTabState();
}

class _ExplorerTabState extends State<ExplorerTab> {
  late final TextEditingController _searchController;
  bool _searchOpen = false;

  @override
  void initState() {
    super.initState();
    final query = context.read<AppState>().fileSearchQuery;
    _searchController = TextEditingController(text: query);
    _searchOpen = query.isNotEmpty;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Listen only to the slices the explorer renders, so unrelated state
    // changes (terminal output, editor edits…) don't rebuild this tab. The
    // `files`/`selectedPaths` references are replaced on each change (see
    // AppState._loadFilesForSession / toggleSelected).
    final currentPath = context.select<AppState, String>((s) => s.currentPath);
    final isLoadingFiles =
        context.select<AppState, bool>((s) => s.isLoadingFiles);
    final files = context
        .select<AppState, List<FileSystemEntityInfo>>((s) => s.files);
    final searchQuery =
        context.select<AppState, String>((s) => s.fileSearchQuery);
    final typeFilter =
        context.select<AppState, FileTypeFilter>((s) => s.fileTypeFilter);
    final selected =
        context.select<AppState, Set<String>>((s) => s.selectedPaths);
    final clipboardCount =
        context.select<AppState, int>((s) => s.clipboardCount);
    final clipboardIsMove =
        context.select<AppState, bool>((s) => s.clipboardIsMove);
    final isRemote = context.select<AppState, bool>(
        (s) => s.connectionStatus == ConnectionStatus.remote);
    final canNavigateBack =
        context.select<AppState, bool>((s) => s.canNavigateBack);
    final isDownloading =
        context.select<AppState, bool>((s) => s.isDownloading);
    final downloadCurrent =
        context.select<AppState, int>((s) => s.downloadCurrent);
    final downloadTotal =
        context.select<AppState, int>((s) => s.downloadTotal);
    final downloadCurrentName =
        context.select<AppState, String>((s) => s.downloadCurrentName);
    // AppColors is a global, mutable palette swapped on theme change; depend on
    // themeChoice so this isolated tab rebuilds and re-reads the new colors.
    context.select<AppState, AppThemeChoice>((s) => s.themeChoice);

    // AppState clears the query when navigating; keep the field in sync (the
    // guard also keeps user typing from being clobbered mid-edit).
    if (_searchController.text != searchQuery) {
      _searchController.text = searchQuery;
    }

    final query = searchQuery.toLowerCase();
    final visible = files.where((f) {
      if (typeFilter == FileTypeFilter.folders && !f.isDirectory) return false;
      if (typeFilter == FileTypeFilter.filesOnly && f.isDirectory) return false;
      return query.isEmpty || f.name.toLowerCase().contains(query);
    }).toList();

    return Container(
      color: AppColors.ink,
      child: Column(
        children: [
          _buildPathBar(context, currentPath, typeFilter, canNavigateBack),
          if (_searchOpen) _buildSearchBar(context, searchQuery),
          if (isDownloading)
            _buildDownloadBar(downloadCurrent, downloadTotal, downloadCurrentName)
          else if (selected.isNotEmpty)
            _buildSelectionBar(context, selected, visible, isRemote)
          else if (clipboardCount > 0)
            _buildPasteBar(context, clipboardCount, clipboardIsMove),
          Expanded(
              child:
                  _buildBody(context, isLoadingFiles, files, visible, selected)),
        ],
      ),
    );
  }

  /// Compact 34px icon button so the path bar fits all its actions.
  Widget _barIcon(IconData icon,
      {required VoidCallback onTap,
      String? tooltip,
      Color? color,
      bool active = false}) {
    final sz = (16 * context.read<AppState>().uiIconFactor).roundToDouble();
    return IconButton(
      icon: Icon(icon,
          size: sz, color: color ?? (active ? AppColors.bone : AppColors.muted)),
      onPressed: onTap,
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildPathBar(BuildContext context, String currentPath,
      FileTypeFilter typeFilter, bool canNavigateBack) {
    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: AppColors.panel,
        border:
            Border(bottom: BorderSide(color: AppColors.hairline, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          _barIcon(Icons.arrow_back,
              tooltip: 'Volver',
              color: canNavigateBack ? null : AppColors.hairline,
              onTap: canNavigateBack
                  ? () => context.read<AppState>().navigateBack()
                  : () {}),
          _barIcon(Icons.arrow_upward,
              tooltip: 'Subir un nivel',
              onTap: () => context.read<AppState>().navigateUp()),
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
          _barIcon(Icons.terminal,
              tooltip: 'Abrir terminal aquí',
              onTap: () =>
                  context.read<AppState>().openTerminalAt(currentPath)),
          _barIcon(Icons.search, tooltip: 'Buscar', active: _searchOpen,
              onTap: () {
            setState(() => _searchOpen = !_searchOpen);
            if (!_searchOpen) context.read<AppState>().setFileSearchQuery('');
          }),
          _buildFilterButton(context, typeFilter),
          _barIcon(Icons.refresh,
              tooltip: 'Actualizar',
              onTap: () =>
                  context.read<AppState>().changeDirectory(currentPath)),
        ],
      ),
    );
  }

  Widget _buildFilterButton(BuildContext context, FileTypeFilter typeFilter) {
    const labels = {
      FileTypeFilter.all: 'TODOS',
      FileTypeFilter.folders: 'CARPETAS',
      FileTypeFilter.filesOnly: 'ARCHIVOS',
    };
    return PopupMenuButton<FileTypeFilter>(
      tooltip: 'Filtrar por tipo',
      color: AppColors.panel,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: AppColors.hairline, width: 1),
      ),
      onSelected: (f) => context.read<AppState>().setFileTypeFilter(f),
      itemBuilder: (_) => [
        for (final f in FileTypeFilter.values)
          PopupMenuItem(
            value: f,
            height: 36,
            child: Text(labels[f]!,
                style: AppText.mono(10,
                    color:
                        f == typeFilter ? AppColors.bone : AppColors.muted,
                    spacing: 1.0)),
          ),
      ],
      child: SizedBox(
        width: 34,
        height: 34,
        child: Icon(Icons.filter_list,
            size: 16,
            color: typeFilter == FileTypeFilter.all
                ? AppColors.muted
                : AppColors.bone),
      ),
    );
  }

  Widget _buildSearchBar(BuildContext context, String searchQuery) {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: AppColors.panel,
        border:
            Border(bottom: BorderSide(color: AppColors.hairline, width: 1)),
      ),
      padding: const EdgeInsets.only(left: 12, right: 4),
      child: Row(
        children: [
          Icon(Icons.search, size: 14, color: AppColors.muted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchController,
              onChanged: (v) =>
                  context.read<AppState>().setFileSearchQuery(v),
              style: AppText.mono(12, color: AppColors.bone),
              cursorColor: AppColors.bone,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: 'Buscar archivos…',
                hintStyle: AppText.mono(12, color: AppColors.muted),
              ),
            ),
          ),
          if (searchQuery.isNotEmpty)
            _barIcon(Icons.close,
                tooltip: 'Limpiar búsqueda',
                onTap: () =>
                    context.read<AppState>().setFileSearchQuery('')),
        ],
      ),
    );
  }

  Widget _buildSelectionBar(BuildContext context, Set<String> selected,
      List<FileSystemEntityInfo> visible, bool isRemote) {
    final state = context.read<AppState>();
    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: AppColors.panelHi,
        border:
            Border(bottom: BorderSide(color: AppColors.hairline, width: 1)),
      ),
      padding: const EdgeInsets.only(left: 12, right: 4),
      child: Row(
        children: [
          Expanded(
            child: Text('${selected.length} SELECCIONADO(S)',
                style: AppText.mono(9, color: AppColors.bone, spacing: 1.5),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          _barIcon(Icons.select_all,
              tooltip: 'Seleccionar todo',
              onTap: () => state.selectPaths(visible.map((f) => f.path))),
          _barIcon(Icons.copy_outlined,
              tooltip: 'Copiar',
              onTap: () => state.copySelectionToClipboard(move: false)),
          _barIcon(Icons.drive_file_move_outlined,
              tooltip: 'Mover',
              onTap: () => state.copySelectionToClipboard(move: true)),
          // Descargar al dispositivo: solo disponible en sesión remota (SSH).
          if (isRemote)
            _barIcon(Icons.download_outlined,
                tooltip: 'Descargar al dispositivo',
                onTap: () => state.downloadSelection()),
          _barIcon(Icons.delete_outline,
              tooltip: 'Eliminar',
              color: AppColors.danger,
              onTap: () => _confirmDelete(context, selected.length)),
          _barIcon(Icons.close,
              tooltip: 'Cancelar selección', onTap: state.clearSelection),
        ],
      ),
    );
  }

  Widget _buildDownloadBar(int current, int total, String name) {
    final progress = total > 0 ? current / total : 0.0;
    final label = current < total
        ? 'DESCARGANDO $name… ($current/$total)'
        : 'DESCARGA COMPLETA';
    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: AppColors.panel,
        border:
            Border(bottom: BorderSide(color: AppColors.hairline, width: 1)),
      ),
      padding: const EdgeInsets.only(left: 12, right: 12),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              value: total == 0 ? null : progress,
              strokeWidth: 1.5,
              color: AppColors.bone,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                style: AppText.mono(9, color: AppColors.muted, spacing: 1.0),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Widget _buildPasteBar(BuildContext context, int count, bool isMove) {
    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: AppColors.panel,
        border:
            Border(bottom: BorderSide(color: AppColors.hairline, width: 1)),
      ),
      padding: const EdgeInsets.only(left: 12, right: 4),
      child: Row(
        children: [
          Icon(Icons.content_paste, size: 14, color: AppColors.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
                '$count EN PORTAPAPELES · ${isMove ? 'MOVER' : 'COPIAR'}',
                style: AppText.mono(9, color: AppColors.muted, spacing: 1.2),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          InvertedButton(
            label: 'Pegar aquí',
            dense: true,
            onPressed: () => context.read<AppState>().pasteClipboard(),
          ),
          _barIcon(Icons.close,
              tooltip: 'Descartar',
              onTap: () => context.read<AppState>().clearClipboard()),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, int count) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('ELIMINAR',
            style: AppText.label(12, color: AppColors.bone, spacing: 1.5)),
        content: Text(
            '¿Eliminar $count elemento(s)? Las carpetas se borran con todo su '
            'contenido. Esta acción no se puede deshacer.',
            style: AppText.body(13, color: AppColors.bone)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('CANCELAR',
                style: AppText.mono(10, color: AppColors.muted, spacing: 1.0)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('ELIMINAR',
                style:
                    AppText.mono(10, color: AppColors.danger, spacing: 1.0)),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      context.read<AppState>().deleteSelection();
    }
  }

  Widget _buildBody(
      BuildContext context,
      bool isLoadingFiles,
      List<FileSystemEntityInfo> files,
      List<FileSystemEntityInfo> visible,
      Set<String> selected) {
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

    if (visible.isEmpty) {
      return Center(
        child: Text('SIN RESULTADOS',
            style: AppText.mono(9, color: AppColors.muted, spacing: 1.5)),
      );
    }

    final selectionMode = selected.isNotEmpty;
    return ListView.separated(
      itemCount: visible.length,
      separatorBuilder: (_, _) => Hairline(),
      itemBuilder: (context, index) {
        final item = visible[index];
        final isSelected = selected.contains(item.path);
        return LayerRow(
          glyph: Icon(selectionMode
              ? (isSelected
                  ? Icons.check_box_outlined
                  : Icons.check_box_outline_blank)
              : item.isDirectory
                  ? Icons.folder_outlined
                  : AppState.isImagePath(item.path)
                      ? Icons.image_outlined
                      : Icons.description_outlined),
          title: item.name,
          meta: item.isDirectory
              ? 'CARPETA'
              : '${_formatBytes(item.size)} · ${_formatDate(item.modified)}',
          active: isSelected,
          // The folder's trailing button drops the terminal into that path.
          trailing: item.isDirectory && !selectionMode
              ? const Icon(Icons.terminal)
              : null,
          onTrailingTap: item.isDirectory && !selectionMode
              ? () => context.read<AppState>().openTerminalAt(item.path)
              : null,
          onTap: () {
            final state = context.read<AppState>();
            if (selectionMode) {
              state.toggleSelected(item.path);
            } else if (item.isDirectory) {
              state.changeDirectory(item.path);
            } else {
              state.openFile(item);
            }
          },
          // Long press enters selection mode with this item selected.
          onLongPress: () =>
              context.read<AppState>().toggleSelected(item.path),
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
