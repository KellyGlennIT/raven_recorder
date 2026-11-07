package com.raven.raven

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/** Posts a silent, clearly visible reminder. It deliberately does not activate the microphone. */
class ScheduledRecordingReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val scheduleId = intent.getStringExtra(EXTRA_SCHEDULE_ID) ?: return
        val title = intent.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotBlank() } ?: "Scheduled recording"
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        createChannel(manager)

        val openIntent = Intent(context, MainActivity::class.java).apply {
            action = "com.raven.raven.SCHEDULED_RECORDING"
            putExtra(EXTRA_SCHEDULE_ID, scheduleId)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val contentIntent = PendingIntent.getActivity(
            context,
            scheduleId.hashCode(),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle("RAVEN · Recording scheduled")
            // Keep project titles out of lock-screen notifications for privacy.
            .setContentText("Tap to open RAVEN and start your scheduled recording.")
            .setStyle(Notification.BigTextStyle().bigText("Your scheduled recording is due. Tap to open RAVEN and start recording."))
            .setCategory(Notification.CATEGORY_REMINDER)
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .build()
        manager.notify(scheduleId.hashCode(), notification)
    }

    private fun createChannel(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Scheduled recording reminders",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Silent, visible reminders for recordings you scheduled in RAVEN."
                setSound(null, null)
                enableVibration(false)
                setShowBadge(true)
            }
            manager.createNotificationChannel(channel)
        }
    }

    companion object {
        const val CHANNEL_ID = "raven_scheduled_recording_silent"
        const val EXTRA_SCHEDULE_ID = "raven_schedule_id"
        const val EXTRA_TITLE = "raven_schedule_title"

        fun schedule(context: Context, id: String, title: String, triggerAtMillis: Long) {
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !alarmManager.canScheduleExactAlarms()) {
                throw SecurityException("Enable Alarms & reminders before scheduling a precise recording reminder.")
            }
            val intent = Intent(context, ScheduledRecordingReceiver::class.java).apply {
                putExtra(EXTRA_SCHEDULE_ID, id)
                putExtra(EXTRA_TITLE, title)
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                id.hashCode(),
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAtMillis, pendingIntent)
        }

        fun cancel(context: Context, id: String) {
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(context, ScheduledRecordingReceiver::class.java).apply {
                putExtra(EXTRA_SCHEDULE_ID, id)
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                id.hashCode(),
                intent,
                PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE,
            )
            if (pendingIntent != null) {
                alarmManager.cancel(pendingIntent)
                pendingIntent.cancel()
            }
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(id.hashCode())
        }
    }
}

/** Rebuilds one-off alarms after a device reboot or app replacement. */
class ScheduledRecordingBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val schedulesFile = java.io.File(context.filesDir, "raven/scheduled_recordings.json")
        if (!schedulesFile.isFile) return
        val records = try {
            org.json.JSONArray(schedulesFile.readText())
        } catch (_: Exception) {
            return
        }
        val now = System.currentTimeMillis()
        for (index in 0 until records.length()) {
            val item = records.optJSONObject(index) ?: continue
            val id = item.optString("id").takeIf { it.isNotBlank() } ?: continue
            val title = item.optString("title", "Scheduled recording")
            val timestamp = item.optString("scheduledAt").toTriggerMillis() ?: continue
            // A stale schedule is not revived long after its intended start time.
            if (timestamp - now > 24L * 60L * 60L * 1000L * 366L * 5L) continue
            if (now - timestamp > 15L * 60L * 1000L) continue
            val triggerAt = if (timestamp <= now) now + 1000L else timestamp
            try {
                ScheduledRecordingReceiver.schedule(context, id, title, triggerAt)
            } catch (_: SecurityException) {
                // Without exact-alarm access, RAVEN will explain the missing permission on next use.
            } catch (_: Exception) {
                // One invalid schedule must not prevent other reminders from being restored.
            }
        }
    }

    private fun String.toTriggerMillis(): Long? {
        return try {
            java.time.Instant.parse(this).toEpochMilli()
        } catch (_: Exception) {
            try {
                java.time.OffsetDateTime.parse(this).toInstant().toEpochMilli()
            } catch (_: Exception) {
                try {
                    java.time.LocalDateTime.parse(this)
                        .atZone(java.time.ZoneId.systemDefault())
                        .toInstant()
                        .toEpochMilli()
                } catch (_: Exception) {
                    null
                }
            }
        }
    }
}
