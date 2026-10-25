package com.opensink.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "opensink/notifications"
    private val notificationChannelId = "opensink_messages"
    private val notificationIds = mutableMapOf<String, Int>()
    private val notificationPermissionRequest = 1001

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ensureChannel()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "show" -> {
                        val id = call.argument<String>("id")
                        val title = call.argument<String>("title") ?: "OpenSink"
                        val body = call.argument<String>("body") ?: ""
                        if (id == null || id.isEmpty()) {
                            result.success(false)
                        } else {
                            result.success(showNotification(id, title, body))
                        }
                    }
                    "cancel" -> {
                        val id = call.argument<String>("id")
                        if (id != null) cancelNotification(id)
                        result.success(null)
                    }
                    "cancelAll" -> {
                        notificationManager().cancelAll()
                        notificationIds.clear()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun notificationManager(): NotificationManager =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = notificationManager()
        if (manager.getNotificationChannel(notificationChannelId) != null) return
        val channel = NotificationChannel(
            notificationChannelId,
            "Сообщения",
            NotificationManager.IMPORTANCE_DEFAULT,
        )
        channel.description = "Новые сообщения в группах OpenSink"
        manager.createNotificationChannel(channel)
    }

    private fun canPostNotifications(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun showNotification(id: String, title: String, body: String): Boolean {
        if (!canPostNotifications()) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                requestPermissions(
                    arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                    notificationPermissionRequest,
                )
            }
            return false
        }
        ensureChannel()
        val notificationId = notificationIds.getOrPut(id) { id.hashCode() }
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            notificationId,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, notificationChannelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()
        notificationManager().notify(notificationId, notification)
        return true
    }

    private fun cancelNotification(id: String) {
        val notificationId = notificationIds.remove(id) ?: return
        notificationManager().cancel(notificationId)
    }
}
