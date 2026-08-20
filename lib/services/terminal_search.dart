import 'package:xterm/xterm.dart';

/// One hit in the scrollback: an absolute buffer line and the columns it spans.
///
/// Columns are *cell* indices, not indices into a trimmed string, so they can
/// be handed straight to `Buffer.createAnchor` to highlight the match.
class TerminalMatch {
  /// Index into `terminal.buffer.lines` — includes scrollback, so it survives
  /// the viewport scrolling.
  final int line;
  final int start;
  final int end;

  const TerminalMatch(this.line, this.start, this.end);
}

/// Full-text search over a terminal's scrollback.
///
/// This is the feature a phone SSH client is most often missing: an error
/// scrolls past, and without search the only way back to it is dragging through
/// thousands of lines with a thumb.
class TerminalSearch {
  TerminalSearch._();

  /// Hard cap on hits. A one-character query against a 10k-line buffer can
  /// match tens of thousands of times; past a few hundred the list is noise and
  /// the work is wasted, so it stops early and the UI says "+".
  static const int maxMatches = 500;

  /// Every occurrence of [query], oldest line first.
  ///
  /// Case-insensitive unless the query contains an uppercase letter — the
  /// "smart case" behaviour of vim and ripgrep, which means the common case
  /// needs no toggle and an explicit capital still narrows.
  static List<TerminalMatch> find(Terminal terminal, String query) {
    if (query.isEmpty) return const [];

    final smartCase = query != query.toLowerCase();
    final needle = smartCase ? query : query.toLowerCase();

    final buffer = terminal.buffer;
    final width = buffer.viewWidth;
    final out = <TerminalMatch>[];

    for (var i = 0; i < buffer.lines.length; i++) {
      final raw = lineText(buffer.lines[i], width);
      final hay = smartCase ? raw : raw.toLowerCase();

      var from = 0;
      while (true) {
        final at = hay.indexOf(needle, from);
        if (at < 0) break;
        out.add(TerminalMatch(i, at, at + needle.length));
        if (out.length >= maxMatches) return out;
        // Overlapping matches ("aa" in "aaa") would double-count the same
        // pixels; advance past the hit instead.
        from = at + needle.length;
      }
    }
    return out;
  }

  /// A buffer line as plain text, one character per cell.
  ///
  /// [BufferLine.getText] drops empty cells, which shifts every column after a
  /// gap — fine for copying, wrong for anything that has to point back at a
  /// cell. Padding blanks keeps `string index == column`, including for wide
  /// glyphs (whose trailing cell reads as empty).
  static String lineText(BufferLine line, int width) {
    final sb = StringBuffer();
    for (var i = 0; i < width; i++) {
      final codePoint = line.getCodePoint(i);
      sb.writeCharCode(codePoint == 0 ? 0x20 : codePoint);
    }
    return sb.toString();
  }
}
