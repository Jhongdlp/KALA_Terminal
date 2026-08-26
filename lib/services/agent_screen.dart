/// Reading of what a terminal screen is *showing*, for the agent activity
/// detector in `AppState`.
///
/// These are pure functions over the last lines of the buffer, kept out of
/// `AppState` so they can be tested on their own: every one of them decides
/// whether a notification reaches the user's lock screen, and getting one
/// wrong is either a missed answer or a phone that buzzes at a shell prompt
/// nobody is waiting on.
library;

/// What the visible tail of a terminal is showing, as one value.
///
/// The four classifiers below overlap on purpose — a screen can look like a
/// question *and* like a prompt — so something has to decide which reading
/// wins. Having it in one place is what lets the notification path and the
/// agents dashboard agree on what a session is doing.
enum ScreenReading {
  /// Work is running right now.
  busy,

  /// An idle shell prompt: nothing is in the foreground.
  shellPrompt,

  /// Something is waiting for the user: a question, a permission, a menu.
  question,

  /// Nothing is running and nothing is being asked.
  quiet,
}

class AgentScreen {
  const AgentScreen._();

  /// The single reading of [recent], resolving the overlap between the
  /// classifiers below.
  ///
  /// The order is **load-bearing**, and it is the order the notification path
  /// has always applied:
  ///
  /// 1. [looksBusy] — still working beats every other reading.
  /// 2. [looksLikeShellPrompt] — before the question check, not after. Many
  ///    prompts (starship, pure, oh-my-zsh) open with `❯`, which
  ///    [looksLikeQuestion] reads as a selection menu; checking questions first
  ///    is exactly the bug that announced "espera tu respuesta" at an empty
  ///    prompt.
  /// 3. [looksLikeQuestion] — somebody is waiting on the user.
  /// 4. Otherwise the screen is simply quiet.
  static ScreenReading read(List<String> recent) {
    if (looksBusy(recent)) return ScreenReading.busy;
    if (looksLikeShellPrompt(recent)) return ScreenReading.shellPrompt;
    if (looksLikeQuestion(recent)) return ScreenReading.question;
    return ScreenReading.quiet;
  }

  /// Unambiguous "work is running right now" affordances: an agent only offers
  /// a way to interrupt while there is something to interrupt. Matched anywhere
  /// in the visible tail. Covers the known agents, not just Claude Code's
  /// phrasing, since each one words its status line differently.
  static final RegExp _busyStrongRegex = RegExp(
    r'esc to interrupt|esc para interrumpir|esc to cancel|esc para cancelar|'
    r'esc to stop|esc twice|ctrl\+c to (?:stop|cancel|interrupt)|'
    r'ctrl-c to (?:stop|cancel|interrupt)|ctrl\+c para (?:parar|cancelar)|'
    r'press esc to',
  );

  /// Progress verbs. On their own these are worthless — an agent's *answer*
  /// says "running the tests" all the time — so they only count as busy on a
  /// line that also carries an animation tell ([_animatedLineRegex]), i.e. a
  /// live status line rather than prose.
  static final RegExp _busyProgressRegex = RegExp(
    r'\b(thinking|pensando|working|trabajando|generating|generando|'
    r'processing|procesando|ejecutando|executing|streaming|esperando|'
    r'loading|cargando|analizando|analyzing|searching|buscando|'
    r'compiling|compilando|installing|instalando|waiting)\b',
  );

  /// Tells that a line is a live, animating status line: a spinner glyph, a
  /// trailing ellipsis, or an elapsed-time/token counter like "(12s" or "↑1.2k".
  static final RegExp _animatedLineRegex = RegExp(
    r'[⠀-⣿✻✳✶✽✢◐◓◑◒◴◵◶◷⏳⌛]|…|\.\.\.|\(\s*\d+\s*[sm]\b|[↑↓]\s*\d',
  );

  /// UI chrome lines of known agents that would pollute classification and
  /// snippets (Claude Code's "? for shortcuts" bar would read as a question).
  static final RegExp _chromeLineRegex = RegExp(
    r'\?\s*for shortcuts|for commands|for newline|@ for file|shift\+tab|'
    r'bypass permissions|auto-accept|plan mode|context left|/help|'
    r'tokens used|tokens remaining',
  );

  /// Box-drawing characters. A line carrying any of them belongs to a TUI
  /// frame, which is what tells an agent's input box apart from a shell.
  static final RegExp _boxDrawingRegex =
      RegExp(r'[│┃║╭╮╰╯┌┐└┘├┤┬┴─━═╌╍╔╗╚╝▏▕]');

  /// A shell prompt's last token: a path, a `user@host:~/dir`, a `[root@box]`
  /// — then the sigil. Deliberately narrow, so an ordinary output line that
  /// happens to end in `$` or `%` isn't mistaken for a prompt.
  static final RegExp _promptTokenRegex =
      RegExp(r'^[\w.@:~/\\+()\[\]-]*[\$#%]$');

