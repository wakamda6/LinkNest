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

class HostForegroundService : Service() {
    companion object {
        private const val TAG = "LinkNest"
        private const val CHANNEL_ID = "linknest_host_sharing"
        private const val NOTIFICATION_ID = 4101
        private const val ACTION_START = "com.linknest.linknest.action.START_HOST"
        private const val EXTRA_SPACE_NAME = "spaceName"
        private const val EXTRA_ONLINE_COUNT = "onlineCount"

        @Volatile
        private var running = false

        fun start(context: Context, spaceName: String, onlineCount: Int) {
            val intent = Intent(context, HostForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_SPACE_NAME, spaceName)
                putExtra(EXTRA_ONLINE_COUNT, onlineCount)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun update(context: Context, spaceName: String, onlineCount: Int) {
            if (!running) return
            try {
                val manager = context.getSystemService(NotificationManager::class.java)
                manager.notify(
                    NOTIFICATION_ID,
                    buildNotification(context, spaceName, onlineCount),
                )
            } catch (error: SecurityException) {
                Log.d(TAG, "缺少权限，无法更新发起者通知", error)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, HostForegroundService::class.java))
        }

        private fun buildNotification(
            context: Context,
            spaceName: String,
            onlineCount: Int,
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
            val displayName = spaceName.trim().ifEmpty { "未命名空间" }
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            return builder
                .setSmallIcon(R.drawable.ic_stat_linknest)
                .setContentTitle("LinkNest 空间正在共享")
                .setContentText("$displayName · $onlineCount 位访客在线")
                .setContentIntent(pendingIntent)
                .setCategory(Notification.CATEGORY_SERVICE)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .build()
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val spaceName = intent?.getStringExtra(EXTRA_SPACE_NAME).orEmpty()
        val onlineCount = intent?.getIntExtra(EXTRA_ONLINE_COUNT, 0) ?: 0
        val notification = buildNotification(this, spaceName, onlineCount)
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
        Log.d(TAG, "发起者共享前台服务已启动 onlineCount=$onlineCount")
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.d(TAG, "发起者共享前台服务任务已移除")
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
        Log.d(TAG, "发起者共享前台服务已停止")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "空间共享",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "LinkNest 正在提供局域网文件共享"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }
}
