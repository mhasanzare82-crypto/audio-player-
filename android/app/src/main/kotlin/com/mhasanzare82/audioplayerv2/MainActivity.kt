package com.mhasanzare82.audioplayerv2

import android.content.Intent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.pm.PackageManager
import android.os.Build
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.mhasanzare82.audioplayer/folder_library"
    private val requestFolder = 4107
    private var pendingFolderResult: MethodChannel.Result? = null
    private var scheduleChannel: MethodChannel? = null
    private var mixerChannel: MethodChannel? = null
    private var pendingMixerOpen = false
    private val mixerNotificationId = 7402
    private val mixerNotificationChannelId = "audio_mixer_controls"
    private val notificationPermissionRequest = 7403
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
        mixerChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.mhasanzare82.audioplayer/mixer_notification"
        )
        mixerChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "show" -> {
                    showMixerNotification()
                    result.success(true)
                }
                "hide" -> {
                    (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                        .cancel(mixerNotificationId)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        if (pendingMixerOpen || intent?.getBooleanExtra("open_mixer_panel", false) == true) {
            pendingMixerOpen = false
            intent?.removeExtra("open_mixer_panel")
            mixerChannel?.invokeMethod("openMixerPanel", null)
        }
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
                    else -> result.notImplemented()
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.getBooleanExtra("open_mixer_panel", false)) {
            intent.removeExtra("open_mixer_panel")
            dispatchMixerOpen()
        }
    }

    private fun dispatchMixerOpen() {
        val channel = mixerChannel
        if (channel == null) {
            pendingMixerOpen = true
        } else {
            channel.invokeMethod("openMixerPanel", null)
        }
    }

    private fun showMixerNotification() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                notificationPermissionRequest
            )
            return
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(
                    mixerNotificationChannelId,
                    "کنترل‌های پلیر صوتی",
                    NotificationManager.IMPORTANCE_LOW
                ).apply { description = "دسترسی سریع به کنترل‌های ترکیب و پخش صدا" }
            )
        }
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("open_mixer_panel", true)
        }
        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0
        val openPendingIntent = PendingIntent.getActivity(
            this, mixerNotificationId, openIntent, pendingFlags
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, mixerNotificationChannelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("پلیر صوتی فعال است")
            .setContentText("برای نمایش چهار کنترل صدا لمس کن")
            .setContentIntent(openPendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(
                android.R.drawable.ic_menu_manage,
                "بازکردن کنترل‌ها",
                openPendingIntent
            )
            .build()
        manager.notify(mixerNotificationId, notification)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == notificationPermissionRequest &&
            grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        ) {
            showMixerNotification()
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
