import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_agent/services/agent_screen.dart';

/// The screen classifier behind agent notifications. Each of these decides
/// whether the phone buzzes, so the two directions matter equally: a shell
/// prompt must never look like an agent waiting for an answer, and an agent
/// actually waiting must not be mistaken for a shell.
void main() {
  group('looksLikeShellPrompt', () {
    test('recognises the usual idle prompts', () {
      for (final prompt in const [
        r'jhon@phone:~/dev/kala$',
        r'jhon@phone:~/dev/kala$   ',
        '# ',
        '[root@server ~]#',
        '~/dev/kala %',
        '❯',
        '~/dev ❯ ',
        '➜  kala git:(main) ➜',
      ]) {
        expect(AgentScreen.looksLikeShellPrompt(['some output', prompt]), isTrue,
            reason: 'should be a prompt: "$prompt"');
      }
    });

    test('an agent waiting for input is not a shell prompt', () {
      // Aider's own prompt: `>` is deliberately not a prompt sigil.
      expect(AgentScreen.looksLikeShellPrompt(['> ']), isFalse);
      // Claude Code's input box.
      expect(
        AgentScreen.looksLikeShellPrompt([
          '╭──────────────────────────────╮',
          '│ >                            │',
          '╰──────────────────────────────╯',
          '  ? for shortcuts',
        ]),
        isFalse,
      );
      // A selection menu.
      expect(
        AgentScreen.looksLikeShellPrompt(['Do you want to proceed?', '❯ 1. Yes', '  2. No']),
        isFalse,
      );
    });

    test('a tmux status bar below the prompt does not hide it', () {
      expect(
        AgentScreen.looksLikeShellPrompt([
          r'jhon@server:~$',
          '[0] 0:zsh*                       "server" 12:41 25-ago-26',
        ]),
        isTrue,
      );
    });

    test('output that merely ends in a sigil is not a prompt', () {
      expect(AgentScreen.looksLikeShellPrompt(['Compiling… 100%']), isFalse);
      expect(AgentScreen.looksLikeShellPrompt(['100%']), isFalse);
      expect(
        AgentScreen.looksLikeShellPrompt(['echo "total cost in \$"']), isFalse);
      expect(AgentScreen.looksLikeShellPrompt([]), isFalse);
      expect(AgentScreen.looksLikeShellPrompt(['', '   ']), isFalse);
    });
  });

  group('looksLikeQuestion', () {
    test('menus and questions', () {
      expect(AgentScreen.looksLikeQuestion(['❯ 1. Yes', '  2. No']), isTrue);
      expect(AgentScreen.looksLikeQuestion(['Do you want to continue?']), isTrue);
      expect(AgentScreen.looksLikeQuestion(['Overwrite file (y/n)']), isTrue);
      expect(AgentScreen.looksLikeQuestion(['1. Uno', '2. Dos']), isTrue);
    });

    test('agent chrome does not count as a question', () {
      expect(AgentScreen.looksLikeQuestion(['? for shortcuts']), isFalse);
      expect(AgentScreen.looksLikeQuestion(['Listo, he tocado 3 archivos.']),
          isFalse);
    });
  });

  group('looksBusy', () {
    test('an interrupt affordance means work is running', () {
      expect(
        AgentScreen.looksBusy(['✻ Thinking… (12s · esc to interrupt)']),
        isTrue,
      );
    });

    test('progress verbs only count on an animating line', () {
      expect(AgentScreen.looksBusy(['Voy a ir ejecutando los tests.']), isFalse);
      expect(AgentScreen.looksBusy(['⠹ ejecutando tests…']), isTrue);
    });
  });

  group('read', () {
    test('a shell prompt is read as a prompt, never as a question', () {
      // The reason the precedence exists at all: starship, pure and oh-my-zsh
      // all open with `❯`, which looksLikeQuestion reads as a selection menu.
      // Asking about questions first is what used to announce "espera tu
      // respuesta" at an empty prompt.
      expect(AgentScreen.read(['❯']), ScreenReading.shellPrompt);
      expect(AgentScreen.looksLikeQuestion(['❯']), isTrue,
          reason: 'the overlap this precedence exists to resolve');
    });

    test('a tmux status bar below the prompt does not hide it', () {
      expect(
        AgentScreen.read([
          r'jhon@server:~$',
          '[0] 0:zsh*                       "server" 12:41 25-ago-26',
        ]),
        ScreenReading.shellPrompt,
      );
    });

    test('work in progress beats every other reading', () {
      // Both a question and an interrupt affordance on screen: the agent has
      // not stopped, so nobody is waiting yet.
      expect(
        AgentScreen.read([
          'Do you want to continue?',
          '✻ Thinking… (12s · esc to interrupt)',
        ]),
        ScreenReading.busy,
      );
    });

    test('an agent waiting on an answer is a question', () {
      expect(
        AgentScreen.read(['Do you want to proceed?', '❯ 1. Yes', '  2. No']),
        ScreenReading.question,
      );
      // Aider's own input line: `>` is not a shell sigil.
      expect(AgentScreen.read(['Overwrite file (y/n)', '> ']),
          ScreenReading.question);
    });

    test('a finished answer is quiet, not a question', () {
      expect(AgentScreen.read(['Listo, he tocado 3 archivos.']),
          ScreenReading.quiet);
      expect(AgentScreen.read([]), ScreenReading.quiet);
    });
  });

  group('snippet', () {
    test('drops chrome and box borders, keeps the last lines', () {
      final text = AgentScreen.snippet([
        '│ primera línea                │',
        '│ segunda línea                │',
        '? for shortcuts',
      ]);
      expect(text, 'primera línea\nsegunda línea');
    });
  });
}
