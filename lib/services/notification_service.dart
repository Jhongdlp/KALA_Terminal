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

  /// Creates/refreshes one notification channel per alert kind at the
  /// requested importance. Android fixes a channel's importance when it is
  /// created, so a level change is implemented by using a differently-suffixed
  /// channel id; [intensities] maps an [AlertKind] name to an [AlertIntensity]
  /// name. Safe to call repeatedly.
  static Future<void> configureChannels({
    required Map<String, String> intensities,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('configureChannels', {
        'intensities': intensities,
      });
    } catch (_) {
      // Older build of the native side, or channels unavailable — alerts fall
      // back to the default channel.
    }
  }

  /// Posts (or refreshes) the alert notification for [sessionId]. Tapping it
  /// opens the app on that session (see `consumePendingSession`). [agent] is
  /// the detected agent id ('claude', 'antigravity', …) used to pick the
  /// notification's large icon badge; null/unknown falls back to a generic
  /// one. [kind] selects the channel (and therefore how loud it is).
  /// [sessionName] is shown as the notification's subtext so the user knows
  /// which tab to expect.
  ///
  /// One notification id per session: a newer alert *replaces* the session's
  /// previous one instead of stacking, so the shade always shows the session's
  /// current state rather than a history of stale claims.
  static Future<void> showAlert({
    required String sessionId,
    required String title,
    required String body,
    String? agent,
    String? kind,
    String? sessionName,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('showAlert', {
        'sessionId': sessionId,
        'title': title,
        'body': body,
        'agent': agent,
        'kind': kind,
        'sessionName': sessionName,
      });
    } catch (_) {
      // Notifications blocked or native side unavailable — the in-app badge
      // still marks the session, so there's nothing actionable here.
    }
  }

  /// Dismisses the alert for a single session — used when that session starts
  /// producing output again (whatever it claimed is no longer true) or when
  /// the user opens it.
  static Future<void> cancelAlert(String sessionId) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('cancelAlert', {'sessionId': sessionId});
    } catch (_) {
      // Ignore — nothing actionable.
    }
  }

  /// Whether the app can actually post notifications right now. False means
  /// the user denied the runtime permission or blocked the channel, which is
  /// worth surfacing in the settings screen: nothing else will work.
  static Future<bool> areNotificationsEnabled() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('areNotificationsEnabled') ??
          true;
    } catch (_) {
      return true;
    }
  }

  /// Opens the system notification settings for the app, so a denied
  /// permission can be fixed without hunting through Android's menus.
  static Future<void> openSystemSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('openNotificationSettings');
    } catch (_) {
      // Ignore — nothing actionable.
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
