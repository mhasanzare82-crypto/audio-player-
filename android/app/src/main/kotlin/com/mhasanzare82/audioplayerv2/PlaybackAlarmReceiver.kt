package com.mhasanzare82.audioplayerv2

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

class PlaybackAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_START -> {
                val serviceIntent = Intent(context, ScheduledPlaybackService::class.java).apply {
                    action = ScheduledPlaybackService.ACTION_START
                    putExtra(EXTRA_PATH, intent.getStringExtra(EXTRA_PATH))
                    putExtra(EXTRA_TITLE, intent.getStringExtra(EXTRA_TITLE))
                }
                startServiceCompat(context, serviceIntent)
            }
            ACTION_STOP -> {
                context.sendBroadcast(Intent(ACTION_STOP_FIRED).setPackage(context.packageName))
                val serviceIntent = Intent(context, ScheduledPlaybackService::class.java).apply {
                    action = ScheduledPlaybackService.ACTION_STOP
                }
                startServiceCompat(context, serviceIntent)
            }
        }
    }

    companion object {
        const val ACTION_START = "com.mhasanzare82.audioplayer.ALARM_START"
        const val ACTION_STOP = "com.mhasanzare82.audioplayer.ALARM_STOP"
        const val ACTION_STOP_FIRED = "com.mhasanzare82.audioplayer.SCHEDULED_STOP_FIRED"
        const val EXTRA_PATH = "audio_path"
        const val EXTRA_TITLE = "audio_title"
        private const val START_REQUEST = 7101
        private const val STOP_REQUEST = 7102

        fun scheduleStart(context: Context, path: String, title: String, atMillis: Long) {
            val intent = Intent(context, PlaybackAlarmReceiver::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_PATH, path)
                putExtra(EXTRA_TITLE, title)
            }
            schedule(context, START_REQUEST, intent, atMillis)
        }

        fun scheduleStop(context: Context, atMillis: Long) {
            val intent = Intent(context, PlaybackAlarmReceiver::class.java).apply {
                action = ACTION_STOP
            }
            schedule(context, STOP_REQUEST, intent, atMillis)
        }

        fun cancelStart(context: Context) = cancel(context, START_REQUEST, ACTION_START)
        fun cancelStop(context: Context) = cancel(context, STOP_REQUEST, ACTION_STOP)

        private fun schedule(context: Context, requestCode: Int, intent: Intent, atMillis: Long) {
            val pending = PendingIntent.getBroadcast(
                context, requestCode, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val alarm = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && alarm.canScheduleExactAlarms()) {
                alarm.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pending)
            } else {
                alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pending)
            }
        }

        private fun cancel(context: Context, requestCode: Int, action: String) {
            val intent = Intent(context, PlaybackAlarmReceiver::class.java).apply { this.action = action }
            val pending = PendingIntent.getBroadcast(
                context, requestCode, intent,
                PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE
            ) ?: return
            val alarm = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            alarm.cancel(pending)
            pending.cancel()
        }

        private fun startServiceCompat(context: Context, intent: Intent) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent)
            else context.startService(intent)
        }
    }
}
