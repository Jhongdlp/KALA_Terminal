import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:re_editor/re_editor.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../theme/code_highlight.dart';
import '../widgets/swiss.dart';
import 'audio_view.dart';
import 'image_view.dart';
import 'markdown_view.dart';
import 'pdf_view.dart';
import 'video_view.dart';

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
    final isSvg = context.select<AppState, bool>((s) => s.isEditingFileSvg);
    final isPreviewMode =
        context.select<AppState, bool>((s) => s.isPreviewMode);
    final isViewingPdf =
        context.select<AppState, bool>((s) => s.isViewingPdf);
    final isViewingImage =
        context.select<AppState, bool>((s) => s.isViewingImage);
    final isViewingVideo =
        context.select<AppState, bool>((s) => s.isViewingVideo);
    final isViewingAudio =
        context.select<AppState, bool>((s) => s.isViewingAudio);
    final editorFontSize =
        context.select<AppState, double>((s) => s.editorFontSize);
    final monoFontFamily =
        context.select<AppState, String>((s) => s.monoFontFamily);
    // AppColors is a global, mutable palette swapped on theme change; depend on
    // themeChoice so this isolated tab rebuilds and re-reads the new colors.
    context.select<AppState, AppThemeChoice>((s) => s.themeChoice);

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

    // Images (PNG/JPG/SVG/…) render in a zoomable read-only viewer.
    if (isViewingImage) {
      return _buildImage(
          context, filename, editingFilePath, isEditingFileRemote);
    }

    // Video and audio play through an embedded media_kit player.
    if (isViewingVideo) {
      return _buildVideo(context, filename, isEditingFileRemote);
    }
    if (isViewingAudio) {
      return _buildAudio(context, filename, isEditingFileRemote);
    }

    // Markdown documents render a formatted, zoomable preview by default; the
    // raw editor stays one tap away via the "Editar" button.
    if (isMarkdown && isPreviewMode) {
      return _buildPreview(context, filename, isFileDirty, isEditingFileRemote);
    }

    // SVGs work the same way: rendered preview by default, raw XML editor
    // behind the "Editar" button.
    if (isSvg && isPreviewMode) {
      return _buildSvgPreview(
          context, filename, editingFilePath, isFileDirty, isEditingFileRemote);
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
                if (isMarkdown || isSvg) ...[
                  GhostButton(
                    label: 'Vista',
                    icon: Icons.visibility_outlined,
                    dense: true,
                    onPressed: () =>
                        context.read<AppState>().setPreviewMode(true),
                  ),
                  const SizedBox(width: 6),
                ],
                // Editor font-size controls.
                _ZoomButton(
                  icon: Icons.remove,
                  onPressed: editorFontSize > AppState.minEditorFontSize
                      ? () => context.read<AppState>().bumpEditorFontSize(-1)
                      : null,
                ),
                _ZoomButton(
                  icon: Icons.add,
                  onPressed: editorFontSize < AppState.maxEditorFontSize
                      ? () => context.read<AppState>().bumpEditorFontSize(1)
                      : null,
                ),
                const SizedBox(width: 8),
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
              padding: const EdgeInsets.symmetric(vertical: 8),
              wordWrap: false,
              // Hairline divider between the line-number gutter and the code.
              sperator: Container(width: 1, color: AppColors.hairline),
              style: CodeEditorStyle(
                fontSize: editorFontSize,
                fontHeight: 1.45,
                fontFamily: monoFontFamily,
                fontFamilyFallback: const ['monospace'],
                textColor: AppColors.bone,
                backgroundColor: AppColors.ink,
                cursorColor: AppColors.accent,
                selectionColor: AppColors.accent.withValues(alpha: 0.18),
                cursorLineColor: AppColors.panelHi,
                chunkIndicatorColor: AppColors.muted,
                // Syntax highlighting tuned to the open file's type; null for
                // unknown types falls back to the flat textColor above.
                codeTheme: CodeHighlight.themeFor(filename),
              ),
              // Line-number gutter + code-folding indicator, themed to match.
              indicatorBuilder:
                  (context, editingController, chunkController, notifier) {
                final numberStyle = TextStyle(
                  fontSize: editorFontSize,
                  height: 1.45,
                  fontFamily: monoFontFamily,
                  fontFamilyFallback: const ['monospace'],
                  color: AppColors.faint,
                );
                return Row(
                  children: [
                    DefaultCodeLineNumber(
                      controller: editingController,
                      notifier: notifier,
                      textStyle: numberStyle,
                      focusedTextStyle:
                          numberStyle.copyWith(color: AppColors.accent),
                    ),
                    DefaultCodeChunkIndicator(
                      width: 18,
                      controller: chunkController,
                      notifier: notifier,
                    ),
                  ],
                );
              },
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
                  onPressed: () => state.setPreviewMode(false),
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

  /// Read-only image viewer (PNG/JPG/SVG/…). Same header chrome as the PDF
  /// viewer, with the zoomable image surface below.
  Widget _buildImage(BuildContext context, String filename, String filePath,
      bool isEditingFileRemote) {
    final bytes = context.read<AppState>().viewingImageBytes;
    final extension =
        filename.contains('.') ? filename.split('.').last.toUpperCase() : '';

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
                MonoTag(extension.isEmpty ? 'IMAGEN' : extension,
                    color: AppColors.faint),
                const SizedBox(width: 4),
              ],
            ),
          ),

          // Rendered image
          Expanded(
            child: bytes == null
                ? const SizedBox.shrink()
                : ImageView(data: bytes, sourceName: filePath),
          ),
        ],
      ),
    );
  }

  /// Embedded video player. Same header chrome as the PDF/image viewers, with
  /// the media_kit video surface and a playback bar below.
  Widget _buildVideo(
      BuildContext context, String filename, bool isEditingFileRemote) {
    final path = context.read<AppState>().viewingMediaPath;
    final extension =
        filename.contains('.') ? filename.split('.').last.toUpperCase() : '';

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
                MonoTag(extension.isEmpty ? 'VIDEO' : extension,
                    color: AppColors.faint),
                const SizedBox(width: 4),
              ],
            ),
          ),

          // Video surface + playback controls
          Expanded(
            child: path == null
                ? const SizedBox.shrink()
                : VideoView(path: path),
          ),
        ],
      ),
    );
  }

  /// Embedded audio player. Same header chrome as the other viewers, with a
  /// centered title/icon and a playback bar below.
  Widget _buildAudio(
      BuildContext context, String filename, bool isEditingFileRemote) {
    final path = context.read<AppState>().viewingMediaPath;
    final extension =
        filename.contains('.') ? filename.split('.').last.toUpperCase() : '';

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
                MonoTag(extension.isEmpty ? 'AUDIO' : extension,
                    color: AppColors.faint),
                const SizedBox(width: 4),
              ],
            ),
          ),

          // Player surface
          Expanded(
            child: path == null
                ? const SizedBox.shrink()
                : AudioView(path: path, filename: filename),
          ),
        ],
      ),
    );
  }

  /// Rendered SVG preview with an "Editar" button that swaps to the raw XML
  /// editor — same toggle scheme as the markdown preview. Reads the live
  /// editing content so edits show up immediately when returning here. Zoom is
  /// pinch/drag inside the viewer, so no +/- controls.
  Widget _buildSvgPreview(BuildContext context, String filename,
      String filePath, bool isFileDirty, bool isEditingFileRemote) {
    final state = context.read<AppState>();
    final content =
        context.select<AppState, String>((s) => s.editingFileContent);

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
                  ),
                ),
                const SizedBox(width: 8),
                MonoTag('SVG', color: AppColors.faint),
                const SizedBox(width: 8),
                InvertedButton(
                  label: 'Guardar',
                  icon: Icons.save_outlined,
                  dense: true,
                  onPressed:
                      isFileDirty ? () => state.saveCurrentFile() : null,
                ),
                const SizedBox(width: 6),
                InvertedButton(
                  label: 'Editar',
                  icon: Icons.edit_outlined,
                  dense: true,
                  onPressed: () => state.setPreviewMode(false),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),

          // Rendered SVG (from the live editing text, so unsaved edits render)
          Expanded(
            child: ImageView(
              data: utf8.encode(content),
              sourceName: filePath,
            ),
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
