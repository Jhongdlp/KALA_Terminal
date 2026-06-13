package com.antigravity.terminalagent.terminal_agent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Foreground service that keeps the app process (and therefore every running
 * PTY/SSH shell) alive while KALA is in the background, mirroring the way
 * Termux stays alive. It shows a persistent notification with two actions:
 *
 *  - "Adquirir/Liberar wakelock": toggles a partial wakelock so long-running
 *    tasks keep executing while the screen is off.
 *  - "Salir": tears everything down and fully closes the app.
 */
class TerminalService : Service() {

    companion object {
        const val ACTION_START = "com.antigravity.terminalagent.action.START"
        const val ACTION_STOP = "com.antigravity.terminalagent.action.STOP"
        const val ACTION_TOGGLE_WAKELOCK =
            "com.antigravity.terminalagent.action.TOGGLE_WAKELOCK"

        private const val CHANNEL_ID = "kala_background"
        private const val NOTIFICATION_ID = 1001
        private const val WAKELOCK_TAG = "KALA::BackgroundWakeLock"
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopEverything()
                return START_NOT_STICKY
            }
            ACTION_TOGGLE_WAKELOCK -> toggleWakeLock()
        }

        startForegroundWithNotification()
        // START_STICKY: if the OS kills the service under memory pressure it is
        // recreated as soon as resources allow, re-establishing the notification.
        return START_STICKY
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }

    private fun startForegroundWithNotification() {
        createChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Sesiones en segundo plano",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Mantiene las terminales activas mientras la app está minimizada"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val held = wakeLock?.isHeld == true

        val contentIntent = packageManager.getLaunchIntentForPackage(packageName)?.let {
            it.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            PendingIntent.getActivity(this, 0, it, pendingFlags())
        }

        val wakeLockIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, TerminalService::class.java).setAction(ACTION_TOGGLE_WAKELOCK),
            pendingFlags(),
        )

        val exitIntent = PendingIntent.getService(
            this,
            2,
            Intent(this, TerminalService::class.java).setAction(ACTION_STOP),
            pendingFlags(),
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("KALA activo")
            .setContentText(
                if (held) "Wakelock activo · las tareas siguen con la pantalla apagada"
                else "Las sesiones siguen ejecutándose en segundo plano",
            )
            .setSmallIcon(R.drawable.ic_notification)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(contentIntent)
            .addAction(
                0,
                if (held) "Liberar wakelock" else "Adquirir wakelock",
                wakeLockIntent,
            )
            .addAction(0, "Salir", exitIntent)
            .build()
    }

    private fun toggleWakeLock() {
        if (wakeLock?.isHeld == true) {
            releaseWakeLock()
        } else {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKELOCK_TAG).apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        // Refresh the notification so the action label/text reflects the change.
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification())
    }

    private fun releaseWakeLock() {
        if (wakeLock?.isHeld == true) wakeLock?.release()
        wakeLock = null
    }

    private fun stopEverything() {
        releaseWakeLock()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
        // Fully close the app, matching Termux's "Exit" behaviour: kill the
        // whole process so no detached shells linger.
        android.os.Process.killProcess(android.os.Process.myPid())
    }

    private fun pendingFlags(): Int {
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return flags
    }
}
