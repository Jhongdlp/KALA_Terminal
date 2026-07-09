package com.antigravity.terminalagent.terminal_agent

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (instead of FlutterActivity) is required by the
// local_auth plugin, which shows the biometric/device-credential prompt inside
// an AndroidX BiometricFragment.
class MainActivity : FlutterFragmentActivity() {

    private val channelName = "com.antigravity.terminalagent/background"
    private val notificationsChannelName = "com.antigravity.terminalagent/notifications"

    // Session id carried by the agent-alert notification that launched or
    // resumed this activity. Held until the Dart side consumes it (see
    // "consumePendingSession") so the app can jump straight to that session.
    private var pendingSessionId: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestNotificationPermission()
        capturePendingSession(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        capturePendingSession(intent)
    }

    private fun capturePendingSession(intent: Intent?) {
        val id = intent?.getStringExtra(AlertNotifier.EXTRA_SESSION_ID)
        if (id != null) pendingSessionId = id
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                0,
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startBackgroundService" -> {
                        startService(TerminalService.ACTION_START)
                        result.success(true)
                    }
                    "stopBackgroundService" -> {
                        startService(TerminalService.ACTION_STOP)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, notificationsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "showAlert" -> {
                        AlertNotifier.show(
                            this,
                            call.argument<String>("sessionId") ?: "",
                            call.argument<String>("title") ?: "KALA",
                            call.argument<String>("body") ?: "",
                            call.argument<String>("agent"),
                        )
                        result.success(true)
                    }
                    "cancelAlerts" -> {
                        AlertNotifier.cancelAll(this)
                        result.success(true)
                    }
                    "consumePendingSession" -> {
                        result.success(pendingSessionId)
                        pendingSessionId = null
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startService(action: String) {
        val intent = Intent(this, TerminalService::class.java).setAction(action)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }
}
