import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../models/terminal_key_layer.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import 'shortcut_manager_sheet.dart';

/// The terminal's quick-access keyboard.
///
/// The design constraint that shapes everything here: **nothing scrolls
/// horizontally**. The previous bar hid its overflow in two side-scrolling
/// rows — no affordance said there was more, and the drag competed with the
/// terminal's own gestures. Instead the keys are split into named layers
/// (CTRL / NAV / FN / ACCIONES / MIS), only one of which is on screen, and the
/// grid's **columns are derived from the row count** so every key of the
/// visible layer always fits the width exactly.
///
/// Three tiers, top to bottom:
///  1. the fixed row — ESC/TAB/CTRL/`^C` (+ arrows, or SHIFT/`^D`), never
///     changes, so muscle memory holds across layer switches;
///  2. the layer grid — swipeable, equal-width cells;
///  3. the tab strip — always visible, so the user can *see* where they are
///     and what else exists, which a dot indicator or a modal "next layer"
///     key cannot do.
class TerminalQuickKeys extends StatefulWidget {
  final AppState state;

  /// Sends raw bytes to the PTY (the host resets the IME first).
  final void Function(String data) onSend;

  /// Handles a named action key: `attach`, `prompts`, `commit`, `links`.
  final void Function(String action) onAction;

  /// Drawn above the keys while a file is uploading.
  final Widget? banner;

  const TerminalQuickKeys({
    super.key,
    required this.state,
    required this.onSend,
    required this.onAction,
    this.banner,
  });

  @override
  State<TerminalQuickKeys> createState() => _TerminalQuickKeysState();
}

class _TerminalQuickKeysState extends State<TerminalQuickKeys> {
  late PageController _pages;

  /// Mirrors the controller's page so an external layer change (a tab tap,
  /// the manager sheet hiding a layer) can be told apart from a swipe.
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _page = widget.state.shortcutLayerIndex;
    _pages = PageController(initialPage: _page);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /// Keys of one layer, resolved against the user's own shortcuts.
  List<QuickKey> _keysOf(QuickKeyLayer layer) {
    switch (layer) {
      case QuickKeyLayer.control:
        return kControlKeys;
      case QuickKeyLayer.nav:
        // The arrows are only folded in when neither the fixed row nor the
        // side d-pad is already drawing them — otherwise NAV would spend four
        // of its cells on duplicates and shrink the rest for nothing.
        return widget.state.shortcutLayout == TerminalShortcutLayout.classic
            ? const [...kArrowKeys, ...kNavKeys]
            : kNavKeys;
      case QuickKeyLayer.fn:
        return kFnKeys;
      case QuickKeyLayer.actions:
        return widget.state.actionShortcuts.map((s) {
          final action = s.value.substring('system:'.length);
          return QuickKey(s.label,
              action: action, icon: kSystemActionIcons[action]);
        }).toList();
      case QuickKeyLayer.mine:
        return widget.state.myShortcuts
            .map((s) => QuickKey(s.label, data: s.parsedValue))
            .toList();
    }
  }

  /// Columns for the whole bar, derived from the row count rather than from
  /// the available width. That inversion is the point: with `rows` fixed by
  /// the user, `ceil(keys / rows)` columns is the narrowest grid that shows
  /// every key of the fullest layer — so nothing ever needs to be scrolled to.
  ///
  /// The built-in layers always get the columns they need — that is the
  /// guarantee. MIS is the one layer the user can grow without limit, so it
  /// may widen the grid up to [_kMineColumnCap] and then scrolls vertically
  /// rather than shrinking every other layer along with it.
  int _columns(List<QuickKeyLayer> layers) {
    final rows = widget.state.shortcutRows;
    var widest = 0;
    for (final layer in layers) {
      final need = (_keysOf(layer).length / rows).ceil();
      widest = math.max(
          widest, layer == QuickKeyLayer.mine ? math.min(need, _kMineColumnCap) : need);
    }
    return widest.clamp(4, 12);
  }

  void _send(QuickKey key) {
    HapticFeedback.selectionClick();
    if (key.action != null) {
      switch (key.action) {
        case 'ctrl':
          widget.state.toggleCtrl();
          return;
        case 'shift':
          widget.state.toggleShift();
          return;
        case 'settings':
          ShortcutManagerSheet.show(context, widget.state);
          return;
        default:
          widget.onAction(key.action!);
          return;
      }
    }
    if (key.data != null) widget.onSend(key.data!);
  }

  bool _isArmed(QuickKey key) {
    if (key.action == 'ctrl') return widget.state.ctrlArmed;
    if (key.action == 'shift') return widget.state.shiftArmed;
    return false;
  }

