import 'dart:io';

import 'package:flutter/services.dart';

/// Thin bridge to the native Android foreground service that keeps the app
/// process — and therefore every running PTY/SSH shell — alive while the app is
/// in the background, the way Termux does.
///
/// On any non-Android platform the methods are no-ops, so callers don't need to
/// branch on the platform themselves.
class BackgroundService {
  BackgroundService._();

  static const MethodChannel _channel =
      MethodChannel('com.antigravity.terminalagent/background');

  static bool _running = false;
  static bool get isRunning => _running;

  /// Starts the persistent foreground service + notification. Safe to call
  /// repeatedly; the native side just refreshes the notification.
  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('startBackgroundService');
      _running = true;
    } on PlatformException {
      // Service couldn't start (e.g. notifications blocked). The app keeps
      // working; it just won't survive aggressive background kills.
    }
  }

  /// Stops the service and fully closes the app (mirrors the notification's
  /// "Salir" action).
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stopBackgroundService');
      _running = false;
    } on PlatformException {
      // Ignore — nothing actionable.
    }
  }
}
