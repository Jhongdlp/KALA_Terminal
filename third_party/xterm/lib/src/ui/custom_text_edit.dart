import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CustomTextEdit extends StatefulWidget {
  CustomTextEdit({
    super.key,
    required this.child,
    required this.onInsert,
    required this.onDelete,
    required this.onComposing,
    required this.onAction,
    required this.onKeyEvent,
    required this.focusNode,
    this.autofocus = false,
    this.readOnly = false,
    // this.initEditingState = TextEditingValue.empty,
    this.inputType = TextInputType.text,
    this.inputAction = TextInputAction.newline,
    this.keyboardAppearance = Brightness.light,
    this.deleteDetection = false,
    this.onInsertContent,
    this.onArrowLeft,
    this.onArrowRight,
  });

  final Widget child;

  final void Function(String) onInsert;

  final void Function() onDelete;

  final void Function(String?) onComposing;

  final void Function(TextInputAction) onAction;

  final KeyEventResult Function(FocusNode, KeyEvent) onKeyEvent;

  final FocusNode focusNode;

  final bool autofocus;

  final bool readOnly;

  final TextInputType inputType;

  final TextInputAction inputAction;

  final Brightness keyboardAppearance;

  final bool deleteDetection;

  /// Called when the platform inserts rich content (an image pasted via the
  /// soft keyboard, e.g. Gboard). Null disables rich-content support.
  final void Function(KeyboardInsertedContent)? onInsertContent;

  final void Function()? onArrowLeft;

  final void Function()? onArrowRight;

  @override
  CustomTextEditState createState() => CustomTextEditState();
}

class CustomTextEditState extends State<CustomTextEdit> with TextInputClient {
  TextInputConnection? _connection;

  @override
  void initState() {
    widget.focusNode.addListener(_onFocusChange);
    super.initState();
  }

  @override
  void didUpdateWidget(CustomTextEdit oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
    }

