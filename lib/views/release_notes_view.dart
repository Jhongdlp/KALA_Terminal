import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Renders a GitHub release body.
///
/// The body is markdown, and it used to be dumped into an 11px muted monospace
/// box exactly as written — so a perfectly good release note reached the user
/// as a wall of literal `##`, `-` and `**`. This is not a markdown engine; it
/// is the four constructs a release note actually uses:
///
/// - `#`/`##`/`###` headings, which are what group the changes;
/// - `-`/`*`/`+` bullets, which are the changes;
/// - `**bold**` and `` `code` `` inline;
/// - blank lines as spacing.
///
/// Anything else falls through as plain text, which is the correct failure:
/// an unrecognised construct still shows its words.
class ReleaseNotesView extends StatelessWidget {
  final String markdown;

  const ReleaseNotesView(this.markdown, {super.key});

  @override
  Widget build(BuildContext context) {
    final blocks = <Widget>[];

    for (final raw in markdown.split('\n')) {
      final line = raw.trimRight();
      final trimmed = line.trim();

      if (trimmed.isEmpty) {
        if (blocks.isNotEmpty) blocks.add(const SizedBox(height: 8));
        continue;
      }

      final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(trimmed);
      if (heading != null) {
        if (blocks.isNotEmpty) blocks.add(const SizedBox(height: 10));
        blocks.add(Text(
          _stripInline(heading.group(2)!).toUpperCase(),
          style: AppText.label(10, color: AppColors.bone, spacing: 1.4),
        ));
        blocks.add(const SizedBox(height: 6));
        continue;
      }

      final bullet = RegExp(r'^[-*+]\s+(.*)$').firstMatch(trimmed);
      if (bullet != null) {
        blocks.add(Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 8),
                child:
                    Container(width: 3, height: 3, color: AppColors.muted),
              ),
              Expanded(child: _inline(bullet.group(1)!, AppColors.bone)),
            ],
          ),
        ));
        continue;
      }

      blocks.add(Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: _inline(trimmed, AppColors.muted),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: blocks,
    );
  }

  /// `**bold**` and `` `code` `` as real spans. Anything unmatched keeps its
  /// literal characters rather than disappearing.
  Widget _inline(String text, Color color) {
    final spans = <TextSpan>[];
    final pattern = RegExp(r'\*\*(.+?)\*\*|`(.+?)`');
    var index = 0;

    for (final m in pattern.allMatches(text)) {
      if (m.start > index) {
        spans.add(TextSpan(text: text.substring(index, m.start)));
      }
      if (m.group(1) != null) {
        spans.add(TextSpan(
          text: m.group(1),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ));
      } else {
        spans.add(TextSpan(
          text: m.group(2),
          style: AppText.mono(11, color: AppColors.accent),
        ));
      }
      index = m.end;
    }
    if (index < text.length) spans.add(TextSpan(text: text.substring(index)));

    return RichText(
      text: TextSpan(style: AppText.body(12, color: color), children: spans),
    );
  }

  /// Headings are drawn in a single style, so inline markers are only noise
  /// there. replaceAllMapped, not replaceAll: a String replacement in Dart has
  /// no group substitution and would leave a literal `$1` on screen.
  String _stripInline(String text) => text
      .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m.group(1)!)
      .replaceAll('`', '')
      .replaceAll('*', '');
}
