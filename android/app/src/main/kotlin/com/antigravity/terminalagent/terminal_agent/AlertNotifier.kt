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

    // Per-kind channels. A channel's importance is fixed when it is created and
    // cannot be raised afterwards, so a level change is applied by moving to a
    // channel whose id encodes the level and deleting the previous one. Kind
    // ids match Dart's AlertKind.name; levels match AlertIntensity.name.
    private const val CHANNEL_PREFIX = "kala_alert"

    private fun channelId(kind: String, level: String) = "${CHANNEL_PREFIX}_${kind}_$level"

    private fun kindTitle(kind: String): String = when (kind) {
        "question" -> "El agente pregunta"
        "done" -> "El agente terminó"
        "bell" -> "Campana del programa"
        "disconnect" -> "Sesión caída"
        else -> "Avisos de agente"
    }

    private fun kindDescription(kind: String): String = when (kind) {
        "question" -> "El agente espera una respuesta, un permiso o una selección"
        "done" -> "El agente dejó de escribir sin pedir nada"
        "bell" -> "El programa pidió atención explícitamente (campana u OSC 9/777)"
        "disconnect" -> "Se perdió la conexión SSH de una sesión"
        else -> "Una sesión de terminal pide tu atención"
    }

    private fun importanceFor(level: String): Int = when (level) {
        "high" -> NotificationManager.IMPORTANCE_HIGH
        "medium" -> NotificationManager.IMPORTANCE_DEFAULT
        "low" -> NotificationManager.IMPORTANCE_LOW
        else -> NotificationManager.IMPORTANCE_NONE
    }

    /** Levels understood by [importanceFor], for pruning stale channels. */
    private val ALL_LEVELS = listOf("high", "medium", "low", "off")

    /**
     * The level currently configured for each kind, as last set by
     * [configureChannels]. Kept so [show] can resolve a kind to its channel
     * without a round trip to Dart.
     */
    private val levels = mutableMapOf<String, String>()

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
        else -> Color.parseColor("#007AFF")           // KAMMEL azure
    }

    /**
     * Creates one channel per alert kind at its configured importance, and
     * removes that kind's channels at every *other* importance so the shade's
     * channel list doesn't accumulate one entry per level ever chosen.
     *
     * [intensities] maps an AlertKind name to an AlertIntensity name.
     */
    fun configureChannels(context: Context, intensities: Map<String, String>) {
        levels.putAll(intensities)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        for ((kind, level) in intensities) {
            for (stale in ALL_LEVELS) {
                if (stale != level) manager.deleteNotificationChannel(channelId(kind, stale))
            }
            if (level == "off") continue
            val id = channelId(kind, level)
            if (manager.getNotificationChannel(id) != null) continue
            manager.createNotificationChannel(
                NotificationChannel(id, kindTitle(kind), importanceFor(level)).apply {
                    description = kindDescription(kind)
                },
            )
        }
    }

    fun show(
        context: Context,
        sessionId: String,
        title: String,
        body: String,
        agent: String?,
        kind: String?,
        sessionName: String? = null,
    ) {
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val level = kind?.let { levels[it] }
        // Fall back to the original single channel when the kind is unknown or
        // has not been configured yet, so an alert is never silently lost.
        val activeChannel = if (kind != null && level != null && level != "off") {
            channelId(kind, level)
        } else {
            createChannel(manager)
            CHANNEL_ID
        }

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
            Notification.Builder(context, activeChannel)
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
            .setContentTitle("KAMMEL")
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