  /// Whether the screen says work is still running. Strong "esc to interrupt"
  /// affordances always count; bare progress verbs only count on an animating
  /// status line, so an agent's prose ("running the tests, then…") can't
  /// silence a real alert.
  static bool looksBusy(List<String> recent) {
    final blob = recent.join('\n').toLowerCase();
    if (_busyStrongRegex.hasMatch(blob)) return true;
    for (final line in recent) {
      final lower = line.toLowerCase();
      if (_busyProgressRegex.hasMatch(lower) &&
          _animatedLineRegex.hasMatch(line)) {
        return true;
      }
    }
    return false;
  }

  /// Whether the tail of the screen looks like an interactive prompt (the
  /// agent is waiting for the user) rather than a finished task.
  static bool looksLikeQuestion(List<String> recent) {
    final meaningful = recent
        .map((l) => l.trim())
        .where(
            (l) => l.isNotEmpty && !_chromeLineRegex.hasMatch(l.toLowerCase()))
        .toList();
    if (meaningful.isEmpty) return false;

    var numbered = 0;
    for (final line in meaningful) {
      final lower = line.toLowerCase();
      // Selection menus: "❯ 1. Yes", "› Option", numbered choices.
      if (line.startsWith('❯') || line.startsWith('›')) return true;
      if (RegExp(r'^\d+[.)]\s').hasMatch(line)) numbered++;
      // Question mark closing a sentence (box borders already trimmed).
      final stripped = line.replaceAll(RegExp(r'[│┃║╮╯┐┘\s]+$'), '');
      if (stripped.endsWith('?')) return true;
      if (lower.contains('¿')) return true;
      if (RegExp(r'\((?:y/n|yes/no|s/n|sí/no)\)|\[(?:y/n|y/N|Y/n|yes/no|s/n)\]',
              caseSensitive: false)
          .hasMatch(line)) {
        return true;
      }
      if (RegExp(r'\b(?:do you want|would you like|allow this|approve|confirm|'
              r'select an option|choose an option|press enter|enter a|'
              r'deseas|quieres|permitir|aprobar|confirmar|selecciona|elige|'
              r'escribe|ingresa|contraseña|password|passphrase)\b')
          .hasMatch(lower)) {
        return true;
      }
    }
    return numbered >= 2;
  }

  /// Whether the screen ends at an **idle shell prompt** — nothing is running
  /// in the foreground, so there is nobody to be waiting on.
  ///
  /// This is what stops the detector from announcing a plain terminal. Leaving
  /// the app hides the soft keyboard, which resizes the PTY, which makes the
  /// shell redraw its prompt: to the signature machinery that is brand new
  /// content going quiet, i.e. exactly the shape of "the agent finished". Many
  /// prompts (starship, pure, oh-my-zsh) even open with `❯`, which
  /// [looksLikeQuestion] reads as a selection menu — hence "espera tu
  /// respuesta" at an empty prompt.
  ///
  /// `>` is deliberately **not** a prompt sigil here: Aider and friends use it
  /// for their own input line, and treating that as a shell would drop the
  /// alerts this feature exists for. Nor is any line carrying box-drawing
  /// characters, which is an agent's input frame rather than a shell.
  static bool looksLikeShellPrompt(List<String> recent) {
    // Only the last couple of lines are considered, and the scan stops dead at
    // the first TUI frame or agent chrome: inside an agent's input box the
    // shell is nowhere near the bottom of the screen. Two lines rather than
    // one because tmux parks its status bar below the prompt.
    var checked = 0;
    for (var i = recent.length - 1; i >= 0 && checked < 2; i--) {
      final line = recent[i].trimRight();
      if (line.trim().isEmpty) continue;
      if (_boxDrawingRegex.hasMatch(line) ||
          _chromeLineRegex.hasMatch(line.toLowerCase())) {
        return false;
      }
      checked++;
      if (_isPromptLine(line)) return true;
    }
    return false;
  }

  /// The prompt shape itself: a sigil closing an otherwise prompt-like line.
  static bool _isPromptLine(String line) {
    if (line.length > 160) return false;
    final sigil = line[line.length - 1];
    if (sigil == '❯' || sigil == '➜' || sigil == '»' || sigil == '▸') {
      return true;
    }
    if (sigil != r'$' && sigil != '#' && sigil != '%') return false;
    // "100%", "(3s)#1" and other output that merely ends in a sigil: a digit
    // right before it is never a prompt.
    if (line.length >= 2 && RegExp(r'\d').hasMatch(line[line.length - 2])) {
      return false;
    }
    final lastToken = line.split(RegExp(r'\s+')).last;
    return _promptTokenRegex.hasMatch(lastToken);
  }

  /// Short human-readable excerpt of what's on screen for the notification
  /// body: the last meaningful lines with TUI chrome and box borders removed.
  static String snippet(List<String> recent) {
    final cleaned = <String>[];
    for (final raw in recent) {
      final line = raw
          .replaceAll(_boxDrawingRegex, ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (line.isEmpty) continue;
      if (_chromeLineRegex.hasMatch(line.toLowerCase())) continue;
      cleaned.add(line);
    }
    if (cleaned.isEmpty) return '';
    final lastLines =
        cleaned.length > 3 ? cleaned.sublist(cleaned.length - 3) : cleaned;
    var snippet = lastLines.join('\n');
    if (snippet.length > 200) {
      snippet = '…${snippet.substring(snippet.length - 200)}';
    }
    return snippet;
  }
}
