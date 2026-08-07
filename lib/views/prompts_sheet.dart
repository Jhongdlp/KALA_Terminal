import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:uuid/uuid.dart';
import '../models/prompt_snippet.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/adaptive_sheet.dart';
import '../widgets/swiss.dart';
import '../l10n/l10n.dart';

/// Bottom sheet with the saved prompt library: tap a template to insert it
/// into the active terminal (as a bracketed paste, without submitting), or
/// open the composer to write/dictate a new prompt. This is the fast path for
/// sending recurring instructions to a TUI agent from a phone keyboard.
///
/// [onInserted] runs after a prompt lands in the terminal so the caller can
/// refocus it.
void showPromptsSheet(BuildContext context, {VoidCallback? onInserted}) {
  final state = Provider.of<AppState>(context, listen: false);

  void insert(BuildContext sheetCtx, String text) {
    state.insertPromptText(text);
    Navigator.of(sheetCtx).pop();
    onInserted?.call();
  }

  showAdaptiveSheet(
    context,
    backgroundColor: AppColors.panel,
    isScrollControlled: true,
    maxWidth: 520,
    builder: (sheetCtx) => Consumer<AppState>(
      builder: (ctx, s, _) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Text(tr('PROMPTS'),
                      style:
                          AppText.label(11, color: AppColors.bone, spacing: 1.4)),
                  const Spacer(),
                  Text('${s.snippets.length}',
                      style: AppText.mono(10, color: AppColors.muted)),
                ],
              ),
            ),
            Hairline(),
            // Composer entry: write or dictate a one-off (or new) prompt.
            InkWell(
              onTap: () => _showComposer(
                sheetCtx,
                state,
                onInsert: (text) => insert(sheetCtx, text),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    Icon(Icons.mic_none, size: 16, color: AppColors.bone),
                    const SizedBox(width: 12),
                    Text(tr('REDACTAR / DICTAR…'),
                        style: AppText.label(10,
                            color: AppColors.bone, spacing: 1.0)),
                  ],
                ),
              ),
            ),
            Hairline(),
            if (s.snippets.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  tr('Sin plantillas. Redacta un prompt y guárdalo para reusarlo.'),
                  textAlign: TextAlign.center,
                  style: AppText.body(12, color: AppColors.muted),
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: s.snippets.length,
                  separatorBuilder: (_, _) => Hairline(),
                  itemBuilder: (_, i) {
                    final snippet = s.snippets[i];
                    return InkWell(
                      onTap: () => insert(sheetCtx, snippet.text),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        child: Row(
                          children: [
                            Icon(Icons.bolt_outlined,
                                size: 16, color: AppColors.muted),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(snippet.title,
                                      style: AppText.mono(12,
                                          color: AppColors.bone,
                                          weight: FontWeight.w700),
                                      overflow: TextOverflow.ellipsis),
                                  const SizedBox(height: 2),
                                  Text(
                                    snippet.text.replaceAll('\n', ' '),
                                    style: AppText.mono(9,
                                        color: AppColors.muted, spacing: 0.3),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            GestureDetector(
                              onTap: () => _showComposer(
                                sheetCtx,
                                state,
                                existing: snippet,
                                onInsert: (text) => insert(sheetCtx, text),
                              ),
                              behavior: HitTestBehavior.opaque,
                              child: Padding(
                                padding: const EdgeInsets.all(6),
                                child: Icon(Icons.edit_outlined,
                                    size: 15, color: AppColors.muted),
                              ),
                            ),
                            const SizedBox(width: 2),
                            GestureDetector(
                              onTap: () => state.deleteSnippet(snippet.id),
                              behavior: HitTestBehavior.opaque,
                              child: Padding(
                                padding: const EdgeInsets.all(6),
                                child: Icon(Icons.close,
                                    size: 15, color: AppColors.muted),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

void _showComposer(
  BuildContext context,
  AppState state, {
  PromptSnippet? existing,
  required ValueChanged<String> onInsert,
}) {
  showAdaptiveSheet(
    context,
    backgroundColor: AppColors.panel,
    isScrollControlled: true,
    heightFactor: 0.95,
    builder: (composerCtx) => _PromptComposer(
      state: state,
      existing: existing,
      onInsert: (text) {
        Navigator.of(composerCtx).pop();
        onInsert(text);
      },
    ),
  );
}

/// Full prompt composer: a multi-line field with autocorrect (so the system
/// keyboard behaves like a normal editor, mic included) plus a dedicated
/// dictation button backed by the platform SpeechRecognizer. Actions: insert
/// into the terminal, or save as a reusable template.
class _PromptComposer extends StatefulWidget {
  final AppState state;
  final PromptSnippet? existing;
  final ValueChanged<String> onInsert;

  const _PromptComposer({
    required this.state,
    this.existing,
    required this.onInsert,
  });

  @override
  State<_PromptComposer> createState() => _PromptComposerState();
}

class _PromptComposerState extends State<_PromptComposer> {
  late final TextEditingController _titleController =
      TextEditingController(text: widget.existing?.title ?? '');
  late final TextEditingController _textController =
      TextEditingController(text: widget.existing?.text ?? '');

  final SpeechToText _speech = SpeechToText();
  bool _listening = false;
  // Text present in the field when dictation started: partial results replace
  // only what was dictated in this run, never what was already written.
  String _dictationBase = '';

  @override
  void dispose() {
    _speech.cancel();
    _titleController.dispose();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _toggleDictation() async {
    if (_listening) {
      await _speech.stop();
      setState(() => _listening = false);
      return;
    }
    try {
      final available = await _speech.initialize();
      if (!available) {
        _toast(tr('Reconocimiento de voz no disponible'));
        return;
      }
    } catch (_) {
      _toast(tr('Reconocimiento de voz no disponible'));
      return;
    }
    _dictationBase = _textController.text;
    if (_dictationBase.isNotEmpty && !_dictationBase.endsWith(' ')) {
      _dictationBase += ' ';
    }
    setState(() => _listening = true);
    await _speech.listen(
      listenOptions: SpeechListenOptions(
        partialResults: true,
        listenMode: ListenMode.dictation,
        pauseFor: const Duration(seconds: 4),
      ),
      onResult: (result) {
        if (!mounted) return;
        final text = _dictationBase + result.recognizedWords;
        _textController.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
        if (result.finalResult) {
          setState(() => _listening = false);
        }
      },
    );
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message,
            style: AppText.mono(11, color: AppColors.bone, spacing: 0.3)),
        backgroundColor: AppColors.panelHi,
        duration: const Duration(milliseconds: 1400),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _save() async {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      _toast(tr('Escribe o dicta el prompt primero'));
      return;
    }
    var title = _titleController.text.trim();
    if (title.isEmpty) {
      // Default title: first words of the prompt.
      title = text.replaceAll('\n', ' ');
      if (title.length > 40) title = '${title.substring(0, 40)}…';
    }
    await widget.state.saveSnippet(PromptSnippet(
      id: widget.existing?.id ?? const Uuid().v4(),
      title: title,
      text: text,
    ));
    if (!mounted) return;
    _toast(tr('Plantilla guardada'));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 16,
        right: 16,
        top: 18,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
                widget.existing == null
                    ? tr('REDACTAR PROMPT')
                    : tr('EDITAR PLANTILLA'),
                style: AppText.label(10, color: AppColors.bone, spacing: 1.6)),
            const SizedBox(height: 4),
            Hairline(),
            const SizedBox(height: 16),
            TextField(
              controller: _titleController,
              enableIMEPersonalizedLearning: true,
              decoration:
                  InputDecoration(labelText: tr('TÍTULO (OPCIONAL)')),
              style: AppText.body(13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _textController,
              autofocus: true,
              minLines: 4,
              maxLines: 10,
              autocorrect: true,
              enableIMEPersonalizedLearning: true,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                labelText: tr('PROMPT'),
                alignLabelWithHint: true,
              ),
              style: AppText.body(13),
            ),
            const SizedBox(height: 14),
            // Dictation: Android-only (SpeechRecognizer); elsewhere the system
            // keyboard is the only input, which still works fine.
            if (Platform.isAndroid)
              InkWell(
                onTap: _toggleDictation,
                child: Container(
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _listening ? AppColors.bone : Colors.transparent,
                    border: Border.all(
                        color:
                            _listening ? Colors.transparent : AppColors.hairline,
                        width: 1),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(_listening ? Icons.graphic_eq : Icons.mic,
                          size: 20,
                          color:
                              _listening ? AppColors.ink : AppColors.bone),
                      const SizedBox(width: 10),
                      Text(_listening ? tr('ESCUCHANDO… TOCA PARA PARAR') : tr('DICTAR'),
                          style: AppText.label(10,
                              color:
                                  _listening ? AppColors.ink : AppColors.bone,
                              spacing: 1.2)),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: GhostButton(
                    label: tr('Guardar plantilla'),
                    icon: Icons.bookmark_add_outlined,
                    dense: true,
                    onPressed: _save,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: InvertedButton(
                    label: tr('Insertar'),
                    icon: Icons.keyboard_return,
                    dense: true,
                    onPressed: () {
                      final text = _textController.text.trim();
                      if (text.isEmpty) {
                        _toast(tr('Escribe o dicta el prompt primero'));
                        return;
                      }
                      widget.onInsert(text);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
          ],
        ),
      ),
    );
  }
}
