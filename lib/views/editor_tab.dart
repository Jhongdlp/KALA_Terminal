import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:re_editor/re_editor.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';

class EditorTab extends StatefulWidget {
  const EditorTab({super.key});

  @override
  State<EditorTab> createState() => _EditorTabState();
}

class _EditorTabState extends State<EditorTab> {
  CodeLineEditingController? _controller;
  String? _currentFilePath;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _initController(String text, String filePath) {
    _controller?.dispose();
    _controller = CodeLineEditingController.fromText(text);
    _currentFilePath = filePath;

    _controller!.addListener(() {
      final state = Provider.of<AppState>(context, listen: false);
      state.updateFileContent(_controller!.text);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);

    if (state.editingFilePath == null) {
      return Container(
        color: AppColors.ink,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.layers_outlined, size: 36, color: AppColors.faint),
              const SizedBox(height: 14),
              Text('NINGÚN ARCHIVO ABIERTO',
                  style:
                      AppText.mono(9, color: AppColors.muted, spacing: 1.5)),
              const SizedBox(height: 8),
              Text('Abre un archivo desde la pestaña Archivos',
                  style: AppText.body(11, color: AppColors.faint)),
            ],
          ),
        ),
      );
    }

    if (_controller == null || _currentFilePath != state.editingFilePath) {
      _initController(state.editingFileContent, state.editingFilePath!);
    }

    final filename = state.editingFilePath!.split('/').last;

    return Container(
      color: AppColors.ink,
      child: Column(
        children: [
          // Header bar
          Container(
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.panel,
              border: Border(
                  bottom: BorderSide(color: AppColors.hairline, width: 1)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(Icons.close,
                      color: AppColors.muted, size: 16),
                  onPressed: () => state.closeFile(),
                  tooltip: 'Cerrar archivo',
                ),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(filename,
                                style: AppText.mono(12,
                                    color: AppColors.bone,
                                    weight: FontWeight.w700),
                                overflow: TextOverflow.ellipsis),
                          ),
                          if (state.isFileDirty) ...[
                            const SizedBox(width: 8),
                            Container(
                                width: 5, height: 5, color: AppColors.bone),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      MonoTag(
                        state.isEditingFileRemote ? 'REMOTO · SFTP' : 'LOCAL',
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                InvertedButton(
                  label: 'Guardar',
                  icon: Icons.save_outlined,
                  dense: true,
                  onPressed:
                      state.isFileDirty ? () => state.saveCurrentFile() : null,
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),

          // Editor surface
          Expanded(
            child: CodeEditor(
              controller: _controller!,
              style: CodeEditorStyle(
                fontSize: 13,
                fontFamily: AppText.cascadiaFamily,
                fontFamilyFallback: const ['monospace'],
                textColor: AppColors.bone,
                backgroundColor: AppColors.ink,
                cursorColor: AppColors.bone,
                selectionColor: AppColors.hairline,
                cursorLineColor: AppColors.panel,
                chunkIndicatorColor: AppColors.muted,
                codeTheme: CodeHighlightTheme(languages: {}, theme: {}),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
