import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// The soft keyboard talks to the terminal through `CustomTextEdit`, a hidden
/// field holding a four-space sentinel with the caret in the middle. Whatever
/// the IME puts between those spaces is forwarded to the shell as a diff.
///
/// The delicate part is that the field is *not* wiped after each character:
/// wiping it restarts the Android input connection, which kills a running
/// voice-typing session and leaves the keyboard with no context to predict or
/// autocorrect from. These tests pin down that ordinary typing still produces
/// exactly the right bytes with the field left standing.
void main() {
  late Terminal terminal;
  late List<String> output;

  // Mirrors CustomTextEdit._initEditingState for deleteDetection: true.
  const prefix = '  ';
  const suffix = '  ';

  TextEditingValue typed(String text, {TextRange? composing}) {
    final full = '$prefix$text$suffix';
    return TextEditingValue(
      text: full,
      selection: TextSelection.collapsed(offset: prefix.length + text.length),
      composing: composing ?? TextRange.empty,
    );
  }

  Future<void> pumpTerminal(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: TerminalView(
              terminal,
              autofocus: true,
              deleteDetection: true,
              textStyle: const TerminalStyle(fontSize: 12),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.testTextInput.hasAnyClients, isTrue,
        reason: 'the terminal should have attached to the input method');
  }

  setUp(() {
    terminal = Terminal(maxLines: 200);
    output = <String>[];
    terminal.onOutput = output.add;
  });

  testWidgets('typing forwards one character at a time', (tester) async {
    await pumpTerminal(tester);

    tester.testTextInput.updateEditingValue(typed('l'));
    tester.testTextInput.updateEditingValue(typed('ls'));
    tester.testTextInput.updateEditingValue(typed('ls '));
    await tester.pump();

    expect(output.join(), 'ls ');
  });

  testWidgets('the field is left standing so dictation is never restarted',
      (tester) async {
    await pumpTerminal(tester);

    var restarts = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.textInput,
      (call) async {
        if (call.method == 'TextInput.setEditingState') restarts++;
        return null;
      },
    );

    // A dictated phrase: partials arrive composing, then the phrase commits.
    tester.testTextInput.updateEditingValue(
        typed('hola', composing: const TextRange(start: 2, end: 6)));
    tester.testTextInput.updateEditingValue(
        typed('hola mundo', composing: const TextRange(start: 2, end: 12)));
    tester.testTextInput.updateEditingValue(typed('hola mundo'));
    await tester.pump();

    expect(output.join(), 'hola mundo');
    expect(restarts, 0,
        reason: 'pushing a new editing state mid-phrase is what cut dictation');
  });

  testWidgets('a rewritten word is sent as backspaces plus the correction',
      (tester) async {
    await pumpTerminal(tester);

    tester.testTextInput.updateEditingValue(typed('hoal'));
    await tester.pump();
    output.clear();

    // Gboard's fix-the-last-word: the same region comes back rewritten rather
    // than appended to.
    tester.testTextInput.updateEditingValue(typed('hola'));
    await tester.pump();

    // Common prefix is "ho", so "al" is backspaced away and "la" typed.
    expect(output.join(), '\x7f\x7fla');
  });

  testWidgets('deleting inside the buffer sends a backspace', (tester) async {
    await pumpTerminal(tester);

    tester.testTextInput.updateEditingValue(typed('ls'));
    await tester.pump();
    output.clear();

    tester.testTextInput.updateEditingValue(typed('l'));
    await tester.pump();

    expect(output.join(), '\x7f');
  });

  testWidgets('backspace past the start of the buffer still deletes',
      (tester) async {
    await pumpTerminal(tester);
    output.clear();

    // Nothing typed yet: the IME eats into the sentinel padding itself.
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: '   ',
      selection: TextSelection.collapsed(offset: 1),
    ));
    await tester.pump();

    expect(output.join(), '\x7f');
  });

  testWidgets('Enter clears the mirror so the next line starts fresh',
      (tester) async {
    await pumpTerminal(tester);

    tester.testTextInput.updateEditingValue(typed('ls'));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.newline);
    await tester.pump();
    output.clear();

    // Same text again: without the reset this would be read as "no change"
    // and the second command would never reach the shell.
    tester.testTextInput.updateEditingValue(typed('ls'));
    await tester.pump();

    expect(output.join(), 'ls');
  });
}
