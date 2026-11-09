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
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : AudioServiceActivity() {
    private val visibilityChannelName = "raven/audio_visibility"
    private val permissionChannelName = "raven/recording_permissions"
    private val recordingControlChannelName = "raven/recording_controls"
    private val storagePermissionChannelName = "raven/storage_permission"
    private var pendingRecordingAction: String? = null
    private var recordingControlChannel: MethodChannel? = null
    private var notificationPermissionResult: MethodChannel.Result? = null
    private val notificationPermissionRequestCode = 7341
    // All-files-access uses startActivityForResult / onActivityResult,
    // which is a separate mechanism from onRequestPermissionsResult.
    private var allFilesAccessResult: MethodChannel.Result? = null
    private val allFilesAccessRequestCode = 7342

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
                    "publishFolder" -> {
                        // Copies a whole project folder (audio, notes, attachments)
                        // into Music/RAVEN/<folder> so it is browsable with any
                        // file manager. Returns the folder's MediaStore URI.
                        val sourcePath = call.argument<String>("sourcePath")
                        val folderName = call.argument<String>("folderName")
                        if (sourcePath.isNullOrBlank() || folderName.isNullOrBlank()) {
                            result.error("BAD_ARGUMENTS", "Missing source folder or folder name.", null)
                            return@setMethodCallHandler
                        }
                        val createdUris = mutableListOf<Uri>()
                        try {
                            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                                throw IllegalStateException("Public folders require Android 10 or newer.")
                            }
                            val source = File(sourcePath)
                            if (!source.isDirectory) throw IllegalStateException("Source folder does not exist.")
                            val relativeRoot = Environment.DIRECTORY_MUSIC + "/RAVEN/" + folderName
                            var folderUri: Uri? = null
                            source.walkTopDown().forEach { file ->
                                if (!file.isFile) return@forEach
                                val relative = file.relativeTo(source).invariantSeparatorsPath
                                val mime = mimeTypeFor(file.name)
                                val values = ContentValues().apply {
                                    put(MediaStore.MediaColumns.DISPLAY_NAME, file.name)
                                    put(MediaStore.MediaColumns.MIME_TYPE, mime)
                                    put(MediaStore.MediaColumns.RELATIVE_PATH, relativeRoot)
                                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                                }
                                val collection = if (mime.startsWith("audio/")) {
                                    MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
                                } else {
                                    MediaStore.Files.getContentUri("external")
                                }
                                val uri = contentResolver.insert(collection, values)
                                    ?: throw IllegalStateException("Could not create a public entry for ${file.name}.")
                                createdUris.add(uri)
                                contentResolver.openOutputStream(uri)?.use { stream ->
                                    FileInputStream(file).use { input -> input.copyTo(stream) }
                                } ?: throw IllegalStateException("Could not open the public destination for ${file.name}.")
                                contentResolver.update(
                                    uri,
                                    ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                                    null,
                                    null,
                                )
                                if (folderUri == null) folderUri = uri
                            }
                            if (folderUri == null) {
                                throw IllegalStateException("The project folder contains no files to publish.")
                            }
                            result.success(folderUri.toString())
                        } catch (error: Exception) {
                            for (uri in createdUris) {
                                try { contentResolver.delete(uri, null, null) } catch (_: Exception) { }
                            }
                            result.error("PUBLISH_FAILED", error.message ?: "Could not publish the project folder.", null)
                        }
                    }
                    "deletePublishedFolder" -> {
                        // Removes every file RAVEN published for a project folder.
                        val rawUri = call.argument<String>("uri")
                        if (rawUri.isNullOrBlank() || !rawUri.startsWith("content://")) {
                            result.error("BAD_URI", "A managed MediaStore URI is required.", null)
                        } else {
                            try {
                                val uri = Uri.parse(rawUri)
                                val relativePath = contentResolver.query(
                                    uri,
                                    arrayOf(MediaStore.MediaColumns.RELATIVE_PATH),
                                    null,
                                    null,
                                    null,
                                )?.use { cursor ->
                                    if (cursor.moveToFirst()) cursor.getString(0) else null
                                }
                                if (relativePath.isNullOrBlank()) {
                                    result.success(false)
                                    return@setMethodCallHandler
                                }
                                val selection = "${MediaStore.MediaColumns.RELATIVE_PATH}=?"
                                val args = arrayOf(relativePath)
                                contentResolver.delete(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, selection, args)
                                contentResolver.delete(MediaStore.Files.getContentUri("external"), selection, args)
                                result.success(true)
                            } catch (error: Exception) {
                                result.error("DELETE_FAILED", error.message ?: "Could not remove the public folder.", null)
                            }
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

        // raven/storage_permission — manages MANAGE_EXTERNAL_STORAGE for Music/RAVEN/
        // access. Uses startActivityForResult / onActivityResult (not
        // onRequestPermissionsResult, which handles only POST_NOTIFICATIONS).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, storagePermissionChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasAllFilesAccess" -> result.success(hasAllFilesAccess())
                    "requestAllFilesAccess" -> {
                        if (hasAllFilesAccess()) {
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        if (allFilesAccessResult != null) {
                            result.error(
                                "PERMISSION_PENDING",
                                "An all-files-access request is already in progress.",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        allFilesAccessResult = result
                        // ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION opens the
                        // per-app settings page. Some OEMs omit it; fall back to the
                        // global MANAGE_ALL_FILES_ACCESS_PERMISSION screen.
                        val launched = tryLaunchAllFilesIntent(
                            Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                            Uri.parse("package:$packageName"),
                        ) || tryLaunchAllFilesIntent(
                            Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION,
                            null,
                        )
                        if (!launched) {
                            allFilesAccessResult = null
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasAllFilesAccess(): Boolean {
        // On Android 10 and below, WRITE_EXTERNAL_STORAGE + requestLegacyExternalStorage
        // grants the filesystem access we need. No special check required; return true
        // so the Dart side does not show a settings prompt to pre-R users.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return true
        return Environment.isExternalStorageManager()
    }

    private fun tryLaunchAllFilesIntent(action: String, data: Uri?): Boolean {
        return try {
            val intent = if (data != null) Intent(action, data) else Intent(action)
            startActivityForResult(intent, allFilesAccessRequestCode)
            true
        } catch (_: Exception) {
            false
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == allFilesAccessRequestCode) {
            val granted = hasAllFilesAccess()
            allFilesAccessResult?.success(granted)
            allFilesAccessResult = null
        }
    }

    private fun mimeTypeFor(fileName: String): String = when (fileName.substringAfterLast('.', "").lowercase()) {
        "wav" -> "audio/wav"
        "flac" -> "audio/flac"
        "mp3" -> "audio/mpeg"
        "m4a", "aac" -> "audio/mp4"
        "txt" -> "text/plain"
        "json" -> "application/json"
        "pdf" -> "application/pdf"
        "png" -> "image/png"
        "jpg", "jpeg" -> "image/jpeg"
        "webp" -> "image/webp"
        else -> "application/octet-stream"
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
