package com.linknest.linknest

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

class GuestTransferForegroundService : Service() {
    companion object {
        private const val TAG = "LinkNest"
        private const val CHANNEL_ID = "linknest_guest_transfer"
        private const val NOTIFICATION_ID = 4102
        private const val ACTION_START = "com.linknest.linknest.action.START_GUEST_TRANSFER"
        private const val EXTRA_DIRECTION = "direction"
        private const val EXTRA_FILE_NAME = "fileName"
        private const val EXTRA_TOTAL_BYTES = "totalBytes"

        @Volatile
        private var running = false

        fun start(
            context: Context,
            direction: String,
            fileName: String,
            totalBytes: Long,
        ) {
            val intent = Intent(context, GuestTransferForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_DIRECTION, direction)
                putExtra(EXTRA_FILE_NAME, fileName)
                putExtra(EXTRA_TOTAL_BYTES, totalBytes)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun update(
            context: Context,
            direction: String,
            fileName: String,
            completedBytes: Long,
            totalBytes: Long,
        ) {
            if (!running) return
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.notify(
                NOTIFICATION_ID,
                buildNotification(
                    context,
                    direction,
                    fileName,
                    completedBytes,
                    totalBytes,
                ),
            )
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, GuestTransferForegroundService::class.java))
        }

        private fun buildNotification(
            context: Context,
            direction: String,
            fileName: String,
            completedBytes: Long,
            totalBytes: Long,
        ): Notification {
            val openApp = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pendingIntent = PendingIntent.getActivity(
                context,
                0,
                openApp,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val title = if (direction == "download") {
                "LinkNest 正在保存文件"
            } else {
                "LinkNest 正在上传文件"
            }
            val safeName = fileName.trim().ifEmpty { "媒体文件" }
            val percent = if (totalBytes > 0) {
                ((completedBytes.coerceAtLeast(0) * 100) / totalBytes)
                    .coerceIn(0, 100)
                    .toInt()
            } else {
                0
            }
            val text = if (totalBytes > 0) "$safeName · $percent%" else safeName
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            builder
                .setSmallIcon(R.drawable.ic_stat_linknest)
                .setContentTitle(title)
                .setContentText(text)
                .setContentIntent(pendingIntent)
                .setCategory(Notification.CATEGORY_PROGRESS)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
            if (totalBytes > 0) {
                builder.setProgress(100, percent, false)
            } else {
                builder.setProgress(0, 0, true)
            }
            return builder.build()
        }
    }

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "文件传输",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "LinkNest 正在与局域网设备传输文件"
                    setShowBadge(false)
                },
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val direction = intent?.getStringExtra(EXTRA_DIRECTION) ?: "upload"
        val fileName = intent?.getStringExtra(EXTRA_FILE_NAME).orEmpty()
        val totalBytes = intent?.getLongExtra(EXTRA_TOTAL_BYTES, 0) ?: 0
        val notification = buildNotification(
            this,
            direction,
            fileName,
            0,
            totalBytes,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        running = true
        Log.d(TAG, "访客文件传输前台服务已启动 direction=$direction")
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.d(TAG, "访客文件传输前台服务任务已移除")
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        running = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        Log.d(TAG, "访客文件传输前台服务已停止")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
