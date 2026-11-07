package com.raven.raven

import android.Manifest
import android.app.AlarmManager
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private val visibilityChannelName = "raven/audio_visibility"
    private val schedulerChannelName = "raven/scheduled_recording"
    private var pendingScheduleId: String? = null
    private var notificationPermissionResult: MethodChannel.Result? = null
    private val notificationPermissionRequestCode = 7341

    override fun onCreate(savedInstanceState: Bundle?) {
        pendingScheduleId = intent?.getStringExtra(ScheduledRecordingReceiver.EXTRA_SCHEDULE_ID)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pendingScheduleId = intent.getStringExtra(ScheduledRecordingReceiver.EXTRA_SCHEDULE_ID)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, visibilityChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "publishAudio" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        val fileName = call.argument<String>("fileName")
                        val mimeType = call.argument<String>("mimeType")
                        if (sourcePath.isNullOrBlank() || fileName.isNullOrBlank() || mimeType.isNullOrBlank()) {
                            result.error("BAD_ARGUMENTS", "Missing source path or media metadata.", null)
                            return@setMethodCallHandler
                        }
                        var uri: Uri? = null
                        try {
                            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                                throw IllegalStateException("Public-folder visibility requires Android 10 or newer.")
                            }
                            val source = File(sourcePath)
                            if (!source.isFile) throw IllegalStateException("Source audio does not exist.")
                            val values = ContentValues().apply {
                                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_MUSIC + "/RAVEN")
                                put(MediaStore.MediaColumns.IS_PENDING, 1)
                            }
                            uri = contentResolver.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, values)
                                ?: throw IllegalStateException("Could not create a public audio entry.")
                            val output = contentResolver.openOutputStream(uri!!)
                                ?: throw IllegalStateException("Could not open the public audio destination.")
                            output.use { stream -> FileInputStream(source).use { input -> input.copyTo(stream) } }
                            val ready = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
                            contentResolver.update(uri!!, ready, null, null)
                            result.success(uri.toString())
                        } catch (error: Exception) {
                            if (uri != null) {
                                try { contentResolver.delete(uri!!, null, null) } catch (_: Exception) { }
                            }
                            result.error("PUBLISH_FAILED", error.message ?: "Could not publish audio.", null)
                        }
                    }
                    "deletePublishedAudio" -> {
                        val rawUri = call.argument<String>("uri")
                        if (rawUri.isNullOrBlank() || !rawUri.startsWith("content://")) {
                            result.error("BAD_URI", "A managed MediaStore URI is required.", null)
                        } else {
                            try {
                                val uri = Uri.parse(rawUri)
                                val deletedCount = contentResolver.delete(uri, null, null)
                                val removed = if (deletedCount > 0) {
                                    true
                                } else {
                                    // A file that the user already removed counts as hidden;
                                    // an item that still exists must not be reported as removed.
                                    val stillExists = contentResolver.query(
                                        uri,
                                        arrayOf(MediaStore.MediaColumns._ID),
                                        null,
                                        null,
                                        null,
                                    )?.use { cursor -> cursor.moveToFirst() } ?: false
                                    !stillExists
                                }
                                result.success(removed)
                            } catch (error: Exception) {
                                result.error("DELETE_FAILED", error.message ?: "Could not remove the public copy.", null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, schedulerChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestNotificationPermission" -> requestNotificationPermission(result)
                    "canScheduleExactAlarms" -> {
                        val allowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                            (getSystemService(ALARM_SERVICE) as AlarmManager).canScheduleExactAlarms()
                        result.success(allowed)
                    }
                    "openExactAlarmSettings" -> {
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:$packageName")))
                            } else {
                                result.success(null)
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) result.success(null)
                        } catch (error: Exception) {
                            result.error("ALARM_SETTINGS_FAILED", error.message ?: "Could not open alarm settings.", null)
                        }
                    }
                    "scheduleAlarm" -> {
                        val id = call.argument<String>("id")
                        val title = call.argument<String>("title")
                        val atMillis = call.argument<Number>("triggerAtMillis")?.toLong()
                        if (id.isNullOrBlank() || atMillis == null || atMillis <= System.currentTimeMillis()) {
                            result.error("BAD_ALARM", "A future time, schedule ID and title are required.", null)
                            return@setMethodCallHandler
                        }
                        try {
                            ScheduledRecordingReceiver.schedule(
                                this,
                                id,
                                title ?: "Scheduled recording",
                                atMillis,
                            )
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("SCHEDULE_FAILED", error.message ?: "Could not set the alarm.", null)
                        }
                    }
                    "cancelAlarm" -> {
                        val id = call.argument<String>("id")
                        if (id.isNullOrBlank()) {
                            result.error("BAD_ALARM", "A schedule ID is required.", null)
                        } else {
                            try {
                                ScheduledRecordingReceiver.cancel(this, id)
                                result.success(null)
                            } catch (error: Exception) {
                                result.error("CANCEL_FAILED", error.message ?: "Could not cancel the alarm.", null)
                            }
                        }
                    }
                    "consumeTappedScheduleId" -> {
                        val resultId = pendingScheduleId ?: intent?.getStringExtra(ScheduledRecordingReceiver.EXTRA_SCHEDULE_ID)
                        pendingScheduleId = null
                        intent?.removeExtra(ScheduledRecordingReceiver.EXTRA_SCHEDULE_ID)
                        result.success(resultId)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        if (notificationPermissionResult != null) {
            result.error("PERMISSION_PENDING", "A notification permission request is already pending.", null)
            return
        }
        notificationPermissionResult = result
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), notificationPermissionRequestCode)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == notificationPermissionRequestCode) {
            val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
            notificationPermissionResult?.success(granted)
            notificationPermissionResult = null
        }
    }
}
