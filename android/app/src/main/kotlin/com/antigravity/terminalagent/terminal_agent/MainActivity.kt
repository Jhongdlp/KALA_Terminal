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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestNotificationPermission()
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