    if (!_shouldCreateInputConnection) {
      _closeInputConnectionIfNeeded();
    } else {
      if (oldWidget.readOnly && widget.focusNode.hasFocus) {
        _openInputConnection();
      }
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    _closeInputConnectionIfNeeded();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: _onKeyEvent,
      child: widget.child,
    );
  }

  bool get hasInputConnection => _connection != null && _connection!.attached;

  void requestKeyboard() {
    if (widget.focusNode.hasFocus) {
      _openInputConnection();
    } else {
      widget.focusNode.requestFocus();
    }
  }

  void closeKeyboard() {
    if (hasInputConnection) {
      _connection?.close();
    }
  }

  void setEditingState(TextEditingValue value) {
    _pendingSent = '';
    _currentEditingState = value;
    _connection?.setEditingState(value);
  }

  void setEditableRect(Rect rect, Rect caretRect) {
    if (!hasInputConnection) {
      return;
    }

    _connection?.setEditableSizeAndTransform(
      rect.size,
      Matrix4.translationValues(0, 0, 0),
    );

    _connection?.setCaretRect(caretRect);
  }

  void _onFocusChange() {
    _openOrCloseInputConnectionIfNeeded();
  }

  KeyEventResult _onKeyEvent(FocusNode focusNode, KeyEvent event) {
    if (_currentEditingState.composing.isCollapsed) {
      return widget.onKeyEvent(focusNode, event);
    }

    return KeyEventResult.skipRemainingHandlers;
  }

  void _openOrCloseInputConnectionIfNeeded() {
    if (widget.focusNode.hasFocus && widget.focusNode.consumeKeyboardToken()) {
      _openInputConnection();
    } else if (!widget.focusNode.hasFocus) {
      _closeInputConnectionIfNeeded();
    }
  }

  bool get _shouldCreateInputConnection => kIsWeb || !widget.readOnly;

  void _openInputConnection() {
    if (!_shouldCreateInputConnection) {
      return;
    }

    if (hasInputConnection) {
      _connection!.show();
    } else {
      final config = TextInputConfiguration(
        inputType: widget.inputType,
        inputAction: widget.inputAction,
        keyboardAppearance: widget.keyboardAppearance,
        autocorrect: true,
        enableSuggestions: true,
        enableIMEPersonalizedLearning: true,
        // Advertise support for pasting images via the soft keyboard (Gboard
        // "insert content"). The platform then routes inserts to
        // [insertContent] below. Empty list = feature disabled.
        allowedMimeTypes: widget.onInsertContent == null
            ? const <String>[]
            : const <String>[
                'image/png',
                'image/jpeg',
                'image/jpg',
                'image/gif',
                'image/webp',
              ],
      );

      _connection = TextInput.attach(this, config);

      _connection!.show();

      // setEditableRect(Rect.zero, Rect.zero);

      // A fresh connection starts from the sentinel buffer, so the mirror of
      // what has already been forwarded has to start empty with it.
      _pendingSent = '';
      _currentEditingState = _initEditingState;
      _connection!.setEditingState(_initEditingState);
    }
  }

  void _closeInputConnectionIfNeeded() {
    if (_connection != null && _connection!.attached) {
      _connection!.close();
      _connection = null;
    }
    _pendingSent = '';
  }

  void reset() {
    _pendingSent = '';
    _currentEditingState = _initEditingState;
    _connection?.setEditingState(_initEditingState);
    widget.onComposing(null);
  }

  TextEditingValue get _initEditingState => widget.deleteDetection
      ? const TextEditingValue(
          text: '    ',
          selection: TextSelection.collapsed(offset: 2),
        )
      : const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        );

  late var _currentEditingState = _initEditingState.copyWith();

  /// The characters currently sitting in the IME's buffer that have already
  /// been forwarded to the terminal. Kept in step with the field's typed
  /// region at all times, so what we send is always the *difference*.
  var _pendingSent = '';

  /// How long the mirror is allowed to grow before it is cleared. One command
  /// line is far below this; the cap only exists so a session that never sends
  /// an Enter can't grow without bound.
  static const _maxPendingLength = 1024;

  @override
  TextEditingValue? get currentTextEditingValue {
    return _currentEditingState;
  }

  @override
  AutofillScope? get currentAutofillScope {
    return null;
  }

  /// Where the typed text sits inside the sentinel buffer.
  int get _prefixLength => _initEditingState.selection.baseOffset;
  int get _suffixLength => _initEditingState.text.length - _prefixLength;

  /// The part of [value] the user actually typed, with the sentinel padding
  /// [_initEditingState] wraps it in stripped off.
  String _typedRegion(String text) =>
      text.substring(_prefixLength, text.length - _suffixLength);

  /// Sends the terminal whatever changed between [_pendingSent] and [typed]:
  /// backspaces over the characters that no longer match, then the new tail.
  ///
  /// Working from a diff rather than from "text got longer" is what makes the
  /// keyboard's own edits land correctly — swipe typing replacing a word,
  /// autocorrect rewriting one, or Gboard's fix-the-last-word all arrive as a
  /// rewrite of text that was already sent, not as an append.
  void _forwardDiff(String typed) {
    final sent = _pendingSent;
    if (typed == sent) return;

    var common = 0;
    final limit = min(sent.length, typed.length);
    while (common < limit && sent.codeUnitAt(common) == typed.codeUnitAt(common)) {
      common++;
    }
    // Never split a surrogate pair, or an emoji would be cut in half.
    if (common > 0 &&
        common < sent.length &&
        _isHighSurrogate(sent.codeUnitAt(common - 1))) {
      common--;
    }

    for (var i = sent.length - common; i > 0; i--) {
      widget.onDelete();
    }
    final added = typed.substring(common);
    if (added.isNotEmpty) {
      widget.onInsert(added);
    }
    _pendingSent = typed;
  }

  static bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

  @override
  void updateEditingValue(TextEditingValue value) {
    final previous = _currentEditingState;
    _currentEditingState = value;

    // Still composing — swipe typing, an IME candidate, or a dictation phrase
    // in progress. Report it and wait.
    if (!value.composing.isCollapsed) {
      widget.onComposing(value.composing.textInside(value.text));
      return;
    }

    widget.onComposing(null);

    // The IME ate into the sentinel padding: a backspace with nothing left to
    // delete on this side.
    if (value.text.length < _initEditingState.text.length) {
      widget.onDelete();
      reset();
      return;
    }

    final typed = _typedRegion(value.text);

    if (typed != _pendingSent) {
      _forwardDiff(typed);
      // The mirror is deliberately *not* wiped after forwarding. Wiping it
      // meant calling setEditingState on every committed character, and on
      // Android that restarts the input connection — which ends any running
      // voice-typing session (dictation kept cutting out mid-sentence) and
      // left the keyboard with no text to predict from or autocorrect
      // against. It is cleared on Enter instead, so the keyboard sees one
      // command line at a time. See [performAction] and [reset].
      if (_pendingSent.length > _maxPendingLength) reset();
      return;
    }

    // Same text: a bare cursor move, e.g. Gboard's spacebar cursor slide.
    if (previous.selection.isCollapsed && value.selection.isCollapsed) {
      final diff = value.selection.baseOffset - previous.selection.baseOffset;
      for (var i = 0; i < diff.abs(); i++) {
        diff < 0 ? widget.onArrowLeft?.call() : widget.onArrowRight?.call();
      }
    }
  }

  @override
  void performAction(TextInputAction action) {
    widget.onAction(action);
    // Enter ends the shell's line, so it ends the mirror's too: the keyboard
    // starts the next command with a clean buffer instead of predicting from
    // everything typed so far.
    reset();
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    // print('updateFloatingCursor $point');
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {
    // print('showAutocorrectionPromptRect');
  }

  @override
  void connectionClosed() {
    _pendingSent = '';
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {
    // print('performPrivateCommand $action');
  }

  @override
  void insertTextPlaceholder(Size size) {
    // print('insertTextPlaceholder');
  }

  @override
  void removeTextPlaceholder() {
    // print('removeTextPlaceholder');
  }

  @override
  void showToolbar() {
    // print('showToolbar');
  }

  @override
  void insertContent(KeyboardInsertedContent content) {
    widget.onInsertContent?.call(content);
  }
}
