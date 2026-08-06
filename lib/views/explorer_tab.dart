import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:io';

import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';
import 'folder_picker_dialog.dart';
import '../l10n/l10n.dart';

class ExplorerTab extends StatefulWidget {
  const ExplorerTab({super.key});

  @override
  State<ExplorerTab> createState() => _ExplorerTabState();
}

class _ExplorerTabState extends State<ExplorerTab> {
  late final TextEditingController _searchController;
  bool _searchOpen = false;
  bool _sideDockOpen = false;
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
      child: Stack(
        children: [
          Column(
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
                  child: _buildBody(
                      context, isLoadingFiles, files, visible, selected)),
            ],
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child:
                Center(child: _buildSideDock(context, visible, selected, clipboardCount)),
          ),
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
              tooltip: tr('Volver'),
              color: canNavigateBack ? null : AppColors.hairline,
              onTap: canNavigateBack
                  ? () => context.read<AppState>().navigateBack()
                  : () {}),
          _barIcon(Icons.arrow_upward,
              tooltip: tr('Subir un nivel'),
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
              tooltip: tr('Abrir terminal aquí'),
              onTap: () =>
                  context.read<AppState>().openTerminalAt(currentPath)),
          _barIcon(Icons.search, tooltip: tr('Buscar'), active: _searchOpen,
              onTap: () {
            setState(() => _searchOpen = !_searchOpen);
            if (!_searchOpen) context.read<AppState>().setFileSearchQuery('');
          }),
          _barIcon(
              showHidden ? Icons.visibility : Icons.visibility_off,
              tooltip: showHidden ? tr('Ocultar archivos ocultos') : tr('Mostrar archivos ocultos'),
              active: showHidden,
              onTap: () => context.read<AppState>().setShowHidden(!showHidden)),
          _buildFilterButton(context, typeFilter),
          _barIcon(Icons.refresh,
              tooltip: tr('Actualizar'),
              onTap: () =>
                  context.read<AppState>().changeDirectory(currentPath)),
        ],
      ),
    );
  }

  Widget _buildFilterButton(BuildContext context, FileTypeFilter typeFilter) {
    final labels = {
      FileTypeFilter.all: tr('TODOS'),
      FileTypeFilter.folders: tr('CARPETAS'),
      FileTypeFilter.filesOnly: tr('ARCHIVOS'),
    };
    return PopupMenuButton<FileTypeFilter>(
      tooltip: tr('Filtrar por tipo'),
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

  /// A narrow tab always pinned to the left edge of the screen. Tapping it
  /// slides out a small panel with the file actions (upload, select all,
  /// copy, paste) that used to live in the path bar's dropdown.
  Widget _buildSideDock(
      BuildContext context,
      List<FileSystemEntityInfo> visible,
      Set<String> selected,
      int clipboardCount) {
    final state = context.read<AppState>();

    Future<void> handleUpload() async {
      setState(() => _sideDockOpen = false);
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
    }

    Widget dockButton(IconData icon,
        {required VoidCallback? onTap, String? tooltip, Color? color}) {
      return IconButton(
        icon: Icon(icon, size: 18, color: color ?? AppColors.bone),
        onPressed: onTap,
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        visualDensity: VisualDensity.compact,
      );
    }

    return Material(
      color: Colors.transparent,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppColors.panelHi,
          borderRadius: const BorderRadius.only(
            topRight: Radius.circular(8),
            bottomRight: Radius.circular(8),
          ),
          border: Border.all(color: AppColors.hairline, width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: () => setState(() => _sideDockOpen = !_sideDockOpen),
              child: SizedBox(
                width: 26,
                height: 46,
                child: Icon(
                  _sideDockOpen ? Icons.chevron_left : Icons.chevron_right,
                  size: 16,
                  color: AppColors.muted,
                ),
              ),
            ),
            if (_sideDockOpen) ...[
              Hairline(),
              dockButton(Icons.mobile_screen_share,
                  tooltip: tr('Subir desde celular'),
                  color: AppColors.accent,
                  onTap: handleUpload),
              dockButton(Icons.create_new_folder_outlined,
                  tooltip: tr('Nueva carpeta'),
                  onTap: () {
                    setState(() => _sideDockOpen = false);
                    _promptCreate(context, isFolder: true);
                  }),
              dockButton(Icons.note_add_outlined,
                  tooltip: tr('Nuevo archivo'),
                  onTap: () {
                    setState(() => _sideDockOpen = false);
                    _promptCreate(context, isFolder: false);
                  }),
              dockButton(Icons.select_all,
                  tooltip: tr('Seleccionar todo'),
                  onTap: visible.isEmpty
                      ? null
                      : () => state.selectPaths(visible.map((f) => f.path))),
              dockButton(Icons.copy_outlined,
                  tooltip: tr('Copiar seleccionados'),
                  onTap: selected.isEmpty
                      ? null
                      : () => state.copySelectionToClipboard(move: false)),
              dockButton(Icons.content_paste,
                  tooltip: tr('Pegar aquí'),
                  onTap: clipboardCount == 0
                      ? null
                      : () => state.pasteClipboard()),
              const SizedBox(height: 4),
            ],
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
                hintText: tr('Buscar archivos…'),
                hintStyle: AppText.mono(12, color: AppColors.muted),
              ),
            ),
          ),
          if (searchQuery.isNotEmpty)
            _barIcon(Icons.close,
                tooltip: tr('Limpiar búsqueda'),
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
            child: Text(tr('{0} SELECCIONADO(S)', [selected.length]),
                style: AppText.mono(9, color: AppColors.bone, spacing: 1.5),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          if (selected.length == 1)
            _barIcon(Icons.drive_file_rename_outline,
                tooltip: tr('Renombrar'),
                onTap: () {
                  final entry =
                      visible.firstWhere((f) => f.path == selected.first);
                  _promptRename(context, entry);
                }),
          _barIcon(Icons.select_all,
              tooltip: tr('Seleccionar todo'),
              onTap: () => state.selectPaths(visible.map((f) => f.path))),
          _barIcon(Icons.copy_outlined,
              tooltip: tr('Copiar'),
              onTap: () => state.copySelectionToClipboard(move: false)),
          _barIcon(Icons.drive_file_move_outlined,
              tooltip: tr('Mover'),
              onTap: () => state.copySelectionToClipboard(move: true)),
          // Descargar al dispositivo (tanto para sesión remota SSH como para local).
          _barIcon(Icons.download_outlined,
              tooltip: tr('Descargar al dispositivo'),
              onTap: () => _downloadWithPicker(context, state)),
          _barIcon(Icons.delete_outline,
              tooltip: tr('Eliminar'),
              color: AppColors.danger,
              onTap: () => _confirmDelete(context, selected.length)),
          _barIcon(Icons.close,
              tooltip: tr('Cancelar selección'), onTap: state.clearSelection),
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
          ? tr('CALCULANDO…')
          : tr('CALCULANDO · {0}', [state.downloadCurrentName]);
    } else {
      final counts =
          tr('{0}/{1} archivos', [state.downloadFilesDone, state.downloadFilesTotal]);
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
                          ? tr('PREPARANDO DESCARGA')
                          : tr('DESCARGANDO') + (pct != null ? ' · $pct%' : ''),
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
                  tooltip: tr('Cancelar descarga'), onTap: state.cancelDownload),
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
      title = tr('DESCARGA FALLIDA');
      detail = state.downloadError;
    } else {
      title = failed > 0
          ? tr('{0} DESCARGADO(S) · {1} CON ERRORES', [state.downloadFilesDone, failed])
          : tr('{0} ARCHIVO(S) DESCARGADO(S)', [state.downloadFilesDone]);
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
                          ? tr('{0} — toca para ver los errores', [detail])
                          : detail,
                      style: AppText.mono(9,
                          color: AppColors.muted, spacing: 0.6),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            _barIcon(Icons.close,
                tooltip: tr('Cerrar'), onTap: state.dismissDownloadStatus),
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
        title: Text(tr('ERRORES DE DESCARGA'),
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
            child: Text(tr('CERRAR'),
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
                tr('{0} EN PORTAPAPELES · {1}', [count, isMove ? tr('MOVER') : tr('COPIAR')]),
                style: AppText.mono(9, color: AppColors.muted, spacing: 1.2),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          InvertedButton(
            label: tr('Pegar aquí'),
            dense: true,
            onPressed: () => context.read<AppState>().pasteClipboard(),
          ),
          _barIcon(Icons.close,
              tooltip: tr('Descartar'),
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
        message = tr('Descarga fallida: {0}', [state.downloadError]);
      } else if (failed > 0) {
        message =
            tr('{0} archivo(s) descargado(s), {1} con errores', [state.downloadFilesDone, failed]);
      } else {
        message =
            tr('{0} archivo(s) descargado(s) en {1}', [state.downloadFilesDone, state.downloadDestDir]);
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

  Future<void> _promptCreate(BuildContext context,
      {required bool isFolder}) async {
    final state = context.read<AppState>();
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isFolder ? tr('NUEVA CARPETA') : tr('NUEVO ARCHIVO'),
            style: AppText.label(12, color: AppColors.bone, spacing: 1.5)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: AppText.mono(13, color: AppColors.bone),
          cursorColor: AppColors.bone,
          decoration: InputDecoration(
            hintText:
                isFolder ? tr('Nombre de la carpeta') : tr('Nombre del archivo'),
            hintStyle: AppText.mono(12, color: AppColors.muted),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('CANCELAR'),
                style: AppText.mono(10, color: AppColors.muted, spacing: 1.0)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(tr('CREAR'),
                style: AppText.mono(10, color: AppColors.bone, spacing: 1.0)),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    if (isFolder) {
      await state.createFolder(name);
    } else {
      await state.createFile(name);
    }
  }

  Future<void> _promptRename(
      BuildContext context, FileSystemEntityInfo entry) async {
    final state = context.read<AppState>();
    final controller = TextEditingController(text: entry.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('RENOMBRAR'),
            style: AppText.label(12, color: AppColors.bone, spacing: 1.5)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: AppText.mono(13, color: AppColors.bone),
          cursorColor: AppColors.bone,
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('CANCELAR'),
                style: AppText.mono(10, color: AppColors.muted, spacing: 1.0)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(tr('RENOMBRAR'),
                style: AppText.mono(10, color: AppColors.bone, spacing: 1.0)),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == entry.name) return;
    await state.renameEntry(entry, name);
    if (context.mounted) state.clearSelection();
  }

  Future<void> _confirmDelete(BuildContext context, int count) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ELIMINAR'),
            style: AppText.label(12, color: AppColors.bone, spacing: 1.5)),
        content: Text(
            tr('¿Eliminar {0} elemento(s)? Las carpetas se borran con todo su contenido. Esta acción no se puede deshacer.', [count]),
            style: AppText.body(13, color: AppColors.bone)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('CANCELAR'),
                style: AppText.mono(10, color: AppColors.muted, spacing: 1.0)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('ELIMINAR'),
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
        child: Text(tr('DIRECTORIO VACÍO'),
            style: AppText.mono(9, color: AppColors.muted, spacing: 1.5)),
      );
    }

    if (visible.isEmpty) {
      return Center(
        child: Text(tr('SIN RESULTADOS'),
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
              ? tr('CARPETA')
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
