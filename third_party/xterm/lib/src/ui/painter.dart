import 'dart:ui';
import 'package:flutter/painting.dart';

import 'package:xterm/src/ui/palette_builder.dart';
import 'package:xterm/src/ui/paragraph_cache.dart';
import 'package:xterm/xterm.dart';

/// Encapsulates the logic for painting various terminal elements.
class TerminalPainter {
  TerminalPainter({
    required TerminalTheme theme,
    required TerminalStyle textStyle,
    required TextScaler textScaler,
  })  : _textStyle = textStyle,
        _theme = theme,
        _textScaler = textScaler;

  /// A lookup table from terminal colors to Flutter colors.
  late var _colorPalette = PaletteBuilder(_theme).build();

  /// Size of each character in the terminal.
  late var _cellSize = _measureCharSize();

  /// The cached for cells in the terminal. Should be cleared when the same
  /// cell no longer produces the same visual output. For example, when
  /// [_textStyle] is changed, or when the system font changes.
  final _paragraphCache = ParagraphCache(10240);

  TerminalStyle get textStyle => _textStyle;
  TerminalStyle _textStyle;
  set textStyle(TerminalStyle value) {
    if (value == _textStyle) return;
    _textStyle = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
  }

  TextScaler get textScaler => _textScaler;
  TextScaler _textScaler = TextScaler.linear(1.0);
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
  }

  TerminalTheme get theme => _theme;
  TerminalTheme _theme;
  set theme(TerminalTheme value) {
    if (value == _theme) return;
    _theme = value;
    _colorPalette = PaletteBuilder(value).build();
    _paragraphCache.clear();
  }

  Size _measureCharSize() {
    const test = 'mmmmmmmmmm';

    final textStyle = _textStyle.toTextStyle();
    final builder = ParagraphBuilder(textStyle.getParagraphStyle());
    builder.pushStyle(
      textStyle.getTextStyle(textScaler: _textScaler),
    );
    builder.addText(test);

    final paragraph = builder.build();
    paragraph.layout(ParagraphConstraints(width: double.infinity));

    final result = Size(
      paragraph.maxIntrinsicWidth / test.length,
      paragraph.height,
    );

    paragraph.dispose();
    return result;
  }

  /// The size of each character in the terminal.
  Size get cellSize => _cellSize;

  /// When the set of font available to the system changes, call this method to
  /// clear cached state related to font rendering.
  void clearFontCache() {
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
  }

  /// Paints the cursor based on the current cursor type.
  void paintCursor(
    Canvas canvas,
    Offset offset, {
    required TerminalCursorType cursorType,
    bool hasFocus = true,
  }) {
    final paint = Paint()
      ..color = _theme.cursor
      ..strokeWidth = 1;

    if (!hasFocus) {
      paint.style = PaintingStyle.stroke;
      canvas.drawRect(offset & _cellSize, paint);
      return;
    }

    switch (cursorType) {
      case TerminalCursorType.block:
        paint.style = PaintingStyle.fill;
        canvas.drawRect(offset & _cellSize, paint);
        return;
      case TerminalCursorType.underline:
        return canvas.drawLine(
          Offset(offset.dx, _cellSize.height - 1),
          Offset(offset.dx + _cellSize.width, _cellSize.height - 1),
          paint,
        );
      case TerminalCursorType.verticalBar:
        return canvas.drawLine(
          Offset(offset.dx, 0),
          Offset(offset.dx, _cellSize.height),
          paint,
        );
    }
  }

  @pragma('vm:prefer-inline')
  void paintHighlight(Canvas canvas, Offset offset, int length, Color color) {
    final endOffset =
        offset.translate(length * _cellSize.width, _cellSize.height);

    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;

    canvas.drawRect(
      Rect.fromPoints(offset, endOffset),
      paint,
    );
  }

  /// Reused across every background rect of a frame; a fresh [Paint] per cell
  /// was thousands of allocations per repaint.
  final _backgroundPaint = Paint();

  /// Paints [line] to [canvas] at [offset]. The x offset of [offset] is usually
  /// 0, and the y offset is the top of the line.
  ///
  /// Backgrounds go first, in one pass that merges neighbouring cells sharing a
  /// colour into a single rect — a filled TUI panel used to cost one
  /// [Canvas.drawRect] per character cell. Glyphs follow in a second pass, so a
  /// merged rect can never land on top of an already-drawn character.
  void paintLine(
    Canvas canvas,
    Offset offset,
    BufferLine line,
  ) {
    final cellData = CellData.empty();
    final cellWidth = _cellSize.width;
    final length = line.length;

    Color? runColor;
    var runStart = 0;
    var runCells = 0;

    void flushRun() {
      final color = runColor;
      if (color == null || runCells == 0) return;
      _backgroundPaint.color = color;
      canvas.drawRect(
        offset.translate(runStart * cellWidth, 0) &
            Size(runCells * cellWidth + 1, _cellSize.height),
        _backgroundPaint,
      );
    }

    for (var i = 0; i < length; i++) {
      line.getCellData(i, cellData);
      final width = cellData.content >> CellContent.widthShift == 2 ? 2 : 1;
      final color = _backgroundColorOf(cellData);

      if (color == runColor) {
        runCells += width;
      } else {
        flushRun();
        runColor = color;
        runStart = i;
        runCells = width;
      }

      if (width == 2) i++;
    }
    flushRun();

    // Group consecutive foreground cells that share the same style
    final runText = StringBuffer();
    var fRunStart = 0;
    var runForeground = 0;
    var runBackground = 0;
    var runFlags = 0;
    var hasRun = false;

    void flushForegroundRun() {
      if (!hasRun) return;
      
      final text = runText.toString();
      if (text.isNotEmpty) {
        paintRunForeground(
          canvas,
          offset.translate(fRunStart * cellWidth, 0),
          runForeground,
          runBackground,
          runFlags,
          text,
        );
      }
      runText.clear();
      hasRun = false;
    }

    for (var i = 0; i < length; i++) {
      line.getCellData(i, cellData);
      final charCode = cellData.content & CellContent.codepointMask;
      final width = cellData.content >> CellContent.widthShift == 2 ? 2 : 1;

      if (charCode == 0) {
        flushForegroundRun();
        if (width == 2) i++;
        continue;
      }

      if (hasRun &&
          cellData.foreground == runForeground &&
          cellData.background == runBackground &&
          cellData.flags == runFlags) {
        var char = String.fromCharCode(charCode);
        if (runFlags & CellFlags.underline != 0 && charCode == 0x20) {
          char = String.fromCharCode(0xA0);
        }
        runText.write(char);
      } else {
        flushForegroundRun();
        runForeground = cellData.foreground;
        runBackground = cellData.background;
        runFlags = cellData.flags;
        fRunStart = i;
        hasRun = true;
        
        var char = String.fromCharCode(charCode);
        if (runFlags & CellFlags.underline != 0 && charCode == 0x20) {
          char = String.fromCharCode(0xA0);
        }
        runText.write(char);
      }

      if (width == 2) i++;
    }
    flushForegroundRun();
  }

  /// Paints a run of text sharing the same style properties (foreground, background, flags).
  void paintRunForeground(
    Canvas canvas,
    Offset offset,
    int foreground,
    int background,
    int flags,
    String text,
  ) {
    if (text.isEmpty) return;

    // Use a hash of the text and style to cache the run's Paragraph
    final styleHash = Object.hash(foreground, background, flags, text);
    final cacheKey = styleHash ^ _textScaler.hashCode;
    var paragraph = _paragraphCache.getLayoutFromCache(cacheKey);

    if (paragraph == null) {
      var color = flags & CellFlags.inverse == 0
          ? resolveForegroundColor(foreground)
          : resolveBackgroundColor(background);

      if (flags & CellFlags.faint != 0) {
        color = color.withOpacity(0.5);
      }

      final style = _textStyle.toTextStyle(
        color: color,
        bold: flags & CellFlags.bold != 0,
        italic: flags & CellFlags.italic != 0,
        underline: flags & CellFlags.underline != 0,
      );

      paragraph = _paragraphCache.performAndCacheLayout(
        text,
        style,
        _textScaler,
        cacheKey,
      );
    }

    canvas.drawParagraph(paragraph, offset);
  }

  /// The colour this cell's background should be filled with, or null when
  /// nothing has to be drawn (the default background shows through).
  @pragma('vm:prefer-inline')
  Color? _backgroundColorOf(CellData cellData) {
    if (cellData.flags & CellFlags.inverse != 0) {
      return resolveForegroundColor(cellData.foreground);
    }
    if (cellData.background & CellColor.typeMask == CellColor.normal) {
      return null;
    }
    return resolveBackgroundColor(cellData.background);
  }

  @pragma('vm:prefer-inline')
  void paintCell(Canvas canvas, Offset offset, CellData cellData) {
    paintCellBackground(canvas, offset, cellData);
    paintCellForeground(canvas, offset, cellData);
  }

  /// Paints the character in the cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellForeground(Canvas canvas, Offset offset, CellData cellData) {
    final charCode = cellData.content & CellContent.codepointMask;
    if (charCode == 0) return;

    final cacheKey = cellData.getHash() ^ _textScaler.hashCode;
    var paragraph = _paragraphCache.getLayoutFromCache(cacheKey);

    if (paragraph == null) {
      final cellFlags = cellData.flags;

      var color = cellFlags & CellFlags.inverse == 0
          ? resolveForegroundColor(cellData.foreground)
          : resolveBackgroundColor(cellData.background);

      if (cellData.flags & CellFlags.faint != 0) {
        color = color.withOpacity(0.5);
      }

      final style = _textStyle.toTextStyle(
        color: color,
        bold: cellFlags & CellFlags.bold != 0,
        italic: cellFlags & CellFlags.italic != 0,
        underline: cellFlags & CellFlags.underline != 0,
      );

      // Flutter does not draw an underline below a space which is not between
      // other regular characters. As only single characters are drawn, this
      // will never produce an underline below a space in the terminal. As a
      // workaround the regular space CodePoint 0x20 is replaced with
      // the CodePoint 0xA0. This is a non breaking space and a underline can be
      // drawn below it.
      var char = String.fromCharCode(charCode);
      if (cellFlags & CellFlags.underline != 0 && charCode == 0x20) {
        char = String.fromCharCode(0xA0);
      }

      paragraph = _paragraphCache.performAndCacheLayout(
        char,
        style,
        _textScaler,
        cacheKey,
      );
    }

    canvas.drawParagraph(paragraph, offset);
  }

  /// Paints the background of a cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellBackground(Canvas canvas, Offset offset, CellData cellData) {
    final color = _backgroundColorOf(cellData);
    if (color == null) return;

    final paint = _backgroundPaint..color = color;
    final doubleWidth = cellData.content >> CellContent.widthShift == 2;
    final widthScale = doubleWidth ? 2 : 1;
    final size = Size(_cellSize.width * widthScale + 1, _cellSize.height);
    canvas.drawRect(offset & size, paint);
  }

  /// Get the effective foreground color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveForegroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.foreground;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }

  /// Get the effective background color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveBackgroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.background;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }
}
