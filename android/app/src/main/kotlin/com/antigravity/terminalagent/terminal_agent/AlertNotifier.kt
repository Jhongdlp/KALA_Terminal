package com.antigravity.terminalagent.terminal_agent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.Color
import android.os.Build

/**
 * Posts the "agent alert" heads-up notifications: a backgrounded terminal
 * session rang the bell (BEL) or emitted an OSC 9/777 notification — typically
 * a TUI agent (Claude Code, aider, …) asking for input — and the user should
 * be able to jump straight back to that session.
 *
 * Separate from [TerminalService]'s persistent low-importance notification:
 * alerts live on their own high-importance channel so they pop and make sound,
 * and are tagged with the session id so tapping one reopens that session.
 */
object AlertNotifier {

    private const val CHANNEL_ID = "kala_alerts"
    const val EXTRA_SESSION_ID = "kala_session_id"

    // Alert notification ids live in their own range so they can never collide
    // with TerminalService's NOTIFICATION_ID (1001).
    private const val ID_BASE = 2000
    private const val ID_RANGE = 1000

    /**
     * Full-color avatar (Android's largeIcon) identifying the agent that
     * asked for attention. The status-bar smallIcon must stay a monochrome
     * silhouette by platform rule, so the branding lives here instead.
     */
    private fun agentBadge(agent: String?): Int = when (agent) {
        "claude" -> R.drawable.ic_agent_claude
        "antigravity" -> R.drawable.ic_agent_antigravity
        "aider" -> R.drawable.ic_agent_aider
        "codex" -> R.drawable.ic_agent_codex
        "gemini" -> R.drawable.ic_agent_gemini
        else -> R.drawable.ic_agent_generic
    }

    /**
     * Resolves the custom brand color for each agent to tint the notification header,
     * small icon circle, and other elements on Android 5.0+ (API 21+).
     */
    private fun agentColor(agent: String?): Int = when (agent) {
        "claude" -> Color.parseColor("#D96B43")       // Warm terracotta
        "antigravity" -> Color.parseColor("#1E3A8A")  // Deep indigo
        "gemini" -> Color.parseColor("#4F46E5")       // Indigo-violet
        "aider" -> Color.parseColor("#0D9488")        // Teal
        "codex" -> Color.parseColor("#7C3AED")        // Violet
        else -> Color.parseColor("#1F2937")           // Dark gray/charcoal
    }

    fun show(
        context: Context,
        sessionId: String,
        title: String,
        body: String,
        agent: String?,
    ) {
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        createChannel(manager)

        val launch = context.packageManager
            .getLaunchIntentForPackage(context.packageName) ?: return
        launch.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        launch.putExtra(EXTRA_SESSION_ID, sessionId)
        val contentIntent = PendingIntent.getActivity(
            context,
            // Distinct request code per session so each notification keeps its
            // own extras instead of all reusing the first PendingIntent.
            notificationId(sessionId),
            launch,
            pendingFlags(),
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context).setPriority(Notification.PRIORITY_HIGH)
        }

        val notification = builder
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(agentColor(agent))
            .setLargeIcon(
                BitmapFactory.decodeResource(context.resources, agentBadge(agent)),
            )
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
            .setContentIntent(contentIntent)
            .build()

        manager.notify(notificationId(sessionId), notification)
    }

    /** Cancels every alert notification (the persistent service one survives). */
    fun cancelAll(context: Context) {
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            for (active in manager.activeNotifications) {
                if (active.id in ID_BASE until ID_BASE + ID_RANGE) {
                    manager.cancel(active.id)
                }
            }
        } else {
            // No way to enumerate active notifications pre-M; cancelAll also
            // drops the foreground service one, which the service re-posts.
            manager.cancelAll()
        }
    }

    /** Cancels the notification for a specific session. */
    fun cancelFor(context: Context, sessionId: String) {
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(notificationId(sessionId))
    }

    /** One stable notification per session: repeated bells update in place. */
    private fun notificationId(sessionId: String): Int =
        ID_BASE + (sessionId.hashCode().let { if (it < 0) -it else it } % ID_RANGE)

    private fun createChannel(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Avisos de agente",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description =
                "Una sesión de terminal pide tu atención (el agente espera una respuesta)"
        }
        manager.createNotificationChannel(channel)
    }

    private fun pendingFlags(): Int {
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return flags
    }
}