  void _goToLayer(int index) {
    if (index == widget.state.shortcutLayerIndex) return;
    HapticFeedback.selectionClick();
    widget.state.setShortcutLayerIndex(index);
    if (_pages.hasClients) {
      _pages.animateToPage(index,
          duration: const Duration(milliseconds: 160), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final layers = state.shortcutLayers;
    final keyH = state.shortcutKeyHeight;
    final rows = state.shortcutRows;
    final gridH = rows * keyH + (rows - 1) * _kGap;
    final columnH = keyH + _kGap + gridH;

    // Keep the PageView in step when the layer changed from somewhere else
    // (a tab tap animates itself; this catches the manager sheet and restore).
    final active = state.shortcutLayerIndex;
    if (active != _page) {
      _page = active;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pages.hasClients && _pages.page?.round() != active) {
          _pages.jumpToPage(active);
        }
      });
    }

    final layout = state.shortcutLayout;
    final dpadLeft = layout == TerminalShortcutLayout.dpadLeft;
    final dpadRight = layout == TerminalShortcutLayout.dpadRight;
    final fixed = layout == TerminalShortcutLayout.inline
        ? kFixedKeysInline
        : kFixedKeys;

    final stack = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: fixed
              .map((k) => Expanded(child: _keyWidget(k, keyH)))
              .toList(),
        ),
        const SizedBox(height: _kGap),
        SizedBox(
          height: gridH,
          child: layers.isEmpty
              ? _emptyLayers()
              : PageView.builder(
                  controller: _pages,
                  itemCount: layers.length,
                  onPageChanged: (i) {
                    _page = i;
                    HapticFeedback.selectionClick();
                    state.setShortcutLayerIndex(i);
                  },
                  itemBuilder: (_, i) =>
                      _grid(_keysOf(layers[i]), _columns(layers), rows, keyH),
                ),
        ),
      ],
    );

    return Container(
      decoration: BoxDecoration(
        color: AppColors.ink,
        border: Border(top: BorderSide(color: AppColors.hairline, width: 1)),
      ),
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.banner != null) widget.banner!,
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (dpadLeft) ...[
                  _dpad(columnH, keyH),
                  const SizedBox(width: 6),
                  Container(width: 1, height: columnH, color: AppColors.hairline),
                  const SizedBox(width: 6),
                ],
                Expanded(child: stack),
                if (dpadRight) ...[
                  const SizedBox(width: 6),
                  Container(width: 1, height: columnH, color: AppColors.hairline),
                  const SizedBox(width: 6),
                  _dpad(columnH, keyH),
                ],
              ],
            ),
            const SizedBox(height: 5),
            _tabStrip(layers, active),
          ],
        ),
      ),
    );
  }

  static const double _kGap = 5;

  /// The tab strip's height. This is the whole price of the redesign — the
  /// ~23px that buy an always-visible map of what else the keyboard holds.
  static const double _kStripHeight = 17;

  /// How wide the user's own layer may push the grid before it starts
  /// scrolling instead. Past this, cells stop being comfortably tappable.
  static const int _kMineColumnCap = 8;

  /// One layer's grid. Cells are equal width (`Expanded`), so a partial last
  /// row left-aligns into empty slots instead of stretching its keys.
  ///
  /// A layer narrower than the bar spreads over at least 4 columns rather than
  /// the full width — 2 keys stretched across a phone screen read as buttons,
  /// not as keys, and the row would stop lining up with the fixed row above.
  Widget _grid(List<QuickKey> keys, int cols, int rows, double keyH) {
    if (keys.isEmpty) return _emptyLayer();
    final layerCols = keys.length.clamp(4, cols);
    final needed = (keys.length / layerCols).ceil();

    final grid = Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var r = 0; r < needed; r++) ...[
          if (r > 0) const SizedBox(height: _kGap),
          Row(
            children: [
              for (var c = 0; c < layerCols; c++)
                Expanded(
                  child: r * layerCols + c < keys.length
                      ? _keyWidget(keys[r * layerCols + c], keyH)
                      : const SizedBox.shrink(),
                ),
            ],
          ),
        ],
      ],
    );

    // Escape hatch, not the primary path: only a MIS layer stuffed past the
    // 8-column clamp overflows, and vertical scrolling at least stays out of
    // the terminal's horizontal gesture space.
    if (needed > rows) {
      return SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        child: grid,
      );
    }
    return Center(child: grid);
  }

  Widget _emptyLayer() => Center(
        child: TextButton(
          onPressed: () => ShortcutManagerSheet.show(context, widget.state),
          child: Text(
            tr('Sin atajos aquí — toca para añadir'),
            style: AppText.mono(10, color: AppColors.muted),
          ),
        ),
      );

  Widget _emptyLayers() => Center(
        child: TextButton(
          onPressed: () => ShortcutManagerSheet.show(context, widget.state),
          child: Text(
            tr('Todas las capas ocultas — toca para mostrarlas'),
            style: AppText.mono(10, color: AppColors.muted),
          ),
        ),
      );

  /// The layer tabs. Equal-width pills so they fill the row, plus a gear that
  /// is *always* here — the manager stays reachable even if the user hides
  /// every layer or deletes the AJUSTES shortcut.
  Widget _tabStrip(List<QuickKeyLayer> layers, int active) {
    return SizedBox(
      height: _kStripHeight,
      child: Row(
        children: [
          for (var i = 0; i < layers.length; i++)
            Expanded(
              child: _tab(layers[i], i == active, () => _goToLayer(i)),
            ),
          if (layers.isEmpty) const Spacer(),
          const SizedBox(width: 4),
          Semantics(
            button: true,
            label: tr('Personalizar atajos'),
            child: InkWell(
              onTap: () => ShortcutManagerSheet.show(context, widget.state),
              child: SizedBox(
                width: 28,
                height: _kStripHeight,
                child: Icon(Icons.settings, size: 13, color: AppColors.muted),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tab(QuickKeyLayer layer, bool active, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: active ? AppColors.bone : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: () => ShortcutManagerSheet.show(context, widget.state),
          child: Container(
            alignment: Alignment.center,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                tr(layer.label),
                style: AppText.label(
                  8.5,
                  color: active ? AppColors.ink : AppColors.muted,
                  weight: active ? FontWeight.w700 : FontWeight.w600,
                  spacing: 0.9,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The side d-pad, kept as a layout option (Personalizar → teclado rápido).
  /// It spans the full height of the fixed row + grid so the bar stays a
  /// rectangle whatever the row count.
  Widget _dpad(double totalH, double keyH) {
    final half = (totalH - _kGap) / 2;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 34,
          child: _keyWidget(kArrowKeys[0], totalH), // ←
        ),
        const SizedBox(width: 4),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 34, child: _keyWidget(kArrowKeys[1], half)), // ↑
            const SizedBox(height: _kGap),
            SizedBox(width: 34, child: _keyWidget(kArrowKeys[2], half)), // ↓
          ],
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 34,
          child: _keyWidget(kArrowKeys[3], totalH), // →
        ),
      ],
    );
  }

  Widget _keyWidget(QuickKey key, double height) {
    // The attach key turns into a progress ring while its file uploads: the
    // transfer happens *before* anything reaches the prompt, so an inert key
    // just reads as a frozen app on a slow link.
    if (key.action == 'attach' && widget.state.isAttaching) {
      return _attachProgress(height);
    }
    return _KeyButton(
      label: tr(key.label),
      icon: key.icon,
      height: height,
      highlighted: _isArmed(key) || key.accent,
      onTap: () => _send(key),
    );
  }

  Widget _attachProgress(double height) {
    final progress = widget.state.attachProgress;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Container(
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.hairline, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                value: progress,
                strokeWidth: 1.6,
                color: AppColors.bone,
                backgroundColor: AppColors.hairline,
              ),
            ),
            const SizedBox(width: 4),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  progress == null ? '···' : '${(progress * 100).round()}%',
                  style: AppText.mono(10.5,
                      color: AppColors.bone,
                      weight: FontWeight.w500,
                      spacing: 0.2),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One key cell.
///
/// The label is wrapped in a [FittedBox] rather than clipped: cells are sized
/// by the grid, and a long label like ADJUNTAR or RE PÁG has to shrink to fit
/// instead of overflowing — that is what lets the same grid hold `^A` and a
/// user-named shortcut without two different key sizes.
class _KeyButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final double height;
  final bool highlighted;
  final VoidCallback onTap;

  const _KeyButton({
    required this.label,
    required this.height,
    required this.highlighted,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final fg = highlighted ? AppColors.ink : AppColors.bone;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: highlighted ? AppColors.bone : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: height,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              border: Border.all(
                color: highlighted ? Colors.transparent : AppColors.hairline,
                width: 1,
              ),
            ),
            child: icon == null
                ? _label(fg, 10.5)
                : LayoutBuilder(builder: (_, c) => _iconKey(fg, c.maxWidth)),
          ),
        ),
      ),
    );
  }

  /// An action key keeps its wording wherever it fits — a bare paperclip is a
  /// guess, "ADJUNTAR" is not. The ACCIONES layer holds few keys, so its cells
  /// are the widest on the bar and normally take the side-by-side form; the
  /// stacked and icon-only fallbacks are for a d-pad layout or a crowded grid.
  Widget _iconKey(Color fg, double width) {
    if (width >= 62) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: fg),
          const SizedBox(width: 5),
          Flexible(child: _label(fg, 9.5)),
        ],
      );
    }
    if (height >= 32) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(height: 1),
          _label(fg, 7),
        ],
      );
    }
    // Narrow and short (the d-pad layouts): the word alone beats an icon plus
    // a word shrunk to 6px, and beats a bare icon — these are app actions, not
    // universally-known glyphs.
    if (width >= 44) return _label(fg, 9);
    return Icon(icon, size: 14, color: fg);
  }

  Widget _label(Color fg, double size) => FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 1,
          style: AppText.mono(
            size,
            color: fg,
            weight: highlighted ? FontWeight.w700 : FontWeight.w500,
            spacing: 0.2,
          ),
        ),
      );
}
