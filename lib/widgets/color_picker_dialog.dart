import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../l10n/l10n.dart';

/// Self-contained HSV color picker (saturation/value field + hue bar + hex
/// input). Returns the chosen color as `#RRGGBB`, or null when cancelled.
class ColorPickerDialog extends StatefulWidget {
  final Color initialColor;

  const ColorPickerDialog({super.key, required this.initialColor});

  static Future<String?> show(BuildContext context, {Color? initialColor}) {
    return showDialog<String>(
      context: context,
      builder: (_) => ColorPickerDialog(
        initialColor: initialColor ?? AppColors.accent,
      ),
    );
  }

  @override
  State<ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<ColorPickerDialog> {
  late HSVColor _hsv;
  late TextEditingController _hexController;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initialColor);
    _hexController = TextEditingController(
        text: AppColors.toHex(widget.initialColor).substring(1));
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  Color get _color => _hsv.toColor();

  void _setHsv(HSVColor value) {
    setState(() {
      _hsv = value;
      _syncHexField(value.toColor());
    });
  }

  /// Keeps the hex field in sync without stealing the caret while the user
  /// types (rewriting an identical value would send it back to position 0).
  void _syncHexField(Color color) {
    final text = AppColors.toHex(color).substring(1);
    if (_hexController.text.toUpperCase() == text) return;
    _hexController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _onHexSubmitted(String raw) {
    final parsed = AppColors.parseHex(raw);
    if (parsed == null) return;
    setState(() => _hsv = HSVColor.fromColor(parsed));
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.panel,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: AppColors.hairline),
        borderRadius: BorderRadius.zero,
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
              child: Text(tr('COLOR PERSONALIZADO'),
                  style: AppText.label(10, color: AppColors.bone)),
            ),
            Container(height: 1, color: AppColors.hairline),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
              child: _SaturationValueField(hsv: _hsv, onChanged: _setHsv),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
              child: _HueBar(
                hue: _hsv.hue,
                onChanged: (h) => _setHsv(_hsv.withHue(h)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: _color,
                      border: Border.all(color: AppColors.hairline),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _hexController,
                      style: AppText.mono(13, color: AppColors.bone),
                      textCapitalization: TextCapitalization.characters,
                      inputFormatters: [
                        LengthLimitingTextInputFormatter(6),
                        FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9a-fA-F]')),
                      ],
                      decoration: InputDecoration(
                        isDense: true,
                        prefixText: '#  ',
                        prefixStyle: AppText.mono(13, color: AppColors.muted),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 10),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.zero,
                          borderSide: BorderSide(color: AppColors.hairline),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.zero,
                          borderSide: BorderSide(color: AppColors.bone),
                        ),
                      ),
                      onChanged: (v) {
                        if (v.length == 6 || v.length == 3) _onHexSubmitted(v);
                      },
                      onSubmitted: _onHexSubmitted,
                    ),
                  ),
                ],
              ),
            ),
            Container(height: 1, color: AppColors.hairline),
            Row(
              children: [
                Expanded(
                  child: _DialogButton(
                    label: tr('CANCELAR'),
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ),
                Container(width: 1, height: 44, color: AppColors.hairline),
                Expanded(
                  child: _DialogButton(
                    label: tr('GUARDAR'),
                    filled: true,
                    onTap: () =>
                        Navigator.of(context).pop(AppColors.toHex(_color)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DialogButton extends StatelessWidget {
  final String label;
  final bool filled;
  final VoidCallback onTap;

  const _DialogButton({
    required this.label,
    required this.onTap,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: filled ? AppColors.bone : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 44,
          child: Center(
            child: Text(
              label,
              style: AppText.label(9,
                  color: filled ? AppColors.ink : AppColors.bone,
                  weight: filled ? FontWeight.w800 : FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }
}

/// Square gradient field: horizontal = saturation, vertical = value.
class _SaturationValueField extends StatelessWidget {
  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  const _SaturationValueField({required this.hsv, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, 170);

        void handle(Offset local) {
          final s = (local.dx / size.width).clamp(0.0, 1.0);
          final v = 1 - (local.dy / size.height).clamp(0.0, 1.0);
          onChanged(hsv.withSaturation(s).withValue(v));
        }

        return GestureDetector(
          onPanDown: (d) => handle(d.localPosition),
          onPanUpdate: (d) => handle(d.localPosition),
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.hairline),
                      gradient: LinearGradient(
                        colors: [
                          Colors.white,
                          HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor(),
                        ],
                      ),
                    ),
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: hsv.saturation * size.width - 8,
                  top: (1 - hsv.value) * size.height - 8,
                  child: _Thumb(color: hsv.toColor()),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _HueBar extends StatelessWidget {
  final double hue;
  final ValueChanged<double> onChanged;

  const _HueBar({required this.hue, required this.onChanged});

  static const List<Color> _hueColors = [
    Color(0xFFFF0000),
    Color(0xFFFFFF00),
    Color(0xFF00FF00),
    Color(0xFF00FFFF),
    Color(0xFF0000FF),
    Color(0xFFFF00FF),
    Color(0xFFFF0000),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;

        void handle(Offset local) =>
            onChanged(((local.dx / width).clamp(0.0, 1.0)) * 360);

        return GestureDetector(
          onPanDown: (d) => handle(d.localPosition),
          onPanUpdate: (d) => handle(d.localPosition),
          child: SizedBox(
            width: width,
            height: 24,
            child: Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.hairline),
                      gradient: const LinearGradient(colors: _hueColors),
                    ),
                  ),
                ),
                Positioned(
                  left: (hue / 360) * width - 8,
                  top: 4,
                  child: _Thumb(
                    color: HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Thumb extends StatelessWidget {
  final Color color;
  const _Thumb({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 3),
        ],
      ),
    );
  }
}
