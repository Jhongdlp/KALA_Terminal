import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:io';

import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';
import 'folder_picker_dialog.dart';

class ExplorerTab extends StatefulWidget {
  const ExplorerTab({super.key});

  @override
  State<ExplorerTab> createState() => _ExplorerTabState();
}

class _ExplorerTabState extends State<ExplorerTab> {
  late final TextEditingController _searchController;
  bool _searchOpen = false;
  // Last phase this tab rendered, so the "download finished" toast fires once
  // on the transition instead of on every rebuild.
  DownloadPhase _lastDownloadPhase = DownloadPhase.idle;

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
    final showHidden =
        context.select<AppState, bool>((s) => s.showHidden);
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
    final downloadPhase =
        context.select<AppState, DownloadPhase>((s) => s.downloadPhase);
    _onDownloadPhaseChanged(context, downloadPhase);
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
      if (!showHidden && f.name.startsWith('.')) return false;
      if (typeFilter == FileTypeFilter.folders && !f.isDirectory) return false;
      if (typeFilter == FileTypeFilter.filesOnly && f.isDirectory) return false;
      return query.isEmpty || f.name.toLowerCase().contains(query);
    }).toList();

    return Container(
      color: AppColors.ink,
      child: Column(
        children: [
          _buildPathBar(
            context,
            currentPath,
            typeFilter,
            showHidden,
            canNavigateBack,
            visible,
            selected,
            clipboardCount,
          ),
          if (_searchOpen) _buildSearchBar(context, searchQuery),
          if (downloadPhase != DownloadPhase.idle)
            _buildDownloadBar(context, downloadPhase)
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

  Widget _buildPathBar(
      BuildContext context,
      String currentPath,
      FileTypeFilter typeFilter,
      bool showHidden,
      bool canNavigateBack,
      List<FileSystemEntityInfo> visible,
      Set<String> selected,
      int clipboardCount) {
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
          _barIcon(
              showHidden ? Icons.visibility : Icons.visibility_off,
              tooltip: showHidden ? 'Ocultar archivos ocultos' : 'Mostrar archivos ocultos',
              active: showHidden,
              onTap: () => context.read<AppState>().setShowHidden(!showHidden)),
          _buildFilterButton(context, typeFilter),
          _buildActionsDropdown(context, visible, selected, clipboardCount),
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

  Widget _buildActionsDropdown(
      BuildContext context,
      List<FileSystemEntityInfo> visible,
      Set<String> selected,
      int clipboardCount) {
    final state = context.read<AppState>();
    return PopupMenuButton<String>(
      tooltip: 'Acciones de archivos',
      color: AppColors.panel,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: AppColors.hairline, width: 1),
      ),
      onSelected: (value) async {
        if (value == 'upload') {
          final result = await state.uploadFilesFromPhone();
          if (result.message.isNotEmpty && context.mounted) {
            ScaffoldMessenger.of(context)
              ..clearSnackBars()
              ..showSnackBar(SnackBar(
                content: Text(result.message,
                    style: AppText.mono(11, color: AppColors.bone)),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 4),
              ));
          }
        } else if (value == 'select') {
          state.selectPaths(visible.map((f) => f.path));
        } else if (value == 'copy') {
          state.copySelectionToClipboard(move: false);
        } else if (value == 'paste') {
          await state.pasteClipboard();
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'upload',
          height: 38,
          child: Row(
            children: [
              Icon(Icons.mobile_screen_share, size: 16, color: AppColors.accent),
              const SizedBox(width: 8),
              Text('Subir desde celular',
                  style: AppText.mono(10, color: AppColors.bone, spacing: 1.0)),
            ],
          ),
        ),
        PopupMenuDivider(height: 1),
        PopupMenuItem(
          value: 'select',
          height: 38,
          enabled: visible.isNotEmpty,
          child: Row(
            children: [
              Icon(Icons.select_all, size: 16, color: AppColors.muted),
              const SizedBox(width: 8),
              Text('Seleccionar todo',
                  style: AppText.mono(10,
                      color: visible.isNotEmpty ? AppColors.bone : AppColors.muted,
                      spacing: 1.0)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'copy',
          height: 38,
          enabled: selected.isNotEmpty,
          child: Row(
            children: [
              Icon(Icons.copy_outlined, size: 16, color: AppColors.muted),
              const SizedBox(width: 8),
              Text('Copiar seleccionados',
                  style: AppText.mono(10,
                      color: selected.isNotEmpty ? AppColors.bone : AppColors.muted,
                      spacing: 1.0)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'paste',
          height: 38,
          enabled: clipboardCount > 0,
          child: Row(
            children: [
              Icon(Icons.content_paste, size: 16, color: AppColors.muted),
              const SizedBox(width: 8),
              Text('Pegar aquí',
                  style: AppText.mono(10,
                      color: clipboardCount > 0 ? AppColors.bone : AppColors.muted,
                      spacing: 1.0)),
            ],
          ),
        ),
      ],
      child: SizedBox(
        width: 34,
        height: 34,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.cloud_upload_outlined, size: 16, color: AppColors.bone),
            Icon(Icons.arrow_drop_down, size: 12, color: AppColors.muted),
          ],
        ),
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
              enableIMEPersonalizedLearning: true,
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
          // Descargar al dispositivo (tanto para sesión remota SSH como para local).
          _barIcon(Icons.download_outlined,
              tooltip: 'Descargar al dispositivo',
              onTap: () => _downloadWithPicker(context, state)),
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

  /// The download strip: a live progress bar while files are transferring, and
  /// — once it finishes — a result bar that stays up (with the destination path
  /// and any per-file errors) until the user dismisses it, so a download that
  /// completed while the user was on another tab is still visible when they
  /// come back.
  Widget _buildDownloadBar(BuildContext context, DownloadPhase phase) {
    final state = context.watch<AppState>();

    if (phase == DownloadPhase.done || phase == DownloadPhase.error) {
      return _buildDownloadResultBar(context, state, phase);
    }

    final progress = state.downloadProgress;
    final scanning = phase == DownloadPhase.scanning;
    final pct = progress == null ? null : (progress * 100).round();

    final String detail;
    if (scanning) {
      detail = state.downloadCurrentName.isEmpty
          ? 'CALCULANDO…'
          : 'CALCULANDO · ${state.downloadCurrentName}';
    } else {
      final counts =
          '${state.downloadFilesDone}/${state.downloadFilesTotal} archivos';
      final bytes = state.downloadBytesTotal > 0
          ? ' · ${_formatBytes(state.downloadBytesDone)} / ${_formatBytes(state.downloadBytesTotal)}'
          : '';
      final name = state.downloadCurrentName;
      detail = name.isEmpty ? '$counts$bytes' : '$name · $counts$bytes';
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.panelHi,
        border:
            Border(bottom: BorderSide(color: AppColors.hairline, width: 1)),
      ),
      padding: const EdgeInsets.only(left: 12, top: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  value: scanning ? null : progress,
                  strokeWidth: 1.5,
                  color: AppColors.accent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      scanning
                          ? 'PREPARANDO DESCARGA'
                          : 'DESCARGANDO${pct != null ? ' · $pct%' : ''}',
                      style:
                          AppText.mono(9, color: AppColors.bone, spacing: 1.5),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(detail,
                        style: AppText.mono(9,
                            color: AppColors.muted, spacing: 0.6),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              _barIcon(Icons.close,
                  tooltip: 'Cancelar descarga', onTap: state.cancelDownload),
            ],
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: scanning ? null : progress,
            minHeight: 2,
            backgroundColor: AppColors.hairline,
            color: AppColors.accent,
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadResultBar(
      BuildContext context, AppState state, DownloadPhase phase) {
    final failed = state.downloadFailures.length;
    final isError = phase == DownloadPhase.error;
    final tint = isError || failed > 0 ? AppColors.danger : AppColors.accent;

    final String title;
    final String detail;
    if (isError) {
      title = 'DESCARGA FALLIDA';
      detail = state.downloadError;
    } else {
      title = failed > 0
          ? '${state.downloadFilesDone} DESCARGADO(S) · $failed CON ERRORES'
          : '${state.downloadFilesDone} ARCHIVO(S) DESCARGADO(S)';
      detail = state.downloadDestDir;
    }

    return InkWell(
      onTap: failed > 0 ? () => _showDownloadFailures(context, state) : null,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.panelHi,
          border: Border(
            bottom: BorderSide(color: AppColors.hairline, width: 1),
            left: BorderSide(color: tint, width: 3),
          ),
        ),
        padding: const EdgeInsets.only(left: 10, top: 8, bottom: 8),
        child: Row(
          children: [
            Icon(isError ? Icons.error_outline : Icons.check_circle_outline,
                size: 15, color: tint),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style:
                          AppText.mono(9, color: AppColors.bone, spacing: 1.5),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                      failed > 0
                          ? '$detail — toca para ver los errores'
                          : detail,
                      style: AppText.mono(9,
                          color: AppColors.muted, spacing: 0.6),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            _barIcon(Icons.close,
                tooltip: 'Cerrar', onTap: state.dismissDownloadStatus),
          ],
        ),
      ),
    );
  }

  Future<void> _showDownloadFailures(
      BuildContext context, AppState state) async {
    final failures = state.downloadFailures;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('ERRORES DE DESCARGA',
            style: AppText.label(12, color: AppColors.bone, spacing: 1.5)),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final f in failures)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child:
                      Text(f, style: AppText.mono(11, color: AppColors.muted)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('CERRAR',
                style: AppText.mono(10, color: AppColors.bone, spacing: 1.0)),
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

  /// Toast the outcome the moment a download settles. The result bar keeps the
  /// details around afterwards; this is the "it actually happened" nudge.
  void _onDownloadPhaseChanged(BuildContext context, DownloadPhase phase) {
    if (phase == _lastDownloadPhase) return;
    final previous = _lastDownloadPhase;
    _lastDownloadPhase = phase;
    final settled =
        phase == DownloadPhase.done || phase == DownloadPhase.error;
    if (!settled ||
        (previous != DownloadPhase.transferring &&
            previous != DownloadPhase.scanning)) {
      return;
    }

    final state = context.read<AppState>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final failed = state.downloadFailures.length;
      final String message;
      if (phase == DownloadPhase.error) {
        message = 'Descarga fallida: ${state.downloadError}';
      } else if (failed > 0) {
        message =
            '${state.downloadFilesDone} archivo(s) descargado(s), $failed con errores';
      } else {
        message =
            '${state.downloadFilesDone} archivo(s) descargado(s) en ${state.downloadDestDir}';
      }
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          content: Text(message,
              style: AppText.mono(11, color: AppColors.bone),
              maxLines: 3,
              overflow: TextOverflow.ellipsis),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ));
    });
  }

  /// Ask the user where to save the downloaded files, then kick off the
  /// download into that folder. Cancelling the picker aborts the download.
  Future<void> _downloadWithPicker(
      BuildContext context, AppState state) async {
    // Listing local storage on Android needs the storage permission.
    await state.ensureStoragePermission();
    if (!context.mounted) return;

    // Start the picker at a sensible root: internal storage on Android,
    // the home directory on desktop.
    final String initialPath = Platform.isAndroid
        ? '/storage/emulated/0'
        : (Platform.environment['HOME'] ?? Directory.current.path);

    final dest = await pickLocalDirectory(context, initialPath: initialPath);
    if (dest == null) return; // user cancelled
    await state.downloadSelection(destDir: dest);
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
                      : AppState.isVideoPath(item.path)
                          ? Icons.movie_outlined
                          : AppState.isAudioPath(item.path)
                              ? Icons.audiotrack_outlined
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
