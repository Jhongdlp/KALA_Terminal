import 'dart:collection';
import 'dart:ui';

import 'package:flutter/widgets.dart';

/// A cache of laid out [Paragraph]s. This is used to avoid laying out the same
/// text multiple times, which is expensive.
class ParagraphCache {
  ParagraphCache(this.maximumSize);

  final int maximumSize;
  final LinkedHashMap<int, Paragraph> _cache = LinkedHashMap<int, Paragraph>();

  /// Returns a [Paragraph] for the given [key]. [key] is the same as the
  /// key argument to [performAndCacheLayout].
  Paragraph? getLayoutFromCache(int key) {
    final paragraph = _cache.remove(key);
    if (paragraph != null) {
      _cache[key] = paragraph; // Move to end (MRU)
    }
    return paragraph;
  }

  /// Applies [style] and [textScaler] to [text] and lays it out to create
  /// a [Paragraph]. The [Paragraph] is cached and can be retrieved with the
  /// same [key] by calling [getLayoutFromCache].
  Paragraph performAndCacheLayout(
    String text,
    TextStyle style,
    TextScaler textScaler,
    int key,
  ) {
    final builder = ParagraphBuilder(style.getParagraphStyle());
    builder.pushStyle(style.getTextStyle(textScaler: textScaler));
    builder.addText(text);

    final paragraph = builder.build();
    paragraph.layout(ParagraphConstraints(width: double.infinity));

    // If key is already in cache, remove and dispose the old one
    final oldParagraph = _cache.remove(key);
    oldParagraph?.dispose();

    if (_cache.length >= maximumSize) {
      final firstKey = _cache.keys.first;
      final evicted = _cache.remove(firstKey);
      evicted?.dispose();
    }

    _cache[key] = paragraph;
    return paragraph;
  }

  /// Clears the cache. This should be called when the same text and style
  /// pair no longer produces the same layout. For example, when a font is
  /// loaded.
  void clear() {
    for (final paragraph in _cache.values) {
      paragraph.dispose();
    }
    _cache.clear();
  }

  /// Returns the number of [Paragraph]s in the cache.
  int get length {
    return _cache.length;
  }
}
