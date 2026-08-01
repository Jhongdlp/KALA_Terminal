import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../l10n/l10n.dart';

/// A lightweight, in-app folder browser for picking a **local** destination
/// directory (e.g. where to save files downloaded over SFTP). It walks the
/// device filesystem with `dart:io`, so it returns a real path that the
/// download code can write to directly — unlike the Android Storage Access
/// Framework, whose `content://` URIs `dart:io` cannot write through.
///
/// Returns the chosen absolute path, or `null` if the user cancels.
Future<String?> pickLocalDirectory(
  BuildContext context, {
  required String initialPath,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _FolderPickerDialog(initialPath: initialPath),
  );
}

class _FolderPickerDialog extends StatefulWidget {
  const _FolderPickerDialog({required this.initialPath});

  final String initialPath;

  @override
  State<_FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<_FolderPickerDialog> {
  late String _path;
  List<Directory> _dirs = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final dir = Directory(_path);
      final entries = <Directory>[];
      for (final e in dir.listSync(followLinks: false)) {
        if (e is Directory) {
          final name = e.path.split(Platform.pathSeparator).last;
          if (name.startsWith('.')) continue; // hide dotfolders
          entries.add(e);
        }
      }
      entries.sort((a, b) => a.path
          .split(Platform.pathSeparator)
          .last
          .toLowerCase()
          .compareTo(b.path.split(Platform.pathSeparator).last.toLowerCase()));
      if (!mounted) return;
      setState(() {
        _dirs = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = tr('No se pudo abrir la carpeta');
        _dirs = const [];
        _loading = false;
      });
    }
  }

  void _enter(Directory d) {
    _path = d.path;
    _load();
  }

  void _goUp() {
    final parent = Directory(_path).parent.path;
    if (parent == _path) return; // already at filesystem root
    _path = parent;
    _load();
  }

  Future<void> _createFolder() async {
    final name = await _promptFolderName(context);
    if (name == null || name.trim().isEmpty) return;
    try {
      final created = await Directory(
              '$_path${Platform.pathSeparator}${name.trim()}')
          .create();
      _path = created.path;
      _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('No se pudo crear la carpeta'),
              style: AppText.mono(11, color: AppColors.bone)),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      child: SizedBox(
        width: size.width,
        height: size.height * 0.7,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(tr('ELEGIR DESTINO'),
                  style: AppText.label(12, color: AppColors.bone, spacing: 1.5)),
            ),
            // Path + navigation
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.panelHi,
                border: Border(
                  top: BorderSide(color: AppColors.hairline, width: 1),
                  bottom: BorderSide(color: AppColors.hairline, width: 1),
                ),
              ),
              child: Row(
                children: [
                  _icon(Icons.arrow_upward, tr('Subir'), _goUp),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(_path,
                        style: AppText.mono(10, color: AppColors.muted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                  _icon(Icons.create_new_folder_outlined, tr('Nueva carpeta'),
                      _createFolder),
                ],
              ),
            ),
            // Folder list
            Expanded(child: _buildList()),
            // Actions
            Container(
              decoration: BoxDecoration(
                border:
                    Border(top: BorderSide(color: AppColors.hairline, width: 1)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(tr('CANCELAR'),
                          style: AppText.mono(10,
                              color: AppColors.muted, spacing: 1.0)),
                    ),
                  ),
                  Container(width: 1, height: 44, color: AppColors.hairline),
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context, _path),
                      child: Text(tr('DESCARGAR AQUÍ'),
                          style: AppText.mono(10,
                              color: AppColors.bone, spacing: 1.0)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    if (_loading) {
      return Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child:
              CircularProgressIndicator(strokeWidth: 1.5, color: AppColors.bone),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Text(_error!.toUpperCase(),
            style: AppText.mono(9, color: AppColors.muted, spacing: 1.5)),
      );
    }
    if (_dirs.isEmpty) {
      return Center(
        child: Text(tr('SIN SUBCARPETAS'),
            style: AppText.mono(9, color: AppColors.muted, spacing: 1.5)),
      );
    }
    return ListView.builder(
      itemCount: _dirs.length,
      itemBuilder: (_, i) {
        final d = _dirs[i];
        final name = d.path.split(Platform.pathSeparator).last;
        return InkWell(
          onTap: () => _enter(d),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              border: Border(
                  bottom: BorderSide(color: AppColors.hairline, width: 1)),
            ),
            child: Row(
              children: [
                Icon(Icons.folder_outlined, size: 18, color: AppColors.muted),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(name,
                      style: AppText.mono(12, color: AppColors.bone),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                Icon(Icons.chevron_right, size: 16, color: AppColors.faint),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _icon(IconData icon, String tooltip, VoidCallback onTap) {
    return IconButton(
      icon: Icon(icon, size: 18, color: AppColors.bone),
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }
}

Future<String?> _promptFolderName(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('NUEVA CARPETA'),
          style: AppText.label(12, color: AppColors.bone, spacing: 1.5)),
      content: TextField(
        controller: controller,
        autofocus: true,
        enableIMEPersonalizedLearning: true,
        style: AppText.mono(13, color: AppColors.bone),
        decoration: const InputDecoration(hintText: 'nombre'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(tr('CANCELAR'),
              style: AppText.mono(10, color: AppColors.muted, spacing: 1.0)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: Text(tr('CREAR'),
              style: AppText.mono(10, color: AppColors.bone, spacing: 1.0)),
        ),
      ],
    ),
  );
}
