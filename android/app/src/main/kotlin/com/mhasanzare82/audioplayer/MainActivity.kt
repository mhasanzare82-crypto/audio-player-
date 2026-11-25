package com.mhasanzare82.audioplayer

import android.content.Intent
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.mhasanzare82.audioplayer/folder_library"
    private val requestFolder = 4107
    private var pendingFolderResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                    else -> result.notImplemented()
                }
            }
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
