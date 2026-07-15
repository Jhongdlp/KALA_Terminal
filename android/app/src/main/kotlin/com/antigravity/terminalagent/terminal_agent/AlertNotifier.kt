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

    // Stack key + summary id so alerts from several sessions collapse into one
    // expandable group instead of flooding the shade.
    private const val GROUP_KEY = "kala_agent_alerts"
    private const val SUMMARY_ID = 1999

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
        "copilot" -> R.drawable.ic_agent_copilot
        "opencode" -> R.drawable.ic_agent_opencode
        "cursor" -> R.drawable.ic_agent_cursor
        "qwen" -> R.drawable.ic_agent_qwen
        else -> R.drawable.ic_agent_generic
    }

    /**
     * Brand accent for each agent: tints the app name, small-icon and action
     * area of the notification on API 21+.
     */
    private fun agentColor(agent: String?): Int = when (agent) {
        "claude" -> Color.parseColor("#D97757")       // Anthropic clay
        "antigravity" -> Color.parseColor("#1E3A8A")  // Deep indigo
        "gemini" -> Color.parseColor("#4796E3")       // Gemini blue
        "aider" -> Color.parseColor("#0D9488")        // Teal
        "codex" -> Color.parseColor("#1A7F64")        // OpenAI green
        "copilot" -> Color.parseColor("#8957E5")      // Copilot purple
        "opencode" -> Color.parseColor("#4B5563")     // Graphite
        "cursor" -> Color.parseColor("#374151")       // Slate
        "qwen" -> Color.parseColor("#6156E6")         // Qwen violet
        else -> Color.parseColor("#007AFF")           // KALA azure
    }

    fun show(
        context: Context,
        sessionId: String,
        title: String,
        body: String,
        agent: String?,
        sessionName: String? = null,
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

        // First line of the body doubles as the collapsed content text; the
        // expanded BigText shows the on-screen excerpt the Dart side attached.
        val collapsed = body.lineSequence().firstOrNull() ?: body

        val notification = builder
            .setContentTitle(title)
            .setContentText(collapsed)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(agentColor(agent))
            .setLargeIcon(
                BitmapFactory.decodeResource(context.resources, agentBadge(agent)),
            )
            .apply {
                if (!sessionName.isNullOrBlank() && sessionName != title) {
                    setSubText(sessionName)
                }
            }
            .setShowWhen(true)
            .setWhen(System.currentTimeMillis())
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setGroup(GROUP_KEY)
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
            .setContentIntent(contentIntent)
            .build()

        manager.notify(notificationId(sessionId), notification)
        maybePostGroupSummary(context, manager)
    }

    /**
     * With two or more live alerts, posts the silent group summary that lets
     * the system stack them; a single alert needs none.
     */
    private fun maybePostGroupSummary(context: Context, manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        val alerts = manager.activeNotifications
            .count { it.id in ID_BASE until ID_BASE + ID_RANGE }
        if (alerts < 2) return

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context).setPriority(Notification.PRIORITY_HIGH)
        }
        val summary = builder
            .setContentTitle("KALA")
            .setContentText("$alerts sesiones piden tu atención")
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(Color.parseColor("#007AFF"))
            .setGroup(GROUP_KEY)
            .setGroupSummary(true)
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
            .build()
        manager.notify(SUMMARY_ID, summary)
    }

    /** Cancels every alert notification (the persistent service one survives). */
    fun cancelAll(context: Context) {
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            for (active in manager.activeNotifications) {
                if (active.id == SUMMARY_ID ||
                    active.id in ID_BASE until ID_BASE + ID_RANGE
                ) {
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
