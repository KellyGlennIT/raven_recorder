package com.raven.raven

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

class RecordingForegroundService : Service() {
    private var title = "RAVEN recording"
    private var elapsedMs = 0L
    private var paused = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START, ACTION_UPDATE -> {
                title = intent.getStringExtra(EXTRA_TITLE) ?: title
                elapsedMs = intent.getLongExtra(EXTRA_ELAPSED_MS, elapsedMs)
                paused = intent.getBooleanExtra(EXTRA_PAUSED, paused)
                createNotificationChannel()
                val notification = buildNotification()
                if (intent.action == ACTION_START) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        startForeground(
                            NOTIFICATION_ID,
                            notification,
                            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
                        )
                    } else {
                        startForeground(NOTIFICATION_ID, notification)
                    }
                } else {
                    getSystemService(NotificationManager::class.java)
                        .notify(NOTIFICATION_ID, notification)
                }
            }
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Recording",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Controls for an active RAVEN recording"
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun actionIntent(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(this, MainActivity::class.java)
            .setAction(action)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder.apply {
            setContentTitle(title)
            setContentText(
                if (paused) "Paused - ${formatElapsed(elapsedMs)}"
                else "Recording in progress",
            )
            setSmallIcon(android.R.drawable.ic_btn_speak_now)
            setOngoing(true)
            setOnlyAlertOnce(true)
            setShowWhen(!paused)
            setWhen(System.currentTimeMillis() - elapsedMs)
            setUsesChronometer(!paused)
            setContentIntent(actionIntent(ACTION_OPEN, REQUEST_OPEN))
            addAction(
                if (paused) android.R.drawable.ic_media_play else android.R.drawable.ic_media_pause,
                if (paused) "Resume" else "Pause",
                actionIntent(if (paused) ACTION_RESUME else ACTION_PAUSE, REQUEST_TOGGLE),
            )
            addAction(
                R.drawable.ic_media_stop,
                "Stop",
                actionIntent(ACTION_STOP_RECORDING, REQUEST_STOP),
            )
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setCategory(Notification.CATEGORY_SERVICE)
        }
        return builder.build()
    }

    private fun formatElapsed(durationMs: Long): String {
        val totalSeconds = durationMs / 1000
        return "%02d:%02d".format(totalSeconds / 60, totalSeconds % 60)
    }

    companion object {
        const val ACTION_START = "com.raven.raven.recording.START"
        const val ACTION_UPDATE = "com.raven.raven.recording.UPDATE"
        const val ACTION_STOP = "com.raven.raven.recording.CLEAR"
        const val ACTION_OPEN = "com.raven.raven.recording.OPEN"
        const val ACTION_PAUSE = "com.raven.raven.recording.PAUSE"
        const val ACTION_RESUME = "com.raven.raven.recording.RESUME"
        const val ACTION_STOP_RECORDING = "com.raven.raven.recording.STOP"
        const val EXTRA_TITLE = "recording_title"
        const val EXTRA_ELAPSED_MS = "elapsed_ms"
        const val EXTRA_PAUSED = "recording_paused"
        private const val CHANNEL_ID = "raven_active_recording"
        private const val NOTIFICATION_ID = 4682
        private const val REQUEST_OPEN = 4683
        private const val REQUEST_TOGGLE = 4684
        private const val REQUEST_STOP = 4685
    }
}
