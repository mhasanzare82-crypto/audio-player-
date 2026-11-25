package com.mhasanzare82.audioplayer

import android.app.*
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

class ScheduledPlaybackService : Service() {
    private var player: MediaPlayer? = null

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "پخش زمان‌بندی‌شده", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, notification())
        when (intent?.action) {
            ACTION_START -> play(
                intent.getStringExtra(PlaybackAlarmReceiver.EXTRA_PATH),
                intent.getStringExtra(PlaybackAlarmReceiver.EXTRA_TITLE)
            )
            ACTION_STOP -> finishService(startId)
            else -> finishService(startId)
        }
        return START_NOT_STICKY
    }

    private fun play(path: String?, title: String?) {
        if (path.isNullOrBlank()) { finishService(0); return }
        stopPlayer()
        try {
            val media = MediaPlayer()
            player = media
            media.setWakeMode(this, PowerManager.PARTIAL_WAKE_LOCK)
            media.setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build())
            media.setOnPreparedListener { if (player === it) it.start() }
            media.setOnCompletionListener { finishService(0) }
            media.setOnErrorListener { _, _, _ -> finishService(0); true }
            val uri = Uri.parse(path)
            if (uri.scheme == "content" || uri.scheme == "file") media.setDataSource(this, uri)
            else media.setDataSource(path)
            getSystemService(NotificationManager::class.java)
                .notify(NOTIFICATION_ID, notification(title ?: "پخش زمان‌بندی‌شده"))
            media.prepareAsync()
        } catch (_: Exception) {
            finishService(0)
        }
    }

    private fun stopPlayer() {
        val old = player
        player = null
        try {
            old?.setOnPreparedListener(null)
            old?.setOnCompletionListener(null)
            old?.setOnErrorListener(null)
            if (old?.isPlaying == true) old.stop()
        } catch (_: Exception) {
        }
        try { old?.release() } catch (_: Exception) {}
    }

    private fun finishService(startId: Int) {
        stopPlayer()
        stopForeground(STOP_FOREGROUND_REMOVE)
        if (startId > 0) stopSelf(startId) else stopSelf()
    }

    private fun notification(title: String = "پخش زمان‌بندی‌شده"): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pending = launch?.let {
            PendingIntent.getActivity(this, 7201, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title)
            .setContentText("پخش صوت طبق زمان‌بندی")
            .setContentIntent(pending)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    override fun onDestroy() { stopPlayer(); super.onDestroy() }
    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        const val ACTION_START = "com.mhasanzare82.audioplayer.SERVICE_START"
        const val ACTION_STOP = "com.mhasanzare82.audioplayer.SERVICE_STOP"
        private const val CHANNEL_ID = "scheduled_audio_playback"
        private const val NOTIFICATION_ID = 7202
    }
}
