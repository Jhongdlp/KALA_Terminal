import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class SwissGaugeChart extends StatelessWidget {
  final double value; // 0.0 to 1.0 (or greater for CPU load representation)
  final String label; // e.g. "CARGA CPU"
  final String valueText; // e.g. "1.24" or "78%"
  final String detailsText; // e.g. "DE 8.0 GB" or "4 CORES"
  final Color color;
  final bool animate;

  const SwissGaugeChart({
    super.key,
    required this.value,
    required this.label,
    required this.valueText,
    required this.detailsText,
    required this.color,
    this.animate = true,
  });

  @override
  Widget build(BuildContext context) {
    // Clamp progress value between 0.0 and 1.0 for rendering the arc
    final targetValue = value.clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            label.toUpperCase(),
            style: AppText.label(9, color: AppColors.muted, spacing: 1.2),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
          AspectRatio(
            aspectRatio: 1.0,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = math.min(constraints.maxWidth, constraints.maxHeight);
                return Center(
                  child: SizedBox(
                    width: size,
                    height: size,
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0.0, end: targetValue),
                      duration: Duration(milliseconds: animate ? 800 : 0),
                      curve: Curves.easeOutCubic,
                      builder: (context, animValue, child) {
                        return CustomPaint(
                          painter: _GaugePainter(
                            value: animValue,
                            color: color,
                          ),
                          child: Center(
                            child: Padding(
                              padding: EdgeInsets.all(size * 0.15),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      valueText,
                                      style: AppText.mono(
                                        size > 80 ? 13 : 11,
                                        color: AppColors.bone,
                                        weight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  if (detailsText.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(
                                        detailsText.toUpperCase(),
                                        style: AppText.mono(
                                          size > 80 ? 8 : 7,
                                          color: AppColors.muted,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double value;
  final Color color;

  _GaugePainter({
    required this.value,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    // Leave some margin for ticks on the outside of the track
    final outerMargin = 6.0;
    final radius = (size.width / 2) - outerMargin;
    final strokeWidth = size.width * 0.08;

    // 1. Draw solid inner panel background fill
    final fillPaint = Paint()
      ..color = AppColors.panelHi.withOpacity(0.4)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius - strokeWidth, fillPaint);

    // 2. Draw background track (a subtle hairline or darker path)
    final trackPaint = Paint()
      ..color = AppColors.hairline
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.butt;
    canvas.drawCircle(center, radius - strokeWidth / 2, trackPaint);

    // 3. Draw active arc
    final activePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.butt;

    final startAngle = -math.pi / 2;
    final sweepAngle = 2 * math.pi * value;

    if (sweepAngle > 0.001) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius - strokeWidth / 2),
        startAngle,
        sweepAngle,
        false,
        activePaint,
      );
    }

    // 4. Draw neat technical ticks on the outer rim
    final tickPaint = Paint()
      ..strokeWidth = 1.0;

    final tickCount = 20;
    for (int i = 0; i < tickCount; i++) {
      final angle = (i * 2 * math.pi) / tickCount + startAngle;
      final isAccentTick = (i % 5 == 0); // Bold tick every 90 degrees
      final tickLength = isAccentTick ? 4.0 : 2.5;

      final startPos = Offset(
        center.dx + (radius + 1) * math.cos(angle),
        center.dy + (radius + 1) * math.sin(angle),
      );
      final endPos = Offset(
        center.dx + (radius + 1 + tickLength) * math.cos(angle),
        center.dy + (radius + 1 + tickLength) * math.sin(angle),
      );

      // Color the tick if it falls within the active range
      final tickPercent = i / tickCount;
      if (tickPercent <= value && value > 0.001) {
        tickPaint.color = color.withOpacity(0.9);
        tickPaint.strokeWidth = 1.2;
      } else {
        tickPaint.color = AppColors.faint.withOpacity(0.4);
        tickPaint.strokeWidth = 0.8;
      }
      canvas.drawLine(startPos, endPos, tickPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _GaugePainter oldDelegate) {
    return oldDelegate.value != value || oldDelegate.color != color;
  }
}
