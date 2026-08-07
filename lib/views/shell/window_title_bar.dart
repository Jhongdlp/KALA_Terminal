import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../../l10n/l10n.dart';
import '../../providers/app_state.dart';
import '../../theme/app_theme.dart';

/// The app's own window title bar, replacing the GTK one on desktop.
///
/// The native header bar is hidden before the window is first shown (see
/// `main.dart`), but the window stays `decorated`, so the WM still provides
/// resize borders and the drop shadow — this only replaces the visible chrome.
///
/// It carries the active SSH session rather than just the app name: on a client
/// whose whole job is being connected somewhere, the title is the natural place
/// to see *where* without reading the prompt.
class WindowTitleBar extends StatefulWidget {
  const WindowTitleBar({super.key});

  /// Matches the compact shell's nav strip rhythm while staying clearly
  /// subordinate to it.
  static const double height = 32;

  @override
  State<WindowTitleBar> createState() => _WindowTitleBarState();
}

class _WindowTitleBarState extends State<WindowTitleBar> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _syncMaximized();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  Future<void> _syncMaximized() async {
    final maximized = await windowManager.isMaximized();
    if (mounted) setState(() => _maximized = maximized);
  }

  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Widget build(BuildContext context) {
    // context.select, not watch: the terminal notifies on every chunk of output
    // and this bar must not rebuild with it. These only fire when the text or
    // the connection state actually changes.
    final label = context.select<AppState, String>((state) {
      final profile = state.activeSession?.activeProfile;
      if (profile == null) return 'KAMMEL SSH';
      return 'KAMMEL — ${profile.username}@${profile.host}';
    });
    final hasSession =
        context.select<AppState, bool>((state) => state.activeSession != null);
    final connected = context.select<AppState, bool>(
        (state) => state.connectionStatus == ConnectionStatus.remote);

    // Material ancestor, required rather than decorative: this bar is mounted
    // above the navigator, where there is none, and unparented Text falls back
    // to the debug style — yellow-underlined on black.
    return Material(
      color: AppColors.ink,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: AppColors.hairline, width: 1),
          ),
        ),
        child: SizedBox(
          height: WindowTitleBar.height,
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  // Hands the drag to the window manager, so the window follows
                  // the pointer natively instead of us chasing it frame by frame.
                  onPanStart: (_) => windowManager.startDragging(),
                  onDoubleTap: _toggleMaximize,
                  // Right-click gives back the WM's own window menu, which the
                  // hidden native bar would otherwise have taken away.
                  onSecondaryTap: windowManager.popUpWindowMenu,
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                    children: [
                      const SizedBox(width: 10),
                      Image.asset(
                        'assets/images/kammel_logo.png',
                        width: 13,
                        height: 13,
                        color: AppColors.accent,
                      ),
                      const SizedBox(width: 9),
                      Flexible(
                        child: Text(
                          label,
                          style: AppText.mono(9.5,
                              color: AppColors.muted, spacing: 1.0),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (hasSession) ...[
                        const SizedBox(width: 8),
                        Container(
                          width: 6,
                          height: 6,
                          color: connected ? AppColors.accent : AppColors.faint,
                        ),
                      ],
                      const SizedBox(width: 12),
                    ],
                  ),
                ),
              ),
              _WindowButton(
                icon: Icons.remove,
                label: tr('Minimizar'),
                onPressed: windowManager.minimize,
              ),
              _WindowButton(
                icon: _maximized ? Icons.filter_none : Icons.crop_square,
                // A restore glyph at the same optical weight as the others
                // needs to be a touch smaller.
                iconSize: _maximized ? 11 : 13,
                label: _maximized ? tr('Restaurar') : tr('Maximizar'),
                onPressed: _toggleMaximize,
              ),
              _WindowButton(
                icon: Icons.close,
                label: tr('Cerrar'),
                danger: true,
                onPressed: windowManager.close,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A square window-control button: no radius, no ripple, a flat hover fill.
class _WindowButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final double iconSize;

  /// Close: fills with the danger colour on hover, the one place in the app
  /// where a control shouts before it is pressed.
  final bool danger;

  const _WindowButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.iconSize = 13,
    this.danger = false,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final background = !_hovering
        ? Colors.transparent
        : widget.danger
            ? AppColors.danger
            : AppColors.bone.withValues(alpha: 0.10);
    final foreground = _hovering && widget.danger
        ? AppColors.bone
        : _hovering
            ? AppColors.bone
            : AppColors.muted;

    // Semantics rather than Tooltip: this bar is mounted above the navigator
    // (so it stays over dialogs), which means there is no Overlay ancestor for
    // a tooltip to render into. Window controls are the most universally read
    // glyphs there are, and the hover fill already confirms the target.
    return Semantics(
      label: widget.label,
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 44,
            height: WindowTitleBar.height,
            color: background,
            child: Icon(widget.icon, size: widget.iconSize, color: foreground),
          ),
        ),
      ),
    );
  }
}
