import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:re_editor/re_editor.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';
import 'markdown_view.dart';
import 'pdf_view.dart';

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
    // Listen only to the fields the editor chrome shows. The CodeEditor itself
    // is driven by its own controller, so per-keystroke content changes don't
    // (and shouldn't) rebuild this tab. Isolating it also means switching tabs
    // or activity elsewhere never disturbs the open file.
    final editingFilePath =
        context.select<AppState, String?>((s) => s.editingFilePath);
    final isFileDirty = context.select<AppState, bool>((s) => s.isFileDirty);
    final isEditingFileRemote =
        context.select<AppState, bool>((s) => s.isEditingFileRemote);
    final isMarkdown =
        context.select<AppState, bool>((s) => s.isEditingFileMarkdown);
    final isMarkdownPreview =
        context.select<AppState, bool>((s) => s.isMarkdownPreview);
    final isViewingPdf =
        context.select<AppState, bool>((s) => s.isViewingPdf);
    // AppColors is a global, mutable palette swapped on theme change; depend on
    // themeMode so this isolated tab rebuilds and re-reads the new colors.
    context.select<AppState, ThemeMode>((s) => s.themeMode);

    if (editingFilePath == null) {
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

    final filename = editingFilePath.split('/').last;

    // PDFs render in a read-only embedded viewer — no code editor, no saving.
    if (isViewingPdf) {
      return _buildPdf(context, filename, editingFilePath, isEditingFileRemote);
    }

    // Markdown documents render a formatted, zoomable preview by default; the
    // raw editor stays one tap away via the "Editar" button.
    if (isMarkdown && isMarkdownPreview) {
      return _buildPreview(context, filename, isFileDirty, isEditingFileRemote);
    }

    if (_controller == null || _currentFilePath != editingFilePath) {
      _initController(
          context.read<AppState>().editingFileContent, editingFilePath);
    }

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
                  onPressed: () => context.read<AppState>().closeFile(),
                  tooltip: 'Cerrar archivo',
                ),
                Expanded(
                  child: _FileTitle(
                    filename: filename,
                    isFileDirty: isFileDirty,
                    isEditingFileRemote: isEditingFileRemote,
                  ),
                ),
                const SizedBox(width: 8),
                if (isMarkdown) ...[
                  GhostButton(
                    label: 'Vista',
                    icon: Icons.visibility_outlined,
                    dense: true,
                    onPressed: () =>
                        context.read<AppState>().setMarkdownPreview(true),
                  ),
                  const SizedBox(width: 6),
                ],
                InvertedButton(
                  label: 'Guardar',
                  icon: Icons.save_outlined,
                  dense: true,
                  onPressed: isFileDirty
                      ? () => context.read<AppState>().saveCurrentFile()
                      : null,
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

  /// Formatted markdown preview with a zoom (+/-) control and an "Editar"
  /// button that swaps back to the raw editor. Reads the live editing content
  /// so edits made in the editor show up immediately when returning here.
  Widget _buildPreview(BuildContext context, String filename, bool isFileDirty,
      bool isEditingFileRemote) {
    final state = context.read<AppState>();
    final scale = context.select<AppState, double>((s) => s.markdownScale);
    final content = context.select<AppState, String>((s) => s.editingFileContent);

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
                  icon: Icon(Icons.close, color: AppColors.muted, size: 16),
                  onPressed: () => state.closeFile(),
                  tooltip: 'Cerrar archivo',
                ),
                Expanded(
                  child: _FileTitle(
                    filename: filename,
                    isFileDirty: isFileDirty,
                    isEditingFileRemote: isEditingFileRemote,
                    markdown: true,
                  ),
                ),
                // Zoom controls
                _ZoomButton(
                  icon: Icons.remove,
                  onPressed: scale > AppState.minMarkdownScale
                      ? () => state.bumpMarkdownScale(-0.1)
                      : null,
                ),
                SizedBox(
                  width: 38,
                  child: Text(
                    '${(scale * 100).round()}%',
                    textAlign: TextAlign.center,
                    style: AppText.mono(10, color: AppColors.muted),
                  ),
                ),
                _ZoomButton(
                  icon: Icons.add,
                  onPressed: scale < AppState.maxMarkdownScale
                      ? () => state.bumpMarkdownScale(0.1)
                      : null,
                ),
                const SizedBox(width: 8),
                InvertedButton(
                  label: 'Editar',
                  icon: Icons.edit_outlined,
                  dense: true,
                  onPressed: () => state.setMarkdownPreview(false),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),

          // Rendered document
          Expanded(
            child: MarkdownView(data: content, scale: scale),
          ),
        ],
      ),
    );
  }

  /// Read-only PDF viewer. Same header chrome as the editor (close button +
  /// file title) minus the save/edit actions, with the pdfrx surface below.
  Widget _buildPdf(BuildContext context, String filename, String filePath,
      bool isEditingFileRemote) {
    final bytes = context.read<AppState>().viewingPdfBytes;

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
                  icon: Icon(Icons.close, color: AppColors.muted, size: 16),
                  onPressed: () => context.read<AppState>().closeFile(),
                  tooltip: 'Cerrar archivo',
                ),
                Expanded(
                  child: _FileTitle(
                    filename: filename,
                    isFileDirty: false,
                    isEditingFileRemote: isEditingFileRemote,
                  ),
                ),
                const SizedBox(width: 8),
                MonoTag('PDF', color: AppColors.faint),
                const SizedBox(width: 4),
              ],
            ),
          ),

          // Rendered document
          Expanded(
            child: bytes == null
                ? const SizedBox.shrink()
                : PdfView(data: bytes, sourceName: filePath),
          ),
        ],
      ),
    );
  }
}

/// The filename + connection/markdown tags shown in the editor/preview header.
class _FileTitle extends StatelessWidget {
  final String filename;
  final bool isFileDirty;
  final bool isEditingFileRemote;
  final bool markdown;

  const _FileTitle({
    required this.filename,
    required this.isFileDirty,
    required this.isEditingFileRemote,
    this.markdown = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(filename,
                  style: AppText.mono(12,
                      color: AppColors.bone, weight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis),
            ),
            if (isFileDirty) ...[
              const SizedBox(width: 8),
              Container(width: 5, height: 5, color: AppColors.bone),
            ],
          ],
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            MonoTag(isEditingFileRemote ? 'REMOTO · SFTP' : 'LOCAL'),
            if (markdown) ...[
              const SizedBox(width: 6),
              MonoTag('MARKDOWN', color: AppColors.faint),
            ],
          ],
        ),
      ],
    );
  }
}

/// Square hairline-less icon button sized for the header zoom controls.
class _ZoomButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;

  const _ZoomButton({required this.icon, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return InkWell(
      onTap: onPressed,
      child: Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.hairline, width: 1),
        ),
        child: Icon(icon,
            size: 16, color: enabled ? AppColors.bone : AppColors.faint),
      ),
    );
  }
}
