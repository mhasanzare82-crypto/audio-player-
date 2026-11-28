package com.mhasanzare82.audioplayerv2

import android.content.Intent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.os.Build
import android.net.Uri
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.mhasanzare82.audioplayer/folder_library"
    private val requestFolder = 4107
    private var pendingFolderResult: MethodChannel.Result? = null
    private var scheduleChannel: MethodChannel? = null
    private var stopReceiverRegistered = false
    private val scheduledStopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            scheduleChannel?.invokeMethod("scheduledStopFired", null)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        scheduleChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.mhasanzare82.audioplayer/scheduled_playback"
        )
        scheduleChannel?.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "scheduleStart" -> {
                        val path = call.argument<String>("path")
                        val title = call.argument<String>("title") ?: "فایل صوتی"
                        val at = call.argument<Number>("triggerAtMillis")?.toLong()
                        if (path.isNullOrBlank() || at == null || at <= System.currentTimeMillis()) {
                            result.error("INVALID_SCHEDULE", "زمان یا فایل انتخاب‌شده معتبر نیست.", null)
                        } else {
                            PlaybackAlarmReceiver.scheduleStart(this, path, title, at)
                            result.success(true)
                        }
                    }
                    "scheduleStop" -> {
                        val at = call.argument<Number>("triggerAtMillis")?.toLong()
                        if (at == null || at <= System.currentTimeMillis()) {
                            result.error("INVALID_SCHEDULE", "زمان توقف معتبر نیست.", null)
                        } else {
                            PlaybackAlarmReceiver.scheduleStop(this, at)
                            result.success(true)
                        }
                    }
                    "cancelStart" -> { PlaybackAlarmReceiver.cancelStart(this); result.success(true) }
                    "cancelStop" -> { PlaybackAlarmReceiver.cancelStop(this); result.success(true) }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("SCHEDULE_FAILED", error.message, null)
            }
        }
        if (!stopReceiverRegistered) {
            val filter = IntentFilter(PlaybackAlarmReceiver.ACTION_STOP_FIRED)
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(scheduledStopReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                registerReceiver(scheduledStopReceiver, filter)
            }
            stopReceiverRegistered = true
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickFolder" -> pickFolder(result)
                    "scanFolders" -> {
                        val uris = call.argument<List<String>>("uris") ?: emptyList()
                        try {
                            result.success(scanFolders(uris))
                        } catch (error: Exception) {
                            result.error("SCAN_FAILED", error.message, null)
                        }
                    }
                    "renameItem" -> {
                        val path = call.argument<String>("path")
                        val requestedName = call.argument<String>("newName")
                        if (path.isNullOrBlank() || requestedName.isNullOrBlank()) {
                            result.error("INVALID_RENAME", "مسیر یا نام جدید معتبر نیست.", null)
                        } else {
                            try {
                                result.success(renameItem(path, requestedName))
                            } catch (error: Exception) {
                                result.error("RENAME_FAILED", error.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        if (stopReceiverRegistered) {
            unregisterReceiver(scheduledStopReceiver)
            stopReceiverRegistered = false
        }
        super.onDestroy()
    }

    private fun pickFolder(result: MethodChannel.Result) {
        if (pendingFolderResult != null) {
            result.error("PICK_IN_PROGRESS", "A folder selection is already open.", null)
            return
        }
        pendingFolderResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
        }
        try {
            startActivityForResult(intent, requestFolder)
        } catch (error: Exception) {
            pendingFolderResult = null
            result.error("PICK_FAILED", error.message, null)
        }
    }

    @Deprecated("Deprecated in Android API; required for FlutterActivity result forwarding")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != requestFolder) return

        val callback = pendingFolderResult
        pendingFolderResult = null
        if (callback == null) return
        if (resultCode != RESULT_OK || data?.data == null) {
            callback.success(null)
            return
        }

        val treeUri = data.data!!
        val grantedFlags = data.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION
        try {
            contentResolver.takePersistableUriPermission(treeUri, grantedFlags)
            val folder = DocumentFile.fromTreeUri(this, treeUri)
            callback.success(
                mapOf(
                    "uri" to treeUri.toString(),
                    "name" to (folder?.name ?: "پوشه انتخاب‌شده")
                )
            )
        } catch (error: Exception) {
            callback.error("PERMISSION_FAILED", error.message, null)
        }
    }

    private fun renameItem(path: String, requestedName: String): Map<String, String> {
        val trimmed = requestedName.trim()
        require(trimmed.isNotEmpty()) { "نام فایل نمی‌تواند خالی باشد." }
        require(!trimmed.contains('/') && !trimmed.contains('\\')) {
            "نام فایل نباید شامل جداکننده مسیر باشد."
        }

        val sourceUri = Uri.parse(path)
        if (sourceUri.scheme == "content") {
            val documentUri = if (DocumentsContract.isTreeUri(sourceUri)) {
                DocumentsContract.buildDocumentUriUsingTree(
                    sourceUri,
                    DocumentsContract.getTreeDocumentId(sourceUri)
                )
            } else {
                sourceUri
            }
            val currentName = queryDisplayName(documentUri)
                ?: throw IllegalStateException("نام فعلی فایل از ارائه‌دهنده دریافت نشد.")
            val extension = currentName.substringAfterLast('.', "").let {
                if (currentName.contains('.') && it.isNotEmpty()) ".$it" else ""
            }
            val finalName = if (extension.isNotEmpty() &&
                !trimmed.endsWith(extension, ignoreCase = true)
            ) "$trimmed$extension" else trimmed
            val renamedUri = DocumentsContract.renameDocument(
                contentResolver,
                documentUri,
                finalName
            ) ?: throw IllegalStateException("مدیریت فایل اجازه تغییر نام این مورد را نداد.")
            return mapOf("path" to renamedUri.toString(), "name" to finalName)
        }

        val source = java.io.File(path)
        if (!source.exists()) throw IllegalStateException("فایل اصلی پیدا نشد.")
        val currentName = source.name
        val extension = currentName.substringAfterLast('.', "").let {
            if (currentName.contains('.') && it.isNotEmpty()) ".$it" else ""
        }
        val finalName = if (extension.isNotEmpty() &&
            !trimmed.endsWith(extension, ignoreCase = true)
        ) "$trimmed$extension" else trimmed
        val destination = java.io.File(source.parentFile, finalName)
        if (destination.exists()) throw IllegalStateException("فایلی با این نام از قبل وجود دارد.")
        if (!source.renameTo(destination)) {
            throw IllegalStateException("سیستم‌عامل نتوانست نام فایل را تغییر دهد.")
        }
        return mapOf("path" to destination.absolutePath, "name" to finalName)
    }

    private fun queryDisplayName(uri: Uri): String? {
        contentResolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                return cursor.getString(0)
            }
        }
        return null
    }

    private fun scanFolders(folderUris: List<String>): List<Map<String, String>> {
        val found = linkedMapOf<String, Map<String, String>>()
        folderUris.forEach { value ->
            val root = DocumentFile.fromTreeUri(this, Uri.parse(value))
                ?: return@forEach
            scanDocument(root, found)
        }
        return found.values.toList()
    }

    private fun scanDocument(
        document: DocumentFile,
        found: MutableMap<String, Map<String, String>>
    ) {
        if (document.isDirectory) {
            document.listFiles().forEach { child -> scanDocument(child, found) }
            return
        }
        if (!document.isFile) return
        val name = document.name ?: return
        val extension = name.substringAfterLast('.', "").lowercase()
        if (extension !in setOf("mp3", "wav", "flac", "aac", "m4a")) return
        val uri = document.uri.toString()
        found[uri] = mapOf("uri" to uri, "name" to name)
    }
}
