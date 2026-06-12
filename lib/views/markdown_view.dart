import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import '../theme/app_theme.dart';

/// Renders markdown [data] as a formatted, scrollable document styled with the
/// app's Swiss palette. [scale] is the zoom multiplier driven by the +/-
/// buttons in the editor's preview header (1.0 == base size).
class MarkdownView extends StatelessWidget {
  final String data;
  final double scale;

  const MarkdownView({super.key, required this.data, required this.scale});

  @override
  Widget build(BuildContext context) {
    final base = 15.0 * scale;

    final sheet = MarkdownStyleSheet(
      p: AppText.body(base, color: AppColors.bone, weight: FontWeight.w400),
      pPadding: EdgeInsets.only(bottom: 6 * scale),
      a: AppText.body(base, color: AppColors.bone)
          .copyWith(decoration: TextDecoration.underline),
      h1: AppText.body(base * 1.9, color: AppColors.bone, weight: FontWeight.w800),
      h1Padding: EdgeInsets.only(top: 16 * scale, bottom: 6 * scale),
      h2: AppText.body(base * 1.55, color: AppColors.bone, weight: FontWeight.w800),
      h2Padding: EdgeInsets.only(top: 14 * scale, bottom: 6 * scale),
      h3: AppText.body(base * 1.3, color: AppColors.bone, weight: FontWeight.w700),
      h4: AppText.body(base * 1.12, color: AppColors.bone, weight: FontWeight.w700),
      h5: AppText.body(base, color: AppColors.bone, weight: FontWeight.w700),
      h6: AppText.label(base * 0.85, color: AppColors.muted, spacing: 1.0),
      em: AppText.body(base, color: AppColors.bone)
          .copyWith(fontStyle: FontStyle.italic),
      strong: AppText.body(base, color: AppColors.bone, weight: FontWeight.w800),
      code: AppText.mono(base * 0.88, color: AppColors.bone).copyWith(
        backgroundColor: AppColors.panelHi,
      ),
      codeblockPadding: EdgeInsets.all(12 * scale),
      codeblockDecoration: BoxDecoration(
        color: AppColors.panelHi,
        border: Border.all(color: AppColors.hairline, width: 1),
      ),
      blockquote: AppText.body(base, color: AppColors.muted),
      blockquotePadding: EdgeInsets.fromLTRB(14 * scale, 8 * scale, 12, 8 * scale),
      blockquoteDecoration: BoxDecoration(
        color: AppColors.panel,
        border: Border(left: BorderSide(color: AppColors.faint, width: 3)),
      ),
      listBullet: AppText.body(base, color: AppColors.bone),
      listIndent: 22 * scale,
      blockSpacing: 10 * scale,
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.hairline, width: 1)),
      ),
      tableHead: AppText.body(base, color: AppColors.bone, weight: FontWeight.w800),
      tableBody: AppText.body(base, color: AppColors.bone, weight: FontWeight.w400),
      tableBorder: TableBorder.all(color: AppColors.hairline, width: 1),
      tableCellsPadding: EdgeInsets.symmetric(horizontal: 10 * scale, vertical: 6 * scale),
    );

    return Markdown(
      data: data,
      selectable: true,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 48),
      styleSheet: sheet,
    );
  }
}
