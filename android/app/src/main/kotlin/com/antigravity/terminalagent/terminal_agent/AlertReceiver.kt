package com.antigravity.terminalagent.terminal_agent

import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.flutter.plugin.common.MethodChannel

/**
 * Handles the agent-alert notification actions ("1", "2", "Responder…")
 * without opening the app: the input travels over [AlertBridge] straight into
 * the Dart side, which writes it to that session's shell. The whole point of
 * the foreground service keeping the process alive is that the SSH channel —
 * and the Flutter engine — are still there to receive this.
 */
class AlertReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_AGENT_INPUT =
            "com.antigravity.terminalagent.action.AGENT_INPUT"
        const val EXTRA_INPUT = "kala_input"
        const val REMOTE_INPUT_KEY = "kala_reply"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_AGENT_INPUT) return
        val sessionId = intent.getStringExtra(AlertNotifier.EXTRA_SESSION_ID) ?: return

        // Fixed quick key ("1"/"2") or free text typed into the reply slot
        // (submitted to the agent with a trailing Enter).
        val input = intent.getStringExtra(EXTRA_INPUT)
            ?: RemoteInput.getResultsFromIntent(intent)
                ?.getCharSequence(REMOTE_INPUT_KEY)
                ?.toString()
                ?.let { "$it\r" }
            ?: return

        // The agent got its answer: this alert is resolved either way.
        AlertNotifier.cancelFor(context, sessionId)

        val channel = AlertBridge.channel
        if (channel != null) {
            channel.invokeMethod(
                "agentInput",
                mapOf("sessionId" to sessionId, "input" to input),
            )
        } else {
            // Engine gone (process was killed, so the session is gone too):
            // fall back to opening the app on that session.
            context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?.let {
                    it.setFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP,
                    )
                    it.putExtra(AlertNotifier.EXTRA_SESSION_ID, sessionId)
                    context.startActivity(it)
                }
        }
    }
}

/**
 * Static handle to the notifications MethodChannel, set while a Flutter engine
 * is alive (see MainActivity). Lets [AlertReceiver] reach Dart from outside
 * any activity.
 */
object AlertBridge {
    @Volatile
    var channel: MethodChannel? = null
}
