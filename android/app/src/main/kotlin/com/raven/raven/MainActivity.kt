package com.raven.raven

import android.Manifest
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private val visibilityChannelName = "raven/audio_visibility"
    private val permissionChannelName = "raven/recording_permissions"
    private val recordingControlChannelName = "raven/recording_controls"
    private var pendingRecordingAction: String? = null
    private var recordingControlChannel: MethodChannel? = null
    private var notificationPermissionResult: MethodChannel.Result? = null
    private val notificationPermissionRequestCode = 7341

    override fun onCreate(savedInstanceState: Bundle?) {
        pendingRecordingAction = recordingAction(intent?.action)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pendingRecordingAction = recordingAction(intent.action)
        dispatchPendingRecordingAction()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        recordingControlChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, recordingControlChannelName)
        recordingControlChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "start", "update" -> {
                    val title = call.argument<String>("title")
                    val elapsedMs = call.argument<Number>("elapsedMs")?.toLong()
                    val paused = call.argument<Boolean>("paused")
                    if (title.isNullOrBlank() || elapsedMs == null || paused == null) {
                        result.error("BAD_ARGUMENTS", "Recording title, elapsed time and pause state are required.", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val action = if (call.method == "start") {
                            RecordingForegroundService.ACTION_START
                        } else {
                            RecordingForegroundService.ACTION_UPDATE
                        }
                        val serviceIntent = Intent(this, RecordingForegroundService::class.java)
                            .setAction(action)
                            .putExtra(RecordingForegroundService.EXTRA_TITLE, title)
                            .putExtra(RecordingForegroundService.EXTRA_ELAPSED_MS, elapsedMs)
                            .putExtra(RecordingForegroundService.EXTRA_PAUSED, paused)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && call.method == "start") {
                            startForegroundService(serviceIntent)
                        } else {
                            startService(serviceIntent)
                        }
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("RECORDING_NOTIFICATION_FAILED", error.message ?: "Could not start recording notification.", null)
                    }
                }
                "stop" -> {
                    stopService(
                        Intent(this, RecordingForegroundService::class.java)
                            .setAction(RecordingForegroundService.ACTION_STOP),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        dispatchPendingRecordingAction()

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
                    "publishDocument" -> {
                        // Saves a plain-text file (e.g. project notes) into the
                        // public Documents/RAVEN folder so it can be opened by
                        // Notepad, Word, Google Docs or any text editor.
                        val sourcePath = call.argument<String>("sourcePath")
                        val fileName = call.argument<String>("fileName")
                        val mimeType = call.argument<String>("mimeType") ?: "text/plain"
                        if (sourcePath.isNullOrBlank() || fileName.isNullOrBlank()) {
                            result.error("BAD_ARGUMENTS", "Missing source path or file name.", null)
                            return@setMethodCallHandler
                        }

                        var uri: Uri? = null
                        try {
                            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                                throw IllegalStateException("Saving to Documents requires Android 10 or newer.")
                            }
                            val source = File(sourcePath)
                            if (!source.isFile) throw IllegalStateException("Source file does not exist.")
                            val values = ContentValues().apply {
                                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOCUMENTS + "/RAVEN")
                                put(MediaStore.MediaColumns.IS_PENDING, 1)
                            }
                            uri = contentResolver.insert(MediaStore.Files.getContentUri("external"), values)
                                ?: throw IllegalStateException("Could not create a public document entry.")
                            val output = contentResolver.openOutputStream(uri!!)
                                ?: throw IllegalStateException("Could not open the public document destination.")
                            output.use { stream -> FileInputStream(source).use { input -> input.copyTo(stream) } }
                            val ready = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
                            contentResolver.update(uri!!, ready, null, null)
                            result.success(uri.toString())
                        } catch (error: Exception) {
                            if (uri != null) {
                                try { contentResolver.delete(uri!!, null, null) } catch (_: Exception) { }
                            }
                            result.error("PUBLISH_FAILED", error.message ?: "Could not save the document.", null)
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, permissionChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestNotificationPermission" -> requestNotificationPermission(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun recordingAction(action: String?): String? = when (action) {
        RecordingForegroundService.ACTION_PAUSE -> "pause"
        RecordingForegroundService.ACTION_RESUME -> "pause"
        RecordingForegroundService.ACTION_STOP_RECORDING -> "stop"
        else -> null
    }

    private fun dispatchPendingRecordingAction() {
        val action = pendingRecordingAction ?: return
        val channel = recordingControlChannel ?: return
        channel.invokeMethod(action, null, object : MethodChannel.Result {
            override fun success(result: Any?) {
                if (pendingRecordingAction == action) pendingRecordingAction = null
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                // Retain the action until the recorder's Dart handler is ready.
            }

            override fun notImplemented() {
                // Retain the action until the recorder's Dart handler is ready.
            }
        })
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
