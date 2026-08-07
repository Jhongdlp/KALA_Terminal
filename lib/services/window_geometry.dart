import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// Whether this build runs on a platform with a resizable OS window.
///
/// Used only to decide whether to talk to `window_manager` at all — layout
/// decisions are made from the *width*, never from the platform, so a narrow
/// desktop window still gets the touch layout. See `theme/breakpoints.dart`.
bool get isDesktopPlatform =>
    !kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS);

/// Saves and restores the desktop window box across launches.
///
/// Writes are debounced: `window_manager` reports a resize per frame while the
/// user drags a window edge, and every one of those would otherwise be a
/// `shared_preferences` disk write.
class WindowGeometry with WindowListener {
  WindowGeometry._({
    required this.size,
    required this.position,
    required this.maximized,
  });

  // Not `settings_*` (user settings) nor a bare data key (`ssh_profiles`,
  // `known_hosts`): window geometry is neither, so it gets its own prefix.
  static const String _kWidth = 'window_width';
  static const String _kHeight = 'window_height';
  static const String _kX = 'window_x';
  static const String _kY = 'window_y';
  static const String _kMaximized = 'window_maximized';

  /// Matches the GTK default in `linux/runner/my_application.cc`, so a first
  /// launch doesn't resize the window after it appears.
  static const Size defaultSize = Size(1280, 720);

  /// Deliberately **below** the desktop breakpoint (900): the touch layout has
  /// to stay reachable on a desktop, which is the whole point of sizing by
  /// width rather than by platform — and it makes the breakpoint testable by
  /// dragging the window.
  static const Size minimumSize = Size(420, 560);

  final Size size;
  final Offset? position;
  final bool maximized;

  Timer? _debounce;

  static Future<WindowGeometry> load() async {
    final prefs = await SharedPreferences.getInstance();
    final width = prefs.getDouble(_kWidth);
    final height = prefs.getDouble(_kHeight);
    final x = prefs.getDouble(_kX);
    final y = prefs.getDouble(_kY);

    return WindowGeometry._(
      // Clamp to the floor: a stored size from before the minimum existed (or
      // from a different monitor) must not open an unusable window.
      size: width == null || height == null
          ? defaultSize
          : Size(
              width.clamp(minimumSize.width, double.infinity),
              height.clamp(minimumSize.height, double.infinity),
            ),
      position: x == null || y == null ? null : Offset(x, y),
      maximized: prefs.getBool(_kMaximized) ?? false,
    );
  }

  /// Start tracking window changes. Call once, after the window is shown.
  void attach() => windowManager.addListener(this);

  @override
  void onWindowResized() => _schedulePersist();

  @override
  void onWindowMoved() => _schedulePersist();

  @override
  void onWindowMaximize() => _schedulePersist();

  @override
  void onWindowUnmaximize() => _schedulePersist();

  void _schedulePersist() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _persist);
  }

  Future<void> _persist() async {
    final maximized = await windowManager.isMaximized();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kMaximized, maximized);

    // While maximized the reported box is the screen, not the size to restore
    // to — keep the last normal geometry so unmaximizing on the next launch
    // gives back the window the user actually sized.
    if (maximized) return;

    final bounds = await windowManager.getBounds();
    await prefs.setDouble(_kWidth, bounds.width);
    await prefs.setDouble(_kHeight, bounds.height);
    await prefs.setDouble(_kX, bounds.left);
    await prefs.setDouble(_kY, bounds.top);
  }
}
