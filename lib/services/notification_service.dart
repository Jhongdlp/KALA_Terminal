import 'dart:io';

import 'package:flutter/services.dart';

/// Thin bridge to the native Android notification helper used for "agent
/// alert" notifications: when a backgrounded terminal session rings the bell
/// (BEL) or emits an OSC 9/777 notification — the way TUI agents like Claude
/// Code signal they need input — a heads-up notification is posted so the user
/// can jump back to that session.
///
/// On any non-Android platform the methods are no-ops, so callers don't need
/// to branch on the platform themselves (mirrors [BackgroundService]).
class NotificationService {
  NotificationService._();

  static const MethodChannel _channel =
      MethodChannel('com.antigravity.terminalagent/notifications');

  /// Posts (or refreshes) the alert notification for [sessionId]. Tapping it
  /// opens the app on that session (see `consumePendingSession`). [agent] is
  /// the detected agent id ('claude', 'antigravity', …) used to pick the
  /// notification's large icon badge; null/unknown falls back to a generic one.
  static Future<void> showAlert({
    required String sessionId,
    required String title,
    required String body,
    String? agent,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('showAlert', {
        'sessionId': sessionId,
        'title': title,
        'body': body,
        'agent': agent,
      });
    } catch (_) {
      // Notifications blocked or native side unavailable — the in-app badge
      // still marks the session, so there's nothing actionable here.
    }
  }

  /// Dismisses every alert notification. Called when the app returns to the
  /// foreground: the user is looking at the app again, so stale alerts would
  /// only be noise.
  static Future<void> cancelAlerts() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('cancelAlerts');
    } catch (_) {
      // Ignore — nothing actionable.
    }
  }

  /// Returns the session id carried by the notification tap that launched (or
  /// resumed) the activity, if any, clearing it on the native side so it fires
  /// once. Null when the app was opened normally.
  static Future<String?> consumePendingSession() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('consumePendingSession');
    } catch (_) {
      return null;
    }
  }
}
